require "./pool"
require "./conn_pool"
require "./h2_engine"

module Gori::Repeater
  # HTTP/2 connection reuse for a sweep's sends — the h2 half of what `ConnPool` does for
  # HTTP/1.1.
  #
  # ## Why this exists
  #
  # `H2Engine.send` dialed a connection, wrote the preface, exchanged ONE request on stream 1
  # and closed. Correct for the Repeater, where a send is an operator's deliberate act, and
  # ruinous for a sweep: an h2 origin is https by definition in practice, so every payload
  # paid a TCP handshake plus a full TLS handshake plus the h2 preface/SETTINGS round before
  # a single byte of it moved. `ConnPool` fixed exactly that for h1 and h2 was excluded from
  # it by one clause in `Fuzz::Sender` — while the seed path (`gori run fuzz`'s
  # `http2 = force_h2 || seed.http2`, and the TUI's ⇧I) turns h2 ON automatically for any
  # sweep of a captured h2 flow, which is most captured traffic from a modern target. So the
  # default workflow against the commonest kind of origin was the one paying per-request
  # handshakes. Measured on loopback for the h1 pool, where RTT is ~0 and the win is therefore
  # UNDERSTATED: 2000 https requests went 1.65s → 0.087s, 2000 handshakes → 50.
  #
  # ## One request at a time, not multiplexing
  #
  # A `Conn` here carries requests SERIALLY: stream 1, then 3, then 5. It is not an h2
  # multiplexer, and the distinction is the whole risk profile. Multiplexing means several
  # streams in flight on one socket, which needs a demultiplexing reader fiber, per-stream
  # queues, and a stream-state machine — a different program. Serial reuse needs none of that
  # and still collects the entire handshake win, because the handshake is what a sweep was
  # paying per request. Concurrency comes from holding SEVERAL connections, exactly as the h1
  # pool gets it from several sockets: `idle_conns` is the run's concurrency, so at most one
  # request is ever inside a given `Conn`.
  #
  # ## Reuse discipline
  #
  # Mirrors `ConnPool`'s, and for the same reason: gori points deliberately odd requests at
  # targets, so a connection is reused only when nothing about the last exchange makes the
  # next one ambiguous. `H2Engine::Conn#poisoned?` is where that verdict is recorded — GOAWAY,
  # RST_STREAM, a clean EOF, a stalled request body, a read that timed out, a response gori
  # could not frame to its end, or stream ids used up. On top of it this pool refuses to park
  # a connection whose Result carries an error or an incomplete body, and it never pools a
  # CONNECT (an h2 CONNECT is a tunnel, not a request).
  #
  # A parked connection the origin closed while it sat idle is normal, and it is discovered at
  # the same two moments `ConnPool` names, with the same consequences: at CHECKOUT, before a
  # byte is written, the redial is a FIRST send for any method; DURING the exchange it is
  # ambiguous, so only an idempotent request is replayed and anything else comes back as the
  # honest error it got. `STALE_GIVE_UP` consecutive stale checkouts and the pool stops
  # pooling for the rest of the run.
  #
  # Concurrency: the scheduler is single-threaded and neither the idle array's `pop`/`push`
  # nor the counter bumps yield, so a worker fiber can never observe a half-updated pool —
  # the same argument `ConnPool` makes.
  class H2Pool < Pool
    # As `ConnPool::STALE_GIVE_UP`: an origin that closes every parked connection turns each
    # park into a wasted probe and a redial, so after this many consecutive stale checkouts
    # the pool runs in dial-per-send mode for the rest of the run.
    STALE_GIVE_UP = 3

    getter dialed : Int64 = 0_i64
    getter reused : Int64 = 0_i64
    getter stale_retries : Int64 = 0_i64
    getter stale_checkouts : Int64 = 0_i64
    getter unsafe_stale : Int64 = 0_i64
    getter? pooling : Bool = true

    def initialize(@scheme : String, @host : String, @port : Int32, @verify : Bool,
                   @sni : String?, @timeout : Time::Span?,
                   @overrides : Gori::HostOverrides?, @max_idle : Int32,
                   @tls_preset : String? = nil)
      @idle = [] of H2Engine::Conn
      @consecutive_stale = 0
    end

    def send(bytes : Bytes) : Repeater::Result
      keepable = @pooling && H2Pool.reusable_request?(bytes)
      method = Repeater::Engine.request_method(bytes)
      if keepable && (conn = @idle.pop?)
        if H2Pool.peer_closed?(conn.io)
          # The peer's FIN was on the socket BEFORE gori wrote a byte, which proves the origin
          # never saw this request — so the redial is a FIRST send, allowed for every method,
          # unmarked, and not charged as a re-send. Same three-way reading `ConnPool::Checkout`
          # documents, minus its Residue arm: unread frames on an h2 connection are ORDINARY
          # (a SETTINGS ACK, a PING, a trailing WINDOW_UPDATE for the stream just finished),
          # not the response-desync residue means on h1.
          conn.close
          @stale_checkouts += 1
          note_stale
          return dial_and_send(bytes, keepable, method)
        end
        started = Time.instant
        result = H2Engine.exchange_request(conn, bytes, scheme: @scheme, host: @host,
          port: @port, started: started, timeout: @timeout)
        if stale?(result)
          conn.close
          note_stale
          unless ConnPool.replayable?(method)
            # A method gori may not replay costs a LOST PAYLOAD if it is dropped and a
            # DOUBLED side effect if it is re-sent, so it gets the honest error and pooling
            # stops at once rather than after STALE_GIVE_UP more holes. `ConnPool` reasons
            # this out at length; the conclusion is identical here.
            @unsafe_stale += 1
            @pooling = false
            drain
            return unsafe_stale_result(result, method)
          end
          @stale_retries += 1
          return dial_and_send(bytes, keepable, method, retried: true)
        end
        @consecutive_stale = 0
        @reused += 1
        recycle(conn, result, keepable)
        return result
      end
      dial_and_send(bytes, keepable, method)
    end

    def close_all : Nil
      drain
    end

    # Whether this request may share a connection with the sweep's others.
    #
    # The h1 rule is long because HTTP/1.1 frames a body by agreement — a Content-Length that
    # disagrees with the bytes is exactly the smuggling payload gori exists to send, and it
    # would leave its tail on a shared socket for the next request to be framed against. h2
    # has no such seam: every message is its own stream, and DATA frames carry their own
    # lengths, so a `content-length` that disagrees with the body is malformed at the ORIGIN
    # (RFC 9113 §8.1.2.6) rather than a way to smuggle a second request past gori. That probe
    # still works — it just draws a RST_STREAM or a GOAWAY, which poisons the connection and
    # retires it, which is the correct outcome and needs no rule here.
    #
    # What is left is CONNECT, which turns the connection into a tunnel and is therefore not a
    # request that can be followed by another.
    def self.reusable_request?(bytes : Bytes) : Bool
      Repeater::Engine.request_method(bytes).compare("CONNECT", case_insensitive: true) != 0
    end

    # Has the peer sent FIN on this parked connection?
    #
    # ONE question, and — unlike `ConnPool.checkout_state`, which also has to hunt for residue
    # and may consume a byte doing it — never consuming one. That difference is load-bearing:
    # bytes waiting on an idle h2 connection are ordinary protocol frames, so a probe that ate
    # one would corrupt the frame stream it was trying to protect. Anything already buffered
    # therefore answers "not closed" outright, and only a connection with nothing waiting
    # anywhere is peeked at the fd.
    def self.peer_closed?(io : IO) : Bool
      return false if io.is_a?(IO::Buffered) && io.gori_buffered_residue?
      if io.is_a?(TCPSocket)
        fin?(io)
      elsif io.is_a?(OpenSSL::SSL::Socket)
        return false if io.gori_ssl_pending?
        under = io.gori_underlying_io
        return false if under.is_a?(IO::Buffered) && under.gori_buffered_residue?
        under.is_a?(TCPSocket) ? fin?(under) : false
      else
        false
      end
    rescue
      # A probe that failed proves nothing about the peer, and "closed" is the answer that
      # licenses re-sending a POST. Say no, and let the exchange find out.
      false
    end

    # `MSG_PEEK` on a socket fd: read-without-consume, non-blocking because Crystal's sockets
    # are evented. 0 means the peer sent FIN; anything else (a byte, or EAGAIN) does not.
    private def self.fin?(sock : TCPSocket) : Bool
      buf = uninitialized UInt8[1]
      LibC.recv(sock.fd, buf.to_unsafe.as(Void*), LibC::SizeT.new(1), ConnPool::MSG_PEEK) == 0
    end

    # A REUSED connection that failed before any response byte arrived — the h2 twin of
    # `ConnPool#stale?`, with the same discriminator and the same limits: it means gori heard
    # nothing back, NOT that the origin never saw the request. The method gate above covers
    # that gap.
    private def stale?(result : Repeater::Result) : Bool
      !result.error.nil? && result.response.nil? && !result.delivered?
    end

    private def unsafe_stale_result(result : Repeater::Result, method : String) : Repeater::Result
      why = "the parked HTTP/2 connection to #{@host}:#{@port} was closed by the origin " \
            "while this #{method} was being sent, and #{method} is not idempotent, so gori did " \
            "NOT re-send it — this request may or may not have reached the origin"
      detail = ConnPool.transport_detail(result.error)
      Repeater::Result.new(result.head, result.body, result.response, result.duration_us,
        detail ? "#{why} (#{detail})" : why, result.incomplete?,
        delivered: result.delivered?, timed_out: result.timed_out?, retried: result.retried?)
    end

    private def dial_and_send(bytes : Bytes, keepable : Bool, method : String,
                              retried : Bool = false) : Repeater::Result
      # Timed from BEFORE the dial, like `H2Engine.send` — a fresh connection's handshakes are
      # part of what that request cost, and a reused one honestly reports less.
      started = Time.instant
      conn, err = H2Engine.dial(@scheme, @host, @port, @verify, @sni, @timeout, @overrides,
        @tls_preset)
      unless conn
        e = Repeater::Engine.error(err || "h2 connect failed", started)
        return retried ? e.as_retried : e
      end
      @dialed += 1
      result = H2Engine.exchange_request(conn, bytes, scheme: @scheme, host: @host,
        port: @port, started: started, timeout: @timeout)
      recycle(conn, result, keepable)
      retried ? result.as_retried : result
    end

    # Park the connection for the next send, or close it. `poisoned?` is the exchange's own
    # verdict on the SOCKET (see `H2Engine::Conn`); the two clauses beside it are this pool's
    # verdict on the RESULT, and both have to hold — an errored or truncated exchange leaves
    # frames of unknown provenance on a wire the next request would be read from.
    private def recycle(conn : H2Engine::Conn, result : Repeater::Result, keepable : Bool) : Nil
      if @pooling && keepable && !conn.poisoned? && result.error.nil? && !result.incomplete? &&
         @idle.size < @max_idle
        @idle.push(conn)
      else
        conn.close
      end
    end

    private def note_stale : Nil
      @consecutive_stale += 1
      return if @consecutive_stale < STALE_GIVE_UP
      @pooling = false
      drain
    end

    private def drain : Nil
      while conn = @idle.pop?
        conn.close
      end
    end
  end
end
