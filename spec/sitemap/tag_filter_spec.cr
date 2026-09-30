require "../spec_helper"

# `Sitemap.split_tag_terms` / `filter_by_tags!` / `select_by_tags` — the `tag:` field every
# sitemap surface reads a query through. It used to live in `Tui::SitemapView`, so `gori run
# sitemap` and MCP `list_sitemap` refused `tag:` as an unknown QL field.

private def origin_entry(target : String, host = "acme.test", method = "GET") : Gori::Store::SitemapOriginEntry
  Gori::Store::SitemapOriginEntry.new("https", host, 443, method, target)
end

# Every endpoint (a node carrying a method) left in the tree, as its path.
private def endpoint_paths(hosts : Array(Gori::Sitemap::Node)) : Array(String)
  paths = [] of String
  hosts.each { |h| Gori::Sitemap.post_order(h) { |n| paths << n.path unless n.methods.empty? } }
  paths.sort
end

private def filtered(targets : Array(String), tags : Hash({String, String}, String), query : String) : Array(String)
  hosts = Gori::Sitemap.build(targets.map { |t| origin_entry(t) })
  Gori::Sitemap.stamp_tags!(hosts, tags)
  terms = Gori::Sitemap.split_tag_terms(query)
  Gori::Sitemap.filter_by_tags!(hosts, terms.positives, terms.negatives)
  endpoint_paths(hosts)
end

describe "Gori::Sitemap.split_tag_terms" do
  it "cuts tag: and -tag: terms out, lowercased, and leaves the QL residual" do
    terms = Gori::Sitemap.split_tag_terms("tag:Auth host:acme.test -tag:OLD")
    terms.positives.should eq(["auth"])
    terms.negatives.should eq(["old"])
    terms.residual.should eq("host:acme.test")
    terms.ql.should eq("host:acme.test")
    terms.filtering?.should be_true
  end

  it "reads NOT tag:x as -tag:x and keeps a quoted value whole" do
    terms = Gori::Sitemap.split_tag_terms(%(NOT tag:done tag:"my memo"))
    terms.negatives.should eq(["done"])
    terms.positives.should eq(["my memo"])
    terms.ql.should be_nil
  end

  it "leaves a half-typed tag: in the residual" do
    terms = Gori::Sitemap.split_tag_terms("tag:")
    terms.filtering?.should be_false
    terms.residual.should eq("tag:")
  end

  it "answers no QL half when cutting the tags left only an operator" do
    terms = Gori::Sitemap.split_tag_terms("tag:a OR tag:b")
    terms.residual.strip.should eq("OR")
    terms.ql.should be_nil
    terms.positives.should eq(["a", "b"])
  end
end

describe "Gori::Sitemap.filter_by_tags!" do
  targets = ["/api", "/api/users", "/api/users/7", "/static/app.js", "/login"]

  it "keeps a tagged folder's subtree and the path to it, case-insensitively by substring" do
    tags = { {"acme.test", "/api/users"} => "Payment flow" }
    filtered(targets, tags, "tag:PAY").should eq(["/api", "/api/users", "/api/users/7"])
  end

  it "needs ONE node's tag to carry every positive keyword" do
    tags = { {"acme.test", "/api"} => "auth", {"acme.test", "/login"} => "auth login" }
    filtered(targets, tags, "tag:auth tag:login").should eq(["/login"])
  end

  it "drops a negative match's whole subtree" do
    tags = { {"acme.test", "/api/users"} => "done" }
    filtered(targets, tags, "-tag:done").should eq(["/api", "/login", "/static/app.js"])
  end

  it "keys a tag on the bare host, so it matches under every origin of that host" do
    hosts = Gori::Sitemap.build([
      Gori::Store::SitemapOriginEntry.new("https", "acme.test", 443, "GET", "/admin"),
      Gori::Store::SitemapOriginEntry.new("http", "acme.test", 8080, "GET", "/admin"),
      Gori::Store::SitemapOriginEntry.new("http", "acme.test", 8080, "GET", "/public"),
    ])
    Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/admin"} => "admin" })
    Gori::Sitemap.filter_by_tags!(hosts, ["admin"], [] of String)
    hosts.map(&.label).should eq(["http://acme.test:8080", "https://acme.test"])
    endpoint_paths(hosts).should eq(["/admin", "/admin"])
  end
end

describe "Gori::Sitemap.select_by_tags" do
  rows = ["/api", "/api/users", "/api/users/7", "/static/app.js", "/login"].map { |t| origin_entry(t) }

  it "keeps exactly the rows whose endpoint the tree filter keeps, the endpoint above a match included" do
    tags = { {"acme.test", "/api/users/7"} => "idor" }
    terms = Gori::Sitemap.split_tag_terms("tag:idor")
    kept = Gori::Sitemap.select_by_tags(rows, tags, terms) { |e| e }
    kept.map(&.target).should eq(["/api", "/api/users", "/api/users/7"])
    kept.map(&.target).sort!.should eq(filtered(rows.map(&.target), tags, "tag:idor"))
  end

  it "maps a row through the block and keeps the row itself" do
    tags = { {"acme.test", "/login"} => "auth" }
    terms = Gori::Sitemap.split_tag_terms("tag:auth")
    kept = Gori::Sitemap.select_by_tags(rows.map(&.target), tags, terms) { |t| origin_entry(t) }
    kept.should eq(["/login"])
  end

  it "prunes a host-level tree for bare (host, method, target) rows" do
    triples = [{"acme.test", "GET", "/login"}, {"acme.test", "GET", "/static/app.js"}]
    tags = { {"acme.test", "/static/app.js"} => "noise" }
    kept = Gori::Sitemap.select_by_tags(triples, tags, Gori::Sitemap.split_tag_terms("-tag:noise")) { |e| e }
    kept.should eq([{"acme.test", "GET", "/login"}])
  end

  it "returns every row untouched when the query has no tag term" do
    Gori::Sitemap.select_by_tags(rows, {} of {String, String} => String,
      Gori::Sitemap.split_tag_terms("host:acme.test")) { |e| e }.should eq(rows)
  end
end
