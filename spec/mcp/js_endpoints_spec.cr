require "../spec_helper"
require "json"

# MCP `scan_js_endpoints` / `list_js_endpoints` / `list_sitemap include_unrequested` — the agent
# surface of `Gori::JsRefs` (spec/js_refs_spec.cr owns the engine). Pinned here: the scan is a
# gated write that sends nothing, the listing pages and says why it is empty, and the sitemap's
# unrequested block stays out of the traffic entries.

private CLOCK = [1_700_000_000_000_000_i64]

private def je_flow(store : Gori::Store, target : String, body : String, *, host = "shop.test",
                    ctype = "application/javascript") : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: #{ctype}\r\n\r\n".to_slice,
    body: body.to_slice, content_type: ctype))
  store.flush
  id
end

private def je(tools : Gori::MCP::Tools, name : String, args = "{}") : JSON::Any
  res = tools.call(name, JSON.parse(args))
  raise "#{name} failed: #{res.text}" if res.is_error
  JSON.parse(res.text)
end

describe "MCP scan_js_endpoints / list_js_endpoints" do
  it "scans, then lists the unrequested references with provenance" do
    with_store do |store|
      je_flow(store, "/api/users", "[]", ctype: "application/json")
      id = je_flow(store, "/app.js", %(fetch("/api/users");\nfetch(`/api/items/${i}`)))
      tools = tools_for(store)
      empty = je(tools, "list_js_endpoints")
      empty["total"].should eq(0)
      empty["note"].as_s.should contain("scan_js_endpoints")
      scan = je(tools, "scan_js_endpoints")
      scan["flows_scanned"].should eq(1)
      scan["new_endpoints"].should eq(2)
      scan["truncated"].should be_false
      out = je(tools, "list_js_endpoints")
      out["total"].should eq(1)
      row = out["endpoints"][0]
      row["path"].should eq("/api/items/{expr}")
      row["templated"].should be_true
      row["requested"].should be_false
      row["flow_id"].should eq(id)
      row["line"].should eq(2)
      row["source_url"].should eq("https://shop.test/app.js")
      je(tools, "list_js_endpoints", %({"include_requested":true}))["total"].should eq(2)
    end
  end

  it "is incremental and pages with a clamp report" do
    with_store do |store|
      je_flow(store, "/a.js", (1..5).map { |i| %(fetch("/api/p#{i}");) }.join)
      tools = tools_for(store)
      je(tools, "scan_js_endpoints")
      je(tools, "scan_js_endpoints")["flows_scanned"].should eq(0)
      page = je(tools, "list_js_endpoints", %({"limit":2,"offset":2}))
      page["returned"].should eq(2)
      page["has_more"].should be_true
      page["endpoints"][0]["path"].should eq("/api/p3")
      clamped = je(tools, "list_js_endpoints", %({"limit":0}))
      clamped["pagination_warning"]?.should_not be_nil
    end
  end

  it "refuses the scan under --read-only and does not advertise it" do
    with_store do |store|
      je_flow(store, "/a.js", %(fetch("/api/x")))
      ro = tools_for(store, allow_actions: false)
      res = ro.call("scan_js_endpoints", JSON.parse("{}"))
      res.is_error.should be_true
      res.text.should contain("read-only")
      names = JSON.parse(JSON.build { |j| ro.list(j) }).as_a.map(&.["name"].as_s)
      names.should contain("list_js_endpoints")
      names.should_not contain("scan_js_endpoints")
    end
  end

  it "hides a never-captured host, says so, and lists it with all_hosts" do
    with_store do |store|
      je_flow(store, "/a.js", %(var ns="http://www.w3.org/2000/svg";))
      tools = tools_for(store)
      je(tools, "scan_js_endpoints")
      out = je(tools, "list_js_endpoints")
      out["total"].should eq(0)
      out["hidden_hosts"].should eq(1)
      out["note"].as_s.should contain("all_hosts")
      je(tools, "list_js_endpoints", %({"all_hosts":true}))["endpoints"][0]["host"].should eq("www.w3.org")
    end
  end

  it "answers in_scope with no scope configured with a note, not everything" do
    with_store do |store|
      je_flow(store, "/a.js", %(fetch("/api/x")))
      tools = tools_for(store)
      je(tools, "scan_js_endpoints")
      out = je(tools, "list_js_endpoints", %({"in_scope":true}))
      out["total"].should eq(0)
      out["note"].as_s.should contain("no scope rules")
      tools.call("scan_js_endpoints", JSON.parse(%({"in_scope":true}))).is_error.should be_true
    end
  end
end

describe "MCP list_sitemap include_unrequested" do
  it "adds the unrequested block beside the traffic entries, never inside them" do
    with_store do |store|
      je_flow(store, "/app.js", %(fetch("/api/hidden")))
      tools = tools_for(store)
      je(tools, "scan_js_endpoints")
      plain = je(tools, "list_sitemap")
      plain["unrequested"]?.should be_nil
      out = je(tools, "list_sitemap", %({"include_unrequested":true}))
      out["entries"].as_a.map(&.["target"].as_s).should eq(["/app.js"])
      out["unrequested"].as_a.map(&.["target"].as_s).should eq(["/api/hidden"])
      out["unrequested_total"].should eq(1)
      out["unrequested_truncated"].should be_false
    end
  end

  it "says a tag on a referenced-only node shows on that node, not that it is lost" do
    with_store do |store|
      je_flow(store, "/app.js", %(fetch("/api/hidden")))
      tools = tools_for(store)
      je(tools, "scan_js_endpoints")
      out = je(tools, "set_sitemap_tag", %({"host":"shop.test","path":"/api/hidden","tag":"look"}))
      out["matches_endpoint"].should be_false
      out["warning"].as_s.should contain("JavaScript-referenced node")
    end
  end
end
