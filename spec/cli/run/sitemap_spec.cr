require "../../spec_helper"
require "json"

# `gori run sitemap` — the three output formats (text tree / json / paths) and the tag
# key normalization the `sitemap tag` subcommand writes with.

# `sitemap_tag_path` is private CLI glue; reopen the module for a bare-call wrapper (the
# same whitebox trick the other CLI specs use).
module Gori::CLI::Run
  def self.sitemap_tag_path_for_spec(target : String) : String
    sitemap_tag_path(target)
  end

  def self.collect_sitemap_for_spec(store : Gori::Store, limit : Int32) : {Array(Gori::Sitemap::Node), Bool}
    collect_sitemap(store, Gori::QL::EMPTY, limit, false, true, true)
  end

  def self.sitemap_truncation_notice_for_spec(truncated : Bool, limit : Int32) : String?
    sitemap_truncation_notice(truncated, limit)
  end
end

private def sitemap_store(&)
  path = File.tempname("gori-clisitemap", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def sitemap_captured(host : String, target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy)
end

describe "gori run sitemap — a capped scan" do
  # The tree used to be built off `store.sitemap_entries(filter, limit)` with nothing ever
  # comparing the returned size to `limit`, so `sitemap -n 5` on a project with more endpoints
  # printed a short host list AND a per-host `(N paths)` header counted off the surviving
  # rows — a positive, wrong claim about the project, with nothing on STDERR in text, json OR
  # paths. The cut is invisible by the time the tree exists (every fold below collapses rows),
  # so it has to be measured on the raw read.
  it "reports the cut when the read comes back at the limit" do
    sitemap_store do |store|
      8.times { |i| store.insert_flow(sitemap_captured("acme.test", "/p#{i}")) }
      store.flush

      hosts, truncated = Gori::CLI::Run.collect_sitemap_for_spec(store, 5)
      truncated.should be_true
      # The counts the header prints ARE the truncated ones — which is exactly why the notice
      # has to fire rather than the number being quietly trusted.
      hosts.sum(&.endpoints).should eq(5)
      Gori::CLI::Output.sitemap_text(hosts).should contain("(5 paths)")
    end
  end

  it "reports no cut when the whole set fits under the limit" do
    sitemap_store do |store|
      3.times { |i| store.insert_flow(sitemap_captured("acme.test", "/p#{i}")) }
      store.flush

      hosts, truncated = Gori::CLI::Run.collect_sitemap_for_spec(store, 5)
      truncated.should be_false
      hosts.sum(&.endpoints).should eq(3)
    end
  end

  it "names the limit and disowns the counts in the notice, and stays silent otherwise" do
    note = Gori::CLI::Run.sitemap_truncation_notice_for_spec(true, 5).should_not be_nil
    note.should contain("TRUNCATED")
    note.should contain("5")
    note.should contain("(N paths)")
    Gori::CLI::Run.sitemap_truncation_notice_for_spec(false, 5).should be_nil
  end
end

describe "gori run sitemap — text tree" do
  it "renders an indented tree with counts, methods, and a path tag" do
    hosts = Gori::Sitemap.build([
      {"acme.test", "GET", "/"},
      {"acme.test", "POST", "/api/orders"},
      {"acme.test", "GET", "/api/users"},
    ])
    Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/api"} => "payment flow" })
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("acme.test  (3 paths)")
    txt.should contain("├─ ") # tree guide
    txt.should contain("orders  [POST]")
    txt.should contain("api  # payment flow") # tag on the folder node, no methods
  end

  it "collapses a folded numeric group with a value count" do
    hosts = Gori::Sitemap.build((1001..1012).map { |i| {"h", "GET", "/p/#{i}"} })
    hosts.each { |h| Gori::Sitemap.group_sequences!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("[1001, 1002, 1003 … +9]  (12 values)")
    txt.should_not contain("1010") # a folded child is hidden in the collapsed text tree
  end

  it "shows one representative subtree under an id fold" do
    # A numeric fold collapses whole; an ID fold must not, or /users/<uuid>/orders and
    # /settings — real route structure, not noise — vanish from the default report.
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678/orders"},
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678/settings"},
      {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00/orders"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    # No verbs on the fold: /users/<uuid> itself was never requested here, only its
    # children were — so the fold correctly stands for a folder, not an endpoint.
    txt.should contain("{uuid}  (2 values)\n")
    txt.should contain("orders")   # route shape below the id survives
    txt.should contain("settings") # ...from ONE representative child
    txt.should_not contain("3f2a8b1c")
  end

  it "shows the verbs a fold stands in for when the ids are themselves endpoints" do
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "PATCH", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("{uuid}  (2 values)  [GET PATCH]")
    txt.should contain("h  (2 paths)") # the fold did not inflate the endpoint count
  end
end

describe "gori run sitemap — query folding" do
  it "collapses two query variants into one /search row" do
    hosts = Gori::Sitemap.build([
      {"shop.demo.test", "GET", "/search?q=widgets"},
      {"shop.demo.test", "GET", "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("shop.demo.test  (1 path)")
    txt.should contain("search  (2 queries)  [GET]")
    txt.should_not contain("script") # the payload is not a tree row
  end

  it "leaves a path with no query as one plain node" do
    hosts = Gori::Sitemap.build([{"h", "GET", "/search"}])
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("search  [GET]")
    txt.should_not contain("queries")
    txt.should contain("h  (1 path)")
  end

  it "prints the literal variants when the fold pass is skipped (--no-fold-query)" do
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/search?q=widgets"},
      {"h", "GET", "/search?q=other"},
    ])
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("search?q=widgets  [GET]")
    txt.should contain("search?q=other  [GET]")
    txt.should contain("h  (2 paths)")
  end

  it "still folds ids on the other axis" do
    # --no-group and --no-fold-query are separate switches: id folding is unchanged by the
    # query pass running after it.
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      {"h", "GET", "/search?q=1"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    hosts.each { |h| Gori::Sitemap.group_sequences!(h) }
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    txt = Gori::CLI::Output.sitemap_text(hosts)
    txt.should contain("{uuid}  (2 values)  [GET]")
    txt.should contain("search  (1 query)  [GET]")
  end
end

describe "gori run sitemap --format paths" do
  it "lists every endpoint flat (numeric folding irrelevant)" do
    hosts = Gori::Sitemap.build([
      {"acme.test", "GET", "/api/users"},
      {"acme.test", "POST", "/api/users"},
    ])
    Gori::CLI::Output.sitemap_paths(hosts).should eq("GET,POST  acme.test/api/users\n")
  end

  it "lists a query fold ONCE, at its path" do
    # Unlike an id fold, whose children are distinct endpoints, the variants here are one
    # endpoint — and this listing is what a tester pipes into the next tool.
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/search?q=widgets"},
      {"h", "POST", "/search?q=other"},
      {"h", "GET", "/login"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    Gori::CLI::Output.sitemap_paths(hosts).should eq(
      "GET  h/login\n" \
      "GET,POST  h/search\n")
  end

  it "merges a query fold onto the same path as the real directory node" do
    # /api/users is both an endpoint and a directory, so the fold sits BESIDE it rather than
    # swallowing it (that would hide /api/users/5) — and both carry the path /api/users. This
    # listing promises one line per (host, path).
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/api/users"},
      {"h", "GET", "/api/users/5"},
      {"h", "POST", "/api/users?page=1"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    Gori::CLI::Output.sitemap_paths(hosts).should eq(
      "GET,POST  h/api/users\n" \
      "GET  h/api/users/5\n")
  end

  it "still lists every FOLDED endpoint flat" do
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    Gori::CLI::Output.sitemap_paths(hosts).should eq(
      "GET  h/users/3f2a8b1c-1234-5678-9abc-def012345678\n" \
      "GET  h/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00\n")
  end
end

describe "gori run sitemap --format json" do
  it "emits host/endpoint/children fields and an empty array when blank" do
    hosts = Gori::Sitemap.build([{"acme.test", "GET", "/api/users"}])
    Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/api"} => "memo" })
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }
    json = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    json.size.should eq(1)
    json[0]["host"].as_s.should eq("acme.test")
    json[0]["endpoints"].as_i.should eq(1)
    api = json[0]["children"].as_a.find! { |c| c["label"].as_s == "api" }
    api["tag"].as_s.should eq("memo")
    users = api["children"].as_a.find! { |c| c["label"].as_s == "users" }
    users["path"].as_s.should eq("/api/users")
    users["methods"].as_a.map(&.as_s).should eq(["GET"])

    Gori::CLI::Output.sitemap_json([] of Gori::Sitemap::Node).should eq("[]")
  end

  it "marks an id fold with a template class, omits its path, and keeps children" do
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    json = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    users = json[0]["children"].as_a.find! { |c| c["label"].as_s == "users" }
    fold = users["children"].as_a.find! { |c| c["label"].as_s == "{uuid}" }
    fold["grouped"].as_bool.should be_true
    fold["template"].as_s.should eq("{uuid}")
    fold["path"]?.should be_nil                         # synthetic: a fold has no path
    fold["methods"].as_a.map(&.as_s).should eq(["GET"]) # union of its children's verbs
    kids = fold["children"].as_a
    kids.size.should eq(2)
    kids.map(&.["path"].as_s).sort!.should eq([
      "/users/3f2a8b1c-1234-5678-9abc-def012345678",
      "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00",
    ])
  end

  it "marks a query fold, and unlike an id fold gives it a path and a query count" do
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/search?q=widgets"},
      {"h", "GET", "/search?q=other"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_queries!(h) }
    json = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    fold = json[0]["children"].as_a.find! { |c| c["label"].as_s == "search" }
    fold["grouped"].as_bool.should be_true
    fold["query_fold"].as_bool.should be_true
    fold["template"]?.should be_nil
    fold["path"].as_s.should eq("/search") # its label IS a real path segment
    fold["queries"].as_i.should eq(2)
    fold["methods"].as_a.map(&.as_s).should eq(["GET"])
    # The complete tree is still there: JSON never collapses, so the raw targets remain.
    fold["children"].as_a.map(&.["path"].as_s).should eq(["/search?q=widgets", "/search?q=other"])
  end

  # sitemap_json is emitted by hand rather than through JSON::Builder precisely because the
  # builder hard-caps nesting at 100, and each path segment costs ~2 levels (object +
  # children array) — a deep captured path used to tear the whole report down with
  # `JSON::Error: Nesting of 100 is too deep`. A security tool must not silently truncate
  # its endpoint tree, so the ceiling is gone; nothing tested that until now.
  it "emits a path deeper than JSON::Builder's 100-level nesting cap" do
    depth = 80 # ≈160 JSON levels — well past the builder's limit
    deep = "/" + (1..depth).map { |i| "s#{i}" }.join('/')
    hosts = Gori::Sitemap.build([{"deep.test", "GET", deep}])
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }

    parsed = JSON.parse(Gori::CLI::Output.sitemap_json(hosts)).as_a
    node = parsed[0]
    depth.times do |i|
      node = node["children"].as_a.find! { |c| c["label"].as_s == "s#{i + 1}" }
    end
    node["path"].as_s.should eq(deep) # the leaf survived the whole descent
    Gori::CLI::Output.sitemap_paths(hosts).should contain(deep)
  end

  it "emits valid UTF-8 in every format when a captured host/path is invalid UTF-8" do
    # Sitemap.template_class's own comment documents that a captured target is raw bytes off
    # the wire and can be invalid UTF-8 (a legacy-encoded or fuzzed path). Repro: no control
    # chars, just a raw 0xFF byte in the host and in a path segment.
    bad_host = String.new(Bytes[0x62, 0x61, 0x64, 0xff, 0x68, 0x6f, 0x73, 0x74]) # "bad\xFFhost"
    bad_seg = String.new(Bytes[0x70, 0x61, 0x74, 0x68, 0xff, 0x73, 0x65, 0x67])  # "path\xFFseg"
    hosts = Gori::Sitemap.build([{bad_host, "GET", "/#{bad_seg}"}])
    hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }

    text = Gori::CLI::Output.sitemap_text(hosts)
    text.valid_encoding?.should be_true
    text.should contain("bad�host")
    text.should contain("path�seg")

    json_str = Gori::CLI::Output.sitemap_json(hosts)
    json_str.valid_encoding?.should be_true
    parsed = JSON.parse(json_str).as_a
    parsed[0]["host"].as_s.valid_encoding?.should be_true
    parsed[0]["children"].as_a[0]["label"].as_s.valid_encoding?.should be_true

    paths = Gori::CLI::Output.sitemap_paths(hosts)
    paths.valid_encoding?.should be_true
    paths.should contain("bad�host")
  end

  it "does not leak a host tag onto a fold" do
    # Host rows are taggable with path "" — the same value a synthetic fold carries.
    hosts = Gori::Sitemap.build([
      {"h", "GET", "/u/3f2a8b1c-1234-5678-9abc-def012345678"},
      {"h", "GET", "/u/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
    ])
    hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
    Gori::Sitemap.stamp_tags!(hosts, { {"h", ""} => "whole host" })
    u = hosts.first.children.find! { |c| c.label == "u" }
    u.children.find! { |c| c.label == "{uuid}" }.tag.should be_nil
  end
end

describe "gori run sitemap tag — the key a tag is filed under" do
  # Every assertion here pins a LITERAL rather than re-deriving the expected value from
  # Sitemap.normalize_path: comparing the function against itself would move both sides
  # together, and a regression in normalize_path — the exact thing that would orphan every
  # stored tag — would keep the spec green.

  # The key KEEPS the query string, because "/login?a=1" is a distinct tree node from
  # "/login". Stripping it would file the tag under a key no node ever has, and the tag
  # would silently never appear in the tree.
  it "keeps the query string, so a query-bearing endpoint keys on its own node" do
    Gori::CLI::Run.sitemap_tag_path_for_spec("/login?a=1").should eq("/login?a=1")
    Gori::CLI::Run.sitemap_tag_path_for_spec("/api/users").should eq("/api/users")
    Gori::CLI::Run.sitemap_tag_path_for_spec("  /api/users  ").should eq("/api/users")
  end

  it "adds the leading slash a hand-typed --path omits, and maps empty to /" do
    Gori::CLI::Run.sitemap_tag_path_for_spec("api/users").should eq("/api/users")
    Gori::CLI::Run.sitemap_tag_path_for_spec("").should eq("/")
    Gori::CLI::Run.sitemap_tag_path_for_spec("   ").should eq("/")
  end

  it "reduces an absolute-form target to its origin-form path" do
    # A tag typed as a full URL still has to land on the node the tree built, and
    # Sitemap.build normalizes before stamping — so the key is "/a", not the whole URL.
    Gori::CLI::Run.sitemap_tag_path_for_spec("http://h/a").should eq("/a")
    Gori::CLI::Run.sitemap_tag_path_for_spec("https://h/a?b=1").should eq("/a?b=1")
  end
end
