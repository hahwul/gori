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

  describe ".group_sequences!" do
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
  end
end
