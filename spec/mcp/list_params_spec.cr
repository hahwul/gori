require "../spec_helper"
require "json"

# MCP `list_params` — the agent surface of `Gori::ParamInventory` (spec/param_inventory_spec.cr
# owns the inventory). Pinned here: pagination and its clamp report, the in-scope lens, the
# location filter, and redaction by default (an agent transcript leaks).

private CLOCK = [1_700_000_000_000_000_i64]

private def lp_flow(store : Gori::Store, target : String, *, host = "shop.test", req_headers = "",
                    resp_body = "") : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: resp_body.to_slice))
  id
end

private def lp(tools : Gori::MCP::Tools, args : String) : JSON::Any
  res = tools.call("list_params", JSON.parse(args))
  raise "list_params failed: #{res.text}" if res.is_error
  JSON.parse(res.text)
end

describe "MCP list_params" do
  it "lists the inventory with reflected + flow ids" do
    with_store do |store|
      id = lp_flow(store, "/search?q=needle", resp_body: "found needle")
      out = lp(tools_for(store), "{}")
      out["total"].should eq(1)
      out["flows_scanned"].should eq(1)
      out["truncated"].should be_false
      row = out["params"][0]
      {row["host"], row["path"], row["location"], row["name"]}.should eq({"shop.test", "/search", "query", "q"})
      row["reflected"].should be_true
      row["reflected_flow_id"].should eq(id)
      row["samples"].should eq(["needle"])
    end
  end

  it "redacts credential values unless include_sensitive" do
    with_store do |store|
      lp_flow(store, "/a?token=t0ps3cret", req_headers: "Cookie: sid=abc123\r\n")
      tools = tools_for(store)
      out = lp(tools, "{}")
      out["sensitive_values_redacted"].should be_true
      out.to_json.should_not contain("t0ps3cret")
      out.to_json.should_not contain("abc123")
      open = lp(tools, %({"include_sensitive":true}))
      open.to_json.should contain("t0ps3cret")
      open.to_json.should contain("abc123")
    end
  end

  it "pages with limit/offset and reports a clamped limit" do
    with_store do |store|
      lp_flow(store, "/a?a=1&b=2&c=3")
      tools = tools_for(store)
      page = lp(tools, %({"limit":2,"offset":1}))
      page["returned"].should eq(2)
      page["total"].should eq(3)
      page["has_more"].should be_false
      page["params"].as_a.map(&.["name"]).should eq(["b", "c"])
      big = lp(tools, %({"limit":999999}))
      big["limit"].should eq(2000)
      big["requested_limit"].should eq(999999)
    end
  end

  it "narrows by location (array or comma list) and refuses an unknown one" do
    with_store do |store|
      lp_flow(store, "/a?q=1", req_headers: "X-Tenant: acme\r\nCookie: c=1\r\n")
      tools = tools_for(store)
      lp(tools, %({"location":["headers"]}))["params"].as_a.map(&.["name"]).should eq(["x-tenant"])
      lp(tools, %({"location":"query,cookies"}))["params"].as_a.map(&.["name"]).should eq(["q", "c"])
      bad = tools.call("list_params", JSON.parse(%({"location":"body-ish"})))
      bad.is_error.should be_true
      bad.error_code.should eq("INVALID_ARGUMENT")
    end
  end

  it "answers in_scope with a note when no scope is configured, and narrows when one is" do
    with_store do |store|
      lp_flow(store, "/a?x=1", host: "in.test")
      lp_flow(store, "/b?y=1", host: "out.test")
      tools = tools_for(store)
      none = lp(tools, %({"in_scope":true}))
      none["total"].should eq(0)
      none["note"].as_s.should contain("no scope rules")
      store.add_scope_rule("include", "host", "in.test")
      lp(tools, %({"in_scope":true}))["params"].as_a.map(&.["name"]).should eq(["x"])
    end
  end

  it "applies the QL query and exact host" do
    with_store do |store|
      lp_flow(store, "/a?x=1", host: "api.test")
      lp_flow(store, "/b?y=1", host: "sub.api.test")
      tools = tools_for(store)
      lp(tools, %({"host":"api.test"}))["params"].as_a.map(&.["name"]).should eq(["x"])
      lp(tools, %({"query":"path:/b"}))["params"].as_a.map(&.["name"]).should eq(["y"])
    end
  end
end
