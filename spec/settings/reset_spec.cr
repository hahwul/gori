require "../spec_helper"
require "file_utils"

# A profile with a NON-DEFAULT value in every section a factory reset has to clear, shaped to
# survive each section's tolerant parser (a rejected entry leaves the section empty, the section
# then never serializes, and the assertions below would pass without the reset doing anything).
private RESET_FIXTURE = <<-JSON
  {
    "theme": "goriday",
    "mouse": false,
    "pretty_bodies": false,
    "layout": { "history_preview": true, "history_list_order": "oldest" },
    "statusline": { "command": "echo hi" },
    "display": { "history_time_format": "relative", "wrap_lines": false },
    "companion": { "enabled": true, "notices": false },
    "language": { "default": "ko", "system": "en" },
    "notifications": { "bell": true, "toast": false },
    "general": { "confirm_quit": true, "clipboard_osc52": false },
    "update": { "notified_version": "9.9.9", "checked_at": 1234 },
    "network": { "bind_port": 9191, "capture_max_mib": 7, "tls_passthrough": ["a.test"] },
    "upstream_rules": [ { "host": "*.corp", "kind": "direct" } ],
    "outbound_tls": [ { "host": "a.test", "min_version": "tls1.2" } ],
    "retention": { "max_flows": 4242 },
    "listeners": [ { "host": "127.0.0.1", "port": 8099, "mode": "proxy" } ],
    "editor": { "command": "nvim", "markdown": false },
    "tabs": [ { "id": "history", "visible": true } ],
    "hostname_overrides": [ { "host": "api.corp", "ip": "10.0.0.5" } ],
    "env": { "prefix": "%", "vars": [ { "key": "TOKEN", "value": "v" } ] },
    "scan_rules": [ { "id": "r1", "title": "t", "pattern": "p", "enabled": false } ],
    "oast_providers": [ { "id": "o1", "name": "p1", "kind": "interactsh", "host": "x.test" } ],
    "hotkeys": { "os": "linux", "command_modifier": "alt", "bindings": { "palette.open": ["ctrl-y"] } },
    "mine": { "locations": ["query"], "concurrency": 11 },
    "fuzzer": { "recent_wordlists": ["/tmp/w.txt"] },
    "probe": { "active_notify": "always" },
    "discover": { "containment": "strict", "max_depth": 3 },
    "decoder": { "chains": [ { "name": "c1", "spec": "base64-decode" } ] },
    "hooks": { "timeout_secs": 30 },
    "rewriter": { "next_rule_id": 7, "rules": [] },
    "colormarker": { "next_rule_id": 7, "rules": [], "colors": [ { "name": "mine", "hex": "#ff0000" } ] },
    "saved_views": { "next_view_id": 7, "views": [ { "id": 1, "name": "v1", "query": "src:proxy" } ] }
  }
  JSON

