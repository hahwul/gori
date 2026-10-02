require "./spec_helper"

# The pure host → path tree builder shared by the Sitemap TUI tab and
# `gori run sitemap`. (The TUI-render side is covered in tui/sitemap_view_spec.cr.)
private def sme(scheme : String, host : String, port : Int32, target : String, method = "GET") : Gori::Store::SitemapOriginEntry
  Gori::Store::SitemapOriginEntry.new(scheme, host, port, method, target)
end

describe Gori::Sitemap do
  describe ".normalize_path" do
    it "reduces an absolute-form target to its path (+query), default '/' for the root" do
      Gori::Sitemap.normalize_path("https://h/a/b").should eq("/a/b")
      Gori::Sitemap.normalize_path("http://h/x?y=1").should eq("/x?y=1")
      Gori::Sitemap.normalize_path("https://h").should eq("/")
    end

    it "leaves an origin-form target unchanged" do
      Gori::Sitemap.normalize_path("/already/a/path").should eq("/already/a/path")
    end
  end

  # #1371: the surfaces build from ORIGIN entries, one root per scheme + host + port.
  describe ".build (origin entries)" do
    it "keeps two ports and two schemes of one host as separate roots, sorted" do
      hosts = Gori::Sitemap.build([
        sme("https", "127.0.0.1", 8443, "/only-tls"),
        sme("http", "127.0.0.1", 19022, "/b"),
        sme("http", "127.0.0.1", 19021, "/a"),
        sme("http", "127.0.0.1", 19021, "/b"),
        sme("https", "acme.test", 443, "/"),
      ])
      hosts.map(&.label).should eq(["http://127.0.0.1:19021", "http://127.0.0.1:19022",
                                    "https://127.0.0.1:8443", "https://acme.test"])
      hosts.map(&.host).uniq!.should eq(["127.0.0.1", "acme.test"])
      hosts[0].origin.should eq(Gori::Sitemap::Origin.new("http", "127.0.0.1", 19021))
      hosts[0].children.map(&.path).should eq(["/a", "/b"])
      hosts[2].children.map(&.path).should eq(["/only-tls"])
    end

    it "labels an origin with its default port elided and an IPv6 literal bracketed" do
      Gori::Sitemap::Origin.new("https", "acme.test", 443).label.should eq("https://acme.test")
      Gori::Sitemap::Origin.new("http", "acme.test", 80).label.should eq("http://acme.test")
      Gori::Sitemap::Origin.new("http", "acme.test", 443).label.should eq("http://acme.test:443")
      Gori::Sitemap::Origin.new("https", "::1", 8443).label.should eq("https://[::1]:8443")
    end

    # A tag is keyed on (host, path) (V17), not on the origin.
    it "stamps a host's tag under every origin of that host" do
      hosts = Gori::Sitemap.build([sme("http", "h.test", 8080, "/admin"), sme("https", "h.test", 443, "/admin")])
      Gori::Sitemap.stamp_tags!(hosts, { {"h.test", "/admin"} => "memo" })
      hosts.map(&.children.first.tag).should eq(["memo", "memo"])
    end
  end

  describe ".build" do
    it "builds a literal host → segment tree with deduped methods on the endpoint node" do
      hosts = Gori::Sitemap.build([
        {"acme.test", "GET", "/api/users"},
        {"acme.test", "POST", "/api/users"},
        {"acme.test", "GET", "/api/users"}, # duplicate method — must not repeat
        {"cdn.test", "GET", "/app.js"},
      ])
      hosts.map(&.label).should eq(["acme.test", "cdn.test"])
      acme = hosts.first
      api = acme.children.find! { |c| c.label == "api" }
      api.methods.should be_empty # a folder, no requests landed on it
      users = api.children.find! { |c| c.label == "users" }
      users.methods.should eq(["GET", "POST"]) # deduped, insertion order
      users.path.should eq("/api/users")       # the durable tag key
    end

    it "represents a bare-root request as a '/' child of the host" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/"}])
      root = hosts.first.children.find! { |c| c.label == "/" }
      root.path.should eq("/")
      root.methods.should eq(["GET"])
    end

    it "does not fabricate path nodes from an unencoded '/' in a query value" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/api?redirect=/home/dashboard"}])
      api = hosts.first.children
      api.map(&.label).should eq(["api?redirect=/home/dashboard"]) # one leaf, not a fake home/dashboard subtree
      api.first.children.should be_empty
      api.first.path.should eq("/api?redirect=/home/dashboard")
    end

    it "normalizes a trailing slash but keeps an interior '//' distinct" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/dup/a"},
        {"h", "GET", "/dup/a/"},  # trailing slash → same endpoint as /dup/a
        {"h", "POST", "//dup/a"}, # interior '//' → a DISTINCT literal path
      ])
      root = hosts.first
      # /dup/a and /dup/a/ merged onto the same leaf (methods just GET, deduped)
      dup = root.children.find! { |c| c.label == "dup" }
      dup.children.find! { |c| c.label == "a" }.methods.should eq(["GET"])
      # //dup/a lives under a distinct interior-empty node, not merged into /dup/a
      empties = root.children.select { |c| c.label == "" }
      empties.size.should eq(1)
      empties.first.children.find! { |c| c.label == "dup" }.children.find! { |c| c.label == "a" }.methods.should eq(["POST"])
    end
  end

  describe ".endpoint_count" do
    it "counts only nodes that carry a method (folders excluded)" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/api/users"},   # endpoint
        {"h", "POST", "/api/orders"}, # endpoint
        {"h", "GET", "/"},            # endpoint
      ])
      # /api is a folder (no method) ⇒ not counted; users, orders, / ⇒ 3.
      Gori::Sitemap.endpoint_count(hosts.first).should eq(3)
    end
  end

  describe ".template_class" do
    it "classifies opaque ids and leaves real segments literal" do
      Gori::Sitemap.template_class("3f2a8b1c-1234-5678-9abc-def012345678").should eq("{uuid}")
      Gori::Sitemap.template_class("a3f2b1c9d8e7").should eq("{hex}")
      Gori::Sitemap.template_class("2026-07-19").should eq("{date}")
      Gori::Sitemap.template_class("users").should be_nil
      Gori::Sitemap.template_class("v2").should be_nil
    end

    it "excludes numerics so they stay with group_sequences!" do
      # Url::HEX is /\A[0-9a-f]{12,}\z/i, so a 13-digit ms timestamp would classify as
      # {hex} without the explicit numeric guard — and be stolen from the numeric fold.
      Gori::Sitemap.template_class("1737300000000").should be_nil
      Gori::Sitemap.template_class("42").should be_nil
    end

    it "classifies the path part of a leaf that carries a query" do
      # `add` appends the query to the LAST segment, so the anchored regexes would miss.
      Gori::Sitemap.template_class("3f2a8b1c-1234-5678-9abc-def012345678?tab=a").should eq("{uuid}")
      Gori::Sitemap.template_class("?q=1").should be_nil # bare root + query
    end

    it "does not label a date-shaped non-date {date}" do
      # Url::DATE checks the SHAPE only, so these matched and got a label that lied about
      # what the segment is. They are still opaque ids — just not dates.
      Gori::Sitemap.template_class("1234-56-78").should be_nil
      Gori::Sitemap.template_class("9999-99-99").should be_nil
      Gori::Sitemap.template_class("2026-00-10").should be_nil
      Gori::Sitemap.template_class("2026-07-19").should eq("{date}") # still a real one
      Gori::Sitemap.template_class("2026-12-31").should eq("{date}")
    end

    it "does not downcase-merge (the reason Url.fold_segment is not reused)" do
      Gori::Sitemap.template_class("Users").should be_nil
    end

    it "survives a segment that is not valid UTF-8" do
      # A captured target is raw bytes: a legacy-encoded (EUC-KR, latin-1) or fuzzed path
      # arrives as invalid UTF-8, and PCRE2 RAISES on such a subject instead of returning
      # false. Unguarded, one such request crashed the whole TUI from the sitemap poll.
      # Each of these is sized to clear a different regex's length gate.
      Gori::Sitemap.template_class(String.new(Bytes.new(10) { 0xFF_u8 })).should be_nil # {date}
      Gori::Sitemap.template_class(String.new(Bytes.new(36) { 0xFF_u8 })).should be_nil # {uuid}
      Gori::Sitemap.template_class(String.new(Bytes.new(12) { 0xFF_u8 })).should be_nil # {hex}
      latin1 = Bytes[0x63, 0x61, 0x66, 0xE9, 0x63, 0x61, 0x66, 0xE9, 0x63, 0x61, 0x66, 0xE9]
      Gori::Sitemap.template_class(String.new(latin1)).should be_nil # "café" ×3, latin-1
    end

    it "still classifies through a whole-tree fold when a host serves invalid UTF-8" do
      # The end-to-end path the crash actually took: build → fold_templates!.
      bad = String.new(Bytes.new(12) { 0xFF_u8 })
      rows = (1..4).map { |i| {"https", "acme.test", 443, "h2", "GET", "/a/#{bad}/#{i}"} }
      hosts = Gori::Sitemap.build(rows.map { |r| {r[1], r[4], r[5]} })
      Gori::Sitemap.fold_templates!(hosts.first)
      hosts.first.children.map(&.label).should contain("a")
    end
  end

  describe ".fold_templates!" do
    it "folds two uuid siblings into one collapsed {uuid}, children keeping literal paths" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      users = hosts.first.children.find! { |c| c.label == "users" }
      users.children.size.should eq(1)
      group = users.children.first
      group.grouped.should be_true
      group.expanded.should be_false
      group.label.should eq("{uuid}")
      group.path.should eq("") # synthetic: never a real endpoint
      group.fold_parent.should eq("/users")
      group.children.size.should eq(2)
      group.children.map(&.path).sort!.should eq([
        "/users/3f2a8b1c-1234-5678-9abc-def012345678",
        "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00",
      ])
    end

    it "leaves a lone uuid literal (below the threshold)" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"}])
      Gori::Sitemap.fold_templates!(hosts.first)
      users = hosts.first.children.find! { |c| c.label == "users" }
      users.children.none?(&.grouped).should be_true
    end

    it "keeps non-id siblings put, ordered before the fold" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/users/me"},
        {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
        {"h", "GET", "/users/settings"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      users = hosts.first.children.find! { |c| c.label == "users" }
      users.children.map(&.label).should eq(["me", "settings", "{uuid}"])
    end

    it "gives each id class its own fold, and holds dates to the numeric threshold" do
      # A date is meaningful CONTENT — folding two of them would hide a real range.
      entries = [
        {"h", "GET", "/x/a3f2b1c9d8e7"},
        {"h", "GET", "/x/b4e3c2d1a0f9"},
        {"h", "GET", "/x/2026-07-18"},
        {"h", "GET", "/x/2026-07-19"},
      ]
      hosts = Gori::Sitemap.build(entries)
      Gori::Sitemap.fold_templates!(hosts.first)
      x = hosts.first.children.find! { |c| c.label == "x" }
      x.children.select(&.grouped).map(&.label).should eq(["{hex}"])
      x.children.reject(&.grouped).map(&.label).sort!.should eq(["2026-07-18", "2026-07-19"])
    end

    it "folds dates once they do explode" do
      hosts = Gori::Sitemap.build((1..11).map { |i| {"h", "GET", "/r/2026-07-%02d" % i} })
      Gori::Sitemap.fold_templates!(hosts.first)
      r = hosts.first.children.find! { |c| c.label == "r" }
      r.children.find! { |c| c.label == "{date}" }.children.size.should eq(11)
    end

    it "does not merge segments that differ only by case" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/Users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      hosts.first.children.map(&.label).sort!.should eq(["Users", "users"])
      # one uuid under each parent ⇒ neither reaches the threshold
      hosts.first.children.each { |c| c.children.none?(&.grouped).should be_true }
    end

    it "folds a uuid whether or not the leaf carries a query" do
      uuid = "3f2a8b1c-1234-5678-9abc-def012345678"
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/i/#{uuid}"},
        {"h", "GET", "/i/#{uuid}?tab=a"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      i = hosts.first.children.find! { |c| c.label == "i" }
      i.children.find! { |c| c.label == "{uuid}" }.children.size.should eq(2)
    end

    it "folds at the parent level while deeper segments stay reachable" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/a/3f2a8b1c-1234-5678-9abc-def012345678/b"},
        {"h", "GET", "/a/a1b2c3d4-5566-7788-99aa-bbccddeeff00/b"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      a = hosts.first.children.find! { |c| c.label == "a" }
      group = a.children.find! { |c| c.label == "{uuid}" }
      group.children.each { |c| c.children.map(&.label).should eq(["b"]) }
    end

    it "is idempotent — a second call does not nest another level" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/u/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/u/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      Gori::Sitemap.fold_templates!(hosts.first)
      u = hosts.first.children.find! { |c| c.label == "u" }
      u.children.size.should eq(1)
      u.children.first.children.none?(&.grouped).should be_true
    end

    it "leaves long numerics to group_sequences!, producing exactly one fold level" do
      hosts = Gori::Sitemap.build((1..12).map { |i| {"h", "GET", "/e/173730000000#{i}"} })
      Gori::Sitemap.fold_templates!(hosts.first)
      Gori::Sitemap.group_sequences!(hosts.first)
      e = hosts.first.children.find! { |c| c.label == "e" }
      e.children.size.should eq(1)
      group = e.children.first
      group.label.should start_with("[")
      group.children.none?(&.grouped).should be_true # no nested {hex} inside
    end

    it "carries the union of its children's verbs without becoming an endpoint" do
      entries = [
        {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "PATCH", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00/orders"},
      ]
      before = Gori::Sitemap.endpoint_count(Gori::Sitemap.build(entries).first)
      hosts = Gori::Sitemap.build(entries)
      Gori::Sitemap.fold_templates!(hosts.first)
      group = hosts.first.children.find! { |c| c.label == "users" }.children.find!(&.grouped)
      group.fold_methods.should eq(["GET", "PATCH"]) # direct children only, not /orders
      group.methods.should be_empty                  # NOT methods: endpoint_count keys on that
      Gori::Sitemap.endpoint_count(hosts.first).should eq(before)
    end

    it "does not change host endpoint counts" do
      entries = [
        {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
        {"h", "GET", "/users/me"},
      ]
      before = Gori::Sitemap.endpoint_count(Gori::Sitemap.build(entries).first)
      hosts = Gori::Sitemap.build(entries)
      Gori::Sitemap.fold_templates!(hosts.first)
      Gori::Sitemap.endpoint_count(hosts.first).should eq(before)
    end
  end

  describe ".fold_queries!" do
    it "folds two query variants of one path into a single node" do
      # The reason this pass exists: mapping shop.demo.test listed /search twice — once per
      # payload — and the second row's LABEL was the XSS payload.
      hosts = Gori::Sitemap.build([
        {"shop.demo.test", "GET", "/search?q=widgets"},
        {"shop.demo.test", "GET", "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.size.should eq(1)
      fold = hosts.first.children.first
      fold.label.should eq("search")
      fold.grouped.should be_true
      fold.query_fold.should be_true
      fold.expanded.should be_false # collapsed by default: the payload is not a visible row
      fold.path.should eq("/search")
      fold.fold_methods.should eq(["GET"])
      fold.methods.should be_empty # endpoint_count keys on that; the fold is not its own endpoint
      Gori::Sitemap.query_variants(fold).should eq(2)
      # The variants keep their literal paths, so a tag on /search?q=1 still stamps and
      # Repeater still resolves a concrete captured target through the fold.
      fold.children.map(&.path).should eq(["/search?q=widgets", "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"])
    end

    it "counts the folded endpoint once" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/search?q=1"},
        {"h", "POST", "/search?q=2"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      # Two captured (method, target) rows, ONE endpoint — which is what the row now says.
      Gori::Sitemap.endpoint_count(hosts.first).should eq(1)
      hosts.first.children.first.fold_methods.should eq(["GET", "POST"])
    end

    it "leaves a path with no query alone" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/search"}, {"h", "GET", "/login"}])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.map(&.label).should eq(["search", "login"])
      hosts.first.children.none?(&.grouped).should be_true
      Gori::Sitemap.endpoint_count(hosts.first).should eq(2)
    end

    it "absorbs the query-LESS leaf sibling, so /search appears exactly once" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/search"},
        {"h", "GET", "/search?q=1"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.map(&.label).should eq(["search"])
      fold = hosts.first.children.first
      fold.children.map(&.path).should eq(["/search", "/search?q=1"])
      Gori::Sitemap.query_variants(fold).should eq(1) # the bare path is not a variant of itself
      Gori::Sitemap.endpoint_count(hosts.first).should eq(1)
    end

    it "leaves a path that is also a DIRECTORY in place, so its subtree stays visible" do
      # Folding /api/users would take /api/users/5 into the collapsed fold with it — the
      # fold would then hide endpoints instead of deduplicating one.
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/api/users"},
        {"h", "GET", "/api/users/5"},
        {"h", "GET", "/api/users?page=1"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      api = hosts.first.children.first
      api.children.map(&.label).should eq(["users", "users"])
      real, fold = api.children
      real.grouped.should be_false
      real.children.map(&.label).should eq(["5"]) # subtree intact
      fold.query_fold.should be_true
      fold.children.map(&.path).should eq(["/api/users?page=1"])
      Gori::Sitemap.endpoint_count(hosts.first).should eq(3) # /api/users, /api/users/5, the fold
    end

    # #1379: the folds were appended after every other child, so `export (1 query)` sat under
    # `rebuild` and a `search` fold after every plain leaf. A fold takes its first member's place.
    it "keeps each fold where its first member was among its siblings" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/api/users"},
        {"h", "GET", "/export?fmt=csv"},
        {"h", "GET", "/login"},
        {"h", "GET", "/search"},
        {"h", "GET", "/search?q=1"},
        {"h", "GET", "/zebra"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.map(&.label).should eq(["api", "export", "login", "search", "zebra"])
      hosts.first.children.select(&.query_fold).map(&.label).should eq(["export", "search"])
    end

    it "folds a query on the bare root onto the '/' node" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/"}, {"h", "GET", "/?utm=x"}])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.map(&.label).should eq(["/"])
      fold = hosts.first.children.first
      fold.query_fold.should be_true
      fold.path.should eq("/")
      fold.children.map(&.path).should eq(["/", "/?utm=x"])
    end

    it "keeps each path's variants separate" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/search?q=1"},
        {"h", "GET", "/login?next=/a"},
        {"h", "GET", "/search?q=2"},
      ])
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.map(&.label).sort.should eq(["login", "search"])
      hosts.first.children.each { |c| c.query_fold.should be_true }
    end

    it "is idempotent — a second call does not nest another level" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/search?q=1"}, {"h", "GET", "/search?q=2"}])
      Gori::Sitemap.fold_queries!(hosts.first)
      Gori::Sitemap.fold_queries!(hosts.first)
      hosts.first.children.size.should eq(1)
      hosts.first.children.first.children.size.should eq(2)
    end

    it "runs AFTER the id folds without disturbing them" do
      # The id passes must still see the literal children: /items/7?ref=home belongs in the
      # numeric run with /items/7, not in a query fold of its own.
      rows = (1..12).map { |i| {"h", "GET", "/items/#{i}?ref=home"} }
      hosts = Gori::Sitemap.build(rows)
      Gori::Sitemap.group_sequences!(hosts.first)
      Gori::Sitemap.fold_queries!(hosts.first)
      items = hosts.first.children.first
      items.children.size.should eq(1)
      fold = items.children.first
      fold.label.should eq("[1, 2, 3 … +9]")
      fold.query_fold.should be_false # a numeric run, not a query fold
      fold.children.size.should eq(12)
    end

    it "leaves the children of an id fold alone (they are already collapsed)" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678?x=1"},
        {"h", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00?x=2"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      Gori::Sitemap.fold_queries!(hosts.first)
      users = hosts.first.children.first
      users.children.size.should eq(1)
      users.children.first.label.should eq("{uuid}")
      users.children.first.children.size.should eq(2)
    end

    it "keeps a query fold collapsed under apply_expand_depth!" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/search?q=1"}, {"h", "GET", "/search?q=2"}])
      Gori::Sitemap.fold_queries!(hosts.first)
      Gori::Sitemap.apply_expand_depth!(hosts, -1) # "expand everything"
      hosts.first.children.first.expanded.should be_false
    end

    it "does not stamp a tag onto the synthetic fold" do
      # The tag key is the node path INCLUDING the query, so the variants keep theirs and
      # the fold — like a {uuid} fold — carries none of its own.
      hosts = Gori::Sitemap.build([{"h", "GET", "/search?q=1"}, {"h", "GET", "/search?q=2"}])
      Gori::Sitemap.stamp_tags!(hosts, { {"h", "/search?q=1"} => "sqli here", {"h", "/search"} => "unreachable" })
      Gori::Sitemap.fold_queries!(hosts.first)
      fold = hosts.first.children.first
      fold.tag.should be_nil
      fold.children.first.tag.should eq("sqli here")
    end
  end

  describe ".group_sequences!" do
    it "folds numeric ids that carry a query, and labels the group by the path part" do
      # `add` appends the query to the LAST segment, so a listing page's links arrive as
      # `7?ref=home`. Both passes tested the raw label, so precisely the case that
      # explodes the tree — a paginated list — was the one that never folded.
      rows = (1..12).map { |i| {"acme.test", "GET", "/items/#{i}?ref=home"} }
      hosts = Gori::Sitemap.build(rows)
      Gori::Sitemap.group_sequences!(hosts.first)
      items = hosts.first.children.first
      items.children.size.should eq(1)
      fold = items.children.first
      fold.grouped.should be_true
      fold.label.should eq("[1, 2, 3 … +9]") # not "[1?ref=home, 2?ref=home, …]"
      fold.children.size.should eq(12)
    end

    it "folds a pure-numeric run beyond the threshold into one collapsed group" do
      hosts = Gori::Sitemap.build((1001..1012).map { |i| {"h", "GET", "/p/#{i}"} })
      Gori::Sitemap.group_sequences!(hosts.first)
      p = hosts.first.children.find! { |c| c.label == "p" }
      p.children.size.should eq(1)
      group = p.children.first
      group.grouped.should be_true
      group.expanded.should be_false
      group.label.should start_with("[1001, 1002, 1003 ")
      group.children.size.should eq(12) # the folded values are retained as children
    end

    it "leaves a short numeric run untouched" do
      hosts = Gori::Sitemap.build((1..5).map { |i| {"h", "GET", "/a/#{i}"} })
      Gori::Sitemap.group_sequences!(hosts.first)
      a = hosts.first.children.find! { |c| c.label == "a" }
      a.children.map(&.label).sort!.should eq(%w(1 2 3 4 5))
      a.children.none?(&.grouped).should be_true
    end

    it "carries its children's verbs too" do
      entries = (1001..1012).map { |i| {"h", "GET", "/p/#{i}"} }.to_a
      entries << {"h", "DELETE", "/p/1005"}
      hosts = Gori::Sitemap.build(entries)
      Gori::Sitemap.group_sequences!(hosts.first)
      group = hosts.first.children.find! { |c| c.label == "p" }.children.find!(&.grouped)
      group.fold_methods.sort!.should eq(["DELETE", "GET"])
      group.methods.should be_empty
    end

    it "is idempotent — a second call does not nest another level" do
      hosts = Gori::Sitemap.build((1001..1012).map { |i| {"h", "GET", "/p/#{i}"} })
      Gori::Sitemap.group_sequences!(hosts.first)
      Gori::Sitemap.group_sequences!(hosts.first)
      p = hosts.first.children.find! { |c| c.label == "p" }
      p.children.size.should eq(1)
      p.children.first.children.none?(&.grouped).should be_true
    end
  end

  describe ".stamp_tags!" do
    it "pins a memo onto the node whose (host, path) matches" do
      hosts = Gori::Sitemap.build([{"acme.test", "GET", "/api/users"}])
      Gori::Sitemap.stamp_tags!(hosts, { {"acme.test", "/api"} => "payment" })
      api = hosts.first.children.find! { |c| c.label == "api" }
      api.tag.should eq("payment")
      api.children.find! { |c| c.label == "users" }.tag.should be_nil
    end
  end

  describe ".apply_expand_depth!" do
    it "expands everything when depth is -1 (all)" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/a/b/c"}])
      Gori::Sitemap.apply_expand_depth!(hosts, -1)
      h = hosts.first
      h.expanded.should be_true
      a = h.children.find! { |c| c.label == "a" }
      a.expanded.should be_true
      a.children.first.expanded.should be_true
    end

    it "collapses hosts at depth 0 (hosts only)" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/a/b"}])
      Gori::Sitemap.apply_expand_depth!(hosts, 0)
      hosts.first.expanded.should be_false
    end

    it "expands only nodes shallower than the depth limit" do
      hosts = Gori::Sitemap.build([{"h", "GET", "/a/b/c"}])
      Gori::Sitemap.apply_expand_depth!(hosts, 1)
      h = hosts.first
      h.expanded.should be_true # depth 0 < 1
      a = h.children.find! { |c| c.label == "a" }
      a.expanded.should be_false # depth 1 is not < 1
    end

    it "keeps grouped sequence folds collapsed" do
      hosts = Gori::Sitemap.build((1001..1012).map { |i| {"h", "GET", "/p/#{i}"} })
      Gori::Sitemap.group_sequences!(hosts.first)
      Gori::Sitemap.apply_expand_depth!(hosts, -1)
      p = hosts.first.children.find! { |c| c.label == "p" }
      group = p.children.find! &.grouped
      group.expanded.should be_false
    end

    it "keeps template folds collapsed" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/u/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/u/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      ])
      Gori::Sitemap.fold_templates!(hosts.first)
      Gori::Sitemap.apply_expand_depth!(hosts, -1)
      u = hosts.first.children.find! { |c| c.label == "u" }
      u.children.find! { |c| c.label == "{uuid}" }.expanded.should be_false
    end
  end
end

# `gori run sitemap tag` and MCP `set_sitemap_tag` both file a tag under this key (#1463).
describe "Gori::Sitemap.tag_path — the key a tag is filed under" do
  # Every assertion here pins a LITERAL rather than re-deriving the expected value from
  # Sitemap.normalize_path: comparing the function against itself would move both sides
  # together, and a regression in normalize_path — the exact thing that would orphan every
  # stored tag — would keep the spec green.

  # The key KEEPS the query string, because "/login?a=1" is a distinct tree node from
  # "/login". Stripping it would file the tag under a key no node ever has, and the tag
  # would silently never appear in the tree.
  it "keeps the query string, so a query-bearing endpoint keys on its own node" do
    Gori::Sitemap.tag_path("/login?a=1").should eq("/login?a=1")
    Gori::Sitemap.tag_path("/api/users").should eq("/api/users")
    Gori::Sitemap.tag_path("/api/users/").should eq("/api/users")
    Gori::Sitemap.tag_path("  /api/users  ").should eq("/api/users")
  end

  it "adds the leading slash a hand-typed path omits, and maps empty to /" do
    Gori::Sitemap.tag_path("api/users").should eq("/api/users")
    Gori::Sitemap.tag_path("").should eq("/")
    Gori::Sitemap.tag_path("   ").should eq("/")
  end

  it "reduces an absolute-form target to its origin-form path" do
    # A tag typed as a full URL still has to land on the node the tree built, and
    # Sitemap.build normalizes before stamping — so the key is "/a", not the whole URL.
    Gori::Sitemap.tag_path("http://h/a").should eq("/a")
    Gori::Sitemap.tag_path("https://h/a?b=1").should eq("/a?b=1")
  end
end
