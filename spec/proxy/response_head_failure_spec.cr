require "../spec_helper"
require "socket"

private class ResponseHeadFailureSink < Gori::Proxy::FlowSink
  getter responses : Channel(Gori::Store::CapturedResponse)

  def initialize
    @next_id = 0_i64
    @responses = Channel(Gori::Store::CapturedResponse).new(4)
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.send(resp)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private def response_head_failure_read_response(client : TCPSocket) : String
  head = Gori::Proxy::Codec::Http1.read_head(client)
  return "" unless head
  response = Gori::Proxy::Codec::Http1.parse_response_head(head)
  body = Bytes.new(response.headers.get?("Content-Length").try(&.to_i) || 0)
  client.read_fully(body) unless body.empty?
  String.new(body)
end

describe "proxy response head failures" do
  it "records oversized response bytes and does not resend a reused request" do
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    requests = Atomic(Int32).new(0)
    oversized = "HTTP/1.1 200 OK\r\nX-Big: #{"a" * (300 * 1024)}\r\nContent-Length: 6\r\n\r\nsecond"

    spawn do
      while conn = origin.accept?
        spawn do
          loop do
            request = Gori::Proxy::Codec::Http1.read_head(conn)
            break unless request
            count = (requests.add(1) + 1).to_i
            case count
            when 1
              conn << "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst"
            when 2
              conn << oversized
            else
              conn << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecond"
            end
            conn.flush
          end
        rescue
        ensure
          conn.close rescue nil
        end
      end
    rescue
    end

    sink = ResponseHeadFailureSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    begin
      client << "GET /one HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      response_head_failure_read_response(client).should eq("first")

      client << "GET /two HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      response_head_failure_read_response(client).should eq("")

      first = sink.responses.receive
      second = sink.responses.receive
      first.state.should eq(Gori::Store::FlowState::Complete)
      second.state.should eq(Gori::Store::FlowState::Error)
      second.head.size.should eq(256 * 1024)
      String.new(second.head[0, 15]).should eq("HTTP/1.1 200 OK")
      second.error.should_not be_nil
      second.error.not_nil!.should contain("response head exceeded 256 KiB")
      requests.get.should eq(2)
    ensure
      client.close rescue nil
      proxy.stop
      origin.close rescue nil
    end
  end
end
