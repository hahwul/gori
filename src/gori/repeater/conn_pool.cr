require "../proxy/codec/body"
require "../proxy/codec/http1"
require "./engine"

# Non-blocking "is there residue in the read buffer?" — the piece Crystal's public IO has no
# way to ask. `ConnPool#checkout_state` needs it because `read_head` reads byte-by-byte through the
# buffered layer, which pulls a large chunk off the socket into `@in_buffer_rem`; any bytes
# the origin left past the framed body therefore sit in THAT buffer, not on the kernel socket,
# where an fd-level `MSG_PEEK` cannot see them. `peek` would find them but calls `fill_buffer`
# (blocking) when the buffer is empty, which is the common clean-socket case — so it cannot be
# used on the keep-alive fast path. Reading `@in_buffer_rem` directly is the only non-blocking
# answer. The name is long-standing Crystal internals; if it ever changes this fails to compile
# rather than silently misbehaving.
module IO::Buffered
  def gori_buffered_residue? : Bool
    !@in_buffer_rem.empty?
  end
end

# `SSL_pending` — bytes OpenSSL has already decrypted and is holding for the next read. Not in
# Crystal's LibSSL bindings, and it is the half of "is this TLS socket clean?" that an fd-level
# peek structurally cannot answer: the record is already off the kernel socket. Present in every
# OpenSSL and LibreSSL gori can link against (it predates SSL_has_pending, which is 1.1+ and
# would also cover a buffered-but-undecrypted record — `gori_buffered_residue?` on the UNDERLYING
# socket covers that instead, so the older, universally available call is enough. It is that
# check and NOT the fd peek: once Crystal's buffered layer has pulled the bytes off the socket
# the fd is empty, so a peek reports the connection idle).
lib LibSSL
  fun ssl_pending = SSL_pending(handle : SSL) : Int
end

# The two things `OpenSSL::SSL::Socket` knows and does not expose, both needed to answer
# "clean?" WITHOUT a timed read. Same shape as `gori_buffered_residue?` above: reaching into
# stdlib internals deliberately, so a rename fails to compile rather than silently misbehaving.
class OpenSSL::SSL::Socket
  # Decrypted bytes waiting inside OpenSSL.
  def gori_ssl_pending? : Bool
    LibSSL.ssl_pending(@ssl) > 0
  end

  # The socket underneath the TLS layer, so the kernel buffer can be peeked for a record that
  # has arrived but not been decrypted yet. `BIO` exposes its `io`; the SSL socket does not.
  def gori_underlying_io : IO
    {% if compare_versions(Crystal::VERSION, "1.12.0") >= 0 %}
      @bio.to_reference.io
    {% else %}
      @bio.io
    {% end %}
  end
