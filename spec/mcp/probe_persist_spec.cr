require "../spec_helper"
require "../support/mcp_harness"
require "../support/probe_harness"

# #1392: `probe_scan` only REPORTED, and persisted findings came from the TUI's live scanner
# alone — so on a headless project `probe_scan` found issues and `probe_issues` listed none,
# leaving promote/dismiss nothing to act on. `persist: true` writes the findings through the
# same merge the Analyzer uses. And `@recon`, which carried the triage tools, now carries the
# passive scan that fills them.

# One https page with no security headers: several passive findings, every time.
private def seed_findings(store) : Int64
  probe_capture_flow(store, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
    body: "<html><body>hi</body></html>").row.id
end

private def recon(store, spec = "@recon") : Gori::MCP::Tools
  filter = Gori::MCP::ToolFilter.parse(spec, Gori::MCP::Tools::TOOL_NAMES,
    Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, tool_filter: filter)
end

private def probe_scan_schema(tools : Gori::MCP::Tools) : JSON::Any
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.find { |t| t["name"].as_s == "probe_scan" }.not_nil!
end

describe "MCP probe_scan persist" do
  it "reports without writing by default" do
    with_store do |store|
      seed_findings(store)
      res = mcp_ok_json(tools_for(store), "probe_scan", "{}")
      res["issue_count"].as_i.should be > 0
      res.as_h.has_key?("persisted").should be_false
      store.count_probe_issues.should eq(0)
    end
  end

  it "writes the findings probe_issues then lists, one row per (code, host)" do
    with_store do |store|
      seed_findings(store)
      tools = tools_for(store)
      res = mcp_ok_json(tools, "probe_scan", %({"persist":true}))
      res["persisted"].as_bool.should be_true
      res["persisted_detections"].as_i.should be > 0
      listed = mcp_ok_json(tools, "probe_issues", "{}")
      listed["total"].as_i.should eq(res["issue_count"].as_i)
      scanned = res["issues"].as_a.map { |i| {i["code"].as_s, i["host"].as_s} }.to_set
      listed["issues"].as_a.map { |i| {i["code"].as_s, i["host"].as_s} }.to_set.should eq(scanned)
    end
  end

  it "merges a rescan instead of duplicating it, and leaves a dismissed finding dismissed" do
    with_store do |store|
      seed_findings(store)
      tools = tools_for(store)
      mcp_ok_json(tools, "probe_scan", %({"persist":true}))
      before = store.probe_issues
      first = before.first
      mcp_ok_json(tools, "probe_dismiss", %({"id":#{first.id}}))["status"].as_s.should_not eq("open")

      mcp_ok_json(tools, "probe_scan", %({"persist":true}))
      after = store.probe_issues
      after.size.should eq(before.size)
      again = after.find(&.id.==(first.id)).not_nil!
      again.status.should_not eq(Gori::Store::Status::Open)
      # hit_count counts observations — the schema says a rescan raises it.
      again.hit_count.should be > first.hit_count
    end
  end

  it "is refused under --read-only before anything is scanned or written" do
    with_store do |store|
      seed_findings(store)
      r = tools_for(store, allow_actions: false).call("probe_scan", JSON.parse(%({"persist":true})))
      r.is_error.should be_true
      r.error_code.should eq("TOOL_DISABLED")
      r.field.should eq("persist")
      store.count_probe_issues.should eq(0)
    end
  end

  it "writes nothing from a scan the caller cancelled" do
    with_store do |store|
      seed_findings(store)
      r = tools_for(store).call("probe_scan", JSON.parse(%({"persist":true})), cancelled: -> { true })
      store.count_probe_issues.should eq(0)
      # Said as a skip, not as a busy store an agent would retry against.
      res = JSON.parse(r.text)
      res["persisted"].as_bool.should be_false
      res["persist_skipped"].as_s.should contain("stopped")
      res.as_h.has_key?("persist_error").should be_false
    end
  end

  it "logs a persisting scan as an agent action, and a report-only one not" do
    with_store do |store|
      seed_findings(store)
      tools = tools_for(store)
      mcp_ok_json(tools, "probe_scan", "{}")
      store.events_after(0_i64, 50).count { |e| e.kind == "agent_action" }.should eq(0)
      mcp_ok_json(tools, "probe_scan", %({"persist":true}))
      store.events_after(0_i64, 50).count { |e| e.kind == "agent_action" && e.payload == "probe_scan" }.should eq(1)
    end
  end
end

describe "MCP --tools=@recon probe_scan" do
  it "serves the scan passive-only: no active arguments, no active sentence" do
    with_store do |store|
      tool = probe_scan_schema(recon(store))
      props = tool["inputSchema"]["properties"].as_h
      Gori::MCP::ToolFilter::PROBE_SCAN_ACTIVE_ARGS.each { |arg| props.has_key?(arg).should be_false }
      props.has_key?("persist").should be_true
      tool["description"].as_s.should contain("PASSIVE-only")
      tool["description"].as_s.should_not contain("active:true")
    end
  end

  it "refuses an active argument by name, and lets a false one through" do
    with_store do |store|
      seed_findings(store)
      tools = recon(store)
      r = tools.call("probe_scan", JSON.parse(%({"active":true})))
      r.error_code.should eq("TOOL_DISABLED")
      r.field.should eq("active")
      r.text.should contain("@recon")
      mcp_ok_json(tools, "probe_scan", %({"active":false}))["active"].as_bool.should be_false
    end
  end

  it "serves the scan whole once the spec names it" do
    with_store do |store|
      ["@recon,probe_scan", "probe_scan,@recon", "@recon,probe_*"].each do |spec|
        props = probe_scan_schema(recon(store, spec))["inputSchema"]["properties"].as_h
        props.has_key?("active").should be_true, "--tools=#{spec} still withholds active"
      end
    end
  end

  it "withholds only arguments probe_scan actually declares" do
    with_store do |store|
      props = probe_scan_schema(tools_for(store))["inputSchema"]["properties"].as_h
      Gori::MCP::ToolFilter::PROBE_SCAN_ACTIVE_ARGS.each { |arg| props.has_key?(arg).should be_true }
    end
  end
end
