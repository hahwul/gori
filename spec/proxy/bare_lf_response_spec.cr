require "../spec_helper"
require "../support/probe_harness"
require "socket"

# An origin whose RESPONSE head ends its lines on a bare LF — an embedded device or a legacy
# CGI. RFC 9112 §2.2 lets a recipient accept it and browsers render it, so through gori the
# client must get the exact bytes, the flow must carry its status and headers, and the
# upstream connection must never serve a second request (gori framed it off the lenient view).

private class BareLfSink < Gori::Proxy::FlowSink
  getter responses : Channel(Gori::Store::CapturedResponse)

  def initialize
    @next_id = 0_i64
    @responses = Channel(Gori::Store::CapturedResponse).new(8)
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

# A response BODY rule (hello → goodbye) that would re-frame the head to the new length.
private class LfBodyRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_response_body? : Bool
    true
  end

  def rewrites_response_body_for_host?(host : String) : Bool
    true
  end

  def rewrite_response_body(entity : Bytes, host : String) : Bytes
    String.new(entity).gsub("hello", "goodbye").to_slice
  end
end

# A response HEAD rule that changes Content-Length, which `restore_framing_headers` undoes.
private class LfHeadClRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    String.new(head).gsub("Content-Length: 5", "Content-Length: 7").to_slice
  end
end

# A plaintext origin that answers every request on a connection with `reply`, counting the
# connections it accepted. `close_after` closes each connection after its first reply. An
# Array reply is written part by part with a pause between, so a later part is NOT already
# buffered when gori reads the head of an earlier one.
private def bare_lf_origin(reply : String | Array(String), connections : Array(Int32), *,
                           close_after : Bool) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  parts = reply.is_a?(String) ? [reply] : reply
  spawn do
    while conn = origin.accept?
      connections[0] += 1
      bare_lf_serve(conn, parts, close_after) # a method, not a `spawn` capturing the loop variable
    end
  rescue
  end
  origin
end

private def bare_lf_serve(conn : TCPSocket, parts : Array(String), close_after : Bool) : Nil
  spawn do
    while Gori::Proxy::Codec::Http1.read_head(conn)
      parts.each_with_index do |part, i|
        sleep 50.milliseconds if i > 0
        conn << part
        conn.flush
      end
      break if close_after
    end
  rescue
  ensure
    conn.close rescue nil
  end
end

# The next recorded response, or a failure after 5 s — a regression here tends to be a flow
# that is never recorded (a misframed body still being read), which must fail, not hang.
private def bare_lf_next(sink : BareLfSink) : Gori::Store::CapturedResponse
  select
  when resp = sink.responses.receive
    resp
  when timeout(5.seconds)
    raise "no response recorded within 5 s"
  end
end

private def bare_lf_request(port : Int32, path : String) : String
  "GET http://127.0.0.1:#{port}#{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
end

private def with_bare_lf_proxy(rewriter : Gori::Proxy::HeadRewriter? = nil,
                               interceptor : Gori::Interceptor? = nil, &)
  sink = BareLfSink.new
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rewriter, interceptor: interceptor)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  client.read_timeout = 5.seconds
  begin
    yield client, sink
  ensure
    client.close rescue nil
    proxy.stop
  end
end

