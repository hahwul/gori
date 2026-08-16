require "../../spec_helper"

# `gori run authorize` — the CLI adapter over `Authorize::Plan`.
#
# Two halves, and both are the adapter's own contract rather than the builder's:
#
#   1. The REFUSAL sentences. `Authorize::PlanError::Reason` has five members and every
#      surface `case`s them exhaustively (plan.cr's header calls that an explicit trap), so
#      each arm is driven here through a REAL `Plan.build` — a sentence asserted against a
#      hand-built error would keep passing after the builder stopped raising that reason.
#   2. The OUTPUT. text/json/jsonl are the three shapes a script or an operator reads, and the
#      point of the tool is that a bypass is obvious in all of them.
#
# The wording lives behind `private def self.` (nothing outside `gori run` may phrase it), so
# it is reached through a shim in the same module — the pattern `env_unresolved_error_for_spec`
# (spec/cli/run/bind_from_disabled_rule_spec.cr) already uses.
module Gori::CLI::Run
  def self.authorize_plan_error_for_spec(ex : Gori::Authorize::PlanError) : String
    authorize_plan_error(ex)
  end

  def self.authorize_skip_text_for_spec(s : Gori::Authorize::Skipped) : String
    authorize_skip_text(s)
  end
end

private alias A = Gori::Authorize

private def with_store(&)
  path = File.tempname("gori-cli-authorize", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A complete captured flow (request + response), the only kind Authorize replays.
private def capture_flow(store, method = "GET", target = "/admin", host = "acme.test",
                         req_headers = "Cookie: session=abc\r\n") : Int64
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ok".to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  id
end

# Two identities: the as-captured baseline plus one that drops the session. Anything less is
# `NoIdentities` by construction, so most examples need this in place first.
private def save_identities(store) : Nil
  store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY, A.serialize([
    A::Identity.as_captured,
    A::Identity.new("anonymous", remove_headers: ["Cookie"]),
  ]))
end

# The sentence `gori run authorize` would abort with for these options.
private def refusal(store, outbound = ungated_outbound, **opts) : String
  A::Plan.build(A::PlanOptions.new(store, **opts), outbound)
  fail "expected Plan.build to refuse"
rescue ex : A::PlanError
  Gori::CLI::Run.authorize_plan_error_for_spec(ex)
end

# --- fixtures for the formatters ------------------------------------------------

private def trial(identity : String, verdict : A::Verdict, status : Int32?, size : Int64?,
                  baseline = false, delta : String? = nil, error : String? = nil) : A::Trial
  meta = Gori::Repeater::ExchangeMeta.of(status, size, 1_000_i64, error)
  summary = A::ResponseSummary.new(status, size, 0_u64, error)
  A::Trial.new(identity, baseline, meta, verdict, delta, summary,
    "GET / HTTP/1.1\r\n\r\n".to_slice, nil, nil)
end

private def bypass_target : A::Target
  A::Target.new(7_i64, "GET", "https://acme.test/admin/users", [
    trial("as-captured", A::Verdict::Baseline, 200, 1200_i64, baseline: true),
    trial("anonymous", A::Verdict::Same, 200, 1200_i64, delta: "Δ status 200 · size same"),
    trial("low-priv", A::Verdict::Different, 403, 30_i64, delta: "Δ status 200 → 403"),
  ])
end

describe "gori run authorize — plan refusals" do
  it "NoTarget: names both selectors and where to find the ids" do
    with_store do |store|
      save_identities(store)
      msg = refusal(store)
      msg.should contain("no request selected")
      msg.should contain("--flow")
      msg.should contain("--query")
      msg.should contain("gori run history")
    end
  end

  it "NoFlows: echoes the query that matched nothing" do
    with_store do |store|
      save_identities(store)
      capture_flow(store)
      msg = refusal(store, query: "host:nowhere.test")
      msg.should contain("nothing to replay")
      msg.should contain("host:nowhere.test")
      msg.should contain("gori run history")
    end
  end

  it "NoFlows: an unknown flow id gets the id sentence, not the query one" do
    with_store do |store|
      save_identities(store)
      msg = refusal(store, flow_ids: [4242_i64])
      msg.should contain("no captured flow with that id")
      msg.should_not contain("--query")
    end
  end

  it "BadQuery: says WHY an uncompilable query is refused rather than run" do
    with_store do |store|
      save_identities(store)
      capture_flow(store)
      msg = refusal(store, query: "status:>=foo")
      msg.should contain("status:>=foo")
      msg.should contain("EVERY captured flow")
      msg.should contain("gori run history")
    end
  end

  it "NoIdentities: the project source points at the tab and the flag" do
    with_store do |store|
      id = capture_flow(store)
      msg = refusal(store, flow_ids: [id])
      msg.should contain("this project has no identities saved")
      msg.should contain("--identities")
      msg.should_not contain("resolved to fewer")
    end
  end

  it "NoIdentities: the json source blames the file, not the project" do
    with_store do |store|
      id = capture_flow(store)
      # One entry, and it claims the baseline — so nothing is prepended and there is no second
      # identity to compare against.
      msg = refusal(store, flow_ids: [id], identities_json: %([{"name":"only-one","baseline":true}]))
      msg.should contain("--identities resolved to fewer than two identities")
      msg.should_not contain("this project has no identities")
    end
  end

  it "NothingToSend: names the flag that would have replayed the skipped method" do
    with_store do |store|
      save_identities(store)
      id = capture_flow(store, method: "POST")
      msg = refusal(store, flow_ids: [id])
      msg.should contain("every selected flow was skipped")
      msg.should contain("not a safe method to repeat") # the builder's tally, carried through
      msg.should contain("--unsafe-methods")
      msg.should contain("--allow-unscoped")
    end
  end

  it "NothingToSend: an out-of-scope selection is reported as such" do
    with_store do |store|
      save_identities(store)
      id = capture_flow(store)
      # `Outbound.allowlist(nil)` has nothing to allowlist against, so it blocks everything —
      # the same shape a project with no scope include rule presents to a stricter surface.
      msg = refusal(store, Gori::Outbound.allowlist(nil), flow_ids: [id])
      msg.should contain("outside project scope")
      msg.should contain("--allow-unscoped")
    end
  end

  it "lists every skipped flow with its own reason, not just a tally" do
    skipped = A::Skipped.new(12_i64, "POST", "https://acme.test/orders", :unsafe_method)
    line = Gori::CLI::Run.authorize_skip_text_for_spec(skipped)
    line.should contain("#12")
    line.should contain("POST")
    line.should contain("https://acme.test/orders")
    line.should contain("not a safe method to repeat")
  end
