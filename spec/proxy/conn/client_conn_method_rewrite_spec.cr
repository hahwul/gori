require "../../spec_helper"
require "socket"

# A rule (or an intercept edit) that changes the request method changes how the ORIGIN's response
# is framed for the upstream hop, but the client still frames it by the method it sent. Where the
# two framings differ the client connection must not be kept alive after the response.

private class MethodSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# Rewrites the request-line method `from` to `to`; optionally claims a response-body rule so the
# response takes the buffered (rewriting) path.
private class MethodRewriter < Gori::Proxy::HeadRewriter
  def initialize(@from : String, @to : String, @body_rule : Bool = false)
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    s = String.new(head)
    s.starts_with?("#{@from} ") ? "#{@to} #{s[(@from.size + 1)..]}".to_slice : head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_response_body_for_host?(host : String) : Bool
    @body_rule
  end
end

# An origin that answers like a real one: a HEAD gets the head alone, anything else the body.
private def method_origin : {Int32, TCPServer}
  srv = TCPServer.new("127.0.0.1", 0)
  port = srv.local_address.port
  spawn do
    while conn = srv.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      if head
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"
        conn << "hello" unless String.new(head).starts_with?("HEAD ")
        conn.flush
      end
      conn.close rescue nil
    end
  rescue
  end
  {port, srv}
end

# What the client reads until the proxy closes the connection, or :timeout when it keeps it open.
private def read_to_close(io : IO) : String | Symbol
  acc = IO::Memory.new
  buf = Bytes.new(256)
  loop do
    n = io.read(buf)
    break if n == 0
    acc.write(buf[0, n])
  end
  acc.to_s
rescue IO::TimeoutError
  :timeout
end

private def exchange(method : String, rewriter : Gori::Proxy::HeadRewriter,
                     interceptor : Gori::Interceptor? = nil) : String | Symbol
  port, origin = method_origin
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, MethodSink.new, rewriter: rewriter, interceptor: interceptor)
  proxy.start
  begin
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 1.second
    client << "#{method} http://127.0.0.1:#{port}/a HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
    client.flush
    result = read_to_close(client)
    client.close rescue nil
    result
  ensure
    proxy.stop
    origin.close rescue nil
  end
end

describe "Gori::Proxy::ClientConn method rewritten upstream" do
  it "closes a HEAD client's connection after a response framed for the GET a rule sent" do
    got = exchange("HEAD", MethodRewriter.new("HEAD", "GET"))
    got.should be_a(String)
    got.as(String).should contain("hello") # forwarded as the origin sent it, not stripped
  end

  it "closes a GET client's connection after a response framed for the HEAD a rule sent" do
    got = exchange("GET", MethodRewriter.new("GET", "HEAD"))
    got.should be_a(String)
    got.as(String).should start_with("HTTP/1.1 200 OK")
  end

  it "closes the connection on the buffered response-body path too" do
    got = exchange("HEAD", MethodRewriter.new("HEAD", "GET", body_rule: true))
    got.should be_a(String)
    got.as(String).should contain("hello")
  end

  it "closes the connection when the response was held at intercept on the way" do
    with_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
      stop = false
      spawn do
        until stop
          ic.pending.each { |item| ic.forward(item.id) }
          sleep 10.milliseconds
        end
      end
      begin
        got = exchange("HEAD", MethodRewriter.new("HEAD", "GET"), interceptor: ic)
        got.should be_a(String)
        got.as(String).should contain("hello")
      ensure
        stop = true
      end
    end
  end

  it "keeps the connection alive when the rule leaves the method alone" do
    exchange("GET", MethodRewriter.new("POST", "PUT")).should eq(:timeout)
  end
end
