require "../../spec_helper"
require "socket"

# A 101 is an upgrade only when the request asked for one. Answering a plain request with a 101
# must not turn the connection into a blind, uncaptured tunnel.

private class UpgradeSink < Gori::Proxy::FlowSink
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil) rescue nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# An origin that answers any request with a 101, then sends bytes that are not HTTP and closes.
private def upgrading_origin : {Int32, TCPServer}
  srv = TCPServer.new("127.0.0.1", 0)
  port = srv.local_address.port
  spawn do
    if conn = srv.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\n"
      conn << "TUNNELLED"
      conn.flush
      sleep 100.milliseconds
      conn.close rescue nil
    end
  rescue
  end
  {port, srv}
end

private def upgrade_exchange(extra_headers : String) : {String, Array(Gori::Store::CapturedResponse)}
  port, origin = upgrading_origin
  done = Channel(Nil).new(2)
  sink = UpgradeSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start
  begin
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 2.seconds
    client << "GET http://127.0.0.1:#{port}/ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{extra_headers}\r\n"
    client.flush
    got = (client.gets_to_end rescue "")
    client.close rescue nil
    select
    when done.receive
    when timeout(2.seconds)
    end
    {got, sink.responses}
  ensure
    proxy.stop
    origin.close rescue nil
  end
end

describe "Gori::Proxy::ClientConn unsolicited 101" do
  it "refuses a 101 answering a request that carried no Upgrade header" do
    got, flows = upgrade_exchange("")
    got.should start_with("HTTP/1.1 502")
    got.should_not contain("TUNNELLED")
    flows.first.error.to_s.should contain("unsolicited 101")
  end

  it "still tunnels a 101 answering a request that asked for the upgrade" do
    got, _ = upgrade_exchange("Connection: Upgrade\r\nUpgrade: tcp\r\n")
    got.should start_with("HTTP/1.1 101")
    got.should contain("TUNNELLED")
  end
end
