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

      # The rest of the module's tree walks, converted later for the same reason. These are
      # cheaper per frame than the two folds above and do NOT overflow at this depth (see
      # the measured table below), so what this pins is that they still produce the right
      # answer on a deep tree — the overflow guard here is the two folds.
      tags = { {"deep.test", "/seg0"} => "memo" } # note the space: {{ starts a macro
      hosts.each { |h| Gori::Sitemap.stamp_tags!([h], tags) }
      Gori::Sitemap.apply_expand_depth!(hosts, -1)
      Gori::Sitemap.endpoint_count(hosts.first).should eq(1) # only the leaf carries a method
      hosts.first.children.first.tag.should eq("memo")
      hosts.first.children.first.expanded.should be_true

      # Distinct, non-id, non-numeric segments → nothing folds; the literal chain survives,
      # cut at MAX_DEPTH (see the memory curve below — a 20k-segment target used to cost
      # 1.6 GB of tree). The endpoint is still THERE, just at the cut path and flagged.
      leaf = deepest_leaf(hosts.first)
      leaf.label.should eq("seg#{Gori::Sitemap::MAX_DEPTH - 1}")
      leaf.methods.should eq(["GET"])
      leaf.truncated.should be_true
      leaf.path.should eq(String.build { |io| Gori::Sitemap::MAX_DEPTH.times { |i| io << "/seg" << i } })
    end

    it "leaves a target at or under MAX_DEPTH untouched and unflagged" do
      depth = Gori::Sitemap::MAX_DEPTH
      target = String.build { |io| depth.times { |i| io << "/seg" << i } }
      hosts = Gori::Sitemap.build([{"deep.test", "GET", target}])

      leaf = deepest_leaf(hosts.first)
      leaf.label.should eq("seg#{depth - 1}")
      leaf.path.should eq(target) # the whole target, not a prefix
      leaf.truncated.should be_false
    end

    it "folds several over-deep targets onto the same cut node and keeps every verb" do
      a = String.build { |io| 500.times { |i| io << "/seg" << i } }
      b = String.build { |io| 400.times { |i| io << "/seg" << i } } # shares the cut prefix
      hosts = Gori::Sitemap.build([{"h", "GET", a}, {"h", "POST", b}])

      leaf = deepest_leaf(hosts.first)
      leaf.truncated.should be_true
      leaf.methods.sort.should eq(["GET", "POST"]) # neither endpoint is dropped, only merged
    end

    # MEASURED (Crystal 1.21, debug build — the mode `crystal spec` uses), so the next person
    # does not have to re-derive which of these walks is worth a deep fixture:
    #
    #   Sitemap.build alone, no walker at all:  109 MB @5k · 404 MB @10k · 1.6 GB @20k ·
    #                                           6.6 GB @40k · 28 GB @80k · OOM-killed @160k
    #   old recursive keep_for_tags?         :  SIGSEGV at 40k (survives 20k)
    #   old recursive SitemapView#collect    :  SIGSEGV at 80k (survives 40k)
    #   old recursive endpoint_count / stamp_tags! / apply_expand_depth! / sitemap_host_paths
    #   / sitemap_children_json              :  survive 80k — the tree exhausts memory first
    #
    # Two consequences worth keeping in mind before "strengthening" this file:
    #
    # 1. `Sitemap.build` itself is QUADRATIC in path depth, because every node stores its
    #    full path from the root (`Node#path`, the durable key for a path tag). That is the
    #    dominant limit — one captured request 20k segments deep costs 1.6 GB before any
    #    walker runs — and no traversal rewrite touches it.
    # 2. A fixture deep enough to catch a reintroduced recursion in the CHEAP walkers would
    #    therefore cost gigabytes, which is why this file does not have one. Their guard is
    #    the code comment at each site, not a spec.
    it "walks a deep tree in every CLI output format without overflowing the stack" do
      # Depth chosen for OUTPUT size, not stack: the text tree's guide prefix grows 3 chars
      # per level and the JSON nests a full path per node, so both are quadratic in depth —
      # at 40k `sitemap_text` already raises IO::EOFError by exceeding IO::Memory's 2 GB cap.
      depth = 2_000
      target = String.build do |io|
        depth.times { |i| io << "/s" << i }
      end
      hosts = Gori::Sitemap.build([{"deep.test", "GET", target}])
      hosts.each { |h| h.endpoints = Gori::Sitemap.endpoint_count(h) }

      cut = Gori::Sitemap::MAX_DEPTH - 1
      Gori::CLI::Output.sitemap_text(hosts).should contain("s#{cut}")
      Gori::CLI::Output.sitemap_json(hosts).should contain(%("label":"s#{cut}"))

      # Truncation is SAID, not silently shown as a short path, in every format.
      Gori::CLI::Output.sitemap_text(hosts).should contain("truncated")
      Gori::CLI::Output.sitemap_json(hosts).should contain(%("truncated":true))
      prefix = String.build { |io| Gori::Sitemap::MAX_DEPTH.times { |i| io << "/s" << i } }
      Gori::CLI::Output.sitemap_paths(hosts).should eq("GET  deep.test#{prefix}\n")
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
