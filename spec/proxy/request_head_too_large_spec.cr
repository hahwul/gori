require "../spec_helper"
require "socket"

# A client head past `MAX_HEAD_BYTES` used to come back from the head read as the same nil as a
# clean close: the client saw a reset and History recorded nothing. It is now an error flow and
# a 431, the way an oversized RESPONSE head was already recorded.

private class OversizedHeadSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses : Channel(Gori::Store::CapturedResponse)

  def initialize
    @next_id = 0_i64
    @responses = Channel(Gori::Store::CapturedResponse).new(4)
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.send(resp)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

describe "proxy request head over the size cap" do
  it "records an error flow and answers 431 instead of resetting in silence" do
    sink = OversizedHeadSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 5.seconds
      big = "a" * (Gori::Proxy::Codec::Http1::MAX_HEAD_BYTES + 1024)
      spawn do
        client << "GET https://api.test:8443/x HTTP/1.1\r\nHost: api.test:8443\r\nX-Big: #{big}\r\n\r\n"
        client.flush
      rescue
      end
      reply = (client.gets rescue nil) || ""
      reply.should start_with("HTTP/1.1 431")
      client.close

      select
      when resp = sink.responses.receive
        (resp.error || "").should contain("request head exceeded 256 KiB")
      when timeout(5.seconds)
        fail "no flow was recorded for the oversized head"
      end
      # Where the request was going, as a forwarded one would be recorded: the absolute-form
      # target's scheme and authority, not the listener's scheme and the raw Host value.
      rec = sink.requests.first
      {rec.method, rec.scheme, rec.host, rec.port}.should eq({"GET", "https", "api.test", 8443})
    ensure
      proxy.stop
    end
  end
end