end

describe "gori run authorize — output" do
  it "text: shouts BYPASS on the headline and counts the identities that matched" do
    text = Gori::CLI::Output.authorize_target_text(bypass_target)
    lines = text.lines
    lines[0].should contain("[!] BYPASS")
    lines[0].should contain("#7")
    lines[0].should contain("https://acme.test/admin/users")
    lines[0].should contain("1 of 2 identities matched the baseline")
    lines[1].should contain("as-captured")
    lines[1].should contain("baseline")
    lines[2].should contain("anonymous")
    lines[2].should contain("same")
    lines[3].should contain("low-priv")
    lines[3].should contain("different")
  end

  it "text: an enforced request is quiet, and an all-errored one says error" do
    enforced = A::Target.new(8_i64, "GET", "https://acme.test/me", [
      trial("as-captured", A::Verdict::Baseline, 200, 10_i64, baseline: true),
      trial("anonymous", A::Verdict::Different, 403, 5_i64, delta: "Δ status 200 → 403"),
    ])
    Gori::CLI::Output.authorize_target_text(enforced).lines[0].should contain("[ ] enforced")

    errored = A::Target.new(9_i64, "GET", "https://acme.test/me", [
      trial("as-captured", A::Verdict::Baseline, 200, 10_i64, baseline: true),
      trial("anonymous", A::Verdict::Error, nil, nil, error: "connect failed"),
    ])
    out = Gori::CLI::Output.authorize_target_text(errored)
    out.lines[0].should contain("[x] error")
    out.should contain("connect failed")
  end

  it "text: names sends the scope gate refused before the socket" do
    blocked = A::Target.new(10_i64, "GET", "https://acme.test/admin",
      [trial("as-captured", A::Verdict::Baseline, nil, nil, baseline: true, error: "blocked"),
       trial("anonymous", A::Verdict::Error, nil, nil, error: "blocked")],
      2_i64, "sandbox: acme.test is not in scope")
    out = Gori::CLI::Output.authorize_target_text(blocked)
    out.should contain("2 sends refused before the socket")
    out.should contain("sandbox: acme.test is not in scope")
  end

  it "jsonl: one object per request, carrying every trial" do
    obj = JSON.parse(Gori::CLI::Output.authorize_target_json(bypass_target))
    obj["flow_id"].as_i64.should eq(7)
    obj["method"].as_s.should eq("GET")
    obj["verdict"].as_s.should eq("bypass")
    obj["same_count"].as_i.should eq(1)
    trials = obj["trials"].as_a
    trials.size.should eq(3)
    trials[0]["identity"].as_s.should eq("as-captured")
    trials[0]["baseline"].as_bool.should be_true
    trials[1]["verdict"].as_s.should eq("same")
    trials[1]["status"].as_i.should eq(200)
    trials[2]["delta"].as_s.should contain("403")
  end

  it "json: ONE array for the whole run, not a stream (the run-producing family's split)" do
    doc = JSON.parse(Gori::CLI::Output.authorize_array_json([bypass_target, bypass_target]))
    arr = doc.as_a
    arr.size.should eq(2)
    arr.each(&.["verdict"].as_s.should(eq("bypass")))
  end

  it "json: blocked is emitted only when sends were actually refused" do
    Gori::CLI::Output.authorize_target_json(bypass_target).should_not contain("blocked")
    blocked = A::Target.new(11_i64, "GET", "https://acme.test/admin",
      [trial("as-captured", A::Verdict::Baseline, nil, nil, baseline: true),
       trial("anonymous", A::Verdict::Error, nil, nil, error: "blocked")],
      2_i64, "sandbox")
    JSON.parse(Gori::CLI::Output.authorize_target_json(blocked))["blocked"].as_i64.should eq(2)
  end

  it "aggregates the same way the TUI master row does" do
    Gori::CLI::Output.authorize_verdict(bypass_target).should eq(:bypass)
    review = A::Target.new(nil, "GET", "https://acme.test/x", [
      trial("as-captured", A::Verdict::Baseline, 200, 10_i64, baseline: true),
      trial("anonymous", A::Verdict::Review, 200, 90_i64),
    ])
    Gori::CLI::Output.authorize_verdict(review).should eq(:review)
  end
end
