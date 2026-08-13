require "../../spec_helper"
require "socket"
require "openssl"

include Gori::Proxy::Tls

# Capture the bytes a REAL TLS client puts on the wire for `hostname`. Hand-built fixtures are
# easy to make agree with a hand-written parser; this makes OpenSSL the author of the input, so
# the spec fails if the parser only understands ClientHellos we imagined.
private def real_client_hello(hostname : String) : Bytes
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  captured = Channel(Bytes).new(1)
  spawn do
    if conn = server.accept?
      buf = Bytes.new(4096)
      n = conn.read(buf)
      captured.send(buf[0, n].dup)
      conn.close rescue nil
    end
  end
  spawn do
    sock = TCPSocket.new("127.0.0.1", port)
    ctx = OpenSSL::SSL::Context::Client.new
    ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    # The handshake never completes (the peer just reads and closes) — we only need the hello.
    OpenSSL::SSL::Socket::Client.new(sock, context: ctx, sync_close: true, hostname: hostname) rescue nil
  end
  bytes = captured.receive
  server.close rescue nil
  bytes
end

describe Gori::Proxy::Tls::ClientHello do
  describe ".peek_sni" do
    it "reads the SNI out of a real OpenSSL ClientHello" do
      io = IO::Memory.new(real_client_hello("api.acme.test"))
      sni, consumed = ClientHello.peek_sni(io)
      sni.should eq("api.acme.test")
      consumed.should_not be_empty
    end

    # The bytes MUST be handed back intact: the caller replays them into the handshake it just
    # inspected, so swallowing even one would break every transparent TLS connection.
    it "returns every byte it consumed, so the handshake can be replayed" do
      hello = real_client_hello("acme.test")
      io = IO::Memory.new(hello)
      _, consumed = ClientHello.peek_sni(io)
      # The whole record was consumed, and what is left in `io` plus `consumed` is the original.
      rest = io.gets_to_end.to_slice
      (consumed.to_a + rest.to_a).should eq(hello.to_a)
    end

    it "lowercases the name, so it matches scope and passthrough patterns" do
      io = IO::Memory.new(real_client_hello("API.Acme.TEST"))
      ClientHello.peek_sni(io)[0].should eq("api.acme.test")
    end

    it "is nil for a connection that is not TLS at all" do
      io = IO::Memory.new("GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice)
      sni, consumed = ClientHello.peek_sni(io)
      sni.should be_nil
      consumed.size.should eq(5) # only the record header was read, and it is handed back
    end

    it "is nil, not an exception, for a truncated record" do
      hello = real_client_hello("acme.test")
      io = IO::Memory.new(hello[0, 20])
      sni, consumed = ClientHello.peek_sni(io)
      sni.should be_nil
      consumed.size.should eq(20) # everything available, so the caller can still relay it
    end

    it "is nil for an empty stream" do
      ClientHello.peek_sni(IO::Memory.new(Bytes.empty)).should eq({nil, Bytes.empty})
    end

    # An unauthenticated peer controls this length field. A huge one must be refused outright
    # rather than allocating what it asks for.
    it "refuses a record claiming more than the RFC maximum instead of allocating it" do
      oversized = Bytes[0x16, 0x03, 0x01, 0xFF, 0xFF]
      sni, consumed = ClientHello.peek_sni(IO::Memory.new(oversized))
      sni.should be_nil
      consumed.should eq(oversized)
    end

    it "is nil for a handshake record that is not a ClientHello" do
      # A well-formed record header wrapping a ServerHello (0x02) body.
      body = Bytes.new(64, 0_u8)
      body[0] = 0x02_u8
      rec = Bytes.new(5 + body.size)
      rec[0] = 0x16_u8; rec[1] = 0x03_u8; rec[2] = 0x01_u8
      rec[3] = (body.size >> 8).to_u8; rec[4] = (body.size & 0xFF).to_u8
      body.copy_to(rec[5, body.size])
      ClientHello.peek_sni(IO::Memory.new(rec))[0].should be_nil
    end

    # RFC 6066 says SNI must not carry a literal address, but Crystal's OpenSSL client sets the
    # extension from its `hostname:` argument unconditionally — so an IP literal DOES arrive
    # here. Accepted rather than rejected: gori mints certificates for IP hosts elsewhere, and
    # refusing would break a transparent connection that named its target perfectly well.
    it "accepts an IP-literal SNI, which real clients do send" do
      hello = real_client_hello("127.0.0.1")
      io = IO::Memory.new(hello)
      sni, consumed = ClientHello.peek_sni(io)
      sni.should eq("127.0.0.1")
      consumed.size.should eq(hello.size)
    end

    # An invalid-UTF-8 byte inside the SNI value used to escape peek_sni as an ArgumentError out
    # of PCRE2, which the accept fiber's blanket rescue turned into a dropped connection — the
    # one thing this function's contract says cannot happen, and it cost the transparent
    # listener its kernel-original-destination fallback (#528).
    it "is nil, not an exception, for an SNI value that is not valid UTF-8" do
      hello = real_client_hello("zzqqzzqq.test")
      needle = "zzqqzzqq.test".to_slice
      at = (0..(hello.size - needle.size)).find { |i| hello[i, needle.size] == needle }
      at.should_not be_nil
      hello[at.not_nil! + 4] = 0xFF_u8 # one raw byte PCRE2 refuses to decode
      sni, consumed = ClientHello.peek_sni(IO::Memory.new(hello))
      sni.should be_nil
      consumed.size.should eq(hello.size) # still replayable, so the caller can fall back
    end

    # The genuine no-SNI case (an old client, or one that simply omits the extension). A
    # transparent listener has to cope with having no name at all, so this must be nil rather
    # than an error — hand-built, because a modern OpenSSL will not produce it.
    it "is nil for a ClientHello carrying no extensions at all" do
      body = IO::Memory.new
      body.write Bytes[0x01, 0x00, 0x00, 0x26] # ClientHello, length 38
      body.write Bytes[0x03, 0x03]             # legacy_version
      body.write Bytes.new(32, 0_u8)           # random
      body.write Bytes[0x00]                   # empty session id
      body.write Bytes[0x00, 0x02, 0x13, 0x01] # one cipher suite
      body.write Bytes[0x01, 0x00]             # compression: null
      payload = body.to_slice
      rec = IO::Memory.new
      rec.write Bytes[0x16, 0x03, 0x01, (payload.size >> 8).to_u8, (payload.size & 0xFF).to_u8]
      rec.write payload
      ClientHello.peek_sni(IO::Memory.new(rec.to_slice))[0].should be_nil
    end
  end
end
