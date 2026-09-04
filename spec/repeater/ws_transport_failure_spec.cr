require "../spec_helper"
require "socket"
require "openssl"
require "digest/sha1"
require "base64"

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

private WSTF_UPGRADE = ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                        "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

# The 101, with the Accept derived from whatever key the engine actually sent.
private def wstf_upgrade(io : IO) : Nil
  head = Gori::Proxy::Codec::Http1.read_head(io).not_nil!
  key = String.new(head).each_line
    .find(&.downcase.starts_with?("sec-websocket-key:"))
    .try(&.split(':', 2)[1].strip) || ""
  accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
  io << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
        "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
  io.flush
end

# A TLS origin that upgrades, echoes ONE frame, and then writes a bogus TLS record straight
# onto the underlying TCP socket — bypassing its own SSL layer, so the client's next
# `SSL_read` fails to decrypt.
#
# That failure is `OpenSSL::SSL::Error`, which is NOT an `IO::Error`, and the two rescues in
# `WsEngine` that turn a dead socket into `peer_gone` used to catch only the latter. So the
# raise unwound out of `drain` → `exchange` → into `send`'s rescue, whose comment reads
# "reaching here means the handshake failed". It had not: measured against this exact origin,
# gori answered `upgraded:false, messages:[], error:"SSL_read: … bad record mac"` — the
# upgrade denied and the frame the origin really sent deleted. The IDENTICAL event on a `ws://`
# socket raises `IO::Error` and has always been a NOTE with the transcript intact, so one
# protocol's findings were being thrown away by the other's exception type.
private def start_garbling_tls_ws_origin(echo_first : Bool = true) : Int32
  # In-memory root + server context, the pattern every other TLS origin in this suite uses
  # (spec/proxy/tls/non_tls_connect_spec.cr, reverse_spec.cr, transparent_spec.cr): no CA on
  # disk, no tempdir, and nothing for an aborted example to leak.
  cert, key = Gori::Proxy::Tls::CertBuilder.build_root("origin.test")
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(cert, key, advertise_h2: false)
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    origin.close rescue nil # one connection is all this origin serves — do not leave it bound
    next unless conn
    begin
      conn.read_timeout = 5.seconds
      ssl = OpenSSL::SSL::Socket::Server.new(conn, ctx, sync_close: false)
      wstf_upgrade(ssl)
      # `echo_first: false` garbles straight after the 101 without waiting for a client frame —
      # the shape a script with NO messages produces, where the engine's only drain is its one
      # generous first-reply pass.
      if echo_first && (frame = WS.read_frame(ssl)) && frame.data?
        ssl.write(WS.encode(frame.opcode, "echo:#{String.new(frame.payload)}".to_slice, mask: false))
        ssl.flush
      end
      # A TLS application-data record header over 0x40 bytes of noise: well-formed framing,
      # undecryptable content. Written straight onto the TCP socket, under its own SSL layer.
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

# A plaintext origin that upgrades, then answers with ONE frame header advertising a payload
# larger than MAX_FRAME (too big to buffer), a few real bytes, and a hold. `read_frame` returns
# nil for both this and EOF, so the drain used to read the peer's answer as "the connection
# ended"; the fix reads the header first and records the oversized frame.
private def start_oversized_frame_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    origin.close rescue nil
    next unless conn
    begin
      conn.read_timeout = 5.seconds
      wstf_upgrade(conn)
      len = WS::MAX_FRAME + 1
      hdr = IO::Memory.new
      hdr.write_byte(0x81_u8) # FIN + TEXT
      hdr.write_byte(0x7f_u8) # 64-bit length follows
      (0..7).each { |i| hdr.write_byte((len >> (56 - i * 8)).to_u8!) }
      conn.write(hdr.to_slice)
      conn.write(Bytes.new(16, 0x41_u8))
      conn.flush
      sleep 300.milliseconds
    rescue
    ensure
      conn.close rescue nil
    end
  end
  port
end

describe Gori::Repeater::WsEngine do
  describe "an oversized server frame after the upgrade" do
    it "records it as a truncation, not as a closed connection" do
      port = start_oversized_frame_ws_origin
      result = WsEngine.send(WSTF_UPGRADE, [] of WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port,
        verify_upstream: false, idle: 500.milliseconds)

      # The peer ANSWERED, with a frame gori could not buffer. Reporting `peer_gone` would
      # delete both the fact and the frame; instead the truncation is named and a marker row
      # sits in the transcript.
      result.upgraded?.should be_true
      result.truncated.not_nil!.should contain("per-frame cap")
      result.messages.any? { |m| String.new(m.payload).includes?("per-frame cap") }.should be_true
    end
  end

  describe "a transport failure AFTER the upgrade" do
    it "keeps the transcript and reports it as a note, not as a failed handshake" do
      port = start_garbling_tls_ws_origin
      result = WsEngine.send(WSTF_UPGRADE, [
        WsEngine::OutMsg.new(1, "first".to_slice),
        WsEngine::OutMsg.new(1, "second".to_slice),
      ], scheme: "https", host: "127.0.0.1", port: port,
        verify_upstream: false, idle: 500.milliseconds)

      # The upgrade HAPPENED. Reporting `upgraded: false` for a socket that answered 101 is
      # the half of this that misdescribes the origin.
      result.upgraded?.should be_true
      result.ok?.should be_true
      result.error.should be_nil

      # …and the frame the origin actually sent is still in the transcript. This is the half
      # that DESTROYS evidence: `err` builds an empty message list.
      result.messages.map(&.direction).should contain("in")
      result.messages.any? { |m| String.new(m.payload) == "echo:first" }.should be_true

      # Not silent about it either: the reason the exchange stopped is named, with the
      # underlying failure quoted, so an operator is not left wondering why the second
      # message never went out.
      note = result.note.not_nil!
      note.should contain("the connection failed")
      note.downcase.should contain("ssl")
    end

    # A session with NO outbound messages — `send_websocket{messages: []}`, or a seed whose
    # every stored row was a `[gori]` advisory `ws_seed_rows` drops — has `sent == total == 0`,
    # which slips past `with_unsent_note`'s `sent < total` guard. Without its own sentence the
    # run was told the connection failed "after the last message was written" for an exchange
    # in which nothing was ever written.
    it "does not claim a message was written when the script had none" do
      port = start_garbling_tls_ws_origin(echo_first: false)
      result = WsEngine.send(WSTF_UPGRADE, [] of WsEngine::OutMsg,
        scheme: "https", host: "127.0.0.1", port: port,
        verify_upstream: false, idle: 500.milliseconds)

      result.upgraded?.should be_true
      result.ok?.should be_true
      note = result.note.not_nil!
      note.should contain("while waiting for the origin")
      note.should_not contain("after the last message was written")
    end
  end
end
