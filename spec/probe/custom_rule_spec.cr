require "../spec_helper"

# Custom Probe match rules: the data-driven passive engine (Probe::CustomRule), its global/project
# merge (Probe.custom_rules), and the per-project storage (probe_custom_rules + probe_disabled_rules).

private def with_store(&)
  path = File.tempname("gori-custom", ".db")
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

private def flow(store, *, resp_head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
                 body : String? = nil, req_headers = "", req_body : String? = nil,
                 host = "acme.test", method = "GET") : Gori::Store::FlowDetail
  head = String.build { |io| io << method << " / HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n" }
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: method, target: "/", http_version: "HTTP/1.1",
    head: head.to_slice, body: req_body.try(&.to_slice))
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def rule(*, side = "response", region = "body", kind = "string", pattern = "SECRET",
                 sev = Gori::Store::Severity::High, scope = "project", enabled = true,
                 id = "1", title = "leak", desc = "found a secret") : Gori::Probe::CustomRule
  Gori::Probe::CustomRule.new(id, title, desc, side, region, kind, pattern, sev, scope, enabled)
end

private def matches?(store, r : Gori::Probe::CustomRule, **flow_kw) : Array(Gori::Probe::Detection)
  ctx = Gori::Probe::Passive::Context.new(flow(store, **flow_kw))
  acc = [] of Gori::Probe::Detection
  r.check(ctx, acc)
  acc
end

