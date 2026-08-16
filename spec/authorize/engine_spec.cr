require "../spec_helper"
require "../../src/gori/authorize/engine"

private alias Identity = Gori::Authorize::Identity
private alias Verdict = Gori::Authorize::Verdict

# A send backend that answers from a table keyed by a marker substring found in the request
# bytes (each identity stamps a distinctive `X-Id:` header; the baseline carries none, so it
# maps to "*"). Order-independent and explicit about which identity gets which response.
private class FakeBackend < Gori::Fuzz::Backend
  getter sent = [] of Bytes

  def initialize(@responses : Hash(String, Gori::Repeater::Result), @origin : Gori::Fuzz::Origin)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes
    text = String.new(bytes)
    key = @responses.keys.find { |k| k != "*" && text.includes?(k) } || "*"
    @responses[key]
  end
end

private def ok_resp(status : Int32, body : String) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\n\r\n".to_slice
  Gori::Repeater::Result.new(head, body.to_slice, nil, 1_000_i64)
end

private def err_resp : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection refused")
end

private def detail : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "api.example.com", 443,
    "/admin", 200, 100_i64, Gori::Store::FlowState::Complete)
  head = "GET /admin HTTP/1.1\r\nHost: api.example.com\r\nCookie: session=ADMIN\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def engine(responses : Hash(String, Gori::Repeater::Result)) : Gori::Authorize::Engine
  origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
  fake = FakeBackend.new(responses, origin)
  Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
end

describe Gori::Authorize::Engine do
  it "judges a low-priv identity that sees baseline content as Same (a likely bypass)" do
    dashboard = "the full admin dashboard with billing and every user record and control panel here"
    responses = {
      "*"          => ok_resp(200, dashboard), # baseline (as-captured admin session)
      "X-Id: user" => ok_resp(200, dashboard), # low-priv sees the SAME page → bypass
      "X-Id: anon" => ok_resp(403, "Forbidden"),
    }
    ids = [
      Identity.new("admin", baseline: true),
      Identity.new("user", set_headers: [{"X-Id", "user"}, {"Cookie", "session=USER"}]),
      Identity.new("anon", remove_headers: ["Cookie"], set_headers: [{"X-Id", "anon"}]),
    ]
    target = engine(responses).run(detail, ids).not_nil!

    target.trials.size.should eq(3)
    target.trials[0].identity.should eq("admin")
    target.trials[0].verdict.should eq(Verdict::Baseline)
    target.trials[0].delta.should be_nil

    user = target.trials.find { |t| t.identity == "user" }.not_nil!
    user.verdict.should eq(Verdict::Same)
    user.delta.should_not be_nil

    anon = target.trials.find { |t| t.identity == "anon" }.not_nil!
    anon.verdict.should eq(Verdict::Different)

    target.same_count.should eq(1)
  end

  it "reports a send failure for that identity as Error without aborting the run" do
    responses = {
      "*"          => ok_resp(200, "baseline body content that is perfectly fine and served here"),
      "X-Id: user" => err_resp,
    }
    ids = [
      Identity.new("admin", baseline: true),
      Identity.new("user", set_headers: [{"X-Id", "user"}]),
    ]
    target = engine(responses).run(detail, ids).not_nil!
    user = target.trials.find { |t| t.identity == "user" }.not_nil!
    user.verdict.should eq(Verdict::Error)
  end

  # REGRESSION: a flow captured through the proxy stores an ABSOLUTE-FORM request line. Sent
  # verbatim to an origin dialed directly, that whole URL reads as the path, so every identity
  # gets the origin's catch-all page and the verdicts describe a request nobody made. Caught in
  # a live run where a properly-protected /orders came back "same" for the anonymous identity.
  it "rewrites an absolute-form request line to origin-form before sending" do
    row = Gori::Store::FlowRow.new(1_i64, 0_i64, "http", "GET", "127.0.0.1", 19311,
      "http://127.0.0.1:19311/orders", 200, 100_i64, Gori::Store::FlowState::Complete)
    head = "GET http://127.0.0.1:19311/orders HTTP/1.1\r\nHost: 127.0.0.1:19311\r\nCookie: s=1\r\n\r\n".to_slice
    captured = Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)

    origin = Gori::Fuzz::Origin.new("http", "127.0.0.1", 19311)
    fake = FakeBackend.new({"*" => ok_resp(200, "ok")}, origin)
    eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
    eng.run(captured, [Identity.as_captured, Identity.new("anon", remove_headers: ["Cookie"])])

    fake.sent.size.should eq(2)
    fake.sent.each do |bytes|
      String.new(bytes).lines.first.should eq("GET /orders HTTP/1.1")
    end
    # and the overlay still applied on top of the rewritten line
    String.new(fake.sent[1]).includes?("Cookie:").should be_false
  end

  it "anchors on the first identity when none is marked baseline" do
    responses = {"*" => ok_resp(200, "some page")}
    target = engine(responses).run(detail, [Identity.new("only")]).not_nil!
    target.trials.size.should eq(1)
    target.trials[0].baseline?.should be_true
    target.baseline.should_not be_nil
  end

  # A stop has to land BETWEEN IDENTITIES, not only between requests: with several identities
  # configured, honouring it only at the request boundary still puts the remaining identities'
  # requests on a target the operator asked gori to leave alone (P4).
  describe "the stop predicate" do
    it "sends no further identities once it fires, and claims no Target" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      ids = [Identity.new("a", baseline: true), Identity.new("b"), Identity.new("c")]

      # Stop after the first identity has gone out.
      sent = 0
      result = eng.run(detail, ids, -> { (sent += 1) > 1 })

      fake.sent.size.should eq(1) # b and c never left
      result.should be_nil        # a partial run must not claim a verdict
    end

    it "returns the Target normally when it never fires" do
      responses = {"*" => ok_resp(200, "page")}
      target = engine(responses).run(detail, [Identity.new("only")], -> { false }).not_nil!
      target.trials.size.should eq(1)
    end

    it "still completes when the predicate only fires after the last identity" do
      origin = Gori::Fuzz::Origin.new("https", "api.example.com", 443)
      fake = FakeBackend.new({"*" => ok_resp(200, "page")}, origin)
      eng = Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { fake.as(Gori::Fuzz::Backend) })
      polls = 0
      target = eng.run(detail, [Identity.new("a", baseline: true), Identity.new("b")],
        -> { (polls += 1) > 2 })
      fake.sent.size.should eq(2)
      target.should_not be_nil # every identity ran, so the result stands
    end
  end
end
