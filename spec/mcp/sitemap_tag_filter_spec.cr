require "../spec_helper"

# `list_sitemap`'s `tag:` field (`Sitemap.split_tag_terms`): accepted, paged AFTER the filter,
# and on the legacy `collapse_transport` rows too. Parity with the TUI and the CLI is pinned in
# `spec/sitemap_tag_parity_spec.cr`.

private def tag_seed(store, target : String) : Nil
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "acme.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def tag_call(tools : Gori::MCP::Tools, args) : Gori::MCP::Tools::Result
  tools.call("list_sitemap", JSON.parse(args.to_json))
end

private def tag_targets(r : Gori::MCP::Tools::Result) : Array(String)
  fail "list_sitemap errored: #{r.text}" if r.is_error
  JSON.parse(r.text)["entries"].as_a.map(&.["target"].as_s)
end

describe "MCP list_sitemap tag: filter" do
  it "accepts tag: instead of refusing it as an unknown query field" do
    with_store do |store|
      tag_seed(store, "/login")
      tag_seed(store, "/static/app.js")
      store.set_sitemap_tag("acme.test", "/login", "Auth")
      tools = tools_for(store)

      tag_targets(tag_call(tools, {query: "tag:auth"})).should eq(["/login"])
      tag_targets(tag_call(tools, {query: "-tag:auth"})).should eq(["/static/app.js"])
      # A tag-only query leaves no QL half, and `OR` alone is not "every term was invalid".
      tag_targets(tag_call(tools, {query: "tag:auth OR tag:auth", strict: true})).should eq(["/login"])
    end
  end

  it "still refuses a misspelled field next to a tag term" do
    with_store do |store|
      tag_seed(store, "/login")
      r = tag_call(tools_for(store), {query: "tag:auth methd:GET"})
      r.is_error.should be_true
      r.text.should contain("methd")
    end
  end

  it "pages the filtered rows, so has_more counts only what the filter kept" do
    with_store do |store|
      %w[/a /b /c /d /e].each { |t| tag_seed(store, t) }
      %w[/b /d].each { |t| store.set_sitemap_tag("acme.test", t, "keep") }
      tools = tools_for(store)

      first = tag_call(tools, {query: "tag:keep", limit: 1})
      tag_targets(first).should eq(["/b"])
      JSON.parse(first.text)["has_more"].as_bool.should be_true
      second = tag_call(tools, {query: "tag:keep", limit: 1, offset: 1})
      tag_targets(second).should eq(["/d"])
      JSON.parse(second.text)["has_more"].as_bool.should be_false
      tag_targets(tag_call(tools, {query: "tag:keep", limit: 1, offset: 2})).should be_empty
    end
  end

  it "filters the collapse_transport rows as well" do
    with_store do |store|
      tag_seed(store, "/login")
      tag_seed(store, "/static/app.js")
      store.set_sitemap_tag("acme.test", "/static/app.js", "noise")

      tag_targets(tag_call(tools_for(store), {query: "-tag:noise", collapse_transport: true})).should eq(["/login"])
    end
  end
end
