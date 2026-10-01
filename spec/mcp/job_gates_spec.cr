require "../spec_helper"
require "../support/mcp_harness"

# The job tools' gates: the scope check reads the path the template sends, and a request
# budget the caller wrote as 0 or less is no budget at all, not an unbounded one.

describe "MCP job tools: the scope gate reads the template's path" do
  it "lets fuzz_start and mine_start through a path-scoped include, and stops a path exclude" do
    with_store do |store|
      store.add_scope_rule("include", "string", "/zzapi/")
      t = tools_for(store)
      fuzz = t.call("fuzz_start", {
        "template" => "GET /zzapi/§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
        "payloads" => %([{"list":["a"]}]), "max_requests" => 1,
      }.to_json.try { |a| JSON.parse(a) })
      fuzz.is_error.should be_false
      mine = t.call("mine_start", {
        "template" => "GET /zzapi/x?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
        "max_requests" => 1,
      }.to_json.try { |a| JSON.parse(a) })
      mine.is_error.should be_false
      [fuzz, mine].each do |r|
        next if r.is_error
        id = JSON.parse(r.text)["job_id"].as_s
        t.call(id.starts_with?("fz") ? "fuzz_stop" : "mine_stop", JSON.parse(%({"job_id":#{id.to_json}})))
      end
      store.add_scope_rule("include", "host", "127.0.0.1")
      store.add_scope_rule("exclude", "string", "/zzadmin/")
      blocked = t.call("fuzz_start", {
        "template" => "GET /zzadmin/§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
        "payloads" => %([{"list":["a"]}]), "max_requests" => 1,
      }.to_json.try { |a| JSON.parse(a) })
      blocked.error_code.should eq("SCOPE_BLOCKED")
    end
  end
end

describe "MCP job tools: request budget" do
  it "ignores a non-positive max_requests instead of running unbounded" do
    with_store do |store|
      t = tools_for(store)
      start = mcp_ok_json(t, "discover_start",
        {"url" => "http://127.0.0.1:1/", "max_requests" => 0, "bruteforce" => false, "keep_alive" => false,
         "retries" => 0, "timeout_ms" => 300, "allow_unscoped" => true}.to_json)
      st = mcp_ok_json(t, "discover_status", %({"job_id":#{start["job_id"].to_json}}))
      st["audit"]["max_requests"].as_i64.should eq(Gori::MCP::Tools::DISCOVER_MAX_REQUESTS)
      t.call("discover_stop", JSON.parse(%({"job_id":#{start["job_id"].to_json}})))
    end
  end
end
