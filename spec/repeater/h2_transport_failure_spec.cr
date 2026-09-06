require "../spec_helper"
require "socket"
require "openssl"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK

# A TLS h2 origin that answers HEADERS(:status 200) + one DATA frame WITHOUT END_STREAM, and
# then writes a bogus TLS record straight onto the underlying TCP socket — bypassing its own
# SSL layer, so the client's next `SSL_read` fails to decrypt.
#
# That failure is `OpenSSL::SSL::Error`, which is NOT an `IO::Error`, so `read_response`'s
# frame-read rescue (`IO::Error | Gori::Error`) does not cover it: the raise unwinds out of
# `read_response`, out of `exchange`, and into `send`'s blanket `rescue ex`, which builds a
# bare failure. The 200 and the body plainly arrived and were fully decoded; over `h2c` the
# same wire event (`start_h2_origin_truncated`) keeps both.
private def start_garbling_tls_h2_origin : Int32
  cert, key = Gori::Proxy::Tls::CertBuilder.build_root("origin.test")
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(cert, key, advertise_h2: true)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    origin.close rescue nil # one connection is all this origin serves
    next unless conn
    begin
      conn.read_timeout = 5.seconds
      ssl = OpenSSL::SSL::Socket::Server.new(conn, ctx, sync_close: false)
      Frame.read_preface(ssl)
      ssl.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
      ssl.flush
      loop do
        f = Frame.read(ssl)
        break if f.nil?
        break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
      end
      block = HPACK::Encoder.new.encode([{":status", "200"}])
      ssl.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
      ssl.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, "partial".to_slice).to_bytes)
      ssl.flush
      # A TLS application-data record header over 0x40 bytes of noise: well-formed framing,
      # undecryptable content. Written under its own SSL layer, onto the raw TCP socket.
      conn.write(Bytes[0x17, 0x03, 0x03, 0x00, 0x40])
      conn.write(Random::Secure.random_bytes(0x40))
      conn.flush
      sleep 300.milliseconds # let the client read the garbage rather than an EOF
    rescue
    ensure
      conn.close rescue nil
    end
  end
  port
end

# A connection whose frames are scripted and whose WRITES fail once the script is spent.
#
# `read_response` (and `pump_once` on the write side) do not only read: a peer SETTINGS or
# PING is ACKed on the spot, from inside the same loop. That write meets exactly the wire
# events the frame reads rescue — a reset socket answers it with `IO::Error`, and on `https`
# with `OpenSSL::SSL::Error` — and an ACK that raised unwound past a status, headers and body
# that had already been decoded. No socket here, because the point is the ORDER of the frames
# and not the transport: SETTINGS, HEADERS(:status 200), DATA, then a PING whose ACK cannot
# be written.
private class ScriptedH2Conn < IO
  getter writes_refused = 0

  def initialize(@script : Bytes)
    @pos = 0
  end

  def read(slice : Bytes) : Int32
    n = Math.min(slice.size, @script.size - @pos)
    return 0 if n <= 0
    @script[@pos, n].copy_to(slice[0, n])
    @pos += n
    n
  end

  # Refused once every scripted byte has been handed over — i.e. from the moment the PING is
  # in the reader's hands, which is when the ACK is written.
  def write(slice : Bytes) : Nil
    if @pos >= @script.size
      @writes_refused += 1
      raise IO::Error.new("connection reset by peer")
    end
  end
end

private def h2_ping_script : Bytes
  block = HPACK::Encoder.new.encode([{":status", "200"}])
  io = IO::Memory.new
  io.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
  io.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, block).to_bytes)
  io.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32, "partial".to_slice).to_bytes)
  io.write(Frame::Header.new(Frame::Type::Ping.value, 0_u8, 0_u32, Bytes.new(8)).to_bytes)
  io.to_slice
end

describe Gori::Repeater::H2Engine do
  describe "a TLS-layer read failure mid-response" do
    it "keeps the decoded status and body it already has" do
      port = start_garbling_tls_h2_origin

      request = "GET /garble HTTP/2\r\n\r\n".to_slice
      result = Gori::Repeater::H2Engine.send(request, scheme: "https", host: "127.0.0.1",
        port: port, verify_upstream: false, timeout: 2.seconds)

      result.ok?.should be_true
      result.response.not_nil!.status.should eq(200)
      String.new(result.body.not_nil!).should eq("partial")
      result.incomplete?.should be_true # no END_STREAM ever arrived
    end
  end
  describe "an ACK that cannot be written mid-response" do
    it "keeps the decoded status and body it already has" do
      sock = ScriptedH2Conn.new(h2_ping_script)
      conn = Gori::Repeater::H2Engine::Conn.new(sock)
      result = Gori::Repeater::H2Engine.exchange_request(conn, "GET /ping HTTP/2\r\n\r\n".to_slice,
        scheme: "http", host: "127.0.0.1", port: 80, started: Time.instant, timeout: 2.seconds)

      sock.writes_refused.should eq(1) # the PING ACK, and only it
      result.ok?.should be_true
      result.response.not_nil!.status.should eq(200)
      String.new(result.body.not_nil!).should eq("partial")
      result.incomplete?.should be_true # no END_STREAM ever arrived
      conn.poisoned?.should be_true     # …and the socket is still retired
    end
  end
end
