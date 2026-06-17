require "uri"
require "../codec/http1"
require "../codec/body"
require "../sink"
require "../head_rewriter"
require "../../interceptor"
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
    # `fixed_host`/`fixed_port` pin all requests to one origin (post-CONNECT TLS
    # tunnel); when nil the upstream is resolved per request from the target /
    # Host header (plaintext forward proxy). `tls_upstream` wraps the origin
    # connection in TLS.
    def initialize(@io : IO, @scheme : String, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @fixed_host : String? = nil, @fixed_port : Int32 = 0,
                   @tls_upstream : Bool = false, @verify_upstream : Bool = true,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil)
    end

    def run : Nil
      loop do
        break unless handle_request
      end
    rescue
      # any IO error (reset, timeout, broken pipe) ends the connection
    ensure
      @io.close rescue nil
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
      # path keeps zero-buffer streaming (P6).
      if (ic = @interceptor) && ic.intercepts_host?(host)
        buffered = Codec::Body.read(@io, req_framing, req_len)
        decision = ic.hold_request(build_message(sent_head, buffered),
          method: sent_req.method, target: sent_req.target,
          host: host, port: port, scheme: scheme)
        if decision.action.drop?
          record_dropped_request(sent_req, scheme, host, port, created_at, buffered)
          write_intercept_drop
          return false
        end
        # forward (edited or original): re-parse the sent head for capture (P7).
        sent_head, edited_body = split_message(decision.bytes)
        sent_req = Codec::Http1.parse_request_head(sent_head)
        upstream = open_upstream(host, port)
        unless upstream
          record_error(sent_req, scheme, host, port, created_at, "upstream connect failed: #{host}:#{port}")
          write_gateway_error
          return false
        end
        begin
          upstream.write(sent_head)
          upstream.write(edited_body) if edited_body
          upstream.flush
          flow_id = @sink.on_request(FlowMapper.request(sent_req,
            scheme: scheme, host: host, port: port, created_at: created_at, body: edited_body))
          return handle_response(upstream, req, flow_id, started, host, port, scheme)
        ensure
          upstream.close rescue nil
        end
      end

      # Non-hold path: stream the request body byte-for-byte (P6), unchanged.
      upstream = open_upstream(host, port)
      unless upstream
        record_error(req, scheme, host, port, created_at, "upstream connect failed: #{host}:#{port}")
        write_gateway_error
        return false
      end
      begin
        upstream.write(sent_head)
        req_capture = IO::Memory.new
        Codec::Body.stream(@io, upstream, req_framing, req_len, req_capture)
        upstream.flush
        req_body = req_framing.none? ? nil : req_capture.to_slice.dup
        flow_id = @sink.on_request(FlowMapper.request(sent_req,
          scheme: scheme, host: host, port: port, created_at: created_at, body: req_body))
        handle_response(upstream, req, flow_id, started, host, port, scheme)
      ensure
        upstream.close rescue nil
      end
    end

    # Reads, (optionally holds), forwards, and captures the response. `req` is the
    # ORIGINAL request (framing/keep-alive/method come from it). Returns true to
    # keep the connection alive.
    private def handle_response(upstream : IO, req : Codec::RawRequest, flow_id : Int64,
                                started : Time::Instant, host : String, port : Int32, scheme : String) : Bool
      resp_head = Codec::Http1.read_head(upstream)
      if resp_head.nil?
        @sink.on_response(FlowMapper.error_response(flow_id, "no response from upstream"))
        return false
      end
      ttfb = (Time.instant - started).total_microseconds.to_i64
      resp = Codec::Http1.parse_response_head(resp_head)

      # Match&Replace (response head). Framing/keep-alive/upgrade stay on the
      # ORIGINAL response so the upstream body is read correctly.
      sent_resp = resp
      sent_resp_head = resp_head
      if rw = @rewriter
        rewritten = rw.rewrite_response(resp_head)
        if rewritten != resp_head
          sent_resp_head = rewritten
          sent_resp = Codec::Http1.parse_response_head(rewritten)
        end
      end

      resp_framing, resp_len = Codec::Body.response_framing(resp, req.method)

      # Intercept (response): hold only in-scope, non-streaming responses. SSE /
      # close-delimited / WebSocket bodies would buffer forever, so they bypass.
      if (ic = @interceptor) && ic.intercepts_host?(host) &&
         !resp_framing.close_delimited? && !sse?(resp) && !websocket_upgrade?(resp)
        body = Codec::Body.read(upstream, resp_framing, resp_len)
        decision = ic.hold_response(build_message(sent_resp_head, body),
          flow_id: flow_id, method: req.method, target: "#{resp.status} #{resp.reason}",
          host: host, port: port, scheme: scheme)
        duration = (Time.instant - started).total_microseconds.to_i64
        if decision.action.drop?
          @sink.on_response(FlowMapper.aborted_response(flow_id, "dropped by intercept",
            ttfb_us: ttfb, duration_us: duration))
          write_intercept_drop
          return false
        end
        out_head, out_body = split_message(decision.bytes)
        sent_resp = Codec::Http1.parse_response_head(out_head)
        @io.write(out_head)
        @io.write(out_body) if out_body
        @io.flush
        @sink.on_response(FlowMapper.response(sent_resp,
          flow_id: flow_id, body: out_body, ttfb_us: ttfb, duration_us: duration))
        return keep_alive?(req, sent_resp, Codec::Body.response_framing(sent_resp, req.method)[0])
      end

      # Non-hold path: stream the response body byte-for-byte (P6), unchanged.
      @io.write(sent_resp_head)
      @io.flush
      resp_capture = IO::Memory.new
      Codec::Body.stream(upstream, @io, resp_framing, resp_len, resp_capture)
      duration = (Time.instant - started).total_microseconds.to_i64
      resp_body = resp_framing.none? ? nil : resp_capture.to_slice.dup
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: resp_body, ttfb_us: ttfb, duration_us: duration))

      if websocket_upgrade?(resp)
        WS::Relay.run(@io, upstream, flow_id, @sink) # frames until close (P6/P7)
        return false
      end

      keep_alive?(req, resp, resp_framing)
    end

    # Cleartext HTTP/2 (h2c) tunnelled inside a CONNECT: the target is the
    # CONNECT authority, so we dial it plaintext and run the same h2 relay (no
    # :authority routing / HPACK coupling needed). The origin must speak h2c.
    private def intercept_h2c(host : String, port : Int32, client : IO) : Nil
      upstream = Upstream.dial(host, port)
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
        upstream = Upstream.dial(host, port)
        unless upstream
          write_gateway_error
          return false
        end
        @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
        @io.flush
        Pump.blind_tunnel(@io, upstream)
        upstream.close rescue nil
      end
      false # the connection has been consumed by the tunnel
    end

    # Resolves {host, port, scheme, forward_head}. Absolute-form request targets
    # (forward-proxy plain HTTP, e.g. `GET http://h/p`) are rewritten to
    # origin-form for the upstream; the captured truth keeps the original bytes.
    private def open_upstream(host : String, port : Int32) : IO?
      if @tls_upstream
        Upstream.dial_tls(host, port, verify: @verify_upstream)
      else
        Upstream.dial(host, port)
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

    private def record_error(req, scheme, host, port, created_at, message) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: nil))
      @sink.on_response(FlowMapper.error_response(flow_id, message))
    end

    # A dropped request never reaches upstream; record it as an Aborted flow so
    # the human sees the attempt + decision (P4/P7).
    private def record_dropped_request(req, scheme, host, port, created_at, body) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: body))
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

    private def header_token(value : String?) : String?
      value.try(&.downcase.strip)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
