require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/codec/body"
require "../proxy/socket_tuning"

module Gori
  module Repeater
    # Outcome of one repeater send.
    struct Result
      getter head : Bytes  # response head bytes (empty on error)
      getter body : Bytes? # response body bytes
      getter response : Proxy::Codec::RawResponse?
      getter duration_us : Int64
      getter error : String?
      # The captured `body` is not the whole response the origin framed, for one of
      # two reasons: the origin closed early (a Content-Length cut short, or a chunked
      # body without its terminating 0-chunk), OR the body exceeded Body::CAPTURE_READ_MAX
      # and the read stopped at the ceiling (an oversized or endlessly-streaming origin).
      # Either way the socket has undelivered/unread bytes, so it must not be reused, and
      # a consumer must not treat a half-delivered response as the whole thing. Distinct
      # from a *display* truncation (gori capping what it shows).
      getter? incomplete : Bool
      # Whether ANY response byte (even an interim 1xx) was received before this Result was
      # built. It answers the one question the pool's stale-retry needs and `response.nil?`
      # cannot: a failure with no response yet means the request never reached the application
      # and is safe to re-send, but a failure AFTER a 1xx means the origin already has the whole
      # request (gori writes it up front), so re-sending would double a non-idempotent side
      # effect. Only set on the error paths; a normal Result carries a non-nil `response`, where
      # this is irrelevant.
      getter? delivered : Bool
      # The read ended on an IDLE TIMEOUT — the origin held the socket open and simply stopped
      # sending — rather than on a close or a completed body. `incomplete?` says the captured
      # response is short; this says which of the two events cut it, and without it the
      # renderers of "incomplete — origin closed before the framed body finished" were blaming
      # the origin for a connection it never closed. Set by the h2 engine, which computes it
      # per read; false everywhere else.
      getter? timed_out : Bool

      # This exchange is the SECOND copy of its request on the wire: a parked keep-alive
      # socket turned out closed, and `ConnPool` re-sent on a fresh connection. It is set
      # only for the methods the pool is willing to replay (see `ConnPool.replayable?`), and
      # it must reach the ROW a surface prints, not only the run's connections line — an
      # origin that reads a request and answers nothing has still processed it, so a replayed
      # request may have been acted on twice. `--format json` and MCP `fuzz_results` are where
      # an agent reads this, and both showed a clean single send.
      getter? retried : Bool

      # The tail is KEYWORD-ONLY (`*`), and that is load-bearing rather than a style choice.
      # `delivered`, `timed_out` and `retried` are three same-typed Bools that were appended one
      # per round by three different fixers; twice, a call site written against the previous
      # arity kept compiling and silently wrote its `true` into the field that had displaced
      # the one it meant (`as_retried` in round 4, `Fuzz::Engine#follow_redirects` in round 5 —
      # the latter still reporting `0 errors` while a row lost its re-send marker and gained a
      # `timed_out` nothing had observed). A grep cannot catch that reliably: the second site
      # was missed because the call spanned two lines and the sweep counted commas on the
      # first. A keyword-only tail turns the whole class of mistake into a compile error, and
      # leaves the sweep to the compiler.
      def initialize(@head, @body, @response, @duration_us, @error = nil, @incomplete = false, *,
                     @delivered = false, @timed_out = false, @retried = false)
      end

      def ok? : Bool
        @error.nil?
      end

      # The same outcome, flagged as a re-send. A struct, so this returns a copy rather than
      # mutating: `ConnPool` builds the Result through `Engine.exchange` and only then knows
      # it was a retry.
      def as_retried : Result
        # Named, not positional. Two fixers added a field to this constructor in the same round
        # and the merge reordered the tail — a positional `true` here silently set `timed_out`
        # instead, and the pool's re-send marker vanished with the suite still green but for the
        # one spec that asserted it. The constructor now REFUSES a positional tail (see there),
        # so this shape is the only one that compiles.
        Result.new(@head, @body, @response, @duration_us, @error, @incomplete,
          delivered: @delivered, timed_out: @timed_out, retried: true)
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
        upstream, dial_error = dial_result(scheme, host, port, verify_upstream, sni, timeout, overrides)
        return error(connect_error(scheme, host, port, verify_upstream, dial_error), started) unless upstream

        begin
          exchange(upstream, request, host, port, started)
        ensure
          upstream.close rescue nil
        end
      end

      # Opens ONE upstream connection to the origin, or nil when the dial (or, for https,
      # the TLS handshake) failed. Public because a keep-alive pool has to own the socket's
      # lifetime across many exchanges — `send` above is the same dial plus a single
      # exchange plus a close. `timeout` is the per-operation bound (connect, and idle
      # between reads/writes), exactly as in `send`.
      def self.dial(scheme : String, host : String, port : Int32, verify_upstream : Bool,
                    sni : String?, timeout : Time::Span?,
                    overrides : Gori::HostOverrides?) : IO?
        dial_result(scheme, host, port, verify_upstream, sni, timeout, overrides)[0]
      end

      # The same dial, paired with WHY there is no socket. Every active send path in gori
      # (repeater, fuzz, mine, sequence, discover, probe, MCP) reaches the network through
      # this one function or through `ConnPool`, which also uses it — so carrying the reason
      # here is what makes an upstream proxy's 407 legible on ALL of them rather than on one.
      def self.dial_result(scheme : String, host : String, port : Int32, verify_upstream : Bool,
                           sni : String?, timeout : Time::Span?,
                           overrides : Gori::HostOverrides?) : {IO?, Proxy::Upstream::DialError?}
        ct = timeout || Settings.connect_timeout
        it = timeout || Settings.io_timeout
        if scheme == "https"
          Proxy::Upstream.dial_tls_result(host, port, verify: verify_upstream, sni: sni,
            connect_timeout: ct, io_timeout: it, overrides: overrides)
        else
          Proxy::Upstream.dial_result(host, port, connect_timeout: ct, io_timeout: it, overrides: overrides)
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
        upstream, dial_error = dial_result(scheme, host, port, verify_upstream, sni, timeout, overrides)
        unless upstream
          msg = connect_error(scheme, host, port, verify_upstream, dial_error)
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
            # A failed OR incomplete exchange leaves the socket unusable for the rest: an
            # error is self-evident; an incomplete body (origin cut it short, or we hit the
            # CAPTURE_READ_MAX ceiling) leaves unread bytes on the wire, so reusing the
            # connection would misframe the next request (response desync).
            dead = true if r.error || r.incomplete?
          end
        ensure
          upstream.close rescue nil
        end
        results
      end

      # The exact error string a clean EOF before ANY response byte produces. A keep-alive
      # pool matches on it to tell "the origin had already closed this parked socket" (retry
      # once on a fresh connection) apart from a timeout or a mid-response failure (never
      # retried — the origin may well have processed the request).
      #
      # There is no `DialError` to read here — the DIAL succeeded (a proxy that answers `200
      # Connection Established` and then closes is a successful tunnel open, by the CONNECT
      # protocol's own rules); the silence only shows up later, on this first read. So this
      # asks `Settings.upstream_route` directly, the same single decision point `dial_result`
      # itself consults — the only way to reach the fact from here without threading a new
      # value through every dial's return tuple (which would touch `ClientConn`'s live-MITM
      # path and every other engine's signature for a clause only THIS message needs). A plain,
      # unproxied miss keeps today's exact wording: `proxied_via` is nil for a direct route.
      def self.no_response_error(host : String, port : Int32) : String
        "no response from #{host}:#{port}#{Proxy::Upstream.proxy_tunnel_note(Proxy::Upstream.proxied_via(host))}"
      end

      # Writes one request on an already-open connection and reads its single response
      # (skipping interim 1xx). Fully self-contained: any IO/parse failure becomes an error
      # Result rather than propagating, so a group send can decide what to do next. `started`
      # is when timing began (pre-dial for a one-shot send; per-request for a group).
      #
      # Public because `send_pipeline` is not the only multi-request-per-connection caller
      # any more: `Fuzz::ConnPool` reuses one socket across a sweep's requests. Both apply
      # the SAME retirement rule to the socket afterwards (error or incomplete ⇒ unusable).
      def self.exchange(upstream : IO, request : Bytes, host : String, port : Int32,
                        started : Time::Instant) : Result
        upstream.write(request)
        upstream.flush
        head = read_response_head(upstream)
        return error(no_response_error(host, port), started) unless head

        resp = Proxy::Codec::Http1.parse_response_head(head)
        # Skip interim 1xx informational responses (RFC 9110 §15.2): a captured request
        # carrying `Expect: 100-continue`, or an origin/CDN that emits 103 Early Hints,
        # would otherwise return the 100/103 as the repeater result. Read on until the final
        # (>=200) status. 101 Switching Protocols is terminal (a protocol upgrade), NOT skipped.
        interim_seen = 0
        # The LAST interim status read, for the rescue below: a raise AFTER a 1xx is a
        # different event from a raise before one, and only this loop knows which happened.
        interim_status = nil.as(Int32?)
        while resp.status >= 100 && resp.status < 200 && resp.status != 101
          # RFC 9112 §6: a 1xx MUST NOT carry content. One that declares a body
          # (Content-Length / Transfer-Encoding) is malformed and a desync vector
          # (its body can embed a fake final response) — refuse it.
          if resp.headers.get?("Content-Length") || resp.headers.get?("Transfer-Encoding")
            return error("malformed interim 1xx response (declared a body) from #{host}:#{port}", started, delivered: true)
          end
          # Cap the run so an origin streaming endless body-less 103s can't hang the
          # repeater/fuzz worker fiber indefinitely (there is no whole-request deadline).
          interim_seen += 1
          interim_status = resp.status
          return error("too many interim 1xx responses from #{host}:#{port}", started, delivered: true) if interim_seen > MAX_INTERIM
          head = read_response_head(upstream)
          return error("upstream closed after interim 1xx from #{host}:#{port}", started, delivered: true) unless head
          resp = Proxy::Codec::Http1.parse_response_head(head)
        end
        # A reply whose status-line can't be parsed (no HTTP-version, or a non-numeric status —
        # garbage/non-HTTP, or an h2 stack answering this h1 request) is flagged `malformed?` by
        # parse_response_head but was otherwise returned as {ok:true,status:0} — a false success,
        # and precisely the desync/smuggling anomaly send_pipeline exists to surface. Report it as
        # a failure with a descriptive error, but keep the raw head + parsed projection so the
        # workbench still shows the bytes that came back. No body is read: with no valid framing
        # anything after the head is unstructured, and (in a group) `error` already retires the
        # socket so the next request won't be misframed against these leftovers.
        if resp.malformed?
          return Result.new(head, nil, resp, elapsed(started),
            error: "malformed/non-HTTP response from #{host}:#{port} (status line unparseable)")
        end
        begin
          framing, len = Proxy::Codec::Body.response_framing(resp, request_method(request))
          # Cap the capture read at CAPTURE_READ_MAX (parity with the h2 engine's MAX_BODY):
          # without it a streaming origin (SSE/heartbeat) or a multi-GB body hangs or OOMs
          # this single-threaded send. A capped body comes back complete:false → incomplete.
          body, complete = Proxy::Codec::Body.read_complete(upstream, framing, len, Proxy::Codec::Body::CAPTURE_READ_MAX)
          Result.new(head, body, resp, elapsed(started), incomplete: !complete)
        rescue ex
          # The head was already read + parsed. A framing rejection (CL+TE — precisely the
          # ambiguous response a smuggling/desync probe is hunting) or a mid-body read error
          # must NOT throw the head away as a bare error string. Keep the head + parsed
          # response, flag incomplete, and carry the reason so the workbench shows both.
          Result.new(head, nil, resp, elapsed(started), error: ex.message || "response read failed", incomplete: true)
        end
      rescue ex
        # `head` is nil iff we failed before/at the FIRST head read (a write error, or a reset
        # on a parked socket) — the pre-delivery case the pool may re-send. A raise AFTER a head
        # was read (an interim-1xx read that then reset) means the origin already has the whole
        # request, so mark it delivered and do not re-send a non-idempotent one.
        error(exchange_error(ex, host, port, interim_status), started, delivered: !head.nil?)
      end

      # The sentence for a raise DURING the exchange.
      #
      # A bare `ex.message` — `"Read timed out"` — names neither the origin nor the one fact
      # that decides what a caller may do next. An origin that answers `100 Continue` and then
      # goes silent is the h1 twin of the case `H2Engine.no_response` writes a careful sentence
      # for, and it read identically to a plain silent origin: same message, same `error_kind`,
      # and (before `delivered?` reached a surface) the same `retryable: true`. The two are
      # opposite instructions — the interim proves the origin has the whole request, because
      # gori writes it up front.
      #
      # Only the INTERIM case is reworded. With no interim there is nothing gori knows that
      # `ex.message` does not, and inventing a host-shaped sentence for every socket error
      # would blur it into the dialer's own vocabulary.
      private def self.exchange_error(ex : Exception, host : String, port : Int32,
                                      interim : Int32?) : String
        base = ex.message.presence || "repeater error"
        return base unless interim
        tail = ex.is_a?(IO::TimeoutError) ? "nothing more before the read timed out" : "the connection failed (#{base})"
        "no response from #{host}:#{port} — the origin sent an interim #{interim} and then " \
        "#{tail} (RFC 9110 §15.2: a 1xx precedes the final response, it is not one)"
      end

      # Read a response head with a TOTAL head-assembly deadline (parity with the proxy's
      # client read, client_conn.cr:111). The per-operation io_timeout only bounds the gap
      # BETWEEN reads, so a slowloris origin dripping the head one byte at a time (each byte
      # inside io_timeout) would pin this read — and, since the MCP server is single-threaded,
      # freeze every other tool. HEAD_DEADLINE caps the whole head. underlying_socket returns
      # nil for an IO with no settable socket, in which case read_head simply skips the
      # deadline (unchanged behaviour), so this is safe on every transport.
      private def self.read_response_head(upstream : IO) : Bytes?
        Proxy::Codec::Http1.read_head(upstream,
          deadline: Proxy::SocketTuning::HEAD_DEADLINE,
          timeout_sock: Proxy::SocketTuning.underlying_socket(upstream))
      end

      # An error Result with no head/body, timed from `started` (shared with the pool, which
      # reports a failed dial the same way `send` does).
      def self.error(message : String, started : Time::Instant, delivered : Bool = false) : Result
        Result.new(Bytes.new(0), nil, nil, elapsed(started), message, delivered: delivered)
      end

      # Why the dial produced no socket.
      #
      # `err` is the dialer's own account of it and is used VERBATIM when it has one, because
      # the cases it can name are exactly the cases this function cannot guess: an upstream
      # proxy that answered 407/403/502, or one gori could not reach at all. Guessing was the
      # defect — a corporate proxy refusing the tunnel arrived at the operator as
      # "host unreachable (DNS/refused/timeout)" naming the ORIGIN, so the next hour went on
      # DNS and firewall rules for a host gori had never tried to contact.
      #
      # With no detail the KIND still answers which layer broke, and that is the whole reason
      # `DialErrorKind` exists (`upstream.cr`: "a surface can say WHICH LAYER broke instead of
      # a blanket 'connect failed'"). `dial_tls_result` returns a TLS kind only after the TCP
      # connect SUCCEEDED and the handshake raised, and `Connect` whenever the socket itself
      # never came up — so the cases an operator has to tell apart (a firewall problem, a name
      # that does not resolve, an untrusted origin cert, "this port is not TLS", and an origin
      # that accepts the connection and then says nothing) are already separated by the time
      # this runs. The proxy path has said so since #323
      # (`client_conn.cr#upstream_error_message`); every DIRECT sender — repeater, fuzz, mine,
      # sequence, discover, probe active, and `ConnPool` — collapsed them into one sentence
      # that named the first, which sent operators to debug DNS for a self-signed cert.
      #
      # `verify` is no longer consulted either: the dialer reports `TlsVerify` only when
      # certificate verification is what rejected the origin, so the remedy is offered to the
      # people it can actually help. Guessing it from the flag is what made a black hole and a
      # plaintext port both read as an untrusted certificate under verify-on. It stays in the
      # signature because every send path passes it positionally.
      #
      # `scheme` is not consulted: only an https dial can produce a TLS kind, and a Connect
      # kind means the TCP layer, whatever the scheme. Same reason for keeping it.
      def self.connect_error(scheme : String, host : String, port : Int32, verify : Bool,
                             err : Proxy::Upstream::DialError? = nil) : String
        if detail = err.try(&.detail)
          return "connect failed: #{detail}"
        end
        if err
          case err.kind
          when .tls_verify?
            return "TLS verification failed: #{host}:#{port} — the origin's certificate is not " \
                   "trusted (self-signed/expired/wrong name); retry with -k/--insecure-upstream " \
                   "or set SSL_CERT_FILE#{err.because}"
          when .tls?
            return "TLS handshake failed: #{host}:#{port} — the port may not be TLS, or the origin " \
                   "refused the protocol/cipher#{err.because}#{err.proxy_note}"
          when .timeout?
            return "TLS handshake timed out: #{host}:#{port} — the origin accepted the connection " \
                   "and then sent nothing; no certificate was exchanged, so -k and SSL_CERT_FILE " \
                   "cannot help#{err.because}#{err.proxy_note}"
          when .dns?
            return "connect failed: #{host} — the name did not resolve, so nothing was dialed#{err.because}"
          end
        end
        # Reached only when the TCP layer is what failed, so the TLS clause that used to ride
        # along here (and made this a catch-all) is gone. "DNS" stays in the list because a
        # dial through an upstream proxy resolves at the PROXY, where gori cannot see it.
        "connect failed: #{host}:#{port} — host unreachable (DNS/refused/timeout)"
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end

      # First whitespace-delimited token of the request = the method (for framing).
      #
      # NOT private: `exchange` frames the response by this, which decides how many bytes it
      # consumes off the socket, and `Fuzz::ConnPool` must decide whether the socket is
      # REUSABLE from the identical derivation. Two independent guesses at the method would
      # let the pool park a socket with an unread body on it (a HEAD vs GET disagreement is
      # exactly that shape), so there is one function and both callers use it.
      def self.request_method(request : Bytes) : String
        head = String.new(request[0, {request.size, 16}.min])
        head.split.first? || "GET" # no-arg split collapses leading/runs of whitespace
      end
    end
  end
end
