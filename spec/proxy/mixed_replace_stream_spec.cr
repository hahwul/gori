require "../spec_helper"
require "socket"

# `multipart/x-mixed-replace` (an MJPEG camera feed, a server-push page) is a chunked response
# that never ends. A response-body rule for its host used to send it down the buffering path,
# where the client received nothing until 16 MiB had arrived.

private class MixedReplaceSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private PART = "--frame\r\nContent-Type: text/plain\r\n\r\ntick\r\n"

# One connection. Chunked: one part every 20 ms until the peer goes away. Otherwise a single
# part under a Content-Length, which is a body that ends.
private def mixed_replace_origin(chunked : Bool) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    if conn = origin.accept?
      begin
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
        if chunked
          conn << "Transfer-Encoding: chunked\r\n\r\n"
          loop do
            conn << PART.bytesize.to_s(16) << "\r\n" << PART << "\r\n"
            conn.flush
            sleep 20.milliseconds
          end
        else
          conn << "Connection: close\r\nContent-Length: #{PART.bytesize}\r\n\r\n" << PART
          conn.flush
        end
      rescue IO::Error
      ensure
        conn.close
      end
    end
  end
  origin
end

private def through_rule(chunked : Bool, & : TCPSocket ->) : Nil
  with_store do |store|
    rules = Gori::Rules.new(store, store.match_rules)
    rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "tick", "tock")
    origin = mixed_replace_origin(chunked)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, MixedReplaceSink.new, rewriter: rules)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 2.seconds
    client << "GET /cam HTTP/1.1\r\nHost: 127.0.0.1:#{origin.local_address.port}\r\n\r\n"
    client.flush
    begin
      yield client
    ensure
      client.close
      proxy.stop
      origin.close
    end
  end
end

describe "proxy: a multipart/x-mixed-replace stream" do
  it "reaches the client part by part while a response-body rule is live for its host" do
    through_rule(chunked: true) do |client|
      client.gets("tick").to_s.should contain("multipart/x-mixed-replace")
    end
  end

  it "still rewrites one that declares its length, which is a body that ends" do
    through_rule(chunked: false) do |client|
      got = client.gets_to_end
      got.should contain("tock")
      got.should_not contain("tick")
    end
  end
end
