require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/codec/body"

module Gori
  module Replay
    # Outcome of one replay send.
    struct Result
      getter head : Bytes  # response head bytes (empty on error)
      getter body : Bytes? # response body bytes
      getter response : Proxy::Codec::RawResponse?
      getter duration_us : Int64
      getter error : String?
      # The origin closed before delivering the full body it framed: a
      # Content-Length cut short, or a chunked body without its terminating
      # 0-chunk. The captured `body` is what actually arrived — distinct from a
      # *display* truncation (gori capping what it shows). A consumer must not
      # treat a half-delivered response as the whole thing.
      getter? incomplete : Bool

      def initialize(@head, @body, @response, @duration_us, @error = nil, @incomplete = false)
      end

      def ok? : Bool
        @error.nil?
      end
    end

    # Sends a request byte-exact to its origin and captures the response (P7).
    # Reuses the proxy's dialer/codec; no proxying — this is a direct send.
    module Engine
      def self.send(request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    timeout : Time::Span? = nil) : Result
        started = Time.instant
        # `timeout` is a PER-OPERATION bound (connect, and idle between reads/writes),
        # not a total request deadline — same model as the proxy's IO_TIMEOUT. A true
        # whole-request deadline would need a timer fiber racing a socket close.
        ct = timeout || Proxy::Upstream::CONNECT_TIMEOUT
        it = timeout || Proxy::Upstream::IO_TIMEOUT
        upstream = scheme == "https" ? Proxy::Upstream.dial_tls(host, port, verify: verify_upstream, sni: sni, connect_timeout: ct, io_timeout: it) : Proxy::Upstream.dial(host, port, connect_timeout: ct, io_timeout: it)
        return error("connect failed: #{host}:#{port}", started) unless upstream

        begin
          upstream.write(request)
          upstream.flush
          head = Proxy::Codec::Http1.read_head(upstream)
          return error("no response from #{host}:#{port}", started) unless head

          resp = Proxy::Codec::Http1.parse_response_head(head)
          # Skip interim 1xx informational responses (RFC 9110 §15.2): a captured
          # request carrying `Expect: 100-continue`, or an origin/CDN that emits
          # 103 Early Hints, would otherwise return the 100/103 as the replay
          # result. Read on until the final (>=200) status. 101 Switching Protocols
          # is terminal (a protocol upgrade), so it is NOT skipped.
          while resp.status >= 100 && resp.status < 200 && resp.status != 101
            # RFC 9112 §6: a 1xx MUST NOT carry content. One that declares a body
            # (Content-Length / Transfer-Encoding) is malformed and a desync vector
            # (its body can embed a fake final response) — refuse it.
            if resp.headers.get?("Content-Length") || resp.headers.get?("Transfer-Encoding")
              return error("malformed interim 1xx response (declared a body) from #{host}:#{port}", started)
            end
            head = Proxy::Codec::Http1.read_head(upstream)
            return error("upstream closed after interim 1xx from #{host}:#{port}", started) unless head
            resp = Proxy::Codec::Http1.parse_response_head(head)
          end
          framing, len = Proxy::Codec::Body.response_framing(resp, request_method(request))
          body, complete = Proxy::Codec::Body.read_complete(upstream, framing, len)
          Result.new(head, body, resp, elapsed(started), incomplete: !complete)
        rescue ex
          error(ex.message || "replay error", started)
        ensure
          upstream.close rescue nil
        end
      end

      private def self.error(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message)
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end

      # First whitespace-delimited token of the request = the method (for framing).
      private def self.request_method(request : Bytes) : String
        head = String.new(request[0, {request.size, 16}.min])
        head.split.first? || "GET" # no-arg split collapses leading/runs of whitespace
      end
    end
  end
end
