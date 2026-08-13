require "./spec_helper"
require "file_utils"

# `Settings.scan_rules` — the GLOBAL user-defined Probe match rules (settings:probe rules →
# global scope), the library half of the same global-base/project-layer split
# `Settings.rewriter_rules` and `Env.effective_vars` rest on.
#
# Two things make this worth its own file. The parse is the boundary a HAND-EDITED
# settings.json crosses on its way into the match engine: `Probe.custom_rules` maps these
# straight into the runtime match list, and `ScanRule#side/region/kind/severity` are read as
# though they were enums. A file that smuggles `"side": "whatever"` past this parse gets a
# rule that matches nothing, or matches the wrong half of the message, with nothing on any
# surface to say so — so the clamp is the whole contract. And every CRUD call persists
# through `save`'s 3-way merge, where an emptied section is the case that has silently
# undone deletions before (see the `chosen` comment in Settings.merge_with_disk).

# Every example here writes process-wide Settings state and a real settings.json, so each
# one owns a temp GORI_HOME and puts back the scan rules it found.
private def with_scan_home(&)
  dir = File.tempname("gori-scan-rules")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  before = Gori::Settings.scan_rules
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.scan_rules = [] of Gori::Settings::ScanRule
    yield dir
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.scan_rules = before
    FileUtils.rm_rf(dir)
  end
end

private def write_settings(json : String) : Nil
  File.write(Gori::Settings.path, json)
end

