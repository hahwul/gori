require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/codec/body"

module Gori
  module Repeater
    # Outcome of one repeater send.
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
      MAX_INTERIM = 64 # cap a run of interim 1xx responses (hostile-origin guard)

      def self.send(request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    timeout : Time::Span? = nil,
                    overrides : Gori::HostOverrides? = nil) : Result
        started = Time.instant
        # `timeout` is a PER-OPERATION bound (connect, and idle between reads/writes),
        # not a total request deadline — same model as the proxy's IO_TIMEOUT. A true
        # whole-request deadline would need a timer fiber racing a socket close.
        ct = timeout || Settings.connect_timeout
        it = timeout || Settings.io_timeout
        upstream = scheme == "https" ? Proxy::Upstream.dial_tls(host, port, verify: verify_upstream, sni: sni, connect_timeout: ct, io_timeout: it, overrides: overrides) : Proxy::Upstream.dial(host, port, connect_timeout: ct, io_timeout: it, overrides: overrides)
        return error(connect_error(scheme, host, port, verify_upstream), started) unless upstream

        begin
          exchange(upstream, request, host, port, started)
        ensure
          upstream.close rescue nil
        end
      end

      # Sends several requests back-to-back on ONE keep-alive connection, capturing each
      # response in order — the primitive behind Repeater's "send group". Active HTTP request
      # smuggling (CL.TE / TE.CL desync) and keep-alive-reuse probes NEED this: a desync
      # induced by request N surfaces only as a corrupted/misaligned response to request N+1
      # on the SAME socket, which the fresh-connection-per-send path can never reveal.
      #
      # Requests are sent AS GIVEN — the caller owns the framing (a deliberately wrong
      # Content-Length is the whole point), so nothing here rewrites them. Sequential
      # send→receive (write a request, read its one response, then the next). Once an
      # exchange errors the socket is treated as unusable: the remaining requests return a
      # "skipped" Result rather than dialing again (a group is ONE connection by definition).
      def self.send_pipeline(requests : Array(Bytes), *, scheme : String, host : String, port : Int32,
                             verify_upstream : Bool, sni : String? = nil,
                             timeout : Time::Span? = nil,
                             overrides : Gori::HostOverrides? = nil) : Array(Result)
        results = [] of Result
        return results if requests.empty?
        ct = timeout || Settings.connect_timeout
        it = timeout || Settings.io_timeout
        upstream = scheme == "https" ? Proxy::Upstream.dial_tls(host, port, verify: verify_upstream, sni: sni, connect_timeout: ct, io_timeout: it, overrides: overrides) : Proxy::Upstream.dial(host, port, connect_timeout: ct, io_timeout: it, overrides: overrides)
        unless upstream
          msg = connect_error(scheme, host, port, verify_upstream)
          now = Time.instant
          requests.size.times { results << error(msg, now) }
          return results
        end
        begin
          dead = false
          requests.each do |request|
            if dead
              results << Result.new(Bytes.new(0), nil, nil, 0_i64, "skipped — the connection closed earlier in the group")
              next
            end
            r = exchange(upstream, request, host, port, Time.instant)
            results << r
            dead = true if r.error # a failed exchange leaves the socket state unusable for the rest
          end
        ensure
          upstream.close rescue nil
        end
        results
      end

      # Writes one request on an already-open connection and reads its single response
      # (skipping interim 1xx). Fully self-contained: any IO/parse failure becomes an error
      # Result rather than propagating, so a group send can decide what to do next. `started`
      # is when timing began (pre-dial for a one-shot send; per-request for a group).
      private def self.exchange(upstream : IO, request : Bytes, host : String, port : Int32,
                                started : Time::Instant) : Result
        upstream.write(request)
        upstream.flush
        head = Proxy::Codec::Http1.read_head(upstream)
        return error("no response from #{host}:#{port}", started) unless head

        resp = Proxy::Codec::Http1.parse_response_head(head)
        # Skip interim 1xx informational responses (RFC 9110 §15.2): a captured request
        # carrying `Expect: 100-continue`, or an origin/CDN that emits 103 Early Hints,
        # would otherwise return the 100/103 as the repeater result. Read on until the final
        # (>=200) status. 101 Switching Protocols is terminal (a protocol upgrade), NOT skipped.
        interim_seen = 0
        while resp.status >= 100 && resp.status < 200 && resp.status != 101
          # RFC 9112 §6: a 1xx MUST NOT carry content. One that declares a body
          # (Content-Length / Transfer-Encoding) is malformed and a desync vector
          # (its body can embed a fake final response) — refuse it.
          if resp.headers.get?("Content-Length") || resp.headers.get?("Transfer-Encoding")
            return error("malformed interim 1xx response (declared a body) from #{host}:#{port}", started)
          end
          # Cap the run so an origin streaming endless body-less 103s can't hang the
          # repeater/fuzz worker fiber indefinitely (there is no whole-request deadline).
          interim_seen += 1
          return error("too many interim 1xx responses from #{host}:#{port}", started) if interim_seen > MAX_INTERIM
          head = Proxy::Codec::Http1.read_head(upstream)
          return error("upstream closed after interim 1xx from #{host}:#{port}", started) unless head
          resp = Proxy::Codec::Http1.parse_response_head(head)
        end
        begin
          framing, len = Proxy::Codec::Body.response_framing(resp, request_method(request))
          body, complete = Proxy::Codec::Body.read_complete(upstream, framing, len)
          Result.new(head, body, resp, elapsed(started), incomplete: !complete)
        rescue ex
          # The head was already read + parsed. A framing rejection (CL+TE — precisely the
          # ambiguous response a smuggling/desync probe is hunting) or a mid-body read error
          # must NOT throw the head away as a bare error string. Keep the head + parsed
          # response, flag incomplete, and carry the reason so the workbench shows both.
          Result.new(head, nil, resp, elapsed(started), error: ex.message || "response read failed", incomplete: true)
        end
      rescue ex
        error(ex.message || "repeater error", started)
      end

      private def self.error(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message)
      end

      # The dialer collapses DNS failure / connection refused / timeout / TLS-verify
      # rejection into a single nil socket, so spell out the likely causes — and, for
      # verified https, that a self-signed/expired cert is a common one — rather than
      # leaving the user with a bare "connect failed".
      private def self.connect_error(scheme : String, host : String, port : Int32, verify : Bool) : String
        if scheme == "https" && verify
          "connect failed: #{host}:#{port} — host unreachable (DNS/refused/timeout) or the origin's TLS certificate failed verification (e.g. self-signed/expired)"
        else
          "connect failed: #{host}:#{port} — host unreachable (DNS/refused/timeout)"
        end
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
