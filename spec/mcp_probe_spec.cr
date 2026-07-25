require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-mcp-probe", ".db")
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

private def call_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# A flow whose URL carries a token → the SecretInUrl passive rule (High, infoleak).
# scan_flows skips a flow with no response_head, so the response is required.
private def seed_secret_flow(store) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/login?token=supersecretvalue123", http_version: "HTTP/1.1",
    head: "GET /login?token=supersecretvalue123 HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

describe "MCP probe_scan tool" do
  it "passively scans and returns grouped issues with the documented fields" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      res = call_json(tools, "probe_scan", "{}")
      res["active"].as_bool.should be_false
      res["flows_scanned"].as_i.should eq(1)
      res["issue_count"].as_i.should be > 0
      issue = res["issues"].as_a.find { |g| g["code"].as_s == "secret_in_url" }.not_nil!
      %w(code category host title severity hit_count affected affected_count evidence sample_flow_id remediation).each do |k|
        issue.as_h.has_key?(k).should be_true
      end
      issue["host"].as_s.should eq("acme.test")
      issue["category"].as_s.should eq("infoleak")
    end
  end

  it "filters by severity" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      res = call_json(tools, "probe_scan", %({"severity":"critical"}))
      codes = res["issues"].as_a.map { |g| g["code"].as_s }
      codes.should_not contain("secret_in_url") # it's High, below Critical
    end
  end

  it "rejects an active scan without write access (read-only)" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      r = tools.call("probe_scan", JSON.parse(%({"active":true})))
      r.is_error.should be_true
      r.text.should contain("read-only")
    end
  end

  it "passively scans even under --read-only (passive needs no write access)" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      res = call_json(tools, "probe_scan", "{}")
      res["issue_count"].as_i.should be > 0
    end
  end

  it "refuses an active scan when no scope is configured (SCOPE_BLOCKED, no network)" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      r = tools.call("probe_scan", JSON.parse(%({"active":true})))
      r.is_error.should be_true
      r.text.should contain("scope")
    end
  end

  it "accepts unsafe/aggressive params, inert (not echoed) under a passive scan" do
    with_store do |store|
      seed_secret_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      # active defaults false → the two knobs parse but do nothing and are not echoed.
      res = call_json(tools, "probe_scan", %({"unsafe":true,"aggressive":true}))
      res["active"].as_bool.should be_false
      res.as_h.has_key?("active_unsafe_methods").should be_false
      res.as_h.has_key?("active_aggressive").should be_false
      res["issue_count"].as_i.should be > 0 # passive scan still runs normally
    end
  end

  it "refuses an active scan with an excludes-only scope (no include rule would send anything)" do
    with_store do |store|
      seed_secret_flow(store)
      Gori::Scope.load(store).add("exclude", "host", "evil.test") # configured, but zero includes
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      r = tools.call("probe_scan", JSON.parse(%({"active":true})))
      r.is_error.should be_true # was: silently ran zero active probes and reported success
      r.text.should contain("include")
    end
  end
end

# Persist a probe finding the way the live Analyzer does, so triage has a row to act on.
private def seed_probe_issue(store, code = "secret_in_url", host = "acme.test",
                             severity = Gori::Store::Severity::High,
                             flow_id : Int64? = nil, repeater_id : Int64? = nil) : Gori::Store::ProbeIssue
  store.upsert_probe_issue(Gori::Probe::Detection.new(
    code: code, category: "infoleak", host: host, title: "token in URL",
    severity: severity, url: "https://#{host}/login", evidence: "token",
    flow_id: flow_id, repeater_id: repeater_id))
  store.probe_issues.find { |i| i.code == code && i.host == host }.not_nil!
end

