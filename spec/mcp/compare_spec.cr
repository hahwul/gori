require "../spec_helper"
require "json"

# MCP `compare_flows` argument errors name the value the agent sent (#1786), the way
# sibling tools (`import`'s kind, `intercept`'s direction) already do. The diff itself is
# pinned in spec/mcp/repeater_tools_spec.cr.

private def cmp_flow(store : Gori::Store, created_at : Int64) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: created_at, scheme: "https", host: "a.test", port: 443,
    method: "GET", target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "same".to_slice))
  id
end

private def cmp_call(store : Gori::Store, extra : String)
  a = cmp_flow(store, 1_i64)
  b = cmp_flow(store, 2_i64)
  tools_for(store).call("compare_flows", JSON.parse(%({"flow_id_a":#{a},"flow_id_b":#{b}#{extra}})))
end

describe "MCP compare_flows argument errors" do
  it "names a bad 'pane' value" do
    with_store do |store|
      res = cmp_call(store, %(,"pane":"reponse"))
      res.is_error.should be_true
      res.text.should contain(%(invalid 'pane' "reponse"))
    end
  end

  it "names a negative 'context' value" do
    with_store do |store|
      res = cmp_call(store, %(,"context":-2))
      res.is_error.should be_true
      res.text.should contain("invalid 'context' -2 (expected >= 0)")
    end
  end

  it "still accepts a valid pane and context" do
    with_store do |store|
      res = cmp_call(store, %(,"pane":"Request","context":0))
      res.is_error.should be_false
      JSON.parse(res.text)["pane"].as_s.should eq("request")
    end
  end
end
