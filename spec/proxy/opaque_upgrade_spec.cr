require "../spec_helper"
require "socket"

# A 101 Switching Protocols that is NOT a WebSocket is relayed as a blind byte tunnel and
# deliberately not decoded (see `Gori::Proxy::Pump`). The two protocols that actually reach a
# proxy this way are kubectl exec/attach/port-forward (`Upgrade: SPDY/3.1`) and the Docker
# Engine API's attach/exec hijack (`Upgrade: tcp`) — both are used below, and neither is h2c.
#
# What is under test is not the tunnelling (that already worked byte-exact) but the RECORD it
# leaves: the WebSocket branch carries a per-flow `notice`, and this branch used to say nothing
# on the flow or in `gori.log` (#736).

# Client→server bytes: a SPDY/3.1 SYN_STREAM-shaped prefix. Contents are irrelevant to the
# tunnel — the SIZE is what the notice has to report.
private CLIENT_BYTES = Bytes[0x80, 0x03, 0x00, 0x01, 0x01, 0x00, 0x00, 0x14]
# Server→client bytes: a Docker multiplexed-stream header plus "hello" (13 bytes).
private ORIGIN_BYTES = Bytes[0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
  0x68, 0x65, 0x6c, 0x6c, 0x6f]

# Captures the flow's notice rows and stubs the HTTP side of the sink.
private class UpgradeSink < Gori::Proxy::FlowSink
  getter rows = [] of {String, Int32, String}

  def initialize(@chan : Channel(Nil))
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    7_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    @rows << {direction, opcode, String.new(payload)}
    @chan.send(nil)
  end
end

# Drives one full non-WebSocket upgrade through a real proxy: the client offers `req_token`,
# the origin answers 101 (echoing `resp_token`, or omitting `Upgrade` entirely when it is nil),
# then both sides push raw bytes and the origin hangs up. Returns what each side received and
# every row the sink was handed.
private def relay_opaque_upgrade(method : String, req_token : String,
                                 resp_token : String?) : {Bytes, Bytes, Array({String, Int32, String})}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  from_client = Channel(Bytes).new(1)
  spawn do
    conn = origin.accept
    conn.read_timeout = 5.seconds
    Gori::Proxy::Codec::Http1.read_head(conn) # the upgrade request
    conn << "HTTP/1.1 101 Switching Protocols\r\n"
    conn << "Upgrade: #{resp_token}\r\n" if resp_token
    conn << "Connection: Upgrade\r\n\r\n"
    conn.flush
    got = Bytes.new(CLIENT_BYTES.size)
    conn.read_fully(got)
    from_client.send(got)
    conn.write(ORIGIN_BYTES)
    conn.flush
    conn.close # ends the tunnel, which is what makes the byte counts final
  rescue
    from_client.send(Bytes.empty) rescue nil
  end

  notices = Channel(Nil).new(4)
  sink = UpgradeSink.new(notices)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start

  client = TCPSocket.new("127.0.0.1", proxy.port)
  client.read_timeout = 5.seconds
  client << "#{method} /upgrade HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
            "Upgrade: #{req_token}\r\nConnection: Upgrade\r\nContent-Length: 0\r\n\r\n"
  client.flush
  String.new(Gori::Proxy::Codec::Http1.read_head(client).not_nil!).should contain("101")

  client.write(CLIENT_BYTES)
  client.flush
  to_client = IO::Memory.new
  IO.copy(client, to_client) # until the tunnel cross-closes on the origin's hangup
  to_origin = receive_within(from_client)

  receive_within(notices) # the notice is written only after both directions are done
  client.close rescue nil
  proxy.stop
  origin.close rescue nil
  {to_origin, to_client.to_slice, sink.rows}
end

describe "a non-WebSocket 101 upgrade through the proxy" do
  it "relays kubectl's SPDY/3.1 byte-exact and says so on the flow (#736)" do
    to_origin, to_client, rows = relay_opaque_upgrade("POST", "SPDY/3.1", "SPDY/3.1")

    # The tunnel itself is unchanged: byte-exact both ways, nothing decoded.
    to_origin.should eq(CLIENT_BYTES)
    to_client.should eq(ORIGIN_BYTES)

    # Exactly one row, and it is a notice — not traffic. `[gori] ` is what keeps a repeater
    # seed from replaying gori's own prose at the target, and "in" is where a notice lives.
    rows.size.should eq(1)
    direction, opcode, text = rows[0]
    direction.should eq(Gori::Proxy::WS::Relay::NOTICE_DIRECTION)
    opcode.should eq(Gori::Proxy::WS::OP_TEXT.to_i)
    text.should start_with(Gori::Proxy::WS::NOTICE_PREFIX)

    # It names the protocol gori refused to decode ...
    text.should contain(%("SPDY/3.1"))
    text.should contain("opaque byte tunnel")
    # ... and how much went each way, so an empty transcript is legible rather than ambiguous.
    text.should contain("#{CLIENT_BYTES.size} bytes client→server")
    text.should contain("#{ORIGIN_BYTES.size} bytes server→client")
  end

  it "names the Docker Engine API's `Upgrade: tcp` from the client's offer when the 101 omits it" do
    # RFC 9110 only says a 101 SHOULD echo `Upgrade`; an origin that leaves it out must not
    # cost the operator the name of the protocol its own client asked for.
    to_origin, to_client, rows = relay_opaque_upgrade("POST", "tcp", nil)

    to_origin.should eq(CLIENT_BYTES)
    to_client.should eq(ORIGIN_BYTES)

    rows.size.should eq(1)
    text = rows[0][2]
    text.should start_with(Gori::Proxy::WS::NOTICE_PREFIX)
    text.should contain(%("tcp"))
    text.should contain("#{CLIENT_BYTES.size} bytes client→server")
    text.should contain("#{ORIGIN_BYTES.size} bytes server→client")
  end
end
