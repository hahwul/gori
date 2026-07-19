require "./spec_helper"

# The pure host → path tree builder shared by the Sitemap TUI tab and
# `gori run sitemap`. (The TUI-render side is covered in tui/sitemap_view_spec.cr.)
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
      Gori::Sitemap.template_class(String.new(Bytes.new(10) { 0xFF_u8 })).should be_nil  # {date}
      Gori::Sitemap.template_class(String.new(Bytes.new(36) { 0xFF_u8 })).should be_nil  # {uuid}
      Gori::Sitemap.template_class(String.new(Bytes.new(12) { 0xFF_u8 })).should be_nil  # {hex}
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
