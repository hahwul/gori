require "../proxy/codec/body"
require "../proxy/codec/http1"
require "./engine"

module Gori::Repeater
  # HTTP/1.1 keep-alive connection pool for a sweep's sends.
  #
  # Lives beside `Repeater::Engine` rather than under `Fuzz` because it is pure transport
  # over that engine's own primitives (`dial` / `exchange` / `error`) and has two callers
  # now: `Fuzz::Sender`, which pools ONE origin for a whole sweep, and `Discover::Sender`,
  # which keeps one of these per origin because a crawl derives URLs on several in-scope
  # hosts. Nothing in here knows which sweep it is serving. `Fuzz::ConnPool` remains as an
  # alias, so the fuzz-side name in specs and comments still resolves.
  #
  # `Repeater::Engine.send` dials a fresh connection, exchanges one request, and closes —
  # correct for the Repeater (one operator-triggered send) but the dominant cost of a
  # SWEEP, which sends the same shape thousands of times to one origin. Per request that
  # is a TCP handshake (1 RTT) plus, on https, a TLS handshake (1-2 more RTTs and the
  # asymmetric crypto that goes with it) before a single payload byte moves. Reusing the
  # socket amortises all of it: at concurrency C a run costs ~C handshakes instead of N.
  #
  # gori is a security tool pointed at deliberately odd requests, so reuse is OPT-IN per
  # message, not a blanket keep-alive loop. A connection is parked for reuse only when BOTH
  # ends of the exchange are unambiguously framed:
  #
  #   request  — HTTP/1.1, no `Connection: close`/`Upgrade`, framing that `request_framing`
  #              accepts (so no CL+TE, no obfuscated header), and a body whose LENGTH ON THE
  #              WIRE matches what the head declares. That last check is what keeps a
  #              smuggling payload (a deliberately short/long Content-Length) off a shared
  #              socket: its leftover bytes would be read by the origin as the START of the
  #              next request, and the next payload's result would be somebody else's
  #              response. Those requests get a fresh connection each, exactly as today.
  #   response — no error, not incomplete, HTTP/1.1 (or 1.0 with an explicit keep-alive),
  #              no `Connection: close`, not a 101, and framed by Content-Length or chunked
  #              rather than close-delimited (a close-delimited body ends WITH the socket).
  #
  # Concurrency: the scheduler is single-threaded (no `-Dpreview_mt`), and neither the idle
  # array's `pop`/`push` nor the counter bumps yield, so a worker fiber can never observe a
  # half-updated pool. The array is a LIFO free list — the most recently used socket is the
  # least likely to have hit the origin's idle timeout.
  class ConnPool
    # A parked socket the origin closed while it sat idle is normal (every server has a
    # keep-alive idle timeout) and must not surface as a failed result: the request never
    # reached the application, so it is re-sent once on a fresh connection. Detected as a
    # clean EOF before ANY response byte — a timeout, or a failure part-way through a
    # response, is NOT retried, because the origin may well have processed the request.
    #
    # An origin that refuses reuse outright would otherwise pay that redial on every single
    # send (two connections per request — worse than not pooling). After this many
    # consecutive stale checkouts the pool gives up and runs in dial-per-send mode for the
    # rest of the run.
    #
    # On `max_requests`: a stale re-send is NOT charged a second time against the cap
    # (CappedBackend counts calls into the Sender, and this retry happens below it). That
    # keeps the cap meaning what it says — an upper bound on requests the ORIGIN PROCESSES —
    # since the re-sent one is precisely the one it demonstrably did not. The observable
    # slack is TCP connections, not requests, and STALE_GIVE_UP bounds it to a handful.
    STALE_GIVE_UP = 3

    # Connections dialed (== handshakes paid) and requests served off a parked socket.
    # `dialed + reused == sends` for a run that never hit a stale retry.
    getter dialed : Int64 = 0_i64
    getter reused : Int64 = 0_i64
    # Re-sends caused by a parked socket the origin had already closed (see STALE_GIVE_UP).
    getter stale_retries : Int64 = 0_i64
    getter? pooling : Bool = true

    # The origin is taken apart rather than as a struct: `Fuzz::Origin` (which folds ws→http)
    # and a Discover URL's `Url::Parts` are different types carrying the same three fields,
    # and the pool needs nothing else from either.
    def initialize(@scheme : String, @host : String, @port : Int32, @verify : Bool,
                   @sni : String?, @timeout : Time::Span?,
                   @overrides : Gori::HostOverrides?, @max_idle : Int32)
      @idle = [] of IO
      @consecutive_stale = 0
    end

    # Send one request, over a parked connection when both this request and the pool's
    # state allow it. Never raises: every failure comes back as an error `Result`, exactly
    # as `Repeater::Engine.send` does.
    def send(bytes : Bytes) : Repeater::Result
      keepable = @pooling && ConnPool.reusable_request?(bytes)
      # The SAME derivation `exchange` frames the response by (Repeater::Engine.request_method),
      # threaded down to the reuse decision so the two can never disagree about how many body
      # bytes were consumed — see reusable_response?.
      method = Repeater::Engine.request_method(bytes)
      if keepable && (io = @idle.pop?)
        started = Time.instant
        result = Repeater::Engine.exchange(io, bytes, @host, @port, started)
        if stale?(result)
          close(io)
          @stale_retries += 1
          @consecutive_stale += 1
          # Give up on pooling for the rest of the run rather than pay a wasted redial on
          # every send. Already-parked sockets are dropped: they are the same vintage.
          if @consecutive_stale >= STALE_GIVE_UP
            @pooling = false
            drain
          end
          return dial_and_send(bytes, keepable, method)
        end
        @consecutive_stale = 0
        @reused += 1
        recycle(io, result, keepable, method)
        return result
      end
      dial_and_send(bytes, keepable, method)
    end

    # Close every parked socket. Idempotent; call when a run ends so a stopped sweep does
    # not leave file descriptors open until GC.
    def close_all : Nil
      drain
    end

    private def dial_and_send(bytes : Bytes, keepable : Bool, method : String) : Repeater::Result
      # Timed from BEFORE the dial, like `Repeater::Engine.send` — a fresh connection's
      # handshake is part of what that request cost. A reused one honestly reports less.
      started = Time.instant
      io = Repeater::Engine.dial(@scheme, @host, @port, @verify,
        @sni, @timeout, @overrides)
      unless io
        return Repeater::Engine.error(
          Repeater::Engine.connect_error(@scheme, @host, @port, @verify), started)
      end
      @dialed += 1
      result = Repeater::Engine.exchange(io, bytes, @host, @port, started)
      recycle(io, result, keepable, method)
      result
    end

    # Park the socket for the next send, or close it. Same retirement rule `send_pipeline`
    # applies to a group's connection (error or incomplete ⇒ unusable), plus the response's
    # own keep-alive signals.
    private def recycle(io : IO, result : Repeater::Result, keepable : Bool, method : String) : Nil
      if @pooling && keepable && @idle.size < @max_idle && ConnPool.reusable_response?(result, method)
        @idle.push(io)
      else
        close(io)
      end
    end

    private def stale?(result : Repeater::Result) : Bool
      result.error == Repeater::Engine.no_response_error(@host, @port)
    end

    private def drain : Nil
      while io = @idle.pop?
        close(io)
      end
    end

    private def close(io : IO) : Nil
      io.close rescue nil
    end

    # ── reuse predicates (pure; specs drive them directly) ─────────────────────────

    # Whether this exact request may share a connection with the sweep's other requests.
    # Conservative by construction: anything this cannot prove is unambiguous gets its own
    # connection, which is just today's behaviour.
    def self.reusable_request?(bytes : Bytes) : Bool
      head_len = head_length(bytes)
      return false unless head_len
      req = Proxy::Codec::Http1.parse_request_head(bytes[0, head_len])
      return false if req.malformed?
      return false unless req.version == "HTTP/1.1"
      # CONNECT turns the connection into a tunnel; Upgrade hands it to another protocol.
      return false if req.method.compare("CONNECT", case_insensitive: true) == 0
      return false if req.headers.has?("Upgrade")
      return false if connection_close?(req.headers)
      # Raises on CL+TE, an obfuscated framing header, or a non-chunked TE — all of them
      # requests whose body length a lenient origin would read differently than gori does.
      framing, len = Proxy::Codec::Body.request_framing(req)
      body = bytes.size - head_len
      case framing
      in Proxy::Codec::BodyFraming::None
        body == 0
      in Proxy::Codec::BodyFraming::Length
        # The one check that keeps a request-smuggling payload off a shared socket: a
        # Content-Length that under- or over-declares the body leaves the origin's parser
        # mid-message, so whatever runs next on this connection is misframed.
        body.to_i64 == len
      in Proxy::Codec::BodyFraming::Chunked
        # A chunked body is reusable only if it actually terminates here. Cheap exact test:
        # the wire form must end with the zero-chunk + (empty) trailer section.
        ends_with?(bytes, "0\r\n\r\n".to_slice)
      in Proxy::Codec::BodyFraming::CloseDelimited
        false # responses only, but the enum is exhaustive
      end
    rescue
      false # Gori::Error from request_framing, or anything else — do not reuse
    end

    # Whether the origin left the connection usable for another request.
    #
    # `request_method` is the method `exchange` framed this response by, NOT a guess: response
    # framing is method-dependent (a HEAD reply carries no body however its Content-Length
    # reads, and CONNECT none at all), so deriving it separately here could disagree with how
    # many bytes were actually consumed off the socket and park one with a body still on it.
    # It defaults to "GET" only for the direct-call specs; every runtime caller threads the
    # value from `Repeater::Engine.request_method`.
    def self.reusable_response?(result : Repeater::Result, request_method : String = "GET") : Bool
      return false unless result.error.nil?
      return false if result.incomplete?
      resp = result.response
      return false unless resp
      return false if resp.malformed?
      return false if resp.status == 101 # Switching Protocols — the socket is no longer HTTP/1
      return false if connection_close?(resp.headers)
      case resp.version
      when "HTTP/1.1" then true
      when "HTTP/1.0" then connection_keep_alive?(resp.headers)
      else                 false
      end &&
        # A close-delimited body ended WITH the connection: there is nothing to park.
        # `response_framing` re-derives what `exchange` already framed by — with the SAME
        # method — so this cannot disagree with how many bytes were actually consumed.
        !close_delimited?(resp, request_method)
    end

    private def self.close_delimited?(resp : Proxy::Codec::RawResponse, request_method : String) : Bool
      framing, _ = Proxy::Codec::Body.response_framing(resp, request_method)
      framing.close_delimited?
    rescue
      true # unframeable ⇒ treat as unusable
    end

    # `Connection: close` — matched per token, so `Connection: keep-alive, close` counts.
    private def self.connection_close?(headers : Proxy::Codec::HeaderList) : Bool
      connection_token?(headers, "close")
    end

    private def self.connection_keep_alive?(headers : Proxy::Codec::HeaderList) : Bool
      connection_token?(headers, "keep-alive")
    end

    private def self.connection_token?(headers : Proxy::Codec::HeaderList, token : String) : Bool
      return false unless headers.has?("Connection")
      headers.get_all("Connection").any? do |v|
        v.split(',').any? { |t| t.strip.compare(token, case_insensitive: true) == 0 }
      end
    end

    # Byte offset just past the head's terminating CRLFCRLF, or nil when the bytes carry no
    # complete head (which no rendered template should, but a hand-written one can).
    private def self.head_length(bytes : Bytes) : Int32?
      i = 0
      last = bytes.size - 4
      while i <= last
        if bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 &&
           bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8
          return i + 4
        end
        i += 1
      end
      nil
    end

    private def self.ends_with?(bytes : Bytes, suffix : Bytes) : Bool
      return false if bytes.size < suffix.size
      bytes[(bytes.size - suffix.size), suffix.size] == suffix
    end
  end
end
