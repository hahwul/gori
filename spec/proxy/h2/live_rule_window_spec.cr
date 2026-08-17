require "../../spec_helper"
require "log/spec"

# #730: the three gates that force a host off HTTP/2 so a body / short-circuit / body-scoped
# extract rule can run are evaluated ONCE, inside CONNECT (`tls/tunnel.cr#h2_downgrade_reason`).
# The tables they read are live-mutated in place and nothing tears down an open relay when they
# change, so a rule enabled while an h2 connection is already open applies to nothing on that
# connection — and before this it said nothing at all.
#
# Every rule here is added AFTER the pipeline is built, because that IS the window: the rule
# tables handed to `HeadRewrite` are the same objects `Session` mutates live.

private alias LFrame = Gori::Proxy::H2::Frame
private alias LHPACK = Gori::Proxy::H2::HPACK

private LIVE_SC   = Gori::Store::RuleOp::ShortCircuit
private LIVE_REQ  = Gori::Store::RuleTarget::Request
private LIVE_HEAD = Gori::Store::RulePart::Head
private LIVE_BODY = Gori::Store::RulePart::Body

private CONNECT_HOST = "api.example.com"

private class LiveSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# Both tables off ONE store, the way `Session` wires them.
private def with_live_tables(&)
  path = File.tempname("gori-h2-live", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Rules.load(store), Gori::Bindings.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def live_pipe(rewriter : Gori::Proxy::HeadRewriter?,
                      extractor : Gori::Proxy::ResponseExtract? = nil,
                      direction = "out") : {Gori::Proxy::H2::HeadRewrite, Gori::Proxy::H2::Assembler}
  assembler = Gori::Proxy::H2::Assembler.new(LiveSink.new, CONNECT_HOST, 443, 1_i64)
  {Gori::Proxy::H2::HeadRewrite.new(direction, rewriter, assembler, CONNECT_HOST, extractor), assembler}
end

private def feed_request(pipe : Gori::Proxy::H2::HeadRewrite,
                         assembler : Gori::Proxy::H2::Assembler,
                         authority : String = CONNECT_HOST, stream : UInt32 = 1_u32) : Nil
  block = LHPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                      {":authority", authority}, {":path", "/x"}])
  frame = LFrame::Header.new(LFrame::Type::Headers.value,
    LFrame::END_HEADERS | LFrame::END_STREAM, stream, block)
  pipe.accept(frame) { |f, pre| assembler.feed("out", f, pre) }
end

private def feed_response(pipe : Gori::Proxy::H2::HeadRewrite,
                          assembler : Gori::Proxy::H2::Assembler, stream : UInt32 = 1_u32) : Nil
  block = LHPACK::Encoder.new.encode([{":status", "200"}])
  frame = LFrame::Header.new(LFrame::Type::Headers.value,
    LFrame::END_HEADERS | LFrame::END_STREAM, stream, block)
  pipe.accept(frame) { |f, pre| assembler.feed("in", f, pre) }
end

