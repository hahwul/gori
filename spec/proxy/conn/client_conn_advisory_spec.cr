require "../../spec_helper"
require "socket"
require "compress/gzip"

# What an HTTP/1.1 flow says when both halves of the exchange have something to say (#1905).
# The store's response write replaces the advisory column whenever it carries one, so the
# response record has to bring the request's sentence along.

private class RecordingSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @next_id = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
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

# A request-body rule live for every host: a compressed request body then earns the
# "Match&Replace was NOT applied" advisory on the request record.
private class BodyRuleRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_request_body_for_host?(host : String) : Bool
    true
  end

  def rewrites_body_for_host?(host : String) : Bool
    true
  end
end

private ALT_SVC = %(Alt-Svc: h3=":443"\r\n)

# An origin answering one request per entry of `extras` on one connection, each response
# carrying that entry as extra head lines.
private def start_origin(extras : Array(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      extras.each do |extra|
        length = 0
        while line = conn.gets("\r\n", chomp: true)
          break if line.empty?
          length = line.split(':', 2)[1].strip.to_i if line.downcase.starts_with?("content-length:")
        end
        conn.skip(length)
        conn << "HTTP/1.1 200 OK\r\n#{extra}Content-Length: 2\r\n\r\nOK"
        conn.flush
      end
      conn.close
    end
  end
  port
end

private def gzip_post(port : Int32, path : String) : Bytes
  body = IO::Memory.new
  Compress::Gzip::Writer.open(body, &.print("token=foo"))
  io = IO::Memory.new
  io << "POST #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Encoding: gzip\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n"
  io.write(body.to_slice)
  io.to_slice
end

# Sends `requests` in turn on one client connection, waiting for each record. Yields the sink.
private def exchange(extras : Array(String), &requests : Int32 -> Array(Bytes))
  port = start_origin(extras)
  done = Channel(Nil).new(extras.size)
  sink = RecordingSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRuleRewriter.new)
  proxy.start
  begin
    client = TCPSocket.new("127.0.0.1", proxy.port)
    requests.call(port).each do |raw|
      client.write(raw)
      client.flush
      receive_within(done, what: "the response record")
    end
    client.close
    sink
  ensure
    proxy.stop
  end
end

describe "proxy — an HTTP/1.1 flow's advisory across both halves (#1905)" do
  it "keeps the request's advisory when the response writes one of its own" do
    sink = exchange([ALT_SVC]) { |port| [gzip_post(port, "/h3")] }
    request_note = sink.requests.first.advisory.should_not be_nil
    request_note.should contain("Match&Replace was NOT applied to this request body")
    advisory = sink.responses.first.advisory.should_not be_nil
    advisory.should start_with("#{request_note}\n")
    advisory.should contain(%(Alt-Svc HTTP/3 advertisement (h3=":443")))
    advisory.scan("NOT applied").size.should eq(1)
  end

  it "writes no response advisory when only the request has one, which keeps the column" do
    sink = exchange([""]) { |port| [gzip_post(port, "/plain")] }
    sink.requests.first.advisory.to_s.should contain("NOT applied")
    sink.responses.first.advisory.should be_nil
  end

  it "does not carry one request's advisory onto the next exchange on the connection" do
    sink = exchange(["", ALT_SVC]) do |port|
      [gzip_post(port, "/1"), "GET /2 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice]
    end
    sink.requests[1].advisory.should be_nil
    second = sink.responses[1].advisory.should_not be_nil
    second.should contain("Alt-Svc HTTP/3 advertisement")
    second.should_not contain("NOT applied")
  end
end
