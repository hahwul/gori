require "../spec_helper"
require "socket"

# A request preceded by a blank line (RFC 9112 §2.2) is a HEAD to the origin. Framing its
# response by the method gori read must agree, or a HEAD answer with a Content-Length stalls
# waiting for a body that never comes.

private class BlankLineSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @requests.size.to_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil) rescue nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# The head the origin received, or nil when nothing reached it in time (a regressed proxy must
# fail the example, not hang the suite).
private def head_seen_within(seen : Channel(String)) : String?
  select
  when head = seen.receive
    head
  when timeout(2.seconds)
    nil
  end
end

describe "Gori::Proxy a request behind a leading blank line" do
  it "frames a HEAD response as bodyless and forwards the client's bytes unchanged" do
    seen = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen.send(head ? String.new(head) : "")
        # A HEAD answer: the length of the entity, and no body. The connection stays open.
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n"
        conn.flush
        sleep 3.seconds
        conn.close rescue nil
      end
    rescue
    end
    done = Channel(Nil).new(2)
    sink = BlankLineSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      sent = "\r\nHEAD /x HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client << sent
      client.flush
      head_seen_within(seen).should eq(sent)
      completed = select
      when done.receive then true
      when timeout(1.second) then false
      end
      completed.should be_true
      sink.requests.first.method.should eq("HEAD")
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
      client.close rescue nil
    ensure
      proxy.stop
      origin.close rescue nil
    end
  end

  it "forwards an empty request-line followed by headers to the Host's origin, verbatim" do
    seen = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen.send(head ? String.new(head) : "")
        conn << "HTTP/1.1 400 Bad Request\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad"
        conn.flush
        conn.close rescue nil
      end
    rescue
    end
    done = Channel(Nil).new(2)
    sink = BlankLineSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      sent = "\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client << sent
      client.flush
      head_seen_within(seen).should eq(sent)
      (client.gets_to_end rescue "").should start_with("HTTP/1.1 400 Bad Request")
      client.close rescue nil
      sink.requests.first.method.should eq("")
    ensure
      proxy.stop
      origin.close rescue nil
    end
  end
end
