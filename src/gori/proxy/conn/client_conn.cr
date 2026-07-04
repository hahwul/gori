require "uri"
require "../codec/http1"
require "../codec/body"
require "../sink"
require "../head_rewriter"
require "../../interceptor"
require "../../host_overrides"
require "../prefix_io"
require "../h2/relay"
require "../connect"
require "../upstream"
require "../pump"
require "../ws/relay"
require "../../flow_mapper"

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
                   @host_overrides : Gori::HostOverrides? = nil)
      # Per-connection upstream reuse (see `acquire_upstream`). One live origin
      # connection kept across this client's keep-alive requests.
      @upstream = nil.as(IO?)
      @up_host = nil.as(String?)
      @up_port = 0
    end

    def run : Nil
      loop do
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
      head = Codec::Http1.read_head(@io)
      return false if head.nil? # client closed / keep-alive idle end

      req = Codec::Http1.parse_request_head(head)
      return handle_connect(req) if req.method.upcase == "CONNECT"

      started = Time.instant
      created_at = now_us
      host, port, scheme, forward_head = resolve_forward(req)

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

      req_framing, req_len = Codec::Body.request_framing(req)

      # Intercept (request): hold only when enabled AND in scope. Holding buffers
      # the full body (vs streaming) so the human can see/edit it; the non-hold
      # path keeps zero-buffer streaming (P6). The scope URL is built exactly as the
      # Scope SQL filter does — scheme || '://' || host || <stored target> — over the
      # SAME target that gets captured (sent_req.target, used at the insert below), so a
      # held request is precisely an in-scope History row with no live/SQL divergence.
      scope_url = "#{scheme}://#{host}#{sent_req.target}"
      if (ic = @interceptor) && ic.intercepts_request?(scope_url,
           method: sent_req.method, host: host, target: sent_req.target, scheme: scheme)
        return handle_held_request(ic, req, sent_req, sent_head, host, port, scheme,
          created_at, started, req_framing, req_len)
      end

      # Non-hold path: stream the request body byte-for-byte (P6), unchanged.
      # Replay-safety keys on the ACTUALLY-SENT method (sent_req): an M&R rule that rewrites
      # the request line GET→POST must not leave a non-idempotent request marked retryable.
      retryable = retryable_request?(sent_req, req_framing.none?)
      req_capture = Codec::CaptureBuffer.new(Codec::Body::CAPTURE_MAX)
      req_complete = true
      upstream, reused, sent = acquire_and_send(host, port, retryable) do |up|
        up.write(sent_head)
        req_complete = Codec::Body.stream(@io, up, req_framing, req_len, req_capture)
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
        reused: reused, sent_head: sent_head, can_retry: retryable, scope_url: scope_url, sent_req: sent_req)
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
      # Key replay-safety on the EDITED request: if the human changed the method (e.g.
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
        reused: reused, sent_head: sent_head, can_retry: retryable,
        scope_url: "#{scheme}://#{host}#{sent_req.target}", sent_req: sent_req)
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
      ok = send_guard { yield upstream }
      if !ok && reused && retryable
        release_upstream
        upstream, reused = acquire_upstream(host, port)
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
                                *, reused : Bool, sent_head : Bytes, can_retry : Bool, scope_url : String,
                                sent_req : Codec::RawRequest) : Bool
      resp_head, upstream = read_response_head(upstream, host, port, reused, sent_head, can_retry)
      if resp_head.nil?
        @sink.on_response(FlowMapper.error_response(flow_id, "no response from upstream"))
        release_upstream
        return false
      end
      resp = Codec::Http1.parse_response_head(resp_head)

      # Interim 1xx (RFC 9110 §15.2): an informational response (100 Continue,
      # 103 Early Hints, …) is NOT the final response. A conformant proxy forwards
      # it to the client verbatim and keeps reading until the final (>=200) status;
      # otherwise the real response is stranded on the upstream socket — it gets
      # wrongly recorded as THIS flow's response AND served to the next reused
      # request on this connection (response desync). 101 Switching Protocols is the
      # exception: it is terminal (the protocol upgrade), so it falls through to the
      # normal path (WebSocket handling below).
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
          return false
        end
        # Cap consecutive 1xx (like Burp/nginx) so a hostile upstream streaming endless
        # body-less 103s can't spin this fiber forever / flood the client (per-conn DoS).
        interim_seen += 1
        if interim_seen > MAX_INTERIM
          @sink.on_response(FlowMapper.error_response(flow_id, "too many interim 1xx responses (>#{MAX_INTERIM})"))
          release_upstream
          return false
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
          return false
        end
        resp = Codec::Http1.parse_response_head(resp_head)
      end
      ttfb = (Time.instant - started).total_microseconds.to_i64

      # Match&Replace (response head). Framing/keep-alive/upgrade stay on the
      # ORIGINAL response so the upstream body is read correctly.
      sent_resp_head, sent_resp = apply_response_rewrite(resp_head, resp)
      resp_framing, resp_len = Codec::Body.response_framing(resp, req.method)

      # Intercept (response): hold only in-scope, non-streaming responses. SSE /
      # close-delimited / WebSocket bodies would buffer forever, so they bypass.
      # Use the SAME precise URL gate as the request hold (scope_url built above), so a
      # string/regex-excluded flow whose request wasn't held doesn't get its response held.
      # The response gate also honours the catch direction + can test `status:`. Match the
      # CONDITION against `sent_req` (the rewritten/edited request that was captured + scope-
      # gated), not the original `req`, so a `method:`/`path:` rule that holds the request
      # also holds its response when a Match&Replace rule changed the request line.
      if (ic = @interceptor) && ic.intercepts_response?(scope_url,
           method: sent_req.method, host: host, target: sent_req.target, scheme: scheme, status: resp.status) &&
         !resp_framing.close_delimited? && !sse?(resp) && !websocket_upgrade?(resp)
        return handle_held_response(ic, upstream, req, flow_id, host, port, scheme,
          resp, sent_resp_head, resp_framing, resp_len, ttfb, started)
      end

      # Non-hold path: stream the response body byte-for-byte (P6), unchanged.
      @io.write(sent_resp_head)
      @io.flush
      resp_capture = Codec::CaptureBuffer.new(Codec::Body::CAPTURE_MAX)
      resp_complete = Codec::Body.stream(upstream, @io, resp_framing, resp_len, resp_capture)
      duration = (Time.instant - started).total_microseconds.to_i64
      resp_body = resp_framing.none? ? nil : resp_capture.to_slice
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: resp_body, ttfb_us: ttfb, duration_us: duration,
        body_truncated: resp_capture.truncated?, body_size: resp_capture.total))

      if websocket_upgrade?(resp)
        # Ownership of the upstream transfers to the relay (it cross-closes on
        # teardown); detach it from the reuse slot so `run`'s ensure won't also
        # touch it.
        @upstream = nil
        @up_host = nil
        @up_port = 0
        WS::Relay.run(@io, upstream, flow_id, @sink) # frames until close (P6/P7)
        return false
      end

      # A truncated body (upstream EOF'd before the promised length) was forwarded
      # short; close so the client sees end-of-response instead of waiting for the
      # missing bytes while we read its next keep-alive request.
      unless resp_complete
        release_upstream
        return false
      end
      # Reuse this upstream for the next request iff the ORIGIN keeps its side
      # open; the return value is the CLIENT keep-alive decision (separate sides).
      update_upstream_reuse(origin_keep_alive?(req, resp, resp_framing))
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
      resp_complete = Codec::Body.stream(upstream, buf, resp_framing, resp_len, Codec::DiscardIO.new)
      body = resp_framing.none? ? nil : buf.to_slice.dup
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
      # Reuse the upstream iff we read the WHOLE body cleanly AND the origin kept
      # its side alive. The CLIENT keep-alive (return value) uses the edited resp.
      update_upstream_reuse(resp_complete && origin_keep_alive?(req, resp, resp_framing))
      # A truncated upstream body was forwarded short — close the client connection so it
      # sees end-of-response instead of blocking for the missing bytes while we read its
      # next keep-alive request (mirrors the non-held path's resp_complete guard).
      return false unless resp_complete
      keep_alive?(req, sent_resp, Codec::Body.response_framing(sent_resp, req.method)[0])
    end

    # After a complete response, decide whether the live upstream can serve the
    # next request: keep it parked in the reuse slot, or close it now.
    private def update_upstream_reuse(origin_keep_alive : Bool) : Nil
      release_upstream unless origin_keep_alive
    end

    # Cleartext HTTP/2 (h2c) tunnelled inside a CONNECT: the target is the
    # CONNECT authority, so we dial it plaintext and run the same h2 relay (no
    # :authority routing / HPACK coupling needed). The origin must speak h2c.
    private def intercept_h2c(host : String, port : Int32, client : IO) : Nil
      upstream = Upstream.dial(host, port, overrides: @host_overrides)
      return unless upstream
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

      if tls = @tls
        @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
        @io.flush
        # Peek one byte to route the tunnel: a TLS ClientHello starts with 0x16
        # (handshake), the HTTP/2 cleartext preface with 'P' (0x50, "PRI ...").
        first = @io.read_byte
        return false if first.nil?
        stream = PrefixIO.new(Bytes[first], @io)
        if first == 0x50_u8
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
      return {body, false, nil} if body.size <= Codec::Body::CAPTURE_MAX
      {body[0, Codec::Body::CAPTURE_MAX].dup, true, body.size.to_i64}
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

    private def sse?(resp : Codec::RawResponse) : Bool
      ct = resp.headers.get?("Content-Type")
      !!ct && ct.downcase.includes?("text/event-stream")
    end

    private def write_gateway_error : Nil
      @io.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    private def keep_alive?(req : Codec::RawRequest, resp : Codec::RawResponse,
                            resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited? # body ends at close
      return false if header_token(req.headers.get?("Connection")) == "close"
      return false if header_token(resp.headers.get?("Connection")) == "close"
      req.version == "HTTP/1.1" || header_token(req.headers.get?("Connection")) == "keep-alive"
    end

    # Whether the ORIGIN will keep its connection open after this response, so its
    # upstream socket may be parked for the next request. Distinct from
    # `keep_alive?` (the CLIENT side, keyed on the request): persistence here is
    # the RESPONSE's — HTTP/1.1 persists unless `Connection: close`; HTTP/1.0 only
    # with explicit `Connection: keep-alive`. A close-delimited body, or a
    # `Connection: close` on the request we forwarded upstream OR on the response,
    # all mean the origin closes. Parking a connection the origin will close just
    # wastes one stale-retry on the next request, so err toward NOT reusing.
    private def origin_keep_alive?(req : Codec::RawRequest, resp : Codec::RawResponse,
                                   resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited?
      return false if header_token(req.headers.get?("Connection")) == "close"
      return false if header_token(resp.headers.get?("Connection")) == "close"
      resp.version == "HTTP/1.1" || header_token(resp.headers.get?("Connection")) == "keep-alive"
    end

    # Whether a request may be transparently REPLAYED on a fresh connection after a
    # stale-reuse failure. Only SAFE methods (RFC 7231 §4.2.1: GET/HEAD/OPTIONS/
    # TRACE — no side effects, idempotent) with NO body qualify: replay is then
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

    private def header_token(value : String?) : String?
      value.try(&.downcase.strip)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
