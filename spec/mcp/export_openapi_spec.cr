require "../spec_helper"
require "json"
require "yaml"

# MCP `export_openapi` — the agent surface of `Gori::Export::OpenApi` (spec/export/openapi_spec.cr
# owns the inference). Pinned here: the inline document in both formats, the two caps and
# `truncated`, the in-scope refusal, and that credentials and example values stay out by default.

private CLOCK = [1_700_000_000_000_000_i64]

private def eo_flow(store : Gori::Store, target : String, *, host = "api.test", req_headers = "") : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, content_type: "application/json",
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice, body: %({"ok":true}).to_slice))
  id
end

private def eo(tools : Gori::MCP::Tools, args : String) : JSON::Any
  res = tools.call("export_openapi", JSON.parse(args))
  raise "export_openapi failed: #{res.text}" if res.is_error
  JSON.parse(res.text)
end

describe "MCP export_openapi" do
  it "returns the document inline, as an object or as YAML" do
    with_store do |store|
      eo_flow(store, "/users/1?fields=name")
      eo_flow(store, "/users/2?fields=id")
      out = eo(tools_for(store), "{}")
      out["format"].should eq("json")
      doc = out["document"]
      doc["openapi"].should eq("3.0.3")
      doc["paths"]["/users/{userId}"]["get"]["parameters"][1]["name"].should eq("fields")
      {out["paths"], out["operations"], out["flows_read"]}.should eq({1, 1, 2})
      out["truncated"].should be_false
      out["hosts"].should eq(["api.test"])

      yaml = eo(tools_for(store), %({"format":"yaml"}))
      YAML.parse(yaml["document"].as_s)["paths"]["/users/{userId}"]["get"]["operationId"].should eq("getUsersByUserId")
    end
  end

  it "keeps credential values out, and examples off, by default" do
    with_store do |store|
      eo_flow(store, "/me?token=t0ps3cret", req_headers: "Authorization: Bearer b3arer\r\nCookie: sid=c00kie\r\n")
      out = eo(tools_for(store), "{}")
      {"t0ps3cret", "b3arer", "c00kie"}.each { |s| out.to_json.should_not contain(s) }
      out.to_json.should_not contain(%("example"))
      out["document"]["components"]["securitySchemes"].as_h.keys.should eq(["bearerAuth", "cookie.sid"])
      out["examples_redacted"]?.should be_nil
    end
  end

  it "redacts examples when asked for them, and refuses a profile without examples" do
    with_store do |store|
      eo_flow(store, "/me?token=t0ps3cret&lang=en")
      tools = tools_for(store)
      out = eo(tools, %({"examples":true}))
      out.to_json.should_not contain("t0ps3cret")
      out.to_json.should contain(%("example":"en"))
      out["examples_redacted"].should eq(1)

      bad = tools.call("export_openapi", JSON.parse(%({"redact":"default"})))
      bad.is_error.should be_true
      bad.error_code.should eq("INVALID_ARGUMENT")
      unknown = tools.call("export_openapi", JSON.parse(%({"examples":true,"redact":"nope"})))
      unknown.is_error.should be_true
      unknown.text.should contain("no redaction profile named")
    end
  end

  it "caps operations and bytes, and says so" do
    with_store do |store|
      %w[/a /b /c /d].each { |p| eo_flow(store, p) }
      tools = tools_for(store)
      capped = eo(tools, %({"max_endpoints":2}))
      capped["operations"].should eq(2)
      capped["truncated"].should be_true
      capped["notes"].as_a.map(&.as_s).join.should contain("left out (max endpoints)")

      full = eo(tools, "{}")["document"].to_json.bytesize
      small = eo(tools, %({"max_bytes":#{full - 10}}))
      small["paths"].should eq(3)
      small["truncated"].should be_true
      small["notes"].as_a.map(&.as_s).join.should contain("byte cap")
    end
  end

  it "counts skipped flows by reason" do
    with_store do |store|
      eo_flow(store, "/ok")
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_700_000_100_000_000_i64, scheme: "https", host: "api.test", port: 443,
        method: "GET", target: "/pending", http_version: "HTTP/1.1",
        head: "GET /pending HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      id.should be > 0
      eo(tools_for(store), "{}")["skipped"].should eq(JSON.parse(%({"incomplete":1})))
    end
  end

  it "refuses in_scope with no scope configured, and narrows when one is" do
    with_store do |store|
      eo_flow(store, "/x", host: "in.test")
      eo_flow(store, "/y", host: "out.test")
      tools = tools_for(store)
      none = tools.call("export_openapi", JSON.parse(%({"in_scope":true})))
      none.is_error.should be_true
      none.error_code.should eq("INVALID_ARGUMENT")
      store.add_scope_rule("include", "host", "in.test")
      eo(tools, %({"in_scope":true}))["document"]["paths"].as_h.keys.should eq(["/x"])
    end
  end

  it "rejects an unknown format" do
    with_store do |store|
      res = tools_for(store).call("export_openapi", JSON.parse(%({"format":"xml"})))
      res.is_error.should be_true
      res.error_code.should eq("INVALID_ARGUMENT")
    end
  end
end
