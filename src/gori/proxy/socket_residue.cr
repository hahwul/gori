require "socket"
require "openssl"
# Loaded first so the `gori_underlying_io` reopened below is the one that wins, exactly as it
# did when this block lived in `repeater/conn_pool.cr`, which is required after it.
require "./socket_tuning"

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

module Gori::Proxy
  # "Is anything waiting on this socket?", asked without blocking — of a parked keep-alive
  # socket at checkout (`Repeater::ConnPool.checkout_state`), and of an upstream the proxy is
  # retiring after a response it framed off a bare-LF head (`ClientConn#lf_residue_note`).
  # It lives under the proxy because both ask it, and the proxy must not reach into the
  # repeater for it.
  module SocketResidue
    # What the checkout probe found on a parked socket, right before this request would be
    # written onto it. Three outcomes, not two, because the third one is the discriminator
    # the pool's contract says it does not have (see `Repeater::ConnPool#stale?`): a FIN that is ALREADY on the
    # socket proves the origin never saw this request, since nothing has been written yet.
    enum State
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

    # POSIX `MSG_PEEK` — read-without-consume. Not in Crystal's `LibC`, but the value is
    # 0x02 on every platform gori targets (Linux, macOS, the BSDs).
    MSG_PEEK = 0x02

    # LAST-RESORT probe deadline, for a socket that answers to `read_timeout` but is neither a
    # `TCPSocket` nor an `OpenSSL::SSL::Socket` gori can look inside. Every socket the pool
    # actually parks now takes a non-blocking path (see `state`); this is what keeps a
    # future transport correct-but-slow rather than silently unchecked.
    #
    # It used to be the whole TLS answer, and it cost the full deadline on every CLEAN
    # checkout — which is the common case. MEASURED against a real TLS origin, 200 checkouts:
    # median 1598µs (min 1105, max 5169), against 0.38µs for the plaintext fd peek. Sequential
    # callers paid it per request: a default `gori run sequence` over https is 500 samples on
    # one connection, so ~800ms of the run was this probe.
    #
    # With the two-step check in `state`, a socket parked after a real exchange now
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
    private def self.peek_state(sock : TCPSocket) : State
      buf = uninitialized UInt8[1]
      n = LibC.recv(sock.fd, buf.to_unsafe.as(Void*), LibC::SizeT.new(1), MSG_PEEK)
      return State::Closed if n == 0
      return State::Residue if n > 0
      {Errno::EAGAIN, Errno::EWOULDBLOCK}.includes?(Errno.value) ? State::Clean : State::Residue
    end

    # Let the transport itself say what is waiting, bounded by DRAIN_PROBE. `nil` = EOF (the
    # peer closed); a byte = residue, and it is CONSUMED — which is fine because this only
    # runs on a socket that is about to be retired either way, and never on the clean fast
    # path above.
    private def self.drain_probe_state(io) : State
      prev = io.read_timeout
      begin
        io.read_timeout = DRAIN_PROBE
        io.read_byte.nil? ? State::Closed : State::Residue
      rescue IO::TimeoutError
        State::Clean
      ensure
        io.read_timeout = prev
      end
    end

    # Pure and class-level, like the two reuse predicates below it, so a spec can drive it
    # against a real socket rather than only through a whole pooled send. It reads nothing off
    # the pool — only the socket it is handed.
    def self.state(io : IO) : State
      # 1. Residue already pulled into the buffered layer by `read_head`'s byte reads. This is
      #    where a body-past-Content-Length or a HEAD-with-body actually lands, and it is
      #    non-blocking, so it must be checked FIRST.
      return State::Residue if io.is_a?(IO::Buffered) && io.gori_buffered_residue?
      # 2. Residue — or the peer's FIN — still on the kernel socket.
      if io.is_a?(TCPSocket)
        peek_state(io)
      elsif io.is_a?(OpenSSL::SSL::Socket)
        tls_state(io)
      elsif io.responds_to?(:read_timeout=) && io.responds_to?(:read_timeout)
        drain_probe_state(io)
      else
        State::Clean # an IO with no timeout knob is not a pooled socket; nothing to prove
      end
    rescue
      # Any probe error ⇒ do not risk writing onto this socket. Reported as Residue rather
      # than Closed: a failed probe proves nothing about whether the peer closed, and Closed
      # is the answer that licenses re-sending a POST.
      State::Residue
    end

    # The TLS half of `state`, in its own method because it is four ordered questions
    # rather than one, and the ORDER is the whole design.
    #
    # 1. Decrypted bytes already inside OpenSSL are residue outright (`SSL_pending`), free.
    # 2. Ciphertext Crystal's OWN buffered layer already pulled off the fd. `state`
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
    private def self.tls_state(io : OpenSSL::SSL::Socket) : State
      return State::Residue if io.gori_ssl_pending?
      under = io.gori_underlying_io
      return State::Residue if under.is_a?(IO::Buffered) && under.gori_buffered_residue?
      return State::Clean if under.is_a?(TCPSocket) && peek_state(under) == State::Clean
      drain_probe_state(io)
    end
  end
end
