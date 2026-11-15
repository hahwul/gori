require "../../spec_helper"
require "socket"

# #1901: a chunked message stream (NDJSON here) under a response-body rule. HTTP/1.1 buffers it
# so the rule can run, which is right for one that ends and used to stall one that does not
# until 16 MiB had arrived. It now waits `ClientConn::STREAM_BODY_WAIT` and then releases it.

private class StreamRuleSink < Gori::Proxy::FlowSink
  getter responses = Channel(Gori::Store::CapturedResponse).new(16)

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.send(resp)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private LINE = %({"n":"tick"}\n)

# One connection, one line per chunk every 20 ms: `lines` of them and then the last chunk, or
# without end when `lines` is nil.
private def stream_origin(lines : Int32?, type = "application/x-ndjson", extra_head = "") : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    if conn = origin.accept?
      begin
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\n#{extra_head}" \
                "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
        sent = 0
        while lines.nil? || sent < lines
          conn << LINE.bytesize.to_s(16) << "\r\n" << LINE << "\r\n"
          conn.flush
          sent += 1
          sleep 20.milliseconds
        end
        conn << "0\r\n\r\n"
        conn.flush
      rescue IO::Error
      ensure
        conn.close
      end
    end
  end
  origin
end

# A proxy carrying a response-body rule (`tick` → `tock`) in front of `origin`, with `wait`
# standing in for `ClientConn::STREAM_BODY_WAIT`, which is 5 s in production.
private def through_rule(origin : TCPServer, wait : Time::Span, interceptor : Bool = false,
                         bind : Bool = false, & : TCPSocket, StreamRuleSink, Gori::Interceptor, Gori::Bindings ->) : Nil
  Gori::Proxy::ClientConn.stream_body_wait = wait
  previous = Gori::Env.layer
  with_store do |store|
    rules = Gori::Rules.new(store, store.match_rules)
    rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "tick", "tock") unless interceptor
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    if interceptor
      ic.toggle
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
    end
    bindings = Gori::Bindings.load(store)
    if bind
      Gori::Env.layer = bindings
      bindings.add("SESSION", "path:/stream", Gori::ExtractKind::Cookie, "sid").should be_nil
    end
    sink = StreamRuleSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules,
      interceptor: interceptor ? ic : nil, extractor: bind ? bindings : nil)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 2.seconds
    client << "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:#{origin.local_address.port}\r\n\r\n"
    client.flush
    begin
      yield client, sink, ic, bindings
    ensure
      client.close
      proxy.stop
      origin.close
    end
  end
ensure
  Gori::Env.layer = previous if previous
  Gori::Proxy::ClientConn.stream_body_wait = Gori::Proxy::ClientConn::STREAM_BODY_WAIT
end

# The advisory of the flow as it was finally recorded (a live capture reports more than once).
private def recorded_advisory(sink : StreamRuleSink) : String
  advisory = ""
  loop do
    select
    when resp = sink.responses.receive
      advisory = resp.advisory.to_s
      return advisory unless advisory.empty?
    when timeout(2.seconds)
      return advisory
    end
  end
end

describe "proxy: a chunked message stream under a response-body rule (#1901)" do
  it "releases one that does not end, and says the rule did not run" do
    through_rule(stream_origin(nil), 150.milliseconds) do |client, sink, _, _|
      client.gets("tick").to_s.should contain("application/x-ndjson")
      # Far more lines than the 150 ms of buffer released with the head could hold (a line
      # every 20 ms), so these are writes made after the release.
      40.times { client.gets("tick").should_not be_nil }
      client.close
      advisory = recorded_advisory(sink)
      advisory.should contain("Match&Replace was NOT applied")
      advisory.should contain("had not ended")
    end
  end

  it "still rewrites one that ends in time" do
    through_rule(stream_origin(3), 2.seconds) do |client, _, _, _|
      got = client.gets_to_end
      got.scan("tock").size.should eq(3)
      got.should_not contain("tick")
    end
  end

  it "releases one the response intercept was holding, and tells the operator then" do
    through_rule(stream_origin(nil), 150.milliseconds, interceptor: true) do |client, _, ic, _|
      client.gets("tick").to_s.should contain("application/x-ndjson")
      ic.pending_count.should eq(0)
      notices = [] of String
      50.times do
        notices.concat(ic.drain_notices)
        break unless notices.empty?
        sleep 10.milliseconds
      end
      notices.first.should contain("forwarded UNHELD")
    end
  end

  it "binds a head-scoped extract rule when the stream is released, not when it ends" do
    origin = stream_origin(nil, extra_head: "Set-Cookie: sid=r0tat3d; Path=/\r\n")
    through_rule(origin, 150.milliseconds, bind: true) do |client, _, _, bindings|
      client.gets("tick").should_not be_nil
      50.times { bindings.values["SESSION"]? ? break : sleep(10.milliseconds) }
      bindings.values["SESSION"]?.should eq("r0tat3d") # the stream is still open
    end
  end

  # SSE was never buffered. What changed is that the flow now says the rule did not run, in
  # the words HTTP/2 uses for the same skip.
  it "says so when a rule skipped an event stream" do
    through_rule(stream_origin(nil, type: "text/event-stream"), 2.seconds) do |client, sink, _, _|
      client.gets("tick").should_not be_nil
      client.close
      recorded_advisory(sink).should contain("it is a message stream (text/event-stream), which gori leaves streaming")
    end
  end
end
