require "uri"
require "../codec/http1"
require "../codec/body"
require "../codec/content_decode"
require "../sink"
require "../head_rewriter"
require "../../interceptor"
require "../../host_overrides"
require "../prefix_io"
require "../socket_tuning"
require "../h2/relay"
require "../connect"
require "../upstream"
require "../pump"
require "../ws/relay"
require "../../flow_mapper"
require "./self_page"

module Gori::Proxy
  # Handles one client connection over an `IO` (a plaintext TCPSocket, or — after
  # the CONNECT/TLS handoff — a decrypted TLS socket; the same loop serves both,
  # which is why it is written against `IO`). Reads requests in a keep-alive
  # loop, forwards them byte-faithfully, captures the request/response pair, and
  # streams the response back.
  class ClientConn
    # Max consecutive interim 1xx responses to forward before giving up — a guard
    # against a hostile upstream streaming an unbounded run of body-less 103s.
    MAX_INTERIM = 64

    # `fixed_host`/`fixed_port` pin all requests to one origin (post-CONNECT TLS
    # tunnel); when nil the upstream is resolved per request from the target /
    # Host header (plaintext forward proxy). `tls_upstream` wraps the origin
    # connection in TLS.
    def initialize(@io : IO, @scheme : String, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @fixed_host : String? = nil, @fixed_port : Int32 = 0,
                   @tls_upstream : Bool = false, @verify_upstream : Bool = true,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   @self_addr : {String, Int32}? = nil)
      # Per-connection upstream reuse (see `acquire_upstream`). One live origin
      # connection kept across this client's keep-alive requests.
      @upstream = nil.as(IO?)
      @up_host = nil.as(String?)
      @up_port = 0
      # One 64 KiB copy buffer reused across every request AND response body forwarded on
      # this connection (see `copy_buf`), so a keep-alive stream stops churning a large-object
      # allocation per body. Lazily allocated on the first body copy.
      @copy_buf = nil.as(Bytes?)
    end

    # The connection-lifetime scratch buffer for body forwarding, allocated on first use.
    # Safe to share across the request and response streams because they run sequentially on
    # this one fiber (the request body is fully forwarded before the response head is read).
    private def copy_buf : Bytes
      @copy_buf ||= Bytes.new(Codec::Body::BUFSIZE)
    end

    def run : Nil
      loop do
        # Re-arm the client read/write timeout at the START of every keep-alive request, so a
        # prior request that RELAXED the socket for a streamed (SSE/chunked) response then kept
        # the connection alive can't carry that relaxed (untimed) state into the next request.
        SocketTuning.arm(@io, SocketTuning::CLIENT_IO_TIMEOUT)
        break unless handle_request
      end
    rescue
      # any IO error (reset, timeout, broken pipe) ends the connection
    ensure
      release_upstream
      @io.close rescue nil
    end

    # Per-connection upstream keep-alive reuse. Within one client connection —
    # especially a TLS-MITM tunnel pinned to a single origin (`@fixed_host`),
    # where EVERY request would otherwise pay a fresh TCP+TLS handshake to the
    # same server — we keep ONE upstream connection open and reuse it across the
    # client's keep-alive requests. Reuse is gated on the origin honouring
    # keep-alive (decided at the end of `handle_response`: complete body, not
    # close-delimited, no `Connection: close`); a connection that goes stale
    # while idle (the origin's own keep-alive timeout fired) is detected as an
    # EOF on the response head and transparently retried for body-less requests.
    # Returns {connection, reused?} — `reused` tells the caller a stale EOF is
    # worth one redial+resend.
    private def acquire_upstream(host : String, port : Int32) : {IO?, Bool}
      if (up = @upstream) && @up_host == host && @up_port == port
        return {up, true}
      end
      release_upstream # different origin (forward-proxy) or none yet — dial fresh
      up = open_upstream(host, port)
      if up
        @upstream = up
        @up_host = host
        @up_port = port
      end
      {up, false}
    end

    private def release_upstream : Nil
      @upstream.try(&.close) rescue nil
      @upstream = nil
      @up_host = nil
      @up_port = 0
    end

    # Returns true to keep the connection alive for another request.
    private def handle_request : Bool
      # The client request head is the slowloris surface: bound total head-assembly time after
      # its first byte (a drip-feed that a per-read timeout can't catch). The first-byte (idle
      # keep-alive) wait stays bounded by the baseline timeout armed in `run`.
      head = Codec::Http1.read_head(@io,
        deadline: SocketTuning::HEAD_DEADLINE, timeout_sock: SocketTuning.underlying_socket(@io))
      return false if head.nil? # client closed / keep-alive idle end

      req = Codec::Http1.parse_request_head(head)
      return handle_connect(req) if req.method.compare("CONNECT", case_insensitive: true) == 0

      started = Time.instant
      created_at = now_us
      # A client-supplied absolute-form target with a bad/oversized port makes URI.parse
      # raise; keep the malformed attempt visible in History instead of letting it unwind
      # to run's blanket rescue (which would silently drop the flow and kill the connection).
      begin
        host, port, scheme, forward_head = resolve_forward(req)
      rescue ex : URI::Error | OverflowError
        record_error(req, @scheme, req.host? || "", 0, created_at, "malformed absolute-form target: #{ex.message}")
        write_gateway_error
        return false
      end

      # A browser pointed STRAIGHT at the listener (origin-form request to gori's own
      # address, no proxy configured) gets the self-serve welcome + CA-download page
      # instead of the 502 self-loop refusal below — but only for a plain GET/HEAD and
      # only while the setting is on. Origin-form only: an absolute-form request (a
      # proxy-configured browser) that targets self is a genuine loop and still 502s.
      # Not recorded as a flow — it's a local UI hit, not proxied traffic.
      if (sa = @self_addr) && (tls = @tls) && tls.serve_landing? &&
         origin_form?(req) && get_or_head?(req) && Upstream.addresses_self?(host, port, sa)
        serve_self_page(req, tls, sa)
        return false
      end

      # Refuse to forward a request whose (override-resolved) target is gori's own
      # listener — otherwise gori dials itself, accepts that as a new client, and
      # loops forever. Record it as a visible error instead.
      if (sa = @self_addr) && Upstream.loops_to_self?(host, port, @host_overrides, sa)
        record_error(req, scheme, host, port, created_at, "refusing to proxy to self (loop): #{host}:#{port}")
        write_gateway_error
        return false
      end

      # Match&Replace (request head): rewrite the bytes sent upstream. Only when
      # a rule actually changes something do we capture the modified bytes (the
      # user's chosen semantics); otherwise the original client bytes are kept
      # byte-exact (P7). Body framing always uses the original request.
      sent_req = req
      sent_head = forward_head
      if rw = @rewriter
        rewritten = rw.rewrite_request(forward_head)
        if rewritten != forward_head
          sent_head = rewritten
          sent_req = Codec::Http1.parse_request_head(rewritten)
        end
      end

      # Sandbox: the hard scope gate. When enabled, ONLY requests the scope ALLOWS reach
      # upstream — everything else, including ALL traffic when no include rule is set, is
      # blocked HERE, before we touch (or even dial) the origin. Keyed on the ACTUALLY-SENT
      # target (post Match&Replace), matching the intercept gate + the captured History row.
      # We record the attempt as an aborted flow (visible in History) and answer the client
      # a distinct 403 so a sandbox block never reads like an upstream failure. The scope
      # URL is built lazily inside the interceptor, only while the sandbox is on.
      if (ic = @interceptor) && ic.sandbox_blocks?(scheme, host, sent_req.target)
        record_blocked_request(sent_req, scheme, host, port, created_at)
        write_sandbox_block
        return false
      end

      # Ambiguous/illegal request framing (CL+TE, non-final chunked, bad
      # Content-Length) means we can't determine the body boundary to forward it
      # faithfully — the codec raises to force a close. But the attempt must stay
      # VISIBLE in History (this smuggling-shape traffic is exactly what a pentester
      # wants to see); previously the raise unwound to `run`'s blanket rescue and no
      # flow was recorded at all. Record an error flow, then close.
      begin
        req_framing, req_len = Codec::Body.request_framing(req)
      rescue ex : Gori::Error
        record_error(sent_req, scheme, host, port, created_at, "request framing rejected: #{ex.message}")
        return false
      end

      # Intercept (request): hold only when enabled AND in scope. Holding buffers
      # the full body (vs streaming) so the human can see/edit it; the non-hold
      # path keeps zero-buffer streaming (P6). The gate builds the scope URL lazily
      # (scheme || '://' || host || <stored target>, matching the Scope SQL filter over
      # the SAME captured target) only when intercept + Scope are both on, so the common
      # capture-only path spends nothing here.
      if (ic = @interceptor) && ic.intercepts_request?(
           method: sent_req.method, host: host, target: sent_req.target, scheme: scheme)
        return handle_held_request(ic, req, sent_req, sent_head, host, port, scheme,
          created_at, started, req_framing, req_len)
      end

      # Match&Replace (request body): a body rule can't stream — it must buffer the
      # whole body to rewrite it and re-frame the head (Content-Length). Only pay this
      # when a request-body rule is live AND there's a body to rewrite; the common path
      # (no body rule) falls straight through to zero-buffer streaming below (P6). A body
      # whose declared length exceeds MAX_REWRITE_BODY is left byte-exact (see the constant)
      # so a huge upload can't grow the proxy heap while a rule is on.
      if (rw = @rewriter) && rewrite_request_body?(rw, req_framing, req_len)
        return forward_request_rewriting_body(rw, req, sent_req, sent_head, host, port,
          scheme, created_at, started, req_framing, req_len)
      end

      # Non-hold path: stream the request body byte-for-byte (P6), unchanged.
      # Repeater-safety keys on the ACTUALLY-SENT method (sent_req): an M&R rule that rewrites
      # the request line GET→POST must not leave a non-idempotent request marked retryable.
      retryable = retryable_request?(sent_req, req_framing.none?)
      req_capture = Codec::CaptureBuffer.new(Settings.capture_max, capture_hint(req_framing, req_len))
      req_complete = true
      upstream, reused, sent = acquire_and_send(host, port, retryable) do |up|
        up.write(sent_head)
        req_complete = Codec::Body.stream(@io, up, req_framing, req_len, req_capture, copy_buf)
        up.flush
        true
      end
      unless upstream && sent
        release_upstream
        record_error(req, scheme, host, port, created_at, "upstream connect/write failed: #{host}:#{port}")
        write_gateway_error
        return false
      end
      req_body = req_framing.none? ? nil : req_capture.to_slice
      flow_id = @sink.on_request(FlowMapper.request(sent_req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: req_body,
        body_truncated: req_capture.truncated?, body_size: req_capture.total))
      unless req_complete # client cut the request body short — don't reuse the connection
        release_upstream
        @sink.on_response(FlowMapper.error_response(flow_id, "client truncated request body"))
        return false
      end
      handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: retryable, sent_req: sent_req)
    end

    # The intercept-hold request path: buffer the body, let the human edit/drop
    # it, then forward via the reused upstream (with the same stale-reuse retry).
    private def handle_held_request(ic : Gori::Interceptor, req : Codec::RawRequest,
                                    sent_req : Codec::RawRequest, sent_head : Bytes,
                                    host : String, port : Int32, scheme : String,
                                    created_at : Int64, started : Time::Instant,
                                    req_framing : Codec::BodyFraming, req_len : Int64) : Bool
      buffered, body_complete = Codec::Body.read_complete(@io, req_framing, req_len)
      unless body_complete
        # The client cut its request body short — there's nothing whole to hold/forward, and
        # forwarding a short body under the original Content-Length would desync the upstream
        # (mirrors the non-hold path's req_complete guard). Record + close instead of holding.
        record_error(sent_req, scheme, host, port, created_at, "client truncated request body")
        return false
      end
      # Match&Replace (request body) BEFORE the human sees it — mirroring the head, which is
      # already M&R'd into `sent_head`. A body rule re-frames to Content-Length, so re-parse
      # the (possibly rewritten) head for the hold metadata + capture.
      if (rw = @rewriter) && rw.rewrites_request_body?
        sent_head, buffered = apply_body_rewrite(sent_head, buffered, req_framing) { |e| rw.rewrite_request_body(e) }
        sent_req = Codec::Http1.parse_request_head(sent_head)
      end
      decision = ic.hold_request(build_message(sent_head, buffered),
        method: sent_req.method, target: sent_req.target,
        host: host, port: port, scheme: scheme)
      if decision.action.drop?
        record_dropped_request(sent_req, scheme, host, port, created_at, buffered)
        write_intercept_drop
        return false
      end
      # forward the decision bytes BYTE-EXACT (P7): re-parse the sent head for capture.
      # The intercept editor owns the "update Content-Length" decision (it knows what
      # was edited) — see InterceptView#forward_bytes; the proxy must not rewrite bytes
      # the human chose to send (e.g. a deliberately CL-mismatched smuggling probe).
      sent_head, edited_body = split_message(decision.bytes)
      sent_req = Codec::Http1.parse_request_head(sent_head)
      # Key repeater-safety on the EDITED request: if the human changed the method (e.g.
      # GET→POST), retryability must follow the method actually being sent, not the
      # original — else a now-non-idempotent request could be replayed on a stale-conn retry.
      retryable = retryable_request?(sent_req, edited_body.nil? || edited_body.empty?)
      upstream, reused, sent = acquire_and_send(host, port, retryable) { |up| write_request(up, sent_head, edited_body) }
      unless upstream && sent
        release_upstream
        record_error(sent_req, scheme, host, port, created_at, "upstream connect/write failed: #{host}:#{port}")
        write_gateway_error
        return false
      end
      stored, trunc, size = capped(edited_body)
      flow_id = @sink.on_request(FlowMapper.request(sent_req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size))
      handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: retryable, sent_req: sent_req)
    end

    # The Match&Replace request-body path (no intercept): buffer the whole body,
    # rewrite the entity, re-frame the head (Content-Length), and forward. A body was
    # sent, so the request is never auto-retryable. Structurally this is the hold path
    # minus the human — same buffer + capped-capture + reused-upstream forwarding.
    private def forward_request_rewriting_body(rw : HeadRewriter, req : Codec::RawRequest,
                                               sent_req : Codec::RawRequest, sent_head : Bytes,
                                               host : String, port : Int32, scheme : String,
                                               created_at : Int64, started : Time::Instant,
                                               req_framing : Codec::BodyFraming, req_len : Int64) : Bool
      buffered, body_complete = Codec::Body.read_complete(@io, req_framing, req_len)
      unless body_complete
        # Client cut the body short — forwarding it under the original length would desync
        # the upstream (mirrors the streaming path's req_complete guard). Record + close.
        record_error(sent_req, scheme, host, port, created_at, "client truncated request body")
        return false
      end
      sent_head, fwd_body = apply_body_rewrite(sent_head, buffered, req_framing) { |e| rw.rewrite_request_body(e) }
      sent_req = Codec::Http1.parse_request_head(sent_head) # head may have been re-framed
      upstream, reused, sent = acquire_and_send(host, port, false) { |up| write_request(up, sent_head, fwd_body) }
      unless upstream && sent
        release_upstream
        record_error(sent_req, scheme, host, port, created_at, "upstream connect/write failed: #{host}:#{port}")
        write_gateway_error
        return false
      end
      stored, trunc, size = capped(fwd_body)
      flow_id = @sink.on_request(FlowMapper.request(sent_req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size))
      handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: false, sent_req: sent_req)
    end

    # Acquires the (reused-or-fresh) upstream and runs `send` on it. If a REUSED
    # connection's send fails and the request is REPLAYABLE (a safe, body-less
    # method — nothing consumed from the client, harmless to resend), redials a
    # fresh origin and retries once — this is what makes per-connection keep-alive
    # reuse safe against a server that closed an idle connection. A non-replayable
    # request (any body, or a mutating method) is never auto-resent — the caller
    # fails it so the client decides. Returns {upstream, reused?, ok}.
    private def acquire_and_send(host : String, port : Int32, retryable : Bool, & : IO -> Bool) : {IO?, Bool, Bool}
      upstream, reused = acquire_upstream(host, port)
      return {nil, false, false} unless upstream
      # Re-arm the per-request upstream timeout: a REUSED socket may carry a relaxed (untimed)
      # state from a prior streamed (SSE/chunked) response. A freshly dialed one already has it
      # (direct_dial), so this is an idempotent set there.
      SocketTuning.arm(upstream, Settings.io_timeout)
      ok = send_guard { yield upstream }
      if !ok && reused && retryable
        release_upstream
        upstream, reused = acquire_upstream(host, port)
        SocketTuning.arm(upstream, Settings.io_timeout) if upstream
        ok = upstream ? send_guard { yield upstream } : false
      end
      {upstream, reused, ok}
    end

    private def send_guard(& : -> Bool) : Bool
      yield
    rescue
      false # write to a dead/half-closed reused socket, or client read error mid-body
    end

    # Writes a request head (+ optional body) to the upstream and flushes.
    # Returns false on any IO error (a dead/half-closed reused connection), so
    # the caller can decide whether a stale reuse is worth a redial+resend.
    private def write_request(upstream : IO, head : Bytes, body : Bytes?) : Bool
      upstream.write(head)
      upstream.write(body) if body && !body.empty?
      upstream.flush
      true
    rescue
      false
    end

    # Reads, (optionally holds), forwards, and captures the response. `req` is the
    # ORIGINAL request (framing/keep-alive/method come from it). Returns true to
    # keep the connection alive.
    private def handle_response(upstream : IO, req : Codec::RawRequest, flow_id : Int64,
                                started : Time::Instant, host : String, port : Int32, scheme : String,
                                *, reused : Bool, sent_head : Bytes, can_retry : Bool,
                                sent_req : Codec::RawRequest) : Bool
      resp_head, upstream = read_response_head(upstream, host, port, reused, sent_head, can_retry)
      if resp_head.nil?
        @sink.on_response(FlowMapper.error_response(flow_id, "no response from upstream"))
        release_upstream
        return false
      end
      resp = Codec::Http1.parse_response_head(resp_head)

      final = skip_interim_responses(upstream, req, flow_id, resp_head, resp)
      return false unless final
      resp_head, resp = final
      ttfb = (Time.instant - started).total_microseconds.to_i64

      # Match&Replace (response head). Framing/keep-alive/upgrade stay on the
      # ORIGINAL response so the upstream body is read correctly.
      sent_resp_head, sent_resp = apply_response_rewrite(resp_head, resp)
      # Body framing must reflect the method the ORIGIN actually received (HEAD/CONNECT
      # are bodyless per RFC 7230 §3.3.3). A Match&Replace / intercept edit can rewrite
      # the request-line method, so key off sent_req, not the client's original req.
      framing = response_framing_or_close(resp, sent_req.method, flow_id)
      return false unless framing
      resp_framing, resp_len = framing

      # Intercept (response): hold only in-scope, non-streaming responses. SSE /
      # close-delimited / WebSocket bodies would buffer forever, so they bypass.
      # The gate rebuilds the SAME precise scope URL the request hold uses (lazily, only
      # when intercept + Scope are on), so a string/regex-excluded flow whose request wasn't
      # held doesn't get its response held. The response gate also honours the catch direction
      # + can test `status:`. Match the CONDITION against `sent_req` (the rewritten/edited
      # request that was captured + scope-gated), not the original `req`, so a `method:`/`path:`
      # rule that holds the request also holds its response when M&R changed the request line.
      if (ic = @interceptor) && ic.intercepts_response?(
           method: sent_req.method, host: host, target: sent_req.target, scheme: scheme, status: resp.status) &&
         !resp_framing.close_delimited? && !sse?(resp) && resp.status != 101
        return handle_held_response(ic, upstream, req, sent_req, flow_id, host, port, scheme,
          resp, sent_resp_head, resp_framing, resp_len, ttfb, started)
      end

      # Match&Replace (response body): buffer + rewrite a bounded (Length/chunked),
      # non-streaming response when a response-body rule is live. SSE / close-delimited
      # / 101-upgrade bodies would buffer forever, so they fall through to streaming and
      # the body rule no-ops on them (matching the intercept-hold exclusions above). A body
      # whose declared length exceeds MAX_REWRITE_BODY is likewise left byte-exact (see the
      # constant) so one huge download can't grow the proxy heap while a rule is on.
      if (rw = @rewriter) && rewrite_response_body?(rw, resp, resp_framing, resp_len)
        return forward_response_rewriting_body(rw, upstream, req, sent_req, flow_id, host, port,
          scheme, resp, sent_resp_head, resp_framing, resp_len, ttfb, started)
      end

      relax_for_streaming_response(resp, resp_framing, upstream)

      # Non-hold path: stream the response body byte-for-byte (P6) and record the
      # flow. `completed` is true only when the whole body was delivered cleanly; a
      # client abort or upstream truncation is recorded Aborted (see the helper).
      resp_capture = Codec::CaptureBuffer.new(Settings.capture_max, capture_hint(resp_framing, resp_len))
      completed = stream_nonhold_response(upstream, sent_resp, sent_resp_head,
        resp_framing, resp_len, resp_capture, flow_id, ttfb, started)

      if completed && resp.status == 101
        # A 101 Switching Protocols turns the connection into a bidirectional tunnel of the
        # upgraded protocol — it is NOT more HTTP. Ownership of the upstream transfers to the
        # relay/tunnel (which cross-closes on teardown); detach it from the reuse slot so
        # `run`'s ensure won't also touch it. A WebSocket upgrade gets the frame-aware relay
        # (captures messages, P6/P7); any OTHER upgrade (h2c, or a proprietary protocol) gets
        # a blind byte tunnel. Either way we must NOT fall through to keep-alive/reuse:
        # parsing the post-upgrade bytes as the next HTTP response (upstream) or request
        # (client) would desync both directions and corrupt the tunnel.
        @upstream = nil
        @up_host = nil
        @up_port = 0
        # Entering a long-lived bidirectional tunnel: relax both legs' timeouts so an idle
        # WebSocket/tunnel isn't reaped by a wall-clock cutoff (the 30 s upstream io_timeout would
        # otherwise tear a quiet tunnel down). Keepalive (both legs) reaps a truly dead peer.
        SocketTuning.relax(@io)
        SocketTuning.relax(upstream)
        if websocket_upgrade?(resp)
          WS::Relay.run(@io, upstream, flow_id, @sink) # frames until close (P6/P7)
        else
          Pump.blind_tunnel(@io, upstream) # non-WS upgrade: raw pipe until close
        end
        return false
      end

      # A truncated/aborted body was forwarded short; close so the client sees
      # end-of-response instead of waiting for the missing bytes while we read its
      # next keep-alive request.
      unless completed
        release_upstream
        return false
      end
      # Reuse this upstream for the next request iff the ORIGIN keeps its side
      # open; the return value is the CLIENT keep-alive decision (separate sides).
      # The origin side keys on sent_req (what it received); the client side on req.
      update_upstream_reuse(origin_keep_alive?(sent_req, resp, resp_framing))
      keep_alive?(req, resp, resp_framing)
    end

    # Interim 1xx (RFC 9110 §15.2): an informational response (100 Continue,
    # 103 Early Hints, …) is NOT the final response. A conformant proxy forwards it
    # to the client verbatim and keeps reading until the final (>=200) status;
    # otherwise the real response is stranded on the upstream socket — wrongly
    # recorded as THIS flow's response AND served to the next reused request
    # (response desync). 101 Switching Protocols is terminal (the upgrade) and falls
    # through. Returns the final {head, resp}, or nil when it recorded an error +
    # closed (malformed 1xx with a body, too many 1xx, or upstream closed).
    private def skip_interim_responses(upstream : IO, req : Codec::RawRequest, flow_id : Int64,
                                       resp_head : Bytes, resp : Codec::RawResponse) : {Bytes, Codec::RawResponse}?
      interim_seen = 0
      while interim_response?(resp)
        # RFC 9112 §6: a 1xx response MUST NOT carry content. An interim that declares
        # a body (Content-Length / Transfer-Encoding) is malformed AND a desync vector
        # — its "body" can embed a fake final response while the real one is stranded
        # for the next reused request. Refuse it: close the connection (don't parse a
        # body as the next response, don't reuse the upstream).
        if interim_has_body?(resp)
          @sink.on_response(FlowMapper.error_response(flow_id, "malformed interim 1xx response (declared a body)"))
          release_upstream
          return nil
        end
        # Cap consecutive 1xx (like Burp/nginx) so a hostile upstream streaming endless
        # body-less 103s can't spin this fiber forever / flood the client (per-conn DoS).
        interim_seen += 1
        if interim_seen > MAX_INTERIM
          @sink.on_response(FlowMapper.error_response(flow_id, "too many interim 1xx responses (>#{MAX_INTERIM})"))
          release_upstream
          return nil
        end
        # RFC 9110 §15.2 / RFC 7231: a proxy MUST NOT forward a 1xx to an HTTP/1.0
        # client (it can't parse it). Read past it for everyone; forward only to 1.1.
        if req.version == "HTTP/1.1"
          @io.write(resp_head) # forward byte-exact (P6/P7); no rewrite on interim
          @io.flush
        end
        resp_head = Codec::Http1.read_head(upstream)
        if resp_head.nil?
          @sink.on_response(FlowMapper.error_response(flow_id, "upstream closed after interim 1xx response"))
          release_upstream
          return nil
        end
        resp = Codec::Http1.parse_response_head(resp_head)
      end
      {resp_head, resp}
    end

    # Computes the response body framing, or records a visible error flow and
    # returns nil when the framing is illegal (CL+TE, non-final chunked, bad
    # Content-Length). We already hold a flow_id from on_request, so a raise here
    # used to leave the flow stuck Pending forever; record + close instead.
    private def response_framing_or_close(resp : Codec::RawResponse, method : String,
                                          flow_id : Int64) : {Codec::BodyFraming, Int64}?
      Codec::Body.response_framing(resp, method)
    rescue ex : Gori::Error
      @sink.on_response(FlowMapper.error_response(flow_id, "response framing rejected: #{ex.message}"))
      release_upstream
      nil
    end

    # Streams the non-held response to the client while capturing it, then records
    # the flow. Returns true only if the whole body was delivered:
    #   - a raised write (the CLIENT aborted its read mid-response, e.g. an
    #     EventSource cancel) → record Aborted, return false;
    #   - `stream` returning false (the UPSTREAM cut a Content-Length/chunked body
    #     short) → record Aborted with a truncation note, return false;
    #   - otherwise → record Complete, return true.
    # Both failure modes previously either unwound to `run`'s blanket rescue
    # (leaving the flow Pending forever) or were recorded as a clean response.
    private def stream_nonhold_response(upstream : IO, sent_resp : Codec::RawResponse,
                                        sent_resp_head : Bytes, resp_framing : Codec::BodyFraming,
                                        resp_len : Int64, resp_capture : Codec::CaptureBuffer,
                                        flow_id : Int64, ttfb : Int64, started : Time::Instant) : Bool
      begin
        @io.write(sent_resp_head)
        @io.flush
        resp_complete = Codec::Body.stream(upstream, @io, resp_framing, resp_len, resp_capture, copy_buf)
      rescue
        record_streamed_response(sent_resp, resp_framing, resp_capture, flow_id, ttfb, started,
          state: Store::FlowState::Aborted, error: "connection closed mid-response")
        return false
      end
      record_streamed_response(sent_resp, resp_framing, resp_capture, flow_id, ttfb, started,
        state: resp_complete ? Store::FlowState::Complete : Store::FlowState::Aborted,
        error: resp_complete ? nil : "upstream closed before response body complete")
      resp_complete
    end

    private def record_streamed_response(sent_resp : Codec::RawResponse, resp_framing : Codec::BodyFraming,
                                         resp_capture : Codec::CaptureBuffer, flow_id : Int64,
                                         ttfb : Int64, started : Time::Instant, *,
                                         state : Store::FlowState, error : String?) : Nil
      duration = (Time.instant - started).total_microseconds.to_i64
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: resp_framing.none? ? nil : resp_capture.to_slice,
        ttfb_us: ttfb, duration_us: duration,
        body_truncated: resp_capture.truncated?, body_size: resp_capture.total,
        state: state, error: error))
    end

    # The Match&Replace response-body path (no intercept): buffer the whole body,
    # rewrite the entity, re-frame the head (Content-Length), forward, and capture.
    # Returns the CLIENT keep-alive decision; the upstream is reused iff we read the
    # whole body cleanly AND the origin kept its side. Mirrors stream_nonhold_response
    # + the reuse tail of handle_response, minus the 101/close-delimited cases (excluded
    # at the call site so the buffer is always bounded).
    private def forward_response_rewriting_body(rw : HeadRewriter, upstream : IO, req : Codec::RawRequest,
                                                sent_req : Codec::RawRequest, flow_id : Int64,
                                                host : String, port : Int32, scheme : String,
                                                resp : Codec::RawResponse, sent_resp_head : Bytes,
                                                resp_framing : Codec::BodyFraming, resp_len : Int64,
                                                ttfb : Int64, started : Time::Instant) : Bool
      buf = IO::Memory.new
      resp_complete = Codec::Body.stream(upstream, buf, resp_framing, resp_len, Codec::DiscardIO.new, copy_buf)
      sent_resp_head, fwd_body = apply_body_rewrite(sent_resp_head, buf.to_slice, resp_framing) { |e| rw.rewrite_response_body(e) }
      sent_resp = Codec::Http1.parse_response_head(sent_resp_head) # head may have been re-framed
      stored, trunc, size = capped(fwd_body)
      state = resp_complete ? Store::FlowState::Complete : Store::FlowState::Aborted
      error = resp_complete ? nil : "upstream closed before response body complete"
      begin
        @io.write(sent_resp_head)
        @io.write(fwd_body) if fwd_body
        @io.flush
      rescue
        # Client aborted its read mid-response — record what we have, then close.
        state = Store::FlowState::Aborted
        error = "connection closed mid-response"
        resp_complete = false
      end
      duration = (Time.instant - started).total_microseconds.to_i64
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: stored, ttfb_us: ttfb, duration_us: duration,
        body_truncated: trunc, body_size: size, state: state, error: error))
      # Reuse iff the origin kept its side AND we read the whole body; a truncated body
      # was forwarded short, so close the client connection (return false) rather than
      # block its next keep-alive request on the missing bytes.
      update_upstream_reuse(resp_complete && origin_keep_alive?(sent_req, resp, resp_framing))
      return false unless resp_complete
      keep_alive?(req, resp, resp_framing)
    end

    # Reads the response head, transparently redialing + resending ONCE if a
    # REUSED idle keep-alive turned out stale (immediate EOF) and the request is
    # replayable (body-less). Returns {head, upstream} — `upstream` may be a fresh
    # connection after a retry, so callers must rebind their local.
    private def read_response_head(upstream : IO, host : String, port : Int32,
                                   reused : Bool, sent_head : Bytes, can_retry : Bool) : {Bytes?, IO}
      resp_head = Codec::Http1.read_head(upstream)
      if resp_head.nil? && reused && can_retry
        release_upstream
        fresh, _ = acquire_upstream(host, port)
        if fresh
          upstream = fresh
          resp_head = Codec::Http1.read_head(fresh) if write_request(fresh, sent_head, nil)
        end
      end
      {resp_head, upstream}
    end

    # Apply response-head Match&Replace; returns the (possibly rewritten) head +
    # its parsed projection. Unchanged bytes keep the original (P7).
    private def apply_response_rewrite(resp_head : Bytes, resp : Codec::RawResponse) : {Bytes, Codec::RawResponse}
      rw = @rewriter
      return {resp_head, resp} unless rw
      rewritten = rw.rewrite_response(resp_head)
      return {resp_head, resp} if rewritten == resp_head
      {rewritten, Codec::Http1.parse_response_head(rewritten)}
    end

    # The intercept-hold response path: buffer the (non-streaming) body, let the
    # human edit/drop it, forward the result, and capture. Returns the CLIENT
    # keep-alive decision; the upstream is reused iff the ORIGIN kept its side.
    private def handle_held_response(ic : Gori::Interceptor, upstream : IO, req : Codec::RawRequest,
                                     sent_req : Codec::RawRequest,
                                     flow_id : Int64, host : String, port : Int32, scheme : String,
                                     resp : Codec::RawResponse, sent_resp_head : Bytes,
                                     resp_framing : Codec::BodyFraming, resp_len : Int64,
                                     ttfb : Int64, started : Time::Instant) : Bool
      # Buffer the body, tracking completeness (Codec::Body.read drops it). A
      # truncated/misframed body must NOT leave the upstream parked — its stray
      # unread bytes would become the next reused request's response (desync).
      buf = IO::Memory.new
      # tee into a discard sink, not a second IO::Memory — the body is already buffered in
      # `buf`; a throwaway IO::Memory would hold the whole response a second time.
      resp_complete = Codec::Body.stream(upstream, buf, resp_framing, resp_len, Codec::DiscardIO.new, copy_buf)
      # `buf` is filled once and never written again, and build_message copies head+body into
      # a fresh buffer, so `buf.to_slice` is a stable view — no defensive dup (which would hold
      # the whole body a second time). Mirrors the non-hold M&R path above.
      body = resp_framing.none? ? nil : buf.to_slice
      # Match&Replace (response body) BEFORE the human sees it, like the head. A body rule
      # re-frames the head to Content-Length; `resp` (status/version/Connection) is
      # untouched by that, so keep it as the origin's framing/keep-alive truth.
      if (rw = @rewriter) && rw.rewrites_response_body?
        sent_resp_head, body = apply_body_rewrite(sent_resp_head, body, resp_framing) { |e| rw.rewrite_response_body(e) }
      end
      decision = ic.hold_response(build_message(sent_resp_head, body),
        flow_id: flow_id, method: req.method, target: "#{resp.status} #{resp.reason}",
        host: host, port: port, scheme: scheme)
      duration = (Time.instant - started).total_microseconds.to_i64
      if decision.action.drop?
        @sink.on_response(FlowMapper.aborted_response(flow_id, "dropped by intercept",
          ttfb_us: ttfb, duration_us: duration))
        write_intercept_drop
        release_upstream
        return false
      end
      # Forward the decision bytes BYTE-EXACT (P7); the editor already synced
      # Content-Length for an edited body (InterceptView#forward_bytes). Keeping the
      # proxy byte-exact also preserves the head verbatim for a HEAD/304/204 response
      # forwarded unedited (whose Content-Length describes the entity, not the bytes).
      out_head, out_body = split_message(decision.bytes)
      sent_resp = Codec::Http1.parse_response_head(out_head)
      @io.write(out_head)
      @io.write(out_body) if out_body
      @io.flush
      stored, trunc, size = capped(out_body)
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: stored, ttfb_us: ttfb, duration_us: duration,
        body_truncated: trunc, body_size: size))
      # Reuse the upstream iff we read the WHOLE body cleanly AND the origin kept its
      # side alive. Origin side keys on sent_req (what the origin received); the CLIENT
      # keep-alive (return value) uses the edited resp.
      update_upstream_reuse(resp_complete && origin_keep_alive?(sent_req, resp, resp_framing))
      # A truncated upstream body was forwarded short — close the client connection so it
      # sees end-of-response instead of blocking for the missing bytes while we read its
      # next keep-alive request (mirrors the non-held path's resp_complete guard).
      return false unless resp_complete
      # The human may have edited the held response into conflicting framing (CL+TE); the
      # response was already forwarded + recorded above, so recompute the client-side framing
      # defensively — a raw response_framing raise here would unwind to run's blanket rescue
      # and drop the client connection abruptly instead of a clean keep-alive decision.
      client_framing =
        begin
          Codec::Body.response_framing(sent_resp, req.method)[0]
        rescue Gori::Error
          Codec::BodyFraming::CloseDelimited # unknowable framing → don't keep-alive
        end
      keep_alive?(req, sent_resp, client_framing)
    end

    # After a complete response, decide whether the live upstream can serve the
    # next request: keep it parked in the reuse slot, or close it now.
    private def update_upstream_reuse(origin_keep_alive : Bool) : Nil
      release_upstream unless origin_keep_alive
    end

    # A close-delimited or SSE (event-stream) response streams for an unbounded, idle-prone time;
    # relax BOTH legs' read/write timeouts so a legitimately-idle stream isn't torn down mid-flight
    # (keepalive reaps a genuinely dead peer). A normal Length/chunked response keeps the baseline
    # timeout, and the `run`/`acquire_and_send` re-arm restores it for any later keep-alive request.
    private def relax_for_streaming_response(resp : Codec::RawResponse, resp_framing : Codec::BodyFraming, upstream : IO) : Nil
      return unless resp_framing.close_delimited? || sse?(resp)
      SocketTuning.relax(@io)
      SocketTuning.relax(upstream)
    end

    # Cleartext HTTP/2 (h2c) tunnelled inside a CONNECT: the target is the
    # CONNECT authority, so we dial it plaintext and run the same h2 relay (no
    # :authority routing / HPACK coupling needed). The origin must speak h2c.
    private def intercept_h2c(host : String, port : Int32, client : IO) : Nil
      upstream = Upstream.dial(host, port, overrides: @host_overrides)
      return unless upstream
      # Long-lived h2c relay: relax both legs so an idle h2 connection isn't reaped by the
      # baseline/io timeouts; keepalive (both legs) handles a dead peer.
      SocketTuning.relax(client)
      SocketTuning.relax(upstream)
      begin
        H2::Relay.run(client, upstream, host, port, @sink)
      ensure
        upstream.close rescue nil
      end
    end

    private def websocket_upgrade?(resp : Codec::RawResponse) : Bool
      resp.status == 101 && resp.headers.get?("Upgrade").try(&.downcase) == "websocket"
    end

    # An interim 1xx informational response (100 Continue / 102 / 103 Early Hints /
    # …) — forwarded to the client, then skipped to read the final status. 101
    # Switching Protocols is terminal (handled as an upgrade), so it is NOT interim.
    private def interim_response?(resp : Codec::RawResponse) : Bool
      resp.status >= 100 && resp.status < 200 && resp.status != 101
    end

    # A 1xx that illegally declares body framing (Content-Length / Transfer-Encoding)
    # — malformed per RFC 9112 §6 and a response-smuggling vector.
    private def interim_has_body?(resp : Codec::RawResponse) : Bool
      !!(resp.headers.get?("Content-Length") || resp.headers.get?("Transfer-Encoding"))
    end

    # CONNECT host:port -> 200, then TLS MITM (if configured) or blind tunnel.
    private def handle_connect(req : Codec::RawRequest) : Bool
      host, port = Upstream.split_host_port(req.target, 443)

      # A CONNECT whose (override-resolved) authority is gori's own listener would
      # loop the proxy into itself — refuse before answering 200 / starting MITM.
      if (sa = @self_addr) && Upstream.loops_to_self?(host, port, @host_overrides, sa)
        write_gateway_error
        return false
      end

      # Sandbox: refuse to even open a tunnel to a host that CAN'T be in scope (safe-testing:
      # don't handshake with an out-of-scope origin at all). A host that MIGHT be in scope —
      # e.g. only url/path rules narrow it — IS tunnelled and MITM'd; the Tunnel forces it to
      # h1 so ClientConn can block the out-of-scope requests precisely, per request. Answered
      # before the 200 so the client sees the CONNECT itself refused.
      if (ic = @interceptor) && ic.sandbox_blocks_host?(host)
        write_sandbox_block
        return false
      end

      if tls = @tls
        @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
        @io.flush
        # Peek one byte to route the tunnel: a TLS ClientHello starts with 0x16
        # (handshake), the HTTP/2 cleartext preface with 'P' (0x50, "PRI ...").
        first = @io.read_byte
        return false if first.nil?
        stream = PrefixIO.new(Bytes[first], @io)
        if first == 0x50_u8
          # Cleartext h2 (h2c) tunnelled inside CONNECT runs the raw h2 relay, which bypasses
          # ClientConn's per-request block. Under the sandbox we can't gate it per request, so
          # (the host having already cleared the coarse gate above) refuse the whole tunnel —
          # h2c-in-CONNECT is rare, and a blocking mode must not leave an ungated path open.
          return false if (ic = @interceptor) && ic.sandbox_enabled?
          intercept_h2c(host, port, stream)
        else
          tls.intercept(host, port, stream, @sink)
        end
      else
        upstream = Upstream.dial(host, port, overrides: @host_overrides)
        unless upstream
          write_gateway_error
          return false
        end
        # begin/ensure so the dialed origin fd is freed even if the 200 reply
        # write raises (client RST between CONNECT and our reply) or blind_tunnel
        # itself raises — otherwise one upstream fd leaks per CONNECT-then-reset.
        begin
          @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
          @io.flush
          # Blind CONNECT tunnel: relax both legs so an idle tunnel (IMAP IDLE, long-poll, a quiet
          # TLS session) isn't reaped by the 30 s io_timeout; keepalive reaps a genuinely dead peer.
          SocketTuning.relax(@io)
          SocketTuning.relax(upstream)
          Pump.blind_tunnel(@io, upstream)
        ensure
          upstream.close rescue nil
        end
      end
      false # the connection has been consumed by the tunnel
    end

    # Resolves {host, port, scheme, forward_head}. Absolute-form request targets
    # (forward-proxy plain HTTP, e.g. `GET http://h/p`) are rewritten to
    # origin-form for the upstream; the captured truth keeps the original bytes.
    private def open_upstream(host : String, port : Int32) : IO?
      if @tls_upstream
        Upstream.dial_tls(host, port, verify: @verify_upstream, overrides: @host_overrides)
      else
        Upstream.dial(host, port, overrides: @host_overrides)
      end
    end

    private def resolve_forward(req : Codec::RawRequest) : {String, Int32, String, Bytes}
      # Post-CONNECT tunnel: all requests go to the pinned origin, byte-exact
      # (they arrive origin-form over the decrypted channel).
      if fixed = @fixed_host
        return {fixed, @fixed_port, @scheme, req.raw_head}
      end

      target = req.target
      if target.starts_with?("http://") || target.starts_with?("https://")
        uri = URI.parse(target)
        scheme = uri.scheme || "http"
        host = uri.host || ""
        port = uri.port || (scheme == "https" ? 443 : 80)
        {host, port, scheme, rewrite_request_line(req, origin_form(uri))}
      else
        host, port = Upstream.split_host_port(req.host? || "", @scheme == "https" ? 443 : 80)
        {host, port, @scheme, req.raw_head}
      end
    end

    private def origin_form(uri : URI) : String
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    end

    # New request-line + the original header block (everything from the first
    # CRLF onward), so only the request-target changes.
    private def rewrite_request_line(req : Codec::RawRequest, origin_target : String) : Bytes
      raw = req.raw_head
      nl = raw.index(0x0a_u8) || return raw # no LF at all? leave as-is
      header_block = raw[(nl + 1)..]        # everything after the first CRLF
      io = IO::Memory.new
      io << req.method << ' ' << origin_target << ' ' << req.version << "\r\n"
      io.write(header_block)
      io.to_slice
    end

    # Held bodies are buffered whole (the human may edit them) and forwarded in
    # full, but — like the streaming path — only the capture cap is STORED so an
    # in-scope giant body can't bloat its row. Returns {stored, truncated, size}.
    private def capped(body : Bytes?) : {Bytes?, Bool, Int64?}
      return {nil, false, nil} unless body
      return {body, false, nil} if body.size <= Settings.capture_max
      {body[0, Settings.capture_max].dup, true, body.size.to_i64}
    end

    private def record_error(req, scheme, host, port, created_at, message) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: nil))
      @sink.on_response(FlowMapper.error_response(flow_id, message))
    end

    # A dropped request never reaches upstream; record it as an Aborted flow so
    # the human sees the attempt + decision (P4/P7).
    private def record_dropped_request(req, scheme, host, port, created_at, body) : Nil
      stored, trunc, size = capped(body)
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size))
      @sink.on_response(FlowMapper.aborted_response(flow_id, "dropped by intercept (request)"))
    end

    private def write_intercept_drop : Nil
      @io.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nX-Gori-Intercept: dropped\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    # A request the sandbox refused never reaches upstream; record it as an Aborted flow
    # (like an intercept drop) so the operator still sees the blocked attempt (P4/P7). Body
    # is nil — we block before reading it and close the connection right after.
    private def record_blocked_request(req, scheme, host, port, created_at) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: nil))
      @sink.on_response(FlowMapper.aborted_response(flow_id, "blocked by sandbox (out of scope)"))
    end

    # Tell the client the sandbox refused this request — a distinct 403 + marker header so a
    # blocked flow reads differently from an upstream 502. The caller returns false, so @io
    # closes right after: no keep-alive on a blocked connection.
    private def write_sandbox_block : Nil
      @io.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\nX-Gori-Sandbox: blocked\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    # Concatenate a head and optional body into one contiguous message buffer.
    private def build_message(head : Bytes, body : Bytes?) : Bytes
      return head if body.nil? || body.empty?
      io = IO::Memory.new(head.size + body.size)
      io.write(head)
      io.write(body)
      io.to_slice
    end

    # Split a forwarded message back into head (through CRLFCRLF) + body remainder.
    private def split_message(raw : Bytes) : {Bytes, Bytes?}
      idx = index_crlf_crlf(raw)
      return {raw, nil} unless idx
      head_end = idx + 4
      body = head_end < raw.size ? raw[head_end..].dup : nil
      {raw[0, head_end].dup, body}
    end

    private def index_crlf_crlf(raw : Bytes) : Int32?
      i = 0
      while i + 3 < raw.size
        return i if raw[i] == 0x0d_u8 && raw[i + 1] == 0x0a_u8 && raw[i + 2] == 0x0d_u8 && raw[i + 3] == 0x0a_u8
        i += 1
      end
      nil
    end

    # Ceiling on a body Match&Replace will buffer to rewrite. A body rule can't stream —
    # it must hold the whole entity to gsub + re-frame (Content-Length), and rewriting
    # allocates a few more full copies (dechunk, String round-trip, gsub). Left uncapped,
    # one large download/upload with a body rule live would grow the proxy heap without
    # bound (a per-connection OOM). Above this size the rule no-ops and the body is
    # forwarded byte-exact, exactly as it already does for SSE / compressed / 101 bodies —
    # correctness costs nothing but the rule not applying to a body too big to safely hold.
    # Only gates KNOWN-length (Content-Length) bodies; a chunked body has no declared size
    # to check here and still buffers (bounded only by the peer) — capping that streams a
    # follow-up.
    MAX_REWRITE_BODY = 16 * 1024 * 1024 # 16 MiB

    # Whether a body of this framing/declared-length is small enough to buffer + rewrite.
    # Chunked/unknown-length has no size to gate on, so it isn't blocked here.
    private def rewritable_body_size?(framing : Codec::BodyFraming, len : Int64) : Bool
      !framing.length? || len <= MAX_REWRITE_BODY
    end

    # Whether the response-body Match&Replace path applies: a body rule is live, the body is
    # bounded (Length/chunked, not SSE / close-delimited / 101), and small enough to buffer.
    # Extracted from handle_response so the dispatch stays flat (it just tests + branches).
    private def rewrite_response_body?(rw : HeadRewriter, resp : Codec::RawResponse,
                                       framing : Codec::BodyFraming, len : Int64) : Bool
      rw.rewrites_response_body? &&
        (framing.length? || framing.chunked?) && !sse?(resp) && resp.status != 101 &&
        rewritable_body_size?(framing, len)
    end

    # Whether the request-body Match&Replace path applies: a body rule is live, there IS a
    # body, and it's small enough to buffer. Extracted from handle_request (see above).
    private def rewrite_request_body?(rw : HeadRewriter, framing : Codec::BodyFraming, len : Int64) : Bool
      rw.rewrites_request_body? && !framing.none? && rewritable_body_size?(framing, len)
    end

    # Apply a body Match&Replace to a buffered wire body and return {head, forward_body}.
    # `wire_body` is the on-the-wire form (chunk framing preserved for chunked bodies);
    # it is de-chunked to the entity before matching. `yield entity` runs the rule engine
    # (rewrite_request_body / rewrite_response_body), which returns the SAME bytes when
    # nothing matched. On no change we return the ORIGINAL head + wire body byte-exact
    # (P7) — so an unmatched flow, including a compressed body a literal pattern can't
    # touch, is never re-framed. On a change we re-frame the head to Content-Length (the
    # new entity length, Transfer-Encoding dropped) and forward the rewritten entity.
    private def apply_body_rewrite(head : Bytes, wire_body : Bytes?, framing : Codec::BodyFraming,
                                   & : Bytes -> Bytes) : {Bytes, Bytes?}
      return {head, wire_body} if wire_body.nil? || wire_body.empty?
      entity = framing.chunked? ? Codec::ContentDecode.dechunk(wire_body) : wire_body
      rewritten = yield entity
      return {head, wire_body} if rewritten == entity # nothing matched → byte-exact (P7)
      {reframe_to_length(head, rewritten.size), rewritten}
    end

    # Rebuild a message head framed as `Content-Length: len`: drop any Transfer-Encoding
    # and Content-Length header (a rewritten body invalidates both), append the fresh
    # Content-Length, and keep every other header verbatim in order. Preserves the head's
    # own line ending (CRLF or bare LF) so the re-parsed head stays well-formed.
    private def reframe_to_length(head : Bytes, len : Int32) : Bytes
      text = String.new(head)
      eol = text.index("\r\n") ? "\r\n" : "\n"
      section = text.split(eol + eol, 2).first # headers up to the blank line
      lines = section.split(eol)
      io = IO::Memory.new(head.size + 32)
      io << lines.first << eol # request / status line, untouched
      lines[1..].each do |line|
        next if header_line_named?(line, "transfer-encoding") || header_line_named?(line, "content-length")
        io << line << eol
      end
      io << "Content-Length: " << len << eol << eol
      io.to_slice
    end

    # True when a header line's field-name (case-insensitive, ignoring leading space) is
    # `name`. The request/status line has no ':' before its first space-token, so it never
    # matches a header name here.
    private def header_line_named?(line : String, name : String) : Bool
      colon = line.index(':')
      return false unless colon && colon > 0
      line[0...colon].strip.downcase == name
    end

    private def sse?(resp : Codec::RawResponse) : Bool
      ct = resp.headers.get?("Content-Type")
      !!ct && ct.downcase.includes?("text/event-stream")
    end

    private def write_gateway_error : Nil
      @io.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    # An origin-form request-target (path-only, e.g. `/` or `/ca.pem`) — i.e. a browser
    # that hit us DIRECTLY, not via a proxy config (which sends an absolute-form URI).
    private def origin_form?(req : Codec::RawRequest) : Bool
      t = req.target
      !t.starts_with?("http://") && !t.starts_with?("https://")
    end

    private def get_or_head?(req : Codec::RawRequest) : Bool
      req.method.compare("GET", case_insensitive: true) == 0 ||
        req.method.compare("HEAD", case_insensitive: true) == 0
    end

    # Serve the direct-access welcome + CA-download page (see the guard in handle_request).
    # The CA bytes/fingerprint/path come through the TlsMitm seam so this stays decoupled
    # from the FFI cert code; a HEAD request gets headers only. Best-effort — a write error
    # just drops the connection like every other canned response here.
    private def serve_self_page(req : Codec::RawRequest, tls : TlsMitm, self_addr : {String, Int32}) : Nil
      head_only = req.method.compare("HEAD", case_insensitive: true) == 0
      resp = SelfPage.respond(req.target,
        pem: tls.ca_cert_pem, der: tls.ca_cert_der, spki: tls.ca_spki_sha256,
        ca_path: tls.ca_cert_path, listen: self_addr, version: Gori::VERSION, head_only: head_only)
      @io.write(resp)
      @io.flush
    rescue
    end

    private def keep_alive?(req : Codec::RawRequest, resp : Codec::RawResponse,
                            resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited? # body ends at close
      return false if connection_lists?(req.headers.get?("Connection"), "close")
      return false if connection_lists?(resp.headers.get?("Connection"), "close")
      req.version == "HTTP/1.1" || connection_lists?(req.headers.get?("Connection"), "keep-alive")
    end

    # Whether the ORIGIN will keep its connection open after this response, so its
    # upstream socket may be parked for the next request. Distinct from
    # `keep_alive?` (the CLIENT side, keyed on the request): persistence here is
    # the RESPONSE's — HTTP/1.1 persists unless `Connection: close`; HTTP/1.0 only
    # with explicit `Connection: keep-alive`. A close-delimited body, or a
    # `Connection: close` on the request we forwarded upstream OR on the response,
    # all mean the origin closes. Parking a connection the origin will close just
    # wastes one stale-retry on the next request, so err toward NOT reusing.
    # `sent_req` is the request ACTUALLY forwarded upstream (post Match&Replace /
    # intercept edit), not the client's original — a rule that adds `Connection: close`
    # to the upstream request means the origin closes, even if the client's request didn't.
    private def origin_keep_alive?(sent_req : Codec::RawRequest, resp : Codec::RawResponse,
                                   resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited?
      return false if connection_lists?(sent_req.headers.get?("Connection"), "close")
      return false if connection_lists?(resp.headers.get?("Connection"), "close")
      resp.version == "HTTP/1.1" || connection_lists?(resp.headers.get?("Connection"), "keep-alive")
    end

    # Whether a request may be transparently REPLAYED on a fresh connection after a
    # stale-reuse failure. Only SAFE methods (RFC 7231 §4.2.1: GET/HEAD/OPTIONS/
    # TRACE — no side effects, idempotent) with NO body qualify: repeater is then
    # harmless even if the origin had already processed the first attempt. A
    # mutating method (POST/PUT/PATCH/DELETE), even body-less, is never auto-resent
    # — a wire-inspection proxy must not silently double-submit; the request fails
    # and the client decides. A body request can't be replayed anyway (the bytes
    # were streamed from the client and not retained).
    private def retryable_request?(req : Codec::RawRequest, body_less : Bool) : Bool
      return false unless body_less
      case req.method.upcase
      when "GET", "HEAD", "OPTIONS", "TRACE" then true
      else                                        false
      end
    end

    # Presize hint for a body capture: a Content-Length body's length is known, so the
    # store is sized once. Chunked/close-delimited length is 0 (unknown → grow on demand);
    # a bodyless framing keeps the capture unallocated.
    private def capture_hint(framing : Codec::BodyFraming, length : Int64) : Int64
      framing.length? ? length : 0_i64
    end

    # True when a Connection header field lists `token` (case-insensitive) as one of its
    # comma-separated connection-options — e.g. `Connection: keep-alive, close` carries BOTH
    # `keep-alive` and `close`. Comparing the whole value (the old header_token) missed a
    # token embedded in such a list, so a peer signalling close would be parked as persistent.
    private def connection_lists?(value : String?, token : String) : Bool
      return false unless value
      value.downcase.split(',').any? { |t| t.strip == token }
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