describe Gori::Probe::CustomRule do
  it "builds a stable, scope-tagged finding code" do
    rule(scope: "project", id: "7").code.should eq("custom_p_7")
    rule(scope: "global", id: "ab12").code.should eq("custom_g_ab12")
  end

  it "matches a string in the response body and emits a CUSTOM detection" do
    with_store do |store|
      dets = matches?(store, rule(pattern: "SECRET"), body: "here is a SECRET token")
      dets.size.should eq(1)
      d = dets.first
      d.code.should eq("custom_p_1")
      d.category.should eq(Gori::Probe::Category::CUSTOM)
      d.severity.should eq(Gori::Store::Severity::High)
      d.title.should eq("leak")
    end
  end

  it "matches a regex in the response body" do
    with_store do |store|
      matches?(store, rule(kind: "regex", pattern: "sk_[a-z]+"), body: "key=sk_live here").size.should eq(1)
      matches?(store, rule(kind: "regex", pattern: "sk_[a-z]+"), body: "nothing").size.should eq(0)
    end
  end

  it "matches across sides and regions" do
    with_store do |store|
      # request header
      matches?(store, rule(side: "request", region: "header", pattern: "X-Api-Key"),
        req_headers: "X-Api-Key: abc\r\n").size.should eq(1)
      # request body
      matches?(store, rule(side: "request", region: "body", pattern: "passwd"),
        method: "POST", req_body: "user=a&passwd=b").size.should eq(1)
      # response header
      matches?(store, rule(side: "response", region: "header", pattern: "Content-Type"),
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n").size.should eq(1)
      # whole response = head + body
      matches?(store, rule(side: "response", region: "whole", pattern: "text/html"),
        body: "x").size.should eq(1)
    end
  end

  it "does not match when disabled" do
    with_store do |store|
      matches?(store, rule(enabled: false, pattern: "SECRET"), body: "a SECRET").size.should eq(0)
    end
  end

  it "is byte-safe: a bad regex or non-UTF-8 body never raises" do
    with_store do |store|
      # invalid regex → no match, no raise
      matches?(store, rule(kind: "regex", pattern: "("), body: "anything").size.should eq(0)
      # non-UTF-8 body bytes → scrubbed, no raise
      dirty = String.new(Bytes[0xff, 0xfe, 0x41, 0x41])
      matches?(store, rule(kind: "regex", pattern: "A+"), body: dirty).size.should eq(1)
    end
  end
end

describe "Gori::Probe::Passive.analyze rule config" do
  it "skips disabled built-in rules and runs custom rules" do
    with_store do |store|
      detail = flow(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", body: "SECRET here")
      custom = [rule(pattern: "SECRET")]

      # security_headers disabled → none of its missing_* codes
      dets = Gori::Probe::Passive.analyze(detail, disabled: Set{"security_headers"}, custom: custom)
      codes = dets.map(&.code)
      codes.any?(&.starts_with?("missing_")).should be_false
      codes.should contain("custom_p_1")

      # not disabled → the built-in fires again
      Gori::Probe::Passive.analyze(detail).map(&.code).any?(&.starts_with?("missing_")).should be_true
    end
  end
end

describe "Gori::Store custom-rule config" do
  it "round-trips the disabled-rule set" do
    with_store do |store|
      store.probe_disabled_rules.empty?.should be_true
      store.set_probe_disabled_rules(Set{"cookies", "cors"})
      store.probe_disabled_rules.should eq(Set{"cookies", "cors"})
      store.set_probe_disabled_rules(Set(String).new) # empty clears the key
      store.probe_disabled_rules.empty?.should be_true
    end
  end

  it "CRUDs project custom rules" do
    with_store do |store|
      id = store.insert_probe_custom_rule("t", "d", "response", "body", "regex", "sk_.+", Gori::Store::Severity::Medium)
      rules = store.probe_custom_rules
      rules.size.should eq(1)
      rules.first.title.should eq("t")
      rules.first.severity.should eq(Gori::Store::Severity::Medium)
      rules.first.enabled?.should be_true

      store.set_probe_custom_rule_enabled(id, false)
      store.probe_custom_rules.first.enabled?.should be_false

      store.update_probe_custom_rule(id, "t2", "d2", "request", "header", "string", "x", Gori::Store::Severity::High)
      updated = store.probe_custom_rules.first
      updated.title.should eq("t2")
      updated.side.should eq("request")
      updated.severity.should eq(Gori::Store::Severity::High)

      store.delete_probe_custom_rule(id)
      store.probe_custom_rules.empty?.should be_true
    end
  end

  # Both scan-rule writers report whether the toggle COMMITTED, so `gori run probe rules
  # enable/disable` can refuse instead of printing "Rule 'x' is now disabled." over a
  # busy/locked project that kept the old setting. They used to return Nil — the settings one
  # while already holding the answer, since set_setting/delete_setting are both exec_task_ok.
  # A `true` here means the batch COMMITTED, which is not the same as "a row matched" — so the
  # state is asserted beside every return value. Without that second half the example would
  # still pass for a bogus id, i.e. it would certify exactly the weakness the guard is meant to
  # close.
  it "reports whether a scan-rule toggle committed, and commits it" do
    with_store do |store|
      store.set_probe_disabled_rules(Set{"cookies"}).should be_true
      store.probe_disabled_rules.should eq(Set{"cookies"})
      store.set_probe_disabled_rules(Set(String).new).should be_true # the delete_setting branch
      store.probe_disabled_rules.empty?.should be_true

      id = store.insert_probe_custom_rule("t", "d", "response", "body", "string", "x", Gori::Store::Severity::Low)
      store.set_probe_custom_rule_enabled(id, false).should be_true
      store.probe_custom_rules.first.enabled?.should be_false
      store.set_probe_custom_rule_enabled(id, true).should be_true
      store.probe_custom_rules.first.enabled?.should be_true
    end
  end

  it "reports a scan-rule toggle as NOT committed once the store is closing" do
    path = File.tempname("gori-custom-closed", ".db")
    # Open + seed INSIDE the begin, like `with_store` does: a raise in Store.open or the insert
    # would otherwise leak the temp db and its -wal/-shm siblings.
    begin
      store = Gori::Store.open(path)
      id = store.insert_probe_custom_rule("t", "d", "response", "body", "string", "x", Gori::Store::Severity::Low)
      store.close
      store.set_probe_disabled_rules(Set{"cookies"}).should be_false
      store.set_probe_custom_rule_enabled(id, false).should be_false
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end

describe "Gori::Probe.custom_rules merge" do
  it "unions the global library with the project rules, tagged by scope" do
    with_store do |store|
      saved = Gori::Settings.scan_rules
      begin
        Gori::Settings.scan_rules = [
          Gori::Settings::ScanRule.new("g1", "global rule", "d", "response", "body", "string", "GLOB", "medium", true),
        ]
        store.insert_probe_custom_rule("proj rule", "d", "response", "body", "string", "PROJ", Gori::Store::Severity::Low)

        merged = Gori::Probe.custom_rules(store)
        merged.size.should eq(2)
        g = merged.find(&.global?).not_nil!
        g.title.should eq("global rule")
        g.code.should eq("custom_g_g1")
        g.severity.should eq(Gori::Store::Severity::Medium)
        p = merged.find { |r| !r.global? }.not_nil!
        p.title.should eq("proj rule")
        p.code.should start_with("custom_p_")
      ensure
        Gori::Settings.scan_rules = saved
      end
    end
  end
end

# A custom finding used to store `evidence: nil`, so every surface could say a rule fired on a
# host but never what tripped it — the operator had to re-run the pattern by hand against the
# sample flow. A regex rule now reports its match.
describe "Gori::Probe::CustomRule evidence" do
  it "reports capture group 1 when the pattern defines one" do
    with_store do |store|
      dets = matches?(store, rule(kind: "regex", pattern: "build-id:\\s*([0-9a-f]{8})"),
        body: "meta build-id: deadbeef end")
      dets.size.should eq(1)
      dets.first.evidence.should eq("deadbeef")
    end
  end

  it "reports the whole match when the pattern has no group" do
    with_store do |store|
      dets = matches?(store, rule(kind: "regex", pattern: "internal-[a-z]+\\.corp"),
        body: "host is internal-billing.corp today")
      dets.first.evidence.should eq("internal-billing.corp")
    end
  end

  # A string rule's match is byte-identical to its own pattern, which every surface already
  # shows next to the rule, so reporting it again would be pure duplication.
  it "reports no evidence for a string rule" do
    with_store do |store|
      dets = matches?(store, rule(kind: "string", pattern: "SECRET"), body: "a SECRET here")
      dets.size.should eq(1)
      dets.first.evidence.should be_nil
    end
  end

  it "caps a greedy pattern so it cannot write a whole body into the issue row" do
    with_store do |store|
      dets = matches?(store, rule(kind: "regex", pattern: "A.*"), body: "A#{"z" * 500}")
      ev = dets.first.evidence.not_nil!
      ev.size.should be <= Gori::Probe::CustomRule::EVIDENCE_CAP + 1
      ev.should end_with("…")
    end
  end

  it "strips control bytes out of the captured text before it reaches storage or the TUI" do
    with_store do |store|
      bel = 7.chr
      dets = matches?(store, rule(kind: "regex", pattern: "tag:(.+)"),
        body: "tag:val#{bel}ue")
      dets.first.evidence.should eq("val ue")
    end
  end

  it "still degrades a bad pattern to no match instead of raising" do
    with_store do |store|
      matches?(store, rule(kind: "regex", pattern: "([unclosed"), body: "anything").should be_empty
    end
  end
end

describe "Gori::Probe::Passive::Context whole-region memo" do
  it "joins head and body with CRLF, byte-identically to the per-rule build it replaced" do
    with_store do |store|
      ctx = Gori::Probe::Passive::Context.new(
        flow(store, resp_head: "HTTP/1.1 200 OK\r\nX-A: 1\r\n\r\n", body: "BODY"))
      ctx.response_whole_text.should eq("#{ctx.response_head_text}\r\n#{ctx.body_text}")
    end
  end

  it "hands every rule the SAME string rather than rebuilding it per rule" do
    with_store do |store|
      ctx = Gori::Probe::Passive::Context.new(flow(store, body: "BODY"))
      ctx.response_whole_text.not_nil!.same?(ctx.response_whole_text.not_nil!).should be_true
    end
  end

  it "falls back to whichever side exists when the other is absent" do
    with_store do |store|
      ctx = Gori::Probe::Passive::Context.new(flow(store, body: nil))
      ctx.response_whole_text.should eq(ctx.response_head_text) # no body → head alone
      ctx.request_whole_text.should eq(ctx.request_head_text)   # GET, no request body
    end
  end
end