# Settings are class_properties — process-global, not per-example — and `reset_to_factory`
# clears ALL of them, so an example here would otherwise hand every later spec file a
# factory-default Settings. Snapshot by SERIALIZATION rather than by naming fields (the same
# reasoning as profile_spec's snapshot helper, one level up: this one cannot miss a section,
# because `export_document` is derived from `serialize`), and restore through a LOAD of that
# snapshot inside the temp home so putting it back never writes outside it.
private def with_settings_snapshot(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-reset")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    yield dir
  ensure
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir # still the temp home while the snapshot is read back
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

# Every `x` in a dispatcher's `<verb>_x` call list, in order. `signature` is the dispatcher's
# own `def` line, matched verbatim so the body regex cannot latch onto a same-prefixed helper.
private def dispatched(src : String, signature : String, prefix : String) : Array(String)
  body = src[/^\s*#{Regex.escape(signature)}$.*?^    end$/m]?
  body.should_not be_nil
  body.not_nil!.scan(/^\s+#{prefix}_([a-z_]+)\b/m).map(&.[1])
end

describe "Settings.reset_to_factory" do
  # The GUARD. `reset_sections` and `serialize` are two hand-maintained lists of the same
  # thing — "every section this install persists" — and a factory reset that silently skips a
  # section is invisible in every behavioural test that does not happen to populate it. Adding
  # a `serialize_x` without a `reset_x` fails here, at the dispatcher, rather than shipping a
  # reset that leaves one section behind.
  it "resets exactly the sections serialize writes, in the same order" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "settings.cr"))
    written = dispatched(src, "private def self.serialize : String", "serialize")
    cleared = dispatched(src, "private def self.reset_sections : Nil", "reset")
    written.should_not be_empty
    cleared.should eq(written)
  end

  it "restores every section to its factory default and drops it from the file" do
    with_settings_snapshot do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, RESET_FIXTURE)
      Gori::Settings.load
      # The fixture landed — otherwise the assertions below would be testing nothing.
      Gori::Settings.theme.should eq("goriday")
      Gori::Settings.document_keys.sort.should eq(Gori::Settings::SECTION_KEYS.sort)

      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)

      # What is left is the handful of sections a fresh install writes anyway — every optional
      # one omits itself at its default, which is how the key disappears — plus `rewriter`,
      # `colormarker` and `saved_views`, which stay only to carry their id counters (see
      # reset_rewriter: those are what stop a project's surviving overrides — or, for views, its
      # `history_view` pointer — from latching onto a reused id).
      left = %w[theme mouse pretty_bodies network editor probe rewriter colormarker saved_views]
      Gori::Settings.document_keys.sort.should eq(left.sort)
      JSON.parse(File.read(path)).as_h.keys.sort.should eq(left.sort)

      # …and the in-memory state moved with it, not just the file: a reset that only rewrote
      # settings.json would leave the running session on the old theme, keymap and rules.
      Gori::Settings.theme.should eq(Gori::Settings::DEFAULT_THEME)
      Gori::Settings.mouse.should eq(Gori::Settings::DEFAULT_MOUSE)
      Gori::Settings.bind_port.should eq(Gori::Settings::DEFAULT_BIND_PORT)
      Gori::Settings.capture_max_mib.should eq(Gori::Settings::DEFAULT_CAPTURE_MAX_MIB)
      Gori::Settings.tls_passthrough.should be_empty
      Gori::Settings.editor.should eq(Gori::Settings::DEFAULT_EDITOR)
      Gori::Settings.wrap_lines?.should eq(Gori::Settings::DEFAULT_WRAP_LINES)
      Gori::Settings.command_modifier.should eq(Gori::Settings::DEFAULT_COMMAND_MODIFIER)
      Gori::Settings.language_default.should eq(Gori::Settings::DEFAULT_LANGUAGE)
      Gori::Settings.language_system.should eq(Gori::Settings::DEFAULT_LANGUAGE_OVERRIDE)
      Gori::Settings.keymap_overrides.should be_empty
      Gori::Settings.tab_prefs.should be_empty
      Gori::Settings.env_vars.should be_empty
      Gori::Settings.env_prefix.should eq(Gori::Settings::DEFAULT_ENV_PREFIX)
      Gori::Settings.hostname_overrides.should be_empty
      Gori::Settings.oast_providers.should be_empty
      Gori::Settings.scan_rules.should be_empty
      Gori::Settings.listeners.should be_empty
      Gori::Settings.upstream_rules.should be_empty
      Gori::Settings.outbound_tls.should be_empty
      Gori::Settings.decoder_chains.should be_empty
      Gori::Settings.rewriter_rules.should be_empty
      Gori::Settings.colormarker_rules.should be_empty
      Gori::Settings.colormarker_colors.should be_empty
      Gori::Settings.mine_prefs_saved?.should be_false
      Gori::Settings.discover_prefs_saved?.should be_false
      Gori::Settings.fuzz_recent_wordlists.should be_empty
      Gori::Settings.probe_active_notify.should eq(Gori::Settings::DEFAULT_PROBE_ACTIVE_NOTIFY)
      Gori::Settings.retention_max_flows.should eq(Gori::Settings::DEFAULT_RETENTION_FLOWS)
    end
  end

  # Clearing rules through their SETTERS is what drops the compiled pattern caches with them.
  # Assigning the backing arrays directly would leave `upstream_route` / `outbound_tls_for` /
  # `tls_passthrough?` still matching hosts by rules that no longer exist anywhere.
  it "drops the compiled caches with the rules" do
    with_settings_snapshot do |dir|
      File.write(File.join(dir, "settings.json"), RESET_FIXTURE)
      Gori::Settings.load
      Gori::Settings.outbound_tls_for("a.test").min_version.should eq("tls1.2")
      Gori::Settings.tls_passthrough?("a.test").should be_true

      Gori::Settings.reset_to_factory.saved?.should be_true

      Gori::Settings.outbound_tls_for("a.test").min_version.should eq("")
      Gori::Settings.tls_passthrough?("a.test").should be_false
    end
  end

  # A project store keeps `rewriter_overrides` / `colormarker_overrides` keyed by GLOBAL rule
  # id, and a factory reset cannot reach into those databases to clear them. Rewinding the
  # counter would mint id 1 again for the next rule created, and a project that had overridden
  # the old id 1 would silently apply that override to a rule it has never seen.
  it "keeps the global rule id counters monotonic across a reset" do
    with_settings_snapshot do |dir|
      File.write(File.join(dir, "settings.json"), RESET_FIXTURE)
      Gori::Settings.load
      Gori::Settings.reset_to_factory.saved?.should be_true

      Gori::Settings.rewriter_next_rule_id.should eq(7_i64)
      Gori::Settings.colormarker_next_rule_id.should eq(7_i64)
      # …and they survive a restart, which is the only thing that makes them protective.
      Gori::Settings.rewriter_next_rule_id = 1_i64
      Gori::Settings.colormarker_next_rule_id = 1_i64
      Gori::Settings.load
      Gori::Settings.rewriter_next_rule_id.should eq(7_i64)
      Gori::Settings.colormarker_next_rule_id.should eq(7_i64)
    end
  end

  # `save` refuses outright after a half-read file (the #594 guard), and a reset that cleared
  # memory first would leave the session on defaults while settings.json still held everything
  # — a factory reset that undoes itself at the next start. It has to refuse BEFORE the side
  # effect, and say which of the two failures it was, so the caller does not re-apply settings
  # live or report a reset that never happened. A top-level ARRAY is the same reproducer
  # settings_spec uses: `JSON::Any#[]?` raises at the very first section.
  it "refuses without touching memory when the last load only got half the file in" do
    with_settings_snapshot do |dir|
      path = File.join(dir, "settings.json")
      original = %([{"theme":"dracula"}])
      File.write(path, original)
      Gori::Settings.load
      Gori::Settings.load_degraded?.should be_true

      Gori::Settings.theme = "goriday" # stands in for everything a reset would clear
      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Refused)

      Gori::Settings.theme.should eq("goriday")            # memory untouched…
      File.read(path).should eq(original)                  # …and so is the file
      Gori::Settings.theme = Gori::Settings::DEFAULT_THEME # (the snapshot restore reloads anyway)
    end
  end

  # The `project_*` / `cli_*` overlays are not written by `serialize`, so they are not a
  # settings reset's to clear: they belong to the open project and to this process's argv, and
  # clearing them would silently move a pinned listener out from under a running client.
  it "leaves the project and CLI bind overlays alone" do
    with_settings_snapshot do |dir|
      File.write(File.join(dir, "settings.json"), RESET_FIXTURE)
      Gori::Settings.load
      Gori::Settings.project_bind_port = 7777
      Gori::Settings.cli_bind_port = 6666
      begin
        Gori::Settings.reset_to_factory.saved?.should be_true
        Gori::Settings.project_bind_port.should eq(7777)
        Gori::Settings.cli_bind_port.should eq(6666)
      ensure
        Gori::Settings.project_bind_port = nil
        Gori::Settings.cli_bind_port = nil
      end
    end
  end

  # A file that does NOT round-trip through gori's serializer, which is every file a human
  # wrote and the one shape no other example here has. RESET_FIXTURE is deliberately built to
  # round-trip, so `disk == base` and `merge_with_disk` short-circuits on its second line —
  # meaning no reset example reached the 3-way merge at all, and the merge is where the reset
  # was leaking. Each key below is a different way to be absent from BOTH `mine` and `base`:
  #
  #   decoder.sessions   — a LEGACY block `serialize` never writes back, so it is absent from
  #                        the base even though the file has it (and it holds whatever the
  #                        operator pasted into a Decoder tab — the confirm dialog names
  #                        "saved decoder chains" among the things a reset drops)
  #   hostname_overrides — an entry the tolerant parser drops leaves the section EMPTY, i.e.
  #                        at its factory default, and a defaulted section does not serialize
  #   tabs               — written as `[]`, which parses to the same "never customized" empty
  #   leftover_section   — a key this gori does not know at all
  #
  # All four read as "this process did not change this section", and the section rule copied
  # disk's bytes straight through the reset — which then reported `Saved`.
  it "clears sections that only exist on disk, when the file did not round-trip" do
    with_settings_snapshot do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, <<-JSON)
        {
          "theme": "goriday",
          "decoder": { "sessions": [ { "name": "tab1", "input": "SECRETTOKEN", "spec": "base64-decode" } ] },
          "hostname_overrides": [ { "host": "", "ip": "10.0.0.5" } ],
          "tabs": [],
          "leftover_section": { "keep": "LEFTOVER" }
        }
        JSON
      Gori::Settings.load
      Gori::Settings.theme.should eq("goriday") # the fixture landed

      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)

      text = File.read(path)
      text.should_not contain("SECRETTOKEN")
      text.should_not contain("10.0.0.5")
      text.should_not contain("LEFTOVER")
      keys = JSON.parse(text).as_h.keys
      keys.should_not contain("decoder")
      keys.should_not contain("hostname_overrides")
      keys.should_not contain("tabs")
      keys.should_not contain("leftover_section")
    end
  end

  # …and the same merge path used to write an INCOMPLETE document on the way out. `serialize`
  # writes these four unconditionally, but each one sat at its factory default in memory AND
  # was absent from a disk file that never mentioned it — "unchanged", so disk (nothing) won,
  # so the key vanished. A reset is the one write that should leave a file a fresh install
  # would recognise.
  it "writes the unconditional sections even when the merge path runs" do
    with_settings_snapshot do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"theme":"goriday","tabs":[]}))
      Gori::Settings.load
      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)
      keys = JSON.parse(File.read(path)).as_h.keys
      %w[theme mouse pretty_bodies network editor probe].each { |k| keys.should contain(k) }
    end
  end

  # A peer writing the same file inside the window still keeps its OWN rule — the rule sections
  # are merged entry by entry either way, and turning the section rule off for a reset must not
  # turn that off with it. Our deletions win; their addition survives.
  it "still merges a concurrent peer's new rule while dropping the rules it knew about" do
    with_settings_snapshot do |dir|
      path = File.join(dir, "settings.json")
      ours = %({"id":1,"enabled":true,"name":"ours","target":"request","part":"head",) +
             %("pattern":"X-Ours","replacement":"v","op":"set_header","match_kind":"literal",) +
             %("host":"","body_file":""})
      theirs = %({"id":8,"enabled":true,"name":"peer","target":"request","part":"head",) +
               %("pattern":"X-Peer","replacement":"v","op":"set_header","match_kind":"literal",) +
               %("host":"","body_file":""})
      # Non-round-tripping again (a `tabs: []` nobody serializes), so the merge actually runs.
      File.write(path, %({"tabs":[],"rewriter":{"next_rule_id":2,"rules":[#{ours}]}}))
      Gori::Settings.load
      Gori::Settings.rewriter_rules.map(&.name).should eq(["ours"])
      # The peer adds a rule and lands it between our load and our save.
      File.write(path, %({"tabs":[],"rewriter":{"next_rule_id":9,"rules":[#{ours},#{theirs}]}}))

      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)

      doc = JSON.parse(File.read(path)).as_h
      section = doc["rewriter"].as_h
      section["rules"].as_a.map { |r| r.as_h["name"].as_s }.should eq(["peer"]) # ours deleted
      section["next_rule_id"].as_i64.should eq(9_i64)                           # high-water mark
      doc.keys.should_not contain("tabs")                                       # leak still closed
    end
  end

  # The OTHER way a session ends up sitting on factory defaults over a file that still holds
  # everything: `load_raw`'s blanket rescue swallows every READ failure and leaves no trace —
  # no `load_warning` (nothing was parsed) and no `.corrupt` copy (`load_root` writes one where
  # a PARSE fails, and this never got that far). Resetting from there writes defaults over a
  # file this process never opened, and unlike the unparseable path there is nothing to
  # recover from. A directory at the config path is the same reproducer `--config /some/dir`
  # hits; the root-owned-settings.json case cannot be staged without a second uid.
  it "refuses when the settings file could not be READ at all" do
    with_settings_snapshot do |dir|
      cfg = File.join(dir, "as-a-directory")
      Dir.mkdir_p(cfg)
      Gori::Settings.path_override = cfg
      begin
        Gori::Settings.load
        Gori::Settings.theme = "goriday" # stands in for everything a reset would clear
        Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Refused)
        Gori::Settings.theme.should eq("goriday") # memory untouched…
        Dir.exists?(cfg).should be_true           # …and so is what was at the path
      ensure
        Gori::Settings.path_override = nil
        Gori::Settings.theme = Gori::Settings::DEFAULT_THEME
      end
    end
  end
end
