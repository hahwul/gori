require "./spec_helper"

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