describe "h2 live-rule window (#730)" do
  it "warns once when a BODY rule goes live on an already-open connection" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules)
      Log.capture(level: :warn) do |logs|
        # The connection as it was allowed to negotiate h2: no rule the relay cannot run.
        feed_request(pipe, assembler)
        logs.empty

        # The operator writes the rule now, against the host they are browsing.
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        feed_request(pipe, assembler, stream: 3_u32)
        logs.check(:warn, /a Match&Replace BODY rule now matches "api\.example\.com"/)
        entry = logs.entry.message
        entry.should contain("already open when it went live")
        # It must NOT tell the coalescing story: this stream's authority IS the CONNECT host.
        entry.should_not contain("coalescing")

        # Once per connection, not once per request head.
        feed_request(pipe, assembler, stream: 5_u32)
        feed_request(pipe, assembler, stream: 7_u32)
        logs.empty
      end
    end
  end

  it "warns for a SHORT-CIRCUIT rule — the stub the operator watched reach the origin" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_HEAD, "/x", "403 Forbidden", op: LIVE_SC, host: CONNECT_HOST)
        feed_request(pipe, assembler)
        logs.check(:warn, /a Match&Replace SHORT-CIRCUIT rule now matches/)
      end
    end
  end

  it "warns for a body-scoped session-binding EXTRACT rule" do
    with_live_tables do |rules, bindings|
      pipe, assembler = live_pipe(rules, bindings)
      Log.capture(level: :warn) do |logs|
        # No Match&Replace rule at all — the rewriter is INACTIVE, so this cannot ride `rewrite`.
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: CONNECT_HOST).should be_nil
        rules.active?.should be_false
        feed_request(pipe, assembler)
        logs.check(:warn, /a session-binding EXTRACT rule that reads the response body now matches/)
      end
    end
  end

  it "names every live kind in one line" do
    with_live_tables do |rules, bindings|
      pipe, assembler = live_pipe(rules, bindings)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: CONNECT_HOST).should be_nil
        feed_request(pipe, assembler)
        logs.check(:warn, /now matches/)
        logs.entry.message.should contain("a Match&Replace BODY rule")
        logs.entry.message.should contain("a session-binding EXTRACT rule that reads the response body")
      end
    end
  end

  # The host scoping #526/#531 bought is not given back: a rule that cannot match this
  # connection's host costs it nothing, and says nothing either.
  it "says nothing for a rule scoped to a host this connection is not" do
    with_live_tables do |rules, bindings|
      pipe, assembler = live_pipe(rules, bindings)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: "alpha.test")
        bindings.add("SESSION", "", Gori::ExtractKind::Regex, "tok=(\\w+)", host: "alpha.test").should be_nil
        feed_request(pipe, assembler)
        logs.empty
      end
    end
  end

  # The reachable seams stay quiet, because they are not the window: a HEAD rule runs on this
  # very pipeline from the next request head, and a head-scoped extract runs in `H2::Extract`.
  it "says nothing for a HEAD rule or a head-scoped extract rule, which DO reach this relay" do
    with_live_tables do |rules, bindings|
      pipe, assembler = live_pipe(rules, bindings)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_HEAD, "/x", "/y", host: CONNECT_HOST)
        bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid", host: CONNECT_HOST).should be_nil
        bindings.extracts?.should be_true # live, just not unreachable
        feed_request(pipe, assembler)
        logs.empty
      end
    end
  end

  it "says nothing for a disabled rule" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        rules.toggle(rules.rules.first.id)
        feed_request(pipe, assembler)
        logs.empty
      end
    end
  end

  # The notice is a REQUEST-side one: the "in" pipeline shares the class but never asks.
  it "says nothing on the response direction" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules, direction: "in")
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        feed_response(pipe, assembler)
        logs.empty
      end
    end
  end

  # A request head with no `:authority` is a request for the connection's own host, so it takes
  # the same branch rather than falling out of the notice entirely.
  it "still warns for a head that carries no :authority" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        block = LHPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                            {":path", "/x"}, {"host", CONNECT_HOST}])
        frame = LFrame::Header.new(LFrame::Type::Headers.value,
          LFrame::END_HEADERS | LFrame::END_STREAM, 1_u32, block)
        pipe.accept(frame) { |f, pre| assembler.feed("out", f, pre) }
        logs.check(:warn, /now matches "api\.example\.com"/)
      end
    end
  end

  # Two disjoint failures, two latches: the coalescing notice (#526/#536) must not be swallowed
  # by a same-host line already written, nor the reverse.
  it "keeps the coalesced notice on its own latch" do
    with_live_tables do |rules, _|
      pipe, assembler = live_pipe(rules)
      Log.capture(level: :warn) do |logs|
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: CONNECT_HOST)
        rules.add(LIVE_REQ, LIVE_BODY, "secret", "REDACTED", host: "alpha.test")

        feed_request(pipe, assembler)
        logs.check(:warn, /now matches "api\.example\.com"/)

        feed_request(pipe, assembler, authority: "alpha.test", stream: 3_u32)
        logs.check(:warn, /stream authority "alpha\.test" is not the CONNECT host/)

        # ...and each stays capped at one.
        feed_request(pipe, assembler, stream: 5_u32)
        feed_request(pipe, assembler, authority: "alpha.test", stream: 7_u32)
        logs.empty
      end
    end
  end
end