describe "MCP probe triage tools" do
  it "lists persisted findings open-only by default, and all under include_closed" do
    with_store do |store|
      issue = seed_probe_issue(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      res = call_json(tools, "probe_issues", "{}")
      res["total"].as_i.should eq(1)
      row = res["issues"].as_a.first
      row["id"].as_i64.should eq(issue.id)
      row["status"].as_s.should eq("open")
      %w(id code category host title severity status hit_count sample_flow_id remediation).each do |k|
        row.as_h.has_key?(k).should be_true
      end

      call_json(tools, "probe_dismiss", %({"id":#{issue.id}}))["status"].as_s.should eq("false-positive")
      call_json(tools, "probe_issues", "{}")["total"].as_i.should eq(0) # gone from the default lens
      call_json(tools, "probe_issues", %({"include_closed":true}))["total"].as_i.should eq(1)
    end
  end

  it "toggles a single finding dismissed then back open" do
    with_store do |store|
      issue = seed_probe_issue(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      call_json(tools, "probe_dismiss", %({"id":#{issue.id}}))["status"].as_s.should eq("false-positive")
      call_json(tools, "probe_dismiss", %({"id":#{issue.id}}))["status"].as_s.should eq("open")
    end
  end

  it "bulk-dismisses by code and by host" do
    with_store do |store|
      seed_probe_issue(store, code: "secret_in_url", host: "a.test")
      seed_probe_issue(store, code: "secret_in_url", host: "b.test")
      seed_probe_issue(store, code: "other_code", host: "b.test")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      call_json(tools, "probe_dismiss", %({"code":"secret_in_url"}))["dismissed"].as_i.should eq(2)
      open_now = call_json(tools, "probe_issues", "{}")["issues"].as_a
      open_now.size.should eq(1)
      open_now.first["code"].as_s.should eq("other_code")

      call_json(tools, "probe_dismiss", %({"host":"b.test"}))["dismissed"].as_i.should eq(1)
      call_json(tools, "probe_issues", "{}")["total"].as_i.should eq(0)
    end
  end

  it "rejects zero or multiple dismiss selectors" do
    with_store do |store|
      seed_probe_issue(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      tools.call("probe_dismiss", JSON.parse("{}")).is_error.should be_true
      tools.call("probe_dismiss", JSON.parse(%({"id":1,"code":"x"}))).is_error.should be_true
    end
  end

  it "promotes a finding to an Issue exactly once" do
    with_store do |store|
      issue = seed_probe_issue(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      res = call_json(tools, "probe_promote", %({"id":#{issue.id}}))
      res["promoted"].as_bool.should be_true
      issue_id = res["issue_id"].as_i64
      created = store.get_issue(issue_id).not_nil!
      created.title.should eq(issue.title)
      created.severity.should eq(Gori::Store::Severity::High)
      created.host.should eq("acme.test")
      store.get_probe_issue(issue.id).not_nil!.status.confirmed?.should be_true

      # A second call must NOT mint a duplicate Issue.
      again = call_json(tools, "probe_promote", %({"id":#{issue.id}}))
      again["promoted"].as_bool.should be_false
      store.issues.size.should eq(1)
    end
  end

  it "carries Repeater-only evidence across a promotion as an entity link" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, false, true, nil, 0)
      issue = seed_probe_issue(store, repeater_id: rid)
      issue.sample_flow_id.should be_nil
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      issue_id = call_json(tools, "probe_promote", %({"id":#{issue.id}}))["issue_id"].as_i64
      links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
      links.any? { |l| l.ref_kind.repeater? && l.ref_id == rid }.should be_true
    end
  end

  it "deletes one finding and clears them all" do
    with_store do |store|
      a = seed_probe_issue(store, code: "secret_in_url", host: "a.test")
      seed_probe_issue(store, code: "secret_in_url", host: "b.test")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)

      call_json(tools, "probe_delete", %({"id":#{a.id}}))["deleted"].as_i.should eq(1)
      store.count_probe_issues.should eq(1)

      call_json(tools, "probe_delete", %({"all":true}))["deleted"].as_i.should eq(1)
      store.count_probe_issues.should eq(0)
    end
  end

  it "refuses triage under --read-only" do
    with_store do |store|
      issue = seed_probe_issue(store)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("probe_dismiss", JSON.parse(%({"id":#{issue.id}}))).is_error.should be_true
      ro.call("probe_promote", JSON.parse(%({"id":#{issue.id}}))).is_error.should be_true
      ro.call("probe_delete", JSON.parse(%({"id":#{issue.id}}))).is_error.should be_true
      # …but LISTING them stays available: triage state is read-only-safe.
      call_json(ro, "probe_issues", "{}")["total"].as_i.should eq(1)
    end
  end
end
