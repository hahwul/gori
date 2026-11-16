require "../../spec_helper"
require "socket"

# settings `network.strip_extended_connect` (#1896) on the HTTP/1.1 side. There is no flow for
# the SETTINGS frame the h2 relay rewrote, so the WebSocket upgrade that follows is where the
# operator reads why the socket took that path.

private class UpgradeSink < Gori::Proxy::FlowSink
  getter responses = [] of Gori::Store::CapturedResponse
  getter done = Channel(Nil).new(4)
  @next_id = 0_i64

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private UPGRADE_101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
private PLAIN_200   = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"

private def upgrade_request(port : Int32) : String
  "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
  "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
end

# An origin answering one connection's requests with `answers`, in order, then holding the
# socket open until the client goes.
private def start_origin(answers : Array(String)) : {TCPServer, Int32}
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    conn = origin.accept? || next
    begin
      answers.each do |answer|
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << answer
        conn.flush
      end
      conn.read(Bytes.new(1))
    rescue
    ensure
      conn.close rescue nil
    end
  end
  {origin, origin.local_address.port}
end

# The responses the proxy recorded for `answers`, with the switch and the withheld-origin marker
# in the state the example is about.
private def upgrade_flows(strip : Bool, marked : Bool, answers : Array(String)) : Array(Gori::Store::CapturedResponse)
  before = Gori::Settings.strip_extended_connect?
  Gori::Settings.reset_extended_connect_withheld
  origin, port = start_origin(answers)
  Gori::Settings.first_extended_connect_withheld?("127.0.0.1", port) if marked
  Gori::Settings.strip_extended_connect = strip
  sink = UpgradeSink.new
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  begin
    answers.each do |answer|
      if answer == UPGRADE_101
        client << upgrade_request(port)
      else
        client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      end
      client.flush
      Gori::Proxy::Codec::Http1.read_head(client)
      client.read_fully(Bytes.new(2)) unless answer == UPGRADE_101
      receive_within(sink.done, 5, "the response to be recorded")
    end
    sink.responses
  ensure
    client.close
    proxy.stop
    origin.close rescue nil
    Gori::Settings.strip_extended_connect = before
    Gori::Settings.reset_extended_connect_withheld
  end
end

describe "ClientConn: the withheld extended CONNECT offer on a WebSocket upgrade" do
  it "says the switch is why the socket is on HTTP/1.1, for an origin whose offer gori withheld" do
    flow = upgrade_flows(strip: true, marked: true, answers: [UPGRADE_101]).first
    advisory = flow.advisory.not_nil!
    advisory.should contain("gori withheld 127.0.0.1:")
    advisory.should contain("SETTINGS_ENABLE_CONNECT_PROTOCOL")
    advisory.should contain("settings network.strip_extended_connect")
  end

  it "says nothing for an origin whose offer gori never withheld" do
    flow = upgrade_flows(strip: true, marked: false, answers: [UPGRADE_101]).first
    (flow.advisory || "").should_not contain("network.strip_extended_connect")
  end

  it "says nothing while the switch is off, even for an origin it withheld from earlier" do
    flow = upgrade_flows(strip: false, marked: true, answers: [UPGRADE_101]).first
    (flow.advisory || "").should_not contain("network.strip_extended_connect")
  end

  it "keeps the sentence off a response that is not a WebSocket upgrade" do
    plain, upgrade = upgrade_flows(strip: true, marked: true, answers: [PLAIN_200, UPGRADE_101])
    (plain.advisory || "").should_not contain("network.strip_extended_connect")
    upgrade.advisory.not_nil!.should contain("network.strip_extended_connect")
  end
end
