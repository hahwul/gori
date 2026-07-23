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
end
