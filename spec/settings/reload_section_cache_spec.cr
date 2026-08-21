require "../spec_helper"
require "file_utils"

# `Settings.reload_rewriter_from_disk` / `reload_colormarker_from_disk` run on the TUI's
# `data_version` tick, which fires roughly 1.3×/sec for as long as capture is committing flows.
# Folding a section costs three JSON parses and a full re-serialization of the settings, all on
# the calling fiber: measured at 1.9 ms with 10 global rules per section, 13 ms at 100, and
# 63 ms at 500 — a visible stutter in a UI that is also drawing frames and taking keys.
#
# Almost every one of those ticks has nothing to fold, because nobody touched settings.json. So
# the file's own bytes gate the work, and what these examples pin is the pair of properties that
# makes that safe: it must be free when the file has not moved, and it must NOT be free — or
# stale — the moment it has.
private def with_settings_home(&)
  prev = ENV["GORI_HOME"]?
  dir = File.tempname("gori-reload-cache")
  Dir.mkdir_p(dir)
  before_rules = Gori::Settings.rewriter_rules
  before_counter = Gori::Settings.rewriter_next_rule_id
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.forget_reloaded_sections
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    yield dir
  ensure
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    Gori::Settings.forget_reloaded_sections
    Gori::Settings.rewriter_rules = before_rules
    Gori::Settings.rewriter_next_rule_id = before_counter
    FileUtils.rm_rf(dir)
  end
end

private def write_rewriter(dir : String, rules : String, next_id : Int32) : Nil
  File.write(File.join(dir, "settings.json"),
    %({"rewriter":{"next_rule_id":#{next_id},"rules":[#{rules}]}}))
end

private def rule_json(id : Int32, pattern : String) : String
  %({"id":#{id},"enabled":true,"name":"r#{id}","target":"request","part":"head",) +
    %("pattern":"#{pattern}","replacement":"X","op":"replace","match_kind":"literal",) +
    %("host":"","body_file":""})
end

describe "Settings.reload_section on an unchanged file" do
  it "does not re-fold bytes it has already folded" do
    with_settings_home do |dir|
      write_rewriter(dir, rule_json(1, "AAA"), 2)
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["AAA"])

      # Prove the second call is a no-op by making memory disagree with the file and showing the
      # reload leaves the disagreement alone. Only a fold would overwrite this.
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.should be_empty
    end
  end

  it "folds again the moment the bytes move, including a same-length rewrite" do
    # The reason this is a content check and not an mtime or a size check: a peer flipping one
    # rule's `enabled` flag rewrites the file within the same second and, for `true`→`true` of
    # a different rule, at the same length. Being fast is worth nothing if the answer is stale.
    with_settings_home do |dir|
      write_rewriter(dir, rule_json(1, "AAA"), 2)
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["AAA"])

      write_rewriter(dir, rule_json(1, "BBB"), 2) # same length, same second
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["BBB"])
    end
  end

  it "keeps each section's answer to itself" do
    # Both sections read the SAME file, so a cache keyed on the raw bytes alone would let the
    # rewriter fold consume the colormarker's chance to.
    with_settings_home do |dir|
      before = Gori::Settings.colormarker_rules
      begin
        Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
        File.write(File.join(dir, "settings.json"),
          %({"rewriter":{"next_rule_id":2,"rules":[#{rule_json(1, "AAA")}]},) +
          %("colormarker":{"next_rule_id":2,"rules":[) +
          %({"id":1,"enabled":true,"name":"c1","match_filter":"host:a.test",) +
          %("color":"yellow","style":"bar"}]}}))
        Gori::Settings.reload_rewriter_from_disk
        Gori::Settings.reload_colormarker_from_disk
        Gori::Settings.rewriter_rules.size.should eq(1)
        Gori::Settings.colormarker_rules.size.should eq(1)
      ensure
        Gori::Settings.colormarker_rules = before
      end
    end
  end

  it "is dropped by a full load, which rewrites every section behind it" do
    # `Settings.load` re-reads everything, and a load that ends `@@load_partial` leaves sections
    # at their factory DEFAULTS. A cache entry surviving that would claim those bytes were
    # already folded and let the next tick skip the fold that repairs one.
    with_settings_home do |dir|
      write_rewriter(dir, rule_json(1, "AAA"), 2)
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.load
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
      Gori::Settings.reload_rewriter_from_disk # the cache is gone, so this folds
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["AAA"])
    end
  end

  it "does not let one GORI_HOME seed another whose file happens to match" do
    # Two homes can hold byte-identical settings.json (a fresh install, a copied config, two
    # spec examples in a row). Keying on content alone would have the second one skip its fold
    # and run against the first one's memory.
    same = rule_json(1, "AAA")
    with_settings_home do |dir|
      write_rewriter(dir, same, 2)
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["AAA"])
    end
    with_settings_home do |dir|
      # A different home, identical bytes — and memory deliberately empty going in.
      write_rewriter(dir, same, 2)
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
      Gori::Settings.reload_rewriter_from_disk
      Gori::Settings.rewriter_rules.map(&.pattern).should eq(["AAA"])
    end
  end
end
