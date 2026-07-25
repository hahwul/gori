require "./spec_helper"
require "json"

# Iteratively descend first-children to the deepest leaf, and count the chain length,
# WITHOUT recursion — so the assertions themselves can't overflow on the very deep trees
# these specs build.
private def deepest_leaf(host : Gori::Sitemap::Node) : Gori::Sitemap::Node
  node = host
  until node.children.empty?
    node = node.children.first
  end
  node
end

# Regression coverage for the iterative (non-recursive) rewrite of Sitemap.fold_templates!
# and Sitemap.group_sequences!. A single very deep captured/imported path builds a
# proportionally deep tree, and the old one-frame-per-level recursion SIGSEGV'd (stack
# overflow). The transforms are shared by the Sitemap TUI tab and `gori run sitemap`.
describe Gori::Sitemap do
  describe "deep trees (no unbounded recursion)" do
    it "folds a path thousands of segments deep without overflowing the stack" do
      depth = 20_000
      target = String.build do |io|
        depth.times { |i| io << "/seg" << i }
      end
      hosts = Gori::Sitemap.build([{"deep.test", "GET", target}])

      # The bug: either of these recursed once per tree level and crashed the process.
      hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
      hosts.each { |h| Gori::Sitemap.group_sequences!(h) }

      # Distinct, non-id, non-numeric segments → nothing folds; the literal chain survives.
      leaf = deepest_leaf(hosts.first)
      leaf.label.should eq("seg#{depth - 1}")
      leaf.methods.should eq(["GET"])
    end

    it "still folds id classes and numeric runs correctly after the rewrite" do
      entries = [] of {String, String, String}
      (1..12).each { |i| entries << {"h", "GET", "/api/items/#{i}"} } # 12 numeric siblings → numeric fold
      ["3f2a8b1c-1234-5678-9abc-def012345678",
       "a1b2c3d4-5566-7788-99aa-bbccddeeff00"].each do |u|
        entries << {"h", "GET", "/api/users/#{u}"} # 2 uuid siblings → {uuid} fold
      end
      hosts = Gori::Sitemap.build(entries)
      hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
      hosts.each { |h| Gori::Sitemap.group_sequences!(h) }

      api = hosts.first.children.find! { |c| c.label == "api" }
      items = api.children.find! { |c| c.label == "items" }
      numeric = items.children.find! { |c| c.grouped }
      numeric.label.starts_with?("[1, 2, 3").should be_true
      numeric.children.size.should eq(12)
      users = api.children.find! { |c| c.label == "users" }
      uuid = users.children.find! { |c| c.label == "{uuid}" }
      uuid.grouped.should be_true
      uuid.children.size.should eq(2)
    end

    it "keeps both passes idempotent (a second call folds nothing new)" do
      hosts = Gori::Sitemap.build([
        {"h", "GET", "/u/3f2a8b1c-1234-5678-9abc-def012345678"},
        {"h", "GET", "/u/a1b2c3d4-5566-7788-99aa-bbccddeeff00"},
      ])
      hosts.each { |h| Gori::Sitemap.fold_templates!(h) }
      hosts.each { |h| Gori::Sitemap.group_sequences!(h) }
      u = hosts.first.children.find! { |c| c.label == "u" }
      first = u.children.map(&.label)
      hosts.each { |h| Gori::Sitemap.fold_templates!(h) } # re-run: must be a no-op
      hosts.each { |h| Gori::Sitemap.group_sequences!(h) }
      u.children.map(&.label).should eq(first)
    end
  end
end

# Regression for `gori run sitemap --format json`: the tree nests ~2 JSON levels per path
# segment and Crystal's JSON::Builder hard-caps nesting at 100, so a path ~45-50 segments
# deep crashed with `JSON::Error: Nesting of 100 is too deep`. Output.sitemap_json now
# hand-emits the tree (no builder, no artificial ceiling) — a security tool must keep the
# whole endpoint tree rather than truncate it.
describe Gori::CLI::Output do
  describe ".sitemap_json (deep tree)" do
    it "serializes a path well past the builder's 100-level nesting cap without crashing" do
      depth = 120 # ~240 JSON nesting levels: over the old 100 builder cap, under the parser's
      target = String.build do |io|
        depth.times { |i| io << "/s" << i }
      end
      hosts = Gori::Sitemap.build([{"deep.test", "GET", target}])
      hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }

      str = Gori::CLI::Output.sitemap_json(hosts)
      str.valid_encoding?.should be_true

      # Round-trips as valid JSON and preserves the full chain down to the leaf.
      parsed = JSON.parse(str).as_a
      parsed[0]["host"].as_s.should eq("deep.test")
      node = parsed[0]
      depth.times do |i|
        node = node["children"].as_a.find! { |c| c["label"].as_s == "s#{i}" }
      end
      node["path"].as_s.should eq(target)
      node["methods"].as_a.map(&.as_s).should eq(["GET"])
    end
  end
end
