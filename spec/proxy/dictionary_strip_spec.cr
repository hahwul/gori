require "../spec_helper"
require "socket"

# The Compression Dictionary Transport strip on the HTTP/1.1 path (settings
# `network.strip_available_dictionary`, #1898): what the ORIGIN receives, what History records,
# and what the flow says about it.

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

# A request head rule that puts `Available-Dictionary` back: the operator, for this host.
private class ReAddRewriter < Gori::Proxy::HeadRewriter
  def active? : Bool
    true
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).sub("\r\n\r\n", "\r\nAvailable-Dictionary: :put-back=:\r\n\r\n").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end
end

private HASH  = ":pZGm1Av0IEBKARczz7exkNYsZb8LzaMrV7J32a2fFG4=:"
private OFFER = "Available-Dictionary: #{HASH}\r\nDictionary-ID: \"app-v1\"\r\n" \
                "Accept-Encoding: gzip, br, zstd, dcb, dcz\r\n"

# An origin answering `count` requests per connection, handing each request head it read to `heads`.
private def start_origin(heads : Channel(String), count = 1, response_extra = "") : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      count.times do |i|
        heads.send(String.build do |io|
          while line = conn.gets("\r\n", chomp: false)
            io << line
            break if line == "\r\n"
          end
        end)
        conn << "HTTP/1.1 200 OK\r\n#{response_extra}Content-Length: 3\r\n\r\nOK#{i}"
        conn.flush
      end
      conn.close
    end
  end
  port
end

private def with_switch(on : Bool, &)
  before = Gori::Settings.strip_available_dictionary?
  begin
    Gori::Settings.strip_available_dictionary = on
    yield
  ensure
    Gori::Settings.strip_available_dictionary = before
  end
end

# One request through a live proxy. Yields the head the origin received and the sink.
private def through_proxy(on : Bool, extra : String, rewriter : Gori::Proxy::HeadRewriter? = nil,
                          response_extra = "", &)
  with_switch(on) do
    heads = Channel(String).new(4)
    port = start_origin(heads, response_extra: response_extra)
    done = Channel(Nil).new(1)
    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rewriter)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{extra}Connection: close\r\n\r\n"
      client.flush
      client.gets_to_end.should contain("OK0")
      client.close
      receive_within(done, what: "the response record")
      yield receive_within(heads, what: "the origin's request head"), sink, port
    ensure
      proxy.stop
    end
  end
end

describe "proxy — the dictionary offer strip (HTTP/1.1)" do
  it "removes both fields before the origin, leaves Accept-Encoding, and records what was sent" do
    through_proxy(on: true, extra: OFFER) do |got, sink, _|
      got.downcase.should_not contain("available-dictionary")
      got.downcase.should_not contain("dictionary-id")
      got.should contain("Accept-Encoding: gzip, br, zstd, dcb, dcz\r\n")
      String.new(sink.requests.first.head).should eq(got)
      sink.requests.first.advisory.should eq(Gori::DictionaryTransport.removal_note(
        ["Available-Dictionary: #{HASH}", %(Dictionary-ID: "app-v1")]))
      # nil on the response side is what leaves the request side's advisory in the column.
      sink.responses.first.advisory.should be_nil
    end
  end

  it "joins a response that writes its own advisory, which would otherwise replace the request's" do
    before = Gori::Settings.strip_alt_svc?
    begin
      Gori::Settings.strip_alt_svc = true
      through_proxy(on: true, extra: OFFER, response_extra: %(Alt-Svc: h3=":443"\r\n)) do |_, sink, _|
        advisory = sink.responses.first.advisory.to_s
        advisory.should contain(%(Alt-Svc HTTP/3 advertisement (h3=":443")))
        advisory.scan(sink.requests.first.advisory.not_nil!).size.should eq(1)
      end
    ensure
      Gori::Settings.strip_alt_svc = before
    end
  end

  it "says so on a request recorded without reaching the origin" do
    with_switch(true) do
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.local_address.port
      closed.close
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
      proxy.start
      begin
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{OFFER}Connection: close\r\n\r\n"
        client.flush
        client.gets_to_end.should contain("502")
        client.close
        receive_within(done, what: "the error record")
        sink.responses.first.error.should_not be_nil
        sink.requests.first.advisory.to_s.should contain("network.strip_available_dictionary")
      ensure
        proxy.stop
      end
    end
  end

  it "forwards the client's bytes exactly with the switch off, which is the default" do
    Gori::Settings::DEFAULT_STRIP_AVAILABLE_DICTIONARY.should be_false
    through_proxy(on: false, extra: OFFER) do |got, sink, port|
      got.should eq("GET / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{OFFER}Connection: close\r\n\r\n")
      sink.requests.first.advisory.should be_nil
    end
  end

  it "lets a head rule put a field back, and then does not claim it is gone" do
    through_proxy(on: true, extra: OFFER, rewriter: ReAddRewriter.new) do |got, sink, _|
      got.should contain("Available-Dictionary: :put-back=:\r\n")
      got.should_not contain(HASH)
      sink.requests.first.advisory.should eq(Gori::DictionaryTransport.removal_note([%(Dictionary-ID: "app-v1")]))
    end
  end

  it "does not carry one request's advisory onto the next on the same connection" do
    with_switch(true) do
      heads = Channel(String).new(4)
      port = start_origin(heads, count: 2)
      done = Channel(Nil).new(2)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
      proxy.start
      begin
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET /1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n#{OFFER}\r\n"
        client.flush
        receive_within(done, what: "the first response record")
        client << "GET /2 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
        client.flush
        client.gets_to_end.should contain("OK1")
        client.close
        receive_within(done, what: "the second response record")
        receive_within(heads, what: "the first head").should start_with("GET /1")
        receive_within(heads, what: "the second head").should start_with("GET /2")
        sink.requests.size.should eq(2)
        sink.requests[0].advisory.to_s.should contain("network.strip_available_dictionary")
        sink.requests[1].advisory.should be_nil
      ensure
        proxy.stop
      end
    end
  end
end
