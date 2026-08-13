require "../spec_helper"
require "file_utils"
require "socket"
require "openssl"

private alias P = Gori::Repeater::ConnPool

# `ConnPool.checkout_state` is the question asked of every parked socket right before a
# request is written onto it: is anything waiting, and is the peer still there. It answers on
# two very different paths — an fd-level MSG_PEEK for a plaintext TCPSocket, and a timed read
# probe for TLS, where OpenSSL hides the fd and residue can sit in its DECRYPTED buffer where
# a raw peek cannot see it.
#
# Only the plaintext path had coverage. The TLS branch is the one that costs (measured: a
# clean TLS checkout is ~1.6 ms against 0.38 µs for plaintext, because it pays the whole
# DRAIN_PROBE deadline), so it is the one anybody optimising this will touch — with nothing
# failing if they get it wrong. These pin all three answers on BOTH transports first.
private def with_ca(&)
  dir = File.tempname("gori-pool-tls-ca")
  begin
    yield Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

# A TLS origin whose per-connection behaviour the caller scripts: what to write back (if
# anything) and whether to hang up. Returns the CLIENT side of a live, handshaken socket.
private def tls_socket(ca, *, greet : String? = nil, trailer : String? = nil, hangup : Bool = false, &)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  ready = Channel(Nil).new(1)
  spawn do
    if conn = server.accept?
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(conn, ca.context_for("127.0.0.1", advertise_h2: false),
          sync_close: true)
        if g = greet
          ssl << g
          ssl.flush
        end
        # A SECOND flush, so this lands as its own TLS record rather than being coalesced
        # into the greeting's. That distinction is the whole point of the buffered-residue
        # example: one record puts the leftover in OpenSSL's decrypted buffer, two put the
        # second one's ciphertext in the underlying socket's buffer.
        if t = trailer
          ssl << t
          ssl.flush
        end
        ready.send(nil)
        if hangup
          ssl.close
        else
          sleep 5.seconds # hold it open for the duration of the example
        end
      rescue
        ready.send(nil) rescue nil
      end
    end
  end

  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  tcp = TCPSocket.new("127.0.0.1", port)
  client = OpenSSL::SSL::Socket::Client.new(tcp, ctx, sync_close: true, hostname: "127.0.0.1")
  ready.receive
  begin
    yield client
  ensure
    client.close rescue nil
    server.close rescue nil
  end
end

# The plaintext twin of the above, so both transports answer the same three questions.
private def tcp_socket(*, greet : String? = nil, hangup : Bool = false, &)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  ready = Channel(Nil).new(1)
  spawn do
    if conn = server.accept?
      if g = greet
        conn << g
        conn.flush
      end
      ready.send(nil)
      hangup ? conn.close : sleep(5.seconds)
    end
  end
  client = TCPSocket.new("127.0.0.1", port)
  ready.receive
  begin
    yield client
  ensure
    client.close rescue nil
    server.close rescue nil
  end
end

# The probe races the origin's write, so poll to a deadline rather than sleeping a guess
# (spec_helper's PR #555 note: a bare wait on socket-driven work is how CI hangs).
private def settle(io, want : P::Checkout, timeout : Time::Span = 3.seconds) : P::Checkout
  deadline = Time.instant + timeout
  got = P.checkout_state(io)
  while got != want && Time.instant < deadline
    sleep 10.milliseconds
    got = P.checkout_state(io)
  end
  got
end

describe "ConnPool.checkout_state" do
  describe "plaintext (fd MSG_PEEK)" do
    it "answers Clean on an idle socket with nothing waiting" do
      tcp_socket { |io| P.checkout_state(io).should eq(P::Checkout::Clean) }
    end

    it "answers Residue when the origin left bytes on the socket" do
      tcp_socket(greet: "leftover") { |io| settle(io, P::Checkout::Residue).should eq(P::Checkout::Residue) }
    end

    it "answers Closed when the peer hung up before the write" do
      # Its own answer, not folded into Clean: since the idempotency gate landed, a
      # POST/PUT/PATCH/DELETE cannot be re-sent on the stale path, so handing back a socket
      # proved dead would DROP the request. A FIN seen before the write means the origin never
      # saw it at all.
      tcp_socket(hangup: true) { |io| settle(io, P::Checkout::Closed).should eq(P::Checkout::Closed) }
    end
  end

  describe "TLS (the DRAIN_PROBE path)" do
    it "answers Clean on an idle socket with nothing waiting" do
      with_ca { |ca| tls_socket(ca) { |io| P.checkout_state(io).should eq(P::Checkout::Clean) } }
    end

    it "answers Residue for bytes sitting in OpenSSL's DECRYPTED buffer" do
      # The case a raw fd peek cannot see, and the whole reason this branch exists: the record
      # has already been read off the kernel socket and decrypted, so only OpenSSL knows.
      with_ca do |ca|
        tls_socket(ca, greet: "HTTP/1.1 200 OK\r\n\r\nleftover") do |io|
          settle(io, P::Checkout::Residue).should eq(P::Checkout::Residue)
        end
      end
    end

    it "answers Closed when the peer hung up before the write" do
      with_ca do |ca|
        tls_socket(ca, hangup: true) { |io| settle(io, P::Checkout::Closed).should eq(P::Checkout::Closed) }
      end
    end

    # The fourth place residue can hide, and the one the fast path was blind to: the
    # UNDERLYING socket's own `IO::Buffered` read buffer, holding ciphertext that has been
    # pulled off the fd but not yet decrypted.
    #
    # `OpenSSL::BIO.read_ex` reads through `bio.io.read` — the BUFFERED read — and
    # `IO::Buffered#read` calls `fill_buffer` whenever the request is under half the buffer,
    # pulling up to 8 KiB. OpenSSL asks for a 5-byte record header first, so reading the HEAD
    # drags any already-arrived following record in with it. At that point `SSL_pending` is 0
    # (record 2 is still ciphertext) and an fd peek is EAGAIN (the kernel buffer is drained) —
    # so both of the fast path's checks say Clean while a whole response body is waiting.
    #
    # This is the body-past-Content-Length / HEAD-with-body desync the class header says the
    # check exists to catch, and handing the socket out here frames the NEXT payload's response
    # against these leftovers, silently, mid-sweep.
    it "answers Residue for an undecrypted record in the UNDERLYING socket's read buffer" do
      with_ca do |ca|
        head = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        # Two separate records, and the read below happens only after both have landed — so
        # one `fill_buffer` takes both. Writing them as ONE record instead is what the existing
        # residue example does, and it is why that one passes without this check: the leftover
        # ends up in OpenSSL's decrypted buffer, where `SSL_pending` sees it.
        tls_socket(ca, greet: head, trailer: "leftover body bytes") do |io|
          sleep 150.milliseconds # let record 2 arrive before anything reads
          buf = Bytes.new(head.bytesize)
          io.read_fully(buf)
          String.new(buf).should eq(head) # the head, and only the head, was consumed

          P.checkout_state(io).should eq(P::Checkout::Residue)
        end
      end
    end
  end

  it "refuses the socket rather than trusting it when the probe itself fails" do
    # A closed IO makes the probe raise. Residue, NOT Closed: a failed probe proves nothing
    # about whether the peer closed, and Closed is the answer that licenses re-sending a POST.
    io = TCPSocket.new("127.0.0.1", TCPServer.new("127.0.0.1", 0).local_address.port) rescue nil
    if io
      io.close
      P.checkout_state(io).should eq(P::Checkout::Residue)
    end
  end
end
