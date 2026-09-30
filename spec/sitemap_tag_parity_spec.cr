require "./spec_helper"
require "json"

# One `tag:` query, three answers that must agree: the engine (`Sitemap.split_tag_terms` +
# `filter_by_tags!`, which the TUI Sitemap bar calls), `gori run sitemap -q`, and MCP
# `list_sitemap {"query"}`. The field used to live in `Tui::SitemapView` alone, so the CLI and
# MCP refused it as "unknown query field `tag:`" (AGENTS.md invariant 2: three surfaces, one
# engine layer).

module Gori::CLI::Run
  # The command's own query glue and tree build, minus the `abort`s around them.
  def self.tag_parity_tree_for_spec(store : Gori::Store, query : String) : Array(Gori::Sitemap::Node)
    ql, tags = sitemap_tree_query(query, false)
    hosts, _ = collect_sitemap(store, sitemap_filter(ql), Gori::Store::SITEMAP_MAX, false, false, false, tags: tags)
    hosts
  end
end

private def parity_seed(store : Gori::Store, method : String, target : String, scheme = "https", port = 443) : Nil
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: "acme.test", port: port,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
end

# {origin label, node path} of every endpoint left in a tree.
private def parity_tree_keys(hosts : Array(Gori::Sitemap::Node)) : Array({String, String})
  keys = [] of {String, String}
  hosts.each { |h| Gori::Sitemap.post_order(h) { |n| keys << {h.label, n.path} unless n.methods.empty? } }
  keys.uniq!.sort!
end

private def parity_engine(store : Gori::Store, query : String) : Array({String, String})
  terms = Gori::Sitemap.split_tag_terms(query)
  ql = terms.ql
  filter = ql ? Gori::QL.parse(ql) : Gori::QL::EMPTY
  hosts = Gori::Sitemap.build(store.sitemap_origin_entries(filter))
  Gori::Sitemap.stamp_tags!(hosts, store.sitemap_tags)
  Gori::Sitemap.filter_by_tags!(hosts, terms.positives, terms.negatives)
  parity_tree_keys(hosts)
end

private def parity_mcp(store : Gori::Store, query : String) : Array({String, String})
  r = tools_for(store).call("list_sitemap", JSON.parse({query: query, fold_query: false, limit: 5000}.to_json))
  fail "list_sitemap errored: #{r.text}" if r.is_error
  JSON.parse(r.text)["entries"].as_a.map do |e|
    origin = Gori::Sitemap::Origin.new(e["scheme"].as_s, e["host"].as_s, e["port"].as_i)
    {origin.label, Gori::Sitemap.node_path(e["target"].as_s)}
  end.uniq!.sort!
end

describe "sitemap tag: parity across engine, CLI and MCP" do
  queries = [
    "tag:auth",
    "tag:AUTH",
    "-tag:old",
    "NOT tag:old",
    "tag:auth tag:login",
    "tag:auth OR tag:admin",
    %(tag:"user list"),
    "tag:auth method:POST",
    "tag:auth -tag:old",
  ]

  it "keeps the same endpoints for every query on every surface" do
    with_store do |store|
      parity_seed(store, "GET", "/api")
      parity_seed(store, "GET", "/api/users")
      parity_seed(store, "GET", "/api/users/7")
      parity_seed(store, "POST", "/login")
      parity_seed(store, "GET", "/login")
      parity_seed(store, "GET", "/static/app.js")
      parity_seed(store, "GET", "/admin", "http", 8080)
      parity_seed(store, "GET", "/legacy/old.php")
      store.flush
      store.set_sitemap_tag("acme.test", "/api/users", "User list (auth)")
      store.set_sitemap_tag("acme.test", "/login", "auth login")
      store.set_sitemap_tag("acme.test", "/admin", "admin auth")
      store.set_sitemap_tag("acme.test", "/legacy", "old")

      queries.each do |q|
        engine = parity_engine(store, q)
        engine.should_not be_empty, "#{q.inspect} kept nothing — the fixture no longer exercises it"
        Gori::CLI::Run.unknown_query_field_error("sitemap", Gori::Sitemap.split_tag_terms(q).ql).should be_nil
        parity_tree_keys(Gori::CLI::Run.tag_parity_tree_for_spec(store, q)).should eq(engine), "CLI differs on #{q.inspect}"
        parity_mcp(store, q).should eq(engine), "MCP differs on #{q.inspect}"
      end
    end
  end

  it "keeps an untagged endpoint above a tagged one on every surface" do
    with_store do |store|
      parity_seed(store, "GET", "/api")
      parity_seed(store, "GET", "/api/users")
      parity_seed(store, "GET", "/other")
      store.flush
      store.set_sitemap_tag("acme.test", "/api/users", "idor")

      want = [{"https://acme.test", "/api"}, {"https://acme.test", "/api/users"}]
      parity_engine(store, "tag:idor").should eq(want)
      parity_tree_keys(Gori::CLI::Run.tag_parity_tree_for_spec(store, "tag:idor")).should eq(want)
      parity_mcp(store, "tag:idor").should eq(want)
    end
  end
end