describe Gori::Settings do
  describe "scan_rules — the parse a hand-edited file crosses" do
    it "reads a complete rule field for field" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[{"id":"a1","title":"Leaked key","description":"d",
            "side":"request","region":"header","kind":"regex","pattern":"sk_live_\\\\w+",
            "severity":"critical","enabled":false}]}
          JSON
        Gori::Settings.load
        r = Gori::Settings.scan_rules.first
        {r.id, r.title, r.description}.should eq({"a1", "Leaked key", "d"})
        {r.side, r.region, r.kind}.should eq({"request", "header", "regex"})
        {r.pattern, r.severity, r.enabled}.should eq({"sk_live_\\w+", "critical", false})
      end
    end

    # id/title/pattern are the three a rule cannot be reconstructed without: no id and no
    # surface can address it, no pattern and it matches nothing. Dropped rather than
    # defaulted — a rule with an invented pattern would scan live traffic for it.
    it "drops an entry missing (or blanking) id, title or pattern" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[
            {"title":"no id","pattern":"p"},
            {"id":"b","pattern":"p"},
            {"id":"c","title":"no pattern"},
            {"id":"","title":"blank id","pattern":"p"},
            {"id":"e","title":"","pattern":"p"},
            {"id":"f","title":"blank pattern","pattern":""},
            {"id":"ok","title":"kept","pattern":"p"}
          ]}
          JSON
        Gori::Settings.load
        Gori::Settings.scan_rules.map(&.id).should eq(["ok"])
      end
    end

    # The clamp is what makes ScanRule's four label fields total. Each falls back to the
    # SAFEST choice rather than the first member: a response/body/string/info rule reads
    # the half of a message the operator most likely meant and files at the lowest severity.
    it "clamps an unknown side/region/kind/severity to its default" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[{"id":"x","title":"t","pattern":"p",
            "side":"sideways","region":"middle","kind":"glob","severity":"catastrophic"}]}
          JSON
        Gori::Settings.load
        r = Gori::Settings.scan_rules.first
        {r.side, r.region, r.kind, r.severity}.should eq({"response", "body", "string", "info"})
      end
    end

    it "clamps a non-string (or absent) enum field the same way" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[{"id":"x","title":"t","pattern":"p",
            "side":7,"region":null,"kind":["regex"],"severity":true}]}
          JSON
        Gori::Settings.load
        r = Gori::Settings.scan_rules.first
        {r.side, r.region, r.kind, r.severity}.should eq({"response", "body", "string", "info"})
      end
    end

    it "accepts the enum labels case-insensitively and stores them lowercase" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[{"id":"x","title":"t","pattern":"p",
            "side":"REQUEST","region":"Header","kind":"ReGeX","severity":"HIGH"}]}
          JSON
        Gori::Settings.load
        r = Gori::Settings.scan_rules.first
        {r.side, r.region, r.kind, r.severity}.should eq({"request", "header", "regex", "high"})
      end
    end

    it "accepts every allowed value on each axis" do
      with_scan_home do
        Gori::Settings::SCAN_RULE_SIDES.each do |side|
          write_settings(%({"scan_rules":[{"id":"x","title":"t","pattern":"p","side":#{side.to_json}}]}))
          Gori::Settings.load
          Gori::Settings.scan_rules.first.side.should eq(side)
        end
        Gori::Settings::SCAN_RULE_REGIONS.each do |region|
          write_settings(%({"scan_rules":[{"id":"x","title":"t","pattern":"p","region":#{region.to_json}}]}))
          Gori::Settings.load
          Gori::Settings.scan_rules.first.region.should eq(region)
        end
        Gori::Settings::SCAN_RULE_KINDS.each do |kind|
          write_settings(%({"scan_rules":[{"id":"x","title":"t","pattern":"p","kind":#{kind.to_json}}]}))
          Gori::Settings.load
          Gori::Settings.scan_rules.first.kind.should eq(kind)
        end
        Gori::Settings::SCAN_RULE_SEVERITIES.each do |sev|
          write_settings(%({"scan_rules":[{"id":"x","title":"t","pattern":"p","severity":#{sev.to_json}}]}))
          Gori::Settings.load
          Gori::Settings.scan_rules.first.severity.should eq(sev)
        end
      end
    end

    # An absent `enabled` means "written by a build that predates the flag", not "off": a
    # rule the operator added must keep scanning after an upgrade.
    it "defaults a missing enabled to true, and keeps an explicit false" do
      with_scan_home do
        write_settings(<<-JSON)
          {"scan_rules":[
            {"id":"a","title":"t","pattern":"p"},
            {"id":"b","title":"t","pattern":"p","enabled":false},
            {"id":"c","title":"t","pattern":"p","enabled":"nope"}
          ]}
          JSON
        Gori::Settings.load
        Gori::Settings.scan_rules.map { |r| {r.id, r.enabled} }
          .should eq([{"a", true}, {"b", false}, {"c", true}])
      end
    end

    it "defaults a missing description to the empty string" do
      with_scan_home do
        write_settings(%({"scan_rules":[{"id":"a","title":"t","pattern":"p"}]}))
        Gori::Settings.load
        Gori::Settings.scan_rules.first.description.should eq("")
      end
    end

    # A non-array node is a malformed file, not an instruction to clear the library — the
    # same tolerance `parse_hostname_overrides` and `parse_tab_prefs` have.
    it "keeps the current rules when the node is absent, null or not an array" do
      with_scan_home do
        keep = [Gori::Settings::ScanRule.new("k", "kept", "", "response", "body",
          "string", "p", "info", true)]
        docs = [
          %({"theme":"goridark"}), %({"scan_rules":null}),
          %({"scan_rules":"nope"}), %({"scan_rules":{"id":"x"}}),
        ]
        docs.each do |doc|
          Gori::Settings.scan_rules = keep
          write_settings(doc)
          Gori::Settings.load
          Gori::Settings.scan_rules.map(&.id).should eq(["k"])
        end
      end
    end

    it "drops a non-object entry rather than failing the whole array" do
      with_scan_home do
        write_settings(%({"scan_rules":["nope",42,null,{"id":"ok","title":"t","pattern":"p"}]}))
        Gori::Settings.load
        Gori::Settings.scan_rules.map(&.id).should eq(["ok"])
      end
    end
  end

  describe "scan_rules — the global library CRUD" do
    it "mints an id on add and returns it so the caller can select the new rule" do
      with_scan_home do
        id = Gori::Settings.add_scan_rule("Leaked key", "d", "request", "header",
          "regex", "sk_live_", "critical")
        id.should_not be_empty
        Gori::Settings.scan_rules.size.should eq(1)
        r = Gori::Settings.scan_rules.first
        r.id.should eq(id)
        {r.title, r.side, r.region, r.kind, r.pattern, r.severity, r.enabled}
          .should eq({"Leaked key", "request", "header", "regex", "sk_live_", "critical", true})
      end
    end

    it "gives each rule a distinct id and appends in creation order" do
      with_scan_home do
        a = Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p1", "info")
        b = Gori::Settings.add_scan_rule("b", "", "response", "body", "string", "p2", "info")
        a.should_not eq(b)
        Gori::Settings.scan_rules.map(&.id).should eq([a, b])
      end
    end

    it "creates disabled when asked" do
      with_scan_home do
        Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p", "info", enabled: false)
        Gori::Settings.scan_rules.first.enabled.should be_false
      end
    end

    # The edit form has no enabled checkbox — the list's toggle owns that — so an update
    # must not quietly switch a disabled rule back on.
    it "rewrites every field on update EXCEPT enabled, which the toggle owns" do
      with_scan_home do
        id = Gori::Settings.add_scan_rule("old", "od", "response", "body", "string", "p", "info",
          enabled: false)
        Gori::Settings.update_scan_rule(id, "new", "nd", "request", "header", "regex", "q", "high")
        r = Gori::Settings.scan_rules.first
        {r.id, r.title, r.description}.should eq({id, "new", "nd"})
        {r.side, r.region, r.kind, r.pattern, r.severity}
          .should eq({"request", "header", "regex", "q", "high"})
        r.enabled.should be_false
      end
    end

    it "leaves the other rules alone on update, toggle and delete" do
      with_scan_home do
        a = Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p1", "info")
        b = Gori::Settings.add_scan_rule("b", "", "response", "body", "string", "p2", "info")

        Gori::Settings.update_scan_rule(b, "b2", "", "response", "body", "string", "p2", "low")
        Gori::Settings.scan_rules.map(&.title).should eq(["a", "b2"])

        Gori::Settings.set_scan_rule_enabled(b, false)
        Gori::Settings.scan_rules.map { |r| {r.id, r.enabled} }.should eq([{a, true}, {b, false}])

        Gori::Settings.delete_scan_rule(a)
        Gori::Settings.scan_rules.map(&.id).should eq([b])
      end
    end

    it "is a no-op for an id no rule has" do
      with_scan_home do
        id = Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p", "info")
        Gori::Settings.update_scan_rule("nope", "x", "", "request", "head", "regex", "q", "high")
        Gori::Settings.set_scan_rule_enabled("nope", false)
        Gori::Settings.delete_scan_rule("nope")
        Gori::Settings.scan_rules.map { |r| {r.id, r.title, r.enabled} }.should eq([{id, "a", true}])
      end
    end
  end

  describe "scan_rules — persistence" do
    it "round-trips the whole library through save/load" do
      with_scan_home do
        id = Gori::Settings.add_scan_rule("Leaked key", "desc", "request", "header",
          "regex", "sk_live_\\w+", "critical", enabled: false)
        Gori::Settings.scan_rules = [] of Gori::Settings::ScanRule
        Gori::Settings.load
        r = Gori::Settings.scan_rules.first
        {r.id, r.title, r.description, r.side, r.region, r.kind, r.pattern, r.severity, r.enabled}
          .should eq({id, "Leaked key", "desc", "request", "header", "regex", "sk_live_\\w+",
                      "critical", false})
      end
    end

    # An untouched install must never grow a `"scan_rules": []` block — but the section is
    # still a NAME gori knows, which is what `gori settings export --sections scan_rules`
    # validates against (see SECTION_KEYS).
    it "omits the section entirely when the library is empty" do
      with_scan_home do
        Gori::Settings.save.should be_true
        Gori::Settings.document_keys.should_not contain("scan_rules")
        JSON.parse(File.read(Gori::Settings.path)).as_h.has_key?("scan_rules").should be_false
        Gori::Settings::SECTION_KEYS.should contain("scan_rules")
      end
    end

    # Deleting the LAST rule empties the section, so `serialize` stops emitting the key —
    # exactly the shape that made `save`'s merge copy a stale block forward (see the `chosen`
    # comment in merge_with_disk). The delete has to reach the FILE: an emptied library that
    # still had its block on disk would come back on the next process start, and a rule the
    # operator removed would keep scanning.
    it "erases the section from disk when the last rule is deleted" do
      with_scan_home do
        id = Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p", "info")
        JSON.parse(File.read(Gori::Settings.path)).as_h.has_key?("scan_rules").should be_true

        Gori::Settings.delete_scan_rule(id)
        JSON.parse(File.read(Gori::Settings.path)).as_h.has_key?("scan_rules").should be_false

        # …and a process starting from the factory default (an empty library, the state
        # `load` actually runs against) stays empty rather than resurrecting the rule.
        Gori::Settings.scan_rules = [] of Gori::Settings::ScanRule
        Gori::Settings.load
        Gori::Settings.scan_rules.should be_empty
      end
    end

    # The flip side of "absent keeps current": that tolerance is what makes a truncated or
    # half-written file harmless, and it is why the erase above is checked on DISK rather
    # than through a reload — a reload alone cannot distinguish the two.
    it "does not let an absent section clear a library already in memory" do
      with_scan_home do
        Gori::Settings.add_scan_rule("a", "", "response", "body", "string", "p", "info")
        write_settings(%({"theme":"goridark"}))
        Gori::Settings.load
        Gori::Settings.scan_rules.map(&.title).should eq(["a"])
      end
    end
  end
end