describe "proxy: a bare-LF response head" do
  it "relays a close-delimited origin's reply byte-exact and records its status, headers and body" do
    reply = "HTTP/1.1 200 OK\nContent-Type: text/plain\nX-Device: cam\n\nhello from the device"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: true)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      client.gets_to_end.should eq(reply) # exact bytes, nothing rewritten to CRLF (P7)

      captured = bare_lf_next(sink)
      captured.error.should be_nil
      captured.status.should eq(200)
      captured.reason.should eq("OK")
      captured.content_type.should eq("text/plain")
      String.new(captured.head).should eq("HTTP/1.1 200 OK\nContent-Type: text/plain\nX-Device: cam\n\n")
      String.new(captured.body.not_nil!).should eq("hello from the device")

      # The capture carries the Probe marker for the anomaly.
      with_store do |store|
        dets = probe_analyze(store, resp_head: String.new(captured.head), content_type: "text/plain",
          body: "hello from the device", scheme: "http")
        probe_codes_of(dets).should contain("bare_lf_response")
      end
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "answers a keep-alive origin at once, and dials a NEW upstream for the next request" do
    reply = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      2.times do |i|
        client << bare_lf_request(port, "/#{i}")
        client.flush
        got = Bytes.new(reply.bytesize)
        client.read_fully(got) # no 30 s head-deadline stall
        String.new(got).should eq(reply)

        captured = bare_lf_next(sink)
        captured.error.should be_nil
        captured.status.should eq(200)
        String.new(captured.body.not_nil!).should eq("hello")
      end
      # The first upstream served one response and was retired, even though the origin kept
      # it open and the client connection was reused.
      connections[0].should eq(2)
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "still refuses a bare-LF head whose framing a lenient reader would split on" do
    # The LF reading sees Content-Length: 0; a reader that also ends lines on a lone CR sees
    # Transfer-Encoding: chunked. Same refusal as a CRLF head carrying the same ambiguity.
    reply = "HTTP/1.1 200 OK\nContent-Length: 0\nX-Foo: a\rTransfer-Encoding: chunked\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: true)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      captured = bare_lf_next(sink)
      captured.error.not_nil!.should contain("ambiguous framing")
      String.new(captured.head).should start_with("HTTP/1.1 200 OK\nContent-Length: 0\n")
    end
  ensure
    origin.try(&.close) rescue nil
  end

  # A CRLF-only reader does not stop at the `\n\r\n`; it reads on to the CRLFCRLF that is in
  # the same segment, and its reading frames the body differently. Refused, exactly as before
  # bare-LF heads were accepted — never framed by the shorter head and kept alive.
  it "refuses a head whose buffered CRLFCRLF reading frames the body differently" do
    {"HTTP/1.1 200 OK\r\nX: a\n\r\nContent-Length: 5\r\n\r\n"               => "helloEXTRA",
     "HTTP/1.1 200 OK\r\nContent-Length: 0\n\r\nContent-Length: 50\r\n\r\n" => "x" * 50}.each do |head, body|
      connections = [0]
      origin = bare_lf_origin(head + body, connections, close_after: false)
      port = origin.local_address.port
      begin
        with_bare_lf_proxy do |client, sink|
          client << bare_lf_request(port, "/")
          client.flush
          captured = bare_lf_next(sink)
          captured.error.not_nil!.should contain("ambiguous framing")
          String.new(captured.head).should eq(head)
          client.gets_to_end.should eq("") # nothing forwarded, and the client connection closes
        end
      ensure
        origin.close rescue nil
      end
    end
  end

  # Every rewrite helper models a head as CRLF lines; applied to this one it would hand the
  # client a head that ends at the first `\n\n` and a re-framed tail as the next response.
  it "forwards a bare-LF head byte-exact past a response body rule, and says so" do
    reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\nContent-Length: 5\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy(rewriter: LfBodyRewriter.new) do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      got = Bytes.new(reply.bytesize)
      client.read_fully(got)
      String.new(got).should eq(reply)
      captured = bare_lf_next(sink)
      captured.content_type.should eq("text/html")
      String.new(captured.body.not_nil!).should eq("hello")
      captured.advisory.not_nil!.should contain("Match&Replace was NOT applied")
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "forwards a bare-LF head byte-exact past a head rule that changes its framing" do
    reply = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy(rewriter: LfHeadClRewriter.new) do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      got = Bytes.new(reply.bytesize)
      client.read_fully(got)
      String.new(got).should eq(reply)
      captured = bare_lf_next(sink)
      String.new(captured.head).should eq("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\n")
      captured.advisory.not_nil!.should contain("Match&Replace was NOT applied")
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "records a held bare-LF response with the head the client reads" do
    store_path = File.tempname("gori-lf-hold", ".db")
    store = Gori::Store.open(store_path)
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle
    spawn do
      loop do
        ic.pending.each { |it| ic.forward(it.id) }
        sleep 10.milliseconds
      end
    end
    reply = "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: 5\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy(interceptor: ic) do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      got = Bytes.new(reply.bytesize)
      client.read_fully(got)
      String.new(got).should eq(reply)
      captured = bare_lf_next(sink)
      String.new(captured.head).should eq("HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: 5\n\n")
      captured.content_type.should eq("text/plain")
      String.new(captured.body.not_nil!).should eq("hello")
    end
  ensure
    origin.try(&.close) rescue nil
    store.try(&.close)
    store_path.try { |path| File.delete?(path); File.delete?("#{path}-wal"); File.delete?("#{path}-shm") }
  end

  it "says so on the flow when bytes were waiting past the framed body" do
    reply = "HTTP/1.1 200 OK\nContent-Length: 5\n\nhelloEXTRA"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      got = Bytes.new(reply.bytesize - 5)
      client.read_fully(got)
      String.new(got).should eq("HTTP/1.1 200 OK\nContent-Length: 5\n\nhello")
      captured = bare_lf_next(sink)
      String.new(captured.body.not_nil!).should eq("hello")
      captured.advisory.not_nil!.should contain("bytes were waiting on the upstream connection")
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "does not reuse an upstream whose interim 1xx head ended on a bare LF" do
    # The final head is CRLF; only the 103 before it was bare-LF, and it arrives on its own.
    parts = ["HTTP/1.1 103 Early Hints\nLink: </a.css>\n\n",
             "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"]
    connections = [0]
    origin = bare_lf_origin(parts, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      2.times do |i|
        client << bare_lf_request(port, "/#{i}")
        client.flush
        expected = parts.join
        got = Bytes.new(expected.bytesize)
        client.read_fully(got)
        String.new(got).should eq(expected)
        bare_lf_next(sink).status.should eq(200)
      end
      connections[0].should eq(2)
    end
  ensure
    origin.try(&.close) rescue nil
  end
end