end

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
    # keep-alive idle timeout) and must not surface as a failed result. There are two moments
    # it can be discovered, and they are NOT the same fact:
    #
    #   * at CHECKOUT, before a byte of the next request is written (`Checkout::Closed`) —
    #     the origin cannot have seen the request, so it goes out on a fresh connection as a
    #     FIRST send, for any method, unmarked;
    #   * DURING the exchange, because the FIN landed between the probe and the write
    #     (`stale?`) — gori cannot tell whether the origin read it, so only an IDEMPOTENT
    #     request is re-sent, and its Result is marked `retried`.
    #
    # Either way a timeout, or a failure part-way through a response, is NOT retried: the
    # origin may well have processed the request.
    #
    # An origin that refuses reuse outright turns every park into a wasted probe and a redial.
    # After this many consecutive stale checkouts — of EITHER kind — the pool gives up and
    # runs in dial-per-send mode for the rest of the run.
    #
    # On `max_requests`: a stale re-send is not charged against the CAP (CappedBackend counts
    # calls into the Sender, and this retry happens below it), and STALE_GIVE_UP bounds the
    # slack to a handful. It IS counted in what a run REPORTS as requests, though — see
    # `Fuzz::Backend#extra_requests`. The old note claimed the re-send was free because the
    # origin "demonstrably did not process" the first copy; it demonstrably did not ANSWER it,
    # which is a different fact, so a tester working inside an agreed request budget has to be
    # told about the extra one.
    STALE_GIVE_UP = 3

    # The methods a closed parked socket may be replayed on.
    #
    # RFC 7230 §6.3.1 permits an automatic retry only for an idempotent request; Go's
    # `http.Transport` retries a reused connection only when the request `isReplayable()`,
    # which is this same set. The class contract above used to justify retrying ANY method
    # with "the request never reached the application", and that claim does not hold: the
    # request-read and the response-write are INDEPENDENT events at the origin, so a
    # load-shedding server, a WAF dropping a payload class, or any drop-on-match origin reads
    # the request in full, acts on it, and closes without answering. `delivered?` cannot see
    # the difference — it only knows no response byte arrived.
    #
    # Measured before this gate existed: a 4-payload POST sweep against an origin that reads
    # every other request and then closes silently put SEVEN POSTs at the origin, reported all
    # four as `200`, and said `0 errors`; the same run with `--no-keep-alive` honestly reported
    # two failures. On a client's production system that is a doubled charge or a doubled
    # account creation, and the sweep's own verdict is inverted for exactly the payloads the
    # origin dropped. A non-idempotent request now gets the honest `no response from …` the
    # unpooled path already returns.
    #
    # PUT and DELETE are idempotent per RFC 9110 §9.2.2 and are deliberately NOT here: gori
    # points deliberately odd requests at targets whose handlers are the thing under test, so
    # "the spec says repeating it is safe" is a weaker guarantee than "no observable side
    # effect is even claimed". This is the set every other HTTP client draws the line at.
    REPLAYABLE_METHODS = {"GET", "HEAD", "OPTIONS", "TRACE"}

    # Whether a closed parked socket may be replayed for this request method. Case-insensitive
    # because the method is taken verbatim off the operator's template (`Engine.request_method`),
    # and a lowercase `get` is a legitimate — if odd — thing to send.
    def self.replayable?(method : String) : Bool
      REPLAYABLE_METHODS.any? { |m| method.compare(m, case_insensitive: true) == 0 }
    end

    # What the checkout probe found on a parked socket, right before this request would be
    # written onto it. Three outcomes, not two, because the third one is the discriminator
    # the class contract says it does not have (see `stale?`): a FIN that is ALREADY on the
    # socket proves the origin never saw this request, since nothing has been written yet.
    enum Checkout
      # Nothing waiting. Write the request onto it.
      Clean
      # Unread bytes from the PREVIOUS exchange (a body past Content-Length, a HEAD-with-body).
      # Retire: framing this request's response against them is the response-desync gori
      # exists to DETECT, not to suffer.
      Residue
      # The peer's FIN arrived while the socket sat idle, before gori wrote a byte. Retire —
      # and the re-dial that follows is a FIRST send, for ANY method.
      Closed
    end

    # Connections dialed (== handshakes paid) and requests served off a parked socket.
    # `dialed + reused == sends` for a run that never hit a stale retry.
    getter dialed : Int64 = 0_i64
    getter reused : Int64 = 0_i64
    # Re-sends caused by a parked socket the origin had already closed (see STALE_GIVE_UP).
    getter stale_retries : Int64 = 0_i64
    # Parked sockets found ALREADY CLOSED at checkout, before a byte of this request went
    # onto them. NOT re-sends: nothing had been sent, so the fresh connection carries the
    # request's FIRST and only copy and no `retried` marker is warranted. Counted separately
    # from `stale_retries` because the two answer different questions — this one is "how
    # often did parking turn out to be pointless", which is what STALE_GIVE_UP acts on.
    getter stale_checkouts : Int64 = 0_i64
    # Sends that hit a closed parked socket and were NOT replayed because the method is not
    # idempotent (see REPLAYABLE_METHODS). These came back as errors, exactly as they would
    # with keep-alive off — counted so a surface can say why a pooled run and an unpooled one
    # now agree instead of leaving the operator to wonder where the failures came from.
    getter unsafe_stale : Int64 = 0_i64
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
        # Probe AT CHECKOUT, not only when we parked it. The previous exchange's leftover
        # bytes (a body past Content-Length, a HEAD-with-body) may not have arrived by the time
        # `recycle` ran — the origin can be a peer whose write races our park — so `recycle`'s
        # check is an early retire, and THIS one, right before we write onto the socket, is the
        # reliable one: by now any straggler residue is on the wire. Without it a poisoned socket
        # would frame this request's response against the previous response's leftovers.
        case ConnPool.checkout_state(io)
        when Checkout::Closed
          # The origin's FIN was on the socket BEFORE gori wrote a byte of this request. That
          # proves what `stale?` (below) explicitly cannot: the ORIGIN NEVER SAW THIS REQUEST.
          # So the re-dial is a FIRST send, not a replay — allowed for EVERY method, unmarked,
          # and not charged as a stale re-send, because nothing was re-sent.
          #
          # Treating this as "drained" and writing the request onto the dead socket anyway
          # cost half of every POST sweep: `send` wrote, the read failed with a reset, and
          # the (correct) idempotency gate below then declined to replay a request whose
          # delivery it could no longer disprove — one call too late. The two changes are
          # individually right and jointly dropped the request. `stale?` and the method gate
          # stay for the genuinely ambiguous case: a FIN that lands BETWEEN this probe and
          # the write.
          close(io)
          @stale_checkouts += 1
          # Still charged against STALE_GIVE_UP. An origin that closes every parked socket
          # makes parking pointless, and that is the case the bound exists for whether the
          # deadness is caught here or one exchange later.
          note_stale
          return dial_and_send(bytes, keepable, method)
        when Checkout::Residue
          close(io)
          return dial_and_send(bytes, keepable, method)
        end
        started = Time.instant
        result = Repeater::Engine.exchange(io, bytes, @host, @port, started)
        if stale?(result)
          close(io)
          # Counted for BOTH outcomes below: an origin that always closes parked sockets is the
          # case this bound exists for whether or not the method may be replayed.
          note_stale
          # A non-idempotent request stops here with the result it actually got. Re-sending it
          # is what turned a dropped POST into a false 200 and charged the origin twice — see
          # REPLAYABLE_METHODS.
          unless ConnPool.replayable?(method)
            @unsafe_stale += 1
            # …and stop pooling AT ONCE, without waiting for STALE_GIVE_UP. That bound is sized
            # for an idempotent sweep, where a stale checkout costs a wasted redial and the
            # request still goes out. For a method the pool may not replay it costs a LOST
            # PAYLOAD — a hole in the sweep, and one the operator cannot tell from a payload the
            # origin genuinely refused — so the next two attempts before the bound trips would
            # be two more holes. Measured against an origin that closes 50 ms after answering:
            # three payloads lost with the shared bound, one with this. A handshake per send is
            # a cheap price for the rest of the run agreeing with `--no-keep-alive`.
            @pooling = false
            drain
            return unsafe_stale_result(result, method)
          end
          @stale_retries += 1
          return dial_and_send(bytes, keepable, method, retried: true)
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

    # One more parked socket that turned out to be dead, from EITHER discovery point. Give up
    # on pooling for the rest of the run rather than pay a wasted probe-and-redial on every
    # send; already-parked sockets are dropped, because they are the same vintage.
    private def note_stale : Nil
      @consecutive_stale += 1
      return if @consecutive_stale < STALE_GIVE_UP
      @pooling = false
      drain
    end

    # The row for a request that died on a parked socket and may NOT be replayed.
    #
    # `Engine.exchange` ends this path with the transport's own exception message, and that is
    # not an operator-facing sentence. `read (#<TCPSocket:0x102e5cc80>): Connection reset by
    # peer` on a fuzz row reads as "this payload provoked a reset" — a false positive in a
    # security sweep — blames the ORIGIN for a socket gori wrote onto after the origin had
    # closed it, and puts a heap pointer in the terminal, in `--format json` and in MCP
    # `fuzz_results`. What gori actually knows is stated first; the transport's own words are
    # kept as a trailing clause because they are the only evidence of HOW the socket died.
    #
    # The one thing this must NOT claim is that the request was not delivered. By here the
    # FIN arrived after the probe said the socket was clean, so gori wrote the request and
    # cannot know whether the origin read it — which is exactly why it is not replayed.
    # `delivered?` stays false (gori heard nothing back) and the sentence says so in words.
    private def unsafe_stale_result(result : Repeater::Result, method : String) : Repeater::Result
      why = "the parked keep-alive connection to #{@host}:#{@port} was closed by the origin " \
            "while this #{method} was being sent, and #{method} is not idempotent, so gori did " \
            "NOT re-send it — this request may or may not have reached the origin"
      detail = ConnPool.transport_detail(result.error)
      # Named, not positional, for the three tail flags — same reason `as_retried` says so:
      # they are the fields appended one per round, and a positional `true` in the wrong slot
      # has silently set the wrong one twice now. This rebuilds a Result to change ONE field,
      # so every other value is carried across verbatim.
      Repeater::Result.new(result.head, result.body, result.response, result.duration_us,
        detail ? "#{why} (#{detail})" : why, result.incomplete?,
        delivered: result.delivered?, timed_out: result.timed_out?, retried: result.retried?)
    end

    # A Crystal `IO::Error` renders the socket's `inspect` into its message, so the transport's
    # account of a failure arrives as `read (#<TCPSocket:0x102e5cc80>): Connection reset by
    # peer`. The words after the colon are evidence worth keeping; the heap address is an
    # implementation detail that means nothing to an operator, differs on every run (so two
    # otherwise identical rows never compare equal), and has no business in a terminal, in
    # `--format json` or in an MCP tool result. Pure and `self.` so a spec can pin the shape
    # without a socket.
    #
    # `Upstream::DialError#cause` does the same scrub for the DIAL layer. This is deliberately
    # separate rather than shared: the string here never passes through a `DialError` at all —
    # it comes out of `Engine.exchange`, on a socket the pool had already CONNECTED and handed
    # over, which is the one place a dial-layer scrubber can never see.
    def self.transport_detail(message : String?) : String?
      return nil unless message
      cleaned = message.gsub(/\s*\(#<[^>]*>\)/, "").strip
      cleaned.empty? ? nil : cleaned
    end

    # `retried` marks the Result as the SECOND copy of this request on the wire, so the row a
    # surface prints says so — the run-level `stale_retries` line cannot tell an operator
    # WHICH payload went out twice, and that is the one thing an audit needs.
    private def dial_and_send(bytes : Bytes, keepable : Bool, method : String,
                              retried : Bool = false) : Repeater::Result
      # Timed from BEFORE the dial, like `Repeater::Engine.send` — a fresh connection's
      # handshake is part of what that request cost. A reused one honestly reports less.
      started = Time.instant
      io, dial_error = Repeater::Engine.dial_result(@scheme, @host, @port, @verify,
        @sni, @timeout, @overrides)
      unless io
        err = Repeater::Engine.error(
          Repeater::Engine.connect_error(@scheme, @host, @port, @verify, dial_error), started)
        return retried ? err.as_retried : err
      end
      @dialed += 1
      result = Repeater::Engine.exchange(io, bytes, @host, @port, started)
      recycle(io, result, keepable, method)
      retried ? result.as_retried : result
    end

    # Park the socket for the next send, or close it. Same retirement rule `send_pipeline`
    # applies to a group's connection (error or incomplete ⇒ unusable), plus the response's
    # own keep-alive signals.
    #
    # The EMPTY-socket check that guards against residue (a body past Content-Length, a
    # HEAD-with-body — the canonical response-desync primitives gori exists to DETECT) lives at
    # CHECKOUT (`send`), not here. Residue can arrive AFTER we would park — the origin's write
    # races our recycle — so checking here would miss a straggler and still hand a poisoned
    # socket to the next send. `reusable_response?` interrogates only the response HEAD and
    # cannot see the leftover bytes; the checkout-time `checkout_state` is what catches them, once
    # they are reliably on the wire.
    private def recycle(io : IO, result : Repeater::Result, keepable : Bool, method : String) : Nil
      if @pooling && keepable && @idle.size < @max_idle && ConnPool.reusable_response?(result, method)
        @idle.push(io)
      else
        close(io)
      end
    end

    # POSIX `MSG_PEEK` — read-without-consume. Not in Crystal's `LibC`, but the value is
    # 0x02 on every platform gori targets (Linux, macOS, the BSDs).
    MSG_PEEK = 0x02

    # LAST-RESORT probe deadline, for a socket that answers to `read_timeout` but is neither a
    # `TCPSocket` nor an `OpenSSL::SSL::Socket` gori can look inside. Every socket the pool
    # actually parks now takes a non-blocking path (see `checkout_state`); this is what keeps a
    # future transport correct-but-slow rather than silently unchecked.
    #
    # It used to be the whole TLS answer, and it cost the full deadline on every CLEAN
    # checkout — which is the common case. MEASURED against a real TLS origin, 200 checkouts:
    # median 1598µs (min 1105, max 5169), against 0.38µs for the plaintext fd peek. Sequential
    # callers paid it per request: a default `gori run sequence` over https is 500 samples on
    # one connection, so ~800ms of the run was this probe.
    #
    # With the two-step check in `checkout_state`, a socket parked after a real exchange now
    # answers in 0.5µs median (max 3µs, fast path 250/250 over a live TLS origin) and this
    # deadline is only reached when bytes are genuinely waiting.
    DRAIN_PROBE = 1.millisecond

    # What is waiting on a parked socket, asked once, right before this request is written.
    # A parked socket must be empty, or the next request reads the leftovers as its own
    # response — and it must be OPEN, or the next request is written into a closed pipe.
    #
    # For a plaintext `TCPSocket` this is an fd-level `MSG_PEEK` — Crystal's socket fd is
    # already non-blocking (evented IO), so `recv` returns immediately: `EAGAIN`/`EWOULDBLOCK`
    # means nothing is waiting (Clean), a byte means Residue, and 0 means the peer sent FIN
    # (Closed). ~0.3µs, so it costs the keep-alive fast path nothing. A TLS socket hides its
    # fd and the residue may sit in OpenSSL's decrypted buffer where a raw peek cannot see it,
    # so it falls back to a short read probe, which naturally covers both `SSL_pending` and a
    # kernel-buffered record.
    #
    # EOF used to be folded into "drained", on the reasoning that a closed parked socket is the
    # idle-timeout race the stale-retry path already handles. That stopped being true when the
    # idempotency gate landed: for POST/PUT/PATCH/DELETE the stale path can no longer re-send,
    # so handing back a socket proved dead DROPPED the request. It is now its own answer — and
    # a better one for every method, because a FIN observed BEFORE the write means the origin
    # never saw the request at all.
    # `MSG_PEEK` on a socket fd: read-without-consume, non-blocking because Crystal's sockets
    # are evented. EAGAIN/EWOULDBLOCK means nothing is waiting, a byte means residue, 0 means
    # the peer sent FIN. ~0.38µs measured. Shared by the plaintext branch and the fd half of
    # the TLS one, so the two cannot disagree about what a peek means.
    private def self.peek_state(sock : TCPSocket) : Checkout
      buf = uninitialized UInt8[1]
      n = LibC.recv(sock.fd, buf.to_unsafe.as(Void*), LibC::SizeT.new(1), MSG_PEEK)
      return Checkout::Closed if n == 0
      return Checkout::Residue if n > 0
      {Errno::EAGAIN, Errno::EWOULDBLOCK}.includes?(Errno.value) ? Checkout::Clean : Checkout::Residue
    end

    # Let the transport itself say what is waiting, bounded by DRAIN_PROBE. `nil` = EOF (the
    # peer closed); a byte = residue, and it is CONSUMED — which is fine because this only
    # runs on a socket that is about to be retired either way, and never on the clean fast
    # path above.
    private def self.drain_probe_state(io) : Checkout
      prev = io.read_timeout
      begin
        io.read_timeout = DRAIN_PROBE
        io.read_byte.nil? ? Checkout::Closed : Checkout::Residue
      rescue IO::TimeoutError
        Checkout::Clean
      ensure
        io.read_timeout = prev
      end
    end

    # Pure and class-level, like the two reuse predicates below it, so a spec can drive it
    # against a real socket rather than only through a whole pooled send. It reads nothing off
    # the pool — only the socket it is handed.
    def self.checkout_state(io : IO) : Checkout
      # 1. Residue already pulled into the buffered layer by `read_head`'s byte reads. This is
      #    where a body-past-Content-Length or a HEAD-with-body actually lands, and it is
      #    non-blocking, so it must be checked FIRST.
      return Checkout::Residue if io.is_a?(IO::Buffered) && io.gori_buffered_residue?
      # 2. Residue — or the peer's FIN — still on the kernel socket.
      if io.is_a?(TCPSocket)
        peek_state(io)
      elsif io.is_a?(OpenSSL::SSL::Socket)
        tls_checkout_state(io)
      elsif io.responds_to?(:read_timeout=) && io.responds_to?(:read_timeout)
        drain_probe_state(io)
      else
        Checkout::Clean # an IO with no timeout knob is not a pooled socket; nothing to prove
      end
    rescue
      # Any probe error ⇒ do not risk writing onto this socket. Reported as Residue rather
      # than Closed: a failed probe proves nothing about whether the peer closed, and Closed
      # is the answer that licenses re-sending a POST.
      Checkout::Residue
    end

    # The TLS half of `checkout_state`, in its own method because it is four ordered questions
    # rather than one, and the ORDER is the whole design.
    #
    # 1. Decrypted bytes already inside OpenSSL are residue outright (`SSL_pending`), free.
    # 2. Ciphertext Crystal's OWN buffered layer already pulled off the fd. `checkout_state`
    #    asks the same question of THIS socket's plaintext buffer; this is the different buffer
    #    underneath it, and neither `SSL_pending` nor the peek below can see it.
    #    `OpenSSL::BIO.read_ex` reads through `bio.io.read` — the BUFFERED read — and
    #    `IO::Buffered#read` calls `fill_buffer` whenever the request is under half the buffer,
    #    pulling up to 8 KiB. OpenSSL asks for a 5-byte record header first, so EVERY record
    #    read over-reads. `Socket#initialize` sets only `sync = true`, which is write-side;
    #    read buffering stays on and gori never disables it. So an origin that flushes head and
    #    body as two records leaves record 2 sitting here with `SSL_pending` at 0 (not decrypted
    #    yet) and the fd peek at EAGAIN (kernel buffer already drained) — and without this step
    #    the socket is handed out Clean and the next payload's response is framed against these
    #    leftovers. Pinned by `spec/fuzz/conn_pool_checkout_spec.cr`.
    # 3. Otherwise ask the fd whether ANYTHING is waiting. If the kernel buffer is empty too,
    #    the socket is provably idle and this returns Clean without a read — the common case,
    #    and what removes the ~1.6ms this branch used to cost every checkout.
    # 4. Only when bytes ARE waiting does it fall through to the timed read. That step cannot
    #    be skipped: a peek sees bytes but not what they MEAN. A TLS 1.3 record carrying a
    #    NewSessionTicket has outer content type 0x17, exactly like application data — the real
    #    type is encrypted — so nothing short of letting OpenSSL decrypt it can tell a
    #    post-handshake message from a leftover response. Reading the content-type byte was
    #    tried and is wrong for TLS 1.3 for that reason.
    private def self.tls_checkout_state(io : OpenSSL::SSL::Socket) : Checkout
      return Checkout::Residue if io.gori_ssl_pending?
      under = io.gori_underlying_io
      return Checkout::Residue if under.is_a?(IO::Buffered) && under.gori_buffered_residue?
      return Checkout::Clean if under.is_a?(TCPSocket) && peek_state(under) == Checkout::Clean
      drain_probe_state(io)
    end

    # A REUSED socket that failed BEFORE any response byte arrived. Per the contract at the
    # top of this class, an IDEMPOTENT request is then re-sent once on a fresh connection;
    # anything else stops here with this result. Only ever consulted on the `@idle.pop?`
    # branch, so "reused" is implicit.
    #
    # It used to compare the error string to `no_response_error` exactly, which matches ONLY a
    # clean EOF. An origin that RESET the parked socket failed with an `Errno`-derived message
    # instead, so `stale?` said false, the request was NOT retried, and the payload surfaced a
    # "connection reset" the origin never saw — a silent false negative in the middle of a
    # sweep, plus `@consecutive_stale` never advanced so `STALE_GIVE_UP` could never bound the
    # wasted redials against an origin that always resets.
    #
    # The discriminator is "no response byte was DELIVERED", not which IO error ended it.
    # `response.nil?` alone is not that: `exchange` returns `response: nil` for an interim-1xx
    # failure too (`malformed interim` / `too many interim` / `upstream closed after interim`),
    # and by then the origin has certainly sent something. `delivered?` is false only before any
    # response byte arrives — a clean EOF, a reset, or a write failure on a parked socket. An
    # INCOMPLETE response (head read, body cut) carries a non-nil `response` and so is already
    # excluded.
    #
    # What this does NOT establish, and used to be read as establishing, is that the ORIGIN
    # never saw the request. It only means gori heard nothing back. The method gate in `send`
    # is what covers the gap.
    #
    # `Checkout::Closed` DOES establish it, and is checked first — so by the time this runs the
    # FIN arrived after the probe, i.e. genuinely while or after gori wrote. This is the narrow
    # ambiguous window the method gate exists for, not the whole idle-close population.
    private def stale?(result : Repeater::Result) : Bool
      !result.error.nil? && result.response.nil? && !result.delivered?
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
        # A chunked body is reusable only if it actually terminates here — WALKED, not
        # suffix-matched. `ends_with?(bytes, "0\r\n\r\n")` looks like an exact test and is a
        # forgery: a chunk whose own DATA ends `0\r\n` (e.g. `5\r\nAB0\r\n\r\n`) produces that
        # suffix with no zero-chunk anywhere, so the origin stayed mid-body and the next
        # request off this pooled socket became its continuation chunks. See
        # `Codec::Body.chunked_complete?`, which frames by the same rules `copy_chunked` uses.
        Proxy::Codec::Body.chunked_complete?(bytes[head_len, body])
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
  end
end
