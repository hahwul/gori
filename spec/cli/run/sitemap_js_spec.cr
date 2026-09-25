require "../../spec_helper"
require "json"

# `gori run sitemap js` and `gori run sitemap --js-refs` — the CLI glue over `Gori::JsRefs`
# (the engine is spec/js_refs_spec.cr). Pinned here: what the builders print, that captured
# bytes cannot reach the terminal raw, and that `js` is a reserved verb on the tree.

private alias SJ = Gori::JsRefs

private def sj_ep(path : String, *, host = "shop.test", requested : Bool? = false, flows = 1,
                  comment = false, templated = false, base = SJ::Base::Page,
                  literal : String? = nil) : SJ::Endpoint
  SJ::Endpoint.new("https", host, 443, path, path, flows, requested, comment, templated, base,
    7_i64, 120, 3, literal || path, "https://shop.test/app.js")
end

describe "gori run sitemap js — text" do
  it "groups by host with where each reference was read" do
    out = Gori::CLI::Run.sitemap_js_text([
      sj_ep("/api/admin", flows: 2),
      sj_ep("/api/users/{expr}", templated: true, base: SJ::Base::Guessed, literal: "/api/users/{expr}"),
      sj_ep("/v1/me", host: "api.shop.test", requested: true, comment: true),
    ])
    lines = out.lines
    lines[0].should eq("shop.test")
    lines[1].should match(/^  \/api\/admin\s+2 flows  #7:3  "\/api\/admin"$/)
    lines[2].should match(/\[templated, base: guessed\]$/)
    lines[4].should eq("api.shop.test")
    lines[5].should match(/requested .* \[comment\]$/)
  end

  it "neutralises control bytes in a literal and a host" do
    out = Gori::CLI::Run.sitemap_js_text([sj_ep("/a", host: "h\e[31m.test", literal: "/a\e]0;x\a")])
    out.should_not contain('\e')
    out.should_not contain('\a')
  end
end

describe "gori run sitemap js — json" do
  it "emits one object per endpoint with provenance and flags" do
    arr = JSON.parse(Gori::CLI::Run.sitemap_js_json([sj_ep("/api/x", templated: true)])).as_a
    arr.size.should eq(1)
    o = arr[0]
    o["url"].should eq("https://shop.test/api/x")
    o["requested"].should be_false
    o["templated"].should be_true
    o["base"].should eq("page")
    o["flow_id"].should eq(7)
    o["offset"].should eq(120)
    o["line"].should eq(3)
    o["source_url"].should eq("https://shop.test/app.js")
  end

  it "says requested is unknown as null" do
    JSON.parse(Gori::CLI::Run.sitemap_js_json([sj_ep("/x", requested: nil)])).as_a[0]["requested"].raw.should be_nil
  end
end

describe "gori run sitemap js — notes" do
  it "names an unscanned project, hidden hosts and an unverifiable traffic check" do
    notes = Gori::CLI::Run.sitemap_js_notes(SJ::ListReport.new([] of SJ::Endpoint, 3, true, 0, false))
    notes.any?(&.includes?("pass --scan")).should be_true
    notes.any?(&.includes?("3 reference(s) to hosts gori never captured")).should be_true
    notes.any?(&.includes?("could not be checked against traffic")).should be_true
    Gori::CLI::Run.sitemap_js_notes(SJ::ListReport.new([] of SJ::Endpoint, 0, false, 4, false)).should be_empty
  end

  it "summarises a scan with every cap that cut it" do
    r = SJ::ScanReport.new(3, 10, 4, 1, 1, 2, 0, false)
    s = Gori::CLI::Run.sitemap_js_scan_summary(r)
    s.should contain("scanned 3 responses")
    s.should contain("4 new endpoints")
    s.should contain("1 body read only to 2 MiB")
    s.should contain("2 refused (CR/LF)")
  end
end

describe "gori run sitemap --js-refs — tree output" do
  it "marks a referenced node and an unrequested one, and keeps the host's path count traffic-only" do
    hosts = Gori::Sitemap.build([{"shop.test", "GET", "/api/users"}])
    Gori::Sitemap.attach_js_refs!(hosts, [
      Gori::Store::JsRefNode.new("https", "shop.test", 443, "/api/users", 2),
      Gori::Store::JsRefNode.new("https", "shop.test", 443, "/api/admin", 1),
    ]) { false }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    text = Gori::CLI::Output.sitemap_text(hosts)
    text.should contain("shop.test  (1 path)")
    text.should contain("users  [GET]  (js: 2 flows)")
    text.should contain("admin  (js: 1 flow, never requested)")
    json = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    api = json[0]["children"][0]
    admin = api["children"].as_a.find! { |c| c["label"] == "admin" }
    admin["unrequested"].should be_true
    admin["js_refs"].should eq(1)
    admin["methods"]?.should be_nil
    # The flat listing stays traffic-only: an unrequested path carries no method.
    Gori::CLI::Output.sitemap_paths(hosts).should_not contain("admin")
  end
end

describe "gori run sitemap — the js verb" do
  # Same reason as the params verb: `sitemap --project x js` must not become a QL term.
  it "is on the tree's reserved-verb list" do
    src = File.read(File.join(__DIR__, "../../../src/gori/cli/run/sitemap.cr"))
    src.should match(/reserved_query_verb_error\(positional, "sitemap", \[[^\]]*"js"[^\]]*\]/)
  end
end
