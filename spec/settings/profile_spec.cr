require "../spec_helper"
require "file_utils"

private def with_config_home(&)
  dir = File.tempname("gori-profile")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    yield dir
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.upstream_proxy = ""
    Gori::Settings.bind_port = 8070
    # Through the setter, so the COMPILED pattern cache goes back with it — a leaked rule
    # would silently reroute `upstream_route` in whatever spec file runs next.
    Gori::Settings.upstream_rules = [] of Gori::Settings::UpstreamRule
    Gori::Settings.theme = Gori::Settings::DEFAULT_THEME
    Gori::Settings.env_vars = [] of {String, String}
    # Overlay scratch must not leak into MineConfigOverlay / Discover specs that run later
    # in the same process (class_properties, not the temp settings.json).
    Gori::Settings.mine_locations = [] of String
    Gori::Settings.mine_concurrency = 10
    Gori::Settings.mine_notify = "when-found"
    Gori::Settings.mine_prefs_saved = false
    Gori::Settings.discover_prefs_saved = false
    FileUtils.rm_rf(dir)
  end
end

# A profile that puts a NON-DEFAULT value in every one of Settings::SECTION_KEYS, so
# `document_keys` (derived from `serialize`, which omits a section at its default) can be
# compared against SECTION_KEYS exactly rather than as a one-way subset. Every entry here is
# shaped to survive its section's tolerant parser — a rejected entry leaves the section empty,
# the section then does not serialize, and the guard silently weakens instead of failing.
private MAXIMAL_PROFILE = <<-JSON
  {
    "theme": "goriday",
    "mouse": false,
    "pretty_bodies": false,
    "layout": { "history_preview": true, "history_list_order": "oldest" },
    "statusline": { "command": "echo hi" },
    "display": { "history_time_format": "relative" },
    "companion": { "enabled": true, "notices": false },
    "notifications": { "bell": true, "toast": false },
    "general": { "confirm_quit": false, "clipboard_osc52": false },
    "update": { "notified_version": "9.9.9" },
    "network": { "bind_port": 9191 },
    "upstream_rules": [ { "host": "*.corp", "kind": "direct" } ],
    "outbound_tls": [ { "host": "a.test", "min_version": "tls1.2" } ],
    "retention": { "max_flows": 4242 },
    "listeners": [ { "host": "127.0.0.1", "port": 8099, "mode": "proxy" } ],
    "editor": { "command": "nvim" },
    "tabs": [ { "id": "history", "visible": true } ],
    "hostname_overrides": [ { "host": "api.corp", "ip": "10.0.0.5" } ],
    "env": { "vars": [ { "key": "TOKEN", "value": "v" } ] },
    "scan_rules": [ { "id": "r1", "title": "t", "pattern": "p", "enabled": false } ],
    "oast_providers": [ { "id": "o1", "name": "p1", "kind": "interactsh", "host": "x.test" } ],
    "hotkeys": { "os": "linux" },
    "mine": { "locations": ["query"], "concurrency": 11 },
    "fuzzer": { "recent_wordlists": ["/tmp/w.txt"] },
    "probe": { "active_notify": "always" },
    "discover": { "containment": "strict", "max_depth": 3 },
    "decoder": { "chains": [ { "name": "c1", "spec": "base64-decode" } ] },
    "rewriter": { "next_rule_id": 2, "rules": [] },
    "colormarker": { "next_rule_id": 2, "rules": [] }
  }
  JSON

# Settings are class_properties — process-global, not per-example — so an example that
# populates all 28 sections would leak every one of them into whatever spec file runs next.
# `with_config_home` already resets the handful its own examples touch; this restores the rest
# by SNAPSHOT rather than by naming defaults, so it stays correct whatever state it inherits.
private def with_every_section_populated(&)
  pretty = Gori::Settings.pretty_bodies_default
  mouse = Gori::Settings.mouse
  hist_preview = Gori::Settings.history_preview
  hist_order = Gori::Settings.history_list_order
  statusline = Gori::Settings.statusline_command
  time_format = Gori::Settings.history_time_format
  companion = Gori::Settings.companion?
  companion_notices = Gori::Settings.companion_notices?
  bell = Gori::Settings.notify_bell?
  toast = Gori::Settings.notify_toast?
  osc52 = Gori::Settings.clipboard_osc52?
  confirm_quit = Gori::Settings.confirm_quit?
  notified = Gori::Settings.update_notified_version
  outbound = Gori::Settings.outbound_tls
  retention = Gori::Settings.retention_max_flows
  listeners = Gori::Settings.listeners
  editor = Gori::Settings.editor
  tabs = Gori::Settings.tab_prefs
  overrides = Gori::Settings.hostname_overrides
  scan_rules = Gori::Settings.scan_rules
  oast = Gori::Settings.oast_providers
  keymap_os = Gori::Settings.keymap_os
  wordlists = Gori::Settings.fuzz_recent_wordlists
  probe_notify = Gori::Settings.probe_active_notify
  containment = Gori::Settings.discover_containment
  depth = Gori::Settings.discover_max_depth
  chains = Gori::Settings.decoder_chains
  rules = Gori::Settings.rewriter_rules
  next_id = Gori::Settings.rewriter_next_rule_id
  color_rules = Gori::Settings.colormarker_rules
  color_next_id = Gori::Settings.colormarker_next_rule_id
  # `parse_mine_prefs`/`parse_discover_prefs` end with `keep_alive = obj["keep_alive"]? != false`,
  # so a mine/discover block that omits the key forces BOTH to true — a leak this helper exists
  # to prevent, and one no other reset in this file covers.
  mine_keep_alive = Gori::Settings.mine_keep_alive?
  discover_keep_alive = Gori::Settings.discover_keep_alive?
  begin
    yield
  ensure
    Gori::Settings.pretty_bodies_default = pretty
    Gori::Settings.mouse = mouse
    Gori::Settings.history_preview = hist_preview
    Gori::Settings.history_list_order = hist_order
    Gori::Settings.statusline_command = statusline
    Gori::Settings.history_time_format = time_format
    Gori::Settings.companion = companion
    Gori::Settings.companion_notices = companion_notices
    Gori::Settings.notify_bell = bell
    Gori::Settings.notify_toast = toast
    Gori::Settings.clipboard_osc52 = osc52
    Gori::Settings.confirm_quit = confirm_quit
    Gori::Settings.update_notified_version = notified
    Gori::Settings.outbound_tls = outbound
    Gori::Settings.retention_max_flows = retention
    Gori::Settings.listeners = listeners
    Gori::Settings.editor = editor
    Gori::Settings.tab_prefs = tabs
    Gori::Settings.hostname_overrides = overrides
    Gori::Settings.scan_rules = scan_rules
    Gori::Settings.oast_providers = oast
    Gori::Settings.keymap_os = keymap_os
    Gori::Settings.fuzz_recent_wordlists = wordlists
    Gori::Settings.probe_active_notify = probe_notify
    Gori::Settings.discover_containment = containment
    Gori::Settings.discover_max_depth = depth
    Gori::Settings.decoder_chains = chains
    Gori::Settings.rewriter_rules = rules
    Gori::Settings.rewriter_next_rule_id = next_id
    Gori::Settings.colormarker_rules = color_rules
    Gori::Settings.colormarker_next_rule_id = color_next_id
    Gori::Settings.mine_keep_alive = mine_keep_alive
    Gori::Settings.discover_keep_alive = discover_keep_alive
  end
end

describe "settings profiles" do
  describe ".path resolution" do
    it "prefers --config over $GORI_CONFIG over GORI_HOME" do
      with_config_home do |dir|
        Gori::Settings.path.should eq(File.join(dir, "settings.json"))

        ENV["GORI_CONFIG"] = "/tmp/from-env.json"
        Gori::Settings.path.should eq("/tmp/from-env.json")

        Gori::Settings.path_override = "/tmp/from-flag.json"
        Gori::Settings.path.should eq("/tmp/from-flag.json")

        # A blank override is not an override — it must not shadow the env/home fallbacks.
        Gori::Settings.path_override = ""
        Gori::Settings.path.should eq("/tmp/from-env.json")
      end
    end

    # --config must be orthogonal to GORI_HOME: pointing at another config must NOT relocate
    # the CA, the project databases, the themes or the wordlists.
    it "does not move the rest of GORI_HOME" do
      with_config_home do |dir|
        Gori::Settings.path_override = File.join(dir, "elsewhere", "profile.json")
        Gori::Paths.home_dir.should eq(dir)
        Gori::Paths.default_ca_dir.should eq(File.join(dir, "ca"))
      end
    end

    it "creates the parent directory when saving outside GORI_HOME" do
      with_config_home do |dir|
        nested = File.join(dir, "profiles", "team", "a.json")
        Gori::Settings.path_override = nested
        Gori::Settings.save.should be_true
        File.exists?(nested).should be_true
      end
    end

    # settings.json carries `env` token VALUES and saved decoder sessions. Inside GORI_HOME the
    # 0700 tree covers it, but --config can put it in a shared checkout or a 0755 home, where
    # the file's OWN mode is the only thing protecting it.
    it "writes the settings file owner-only" do
      with_config_home do |dir|
        target = File.join(dir, "shared", "profile.json")
        Gori::Settings.path_override = target
        Gori::Settings.save.should be_true
        (File.info(target).permissions.value & 0o777).should eq(0o600)
      end
    end

    # A `.tmp` left behind by a crashed save keeps its own mode through the rename, so the
    # create-time perm alone is not enough — the chmod has to run too.
    it "tightens a leftover temp file rather than inheriting its mode" do
      with_config_home do |dir|
        target = File.join(dir, "profile.json")
        stale = "#{target}.tmp"
        File.write(stale, "{}")
        File.chmod(stale, 0o644)
        Gori::Settings.path_override = target
        Gori::Settings.save.should be_true
        (File.info(target).permissions.value & 0o777).should eq(0o600)
      end
    end

    # The regression: `--config` into an existing directory used to chmod that directory to
    # 0700. It is the operator's, not gori's — and with a relative --config it is the cwd.
    it "does not re-mode a parent directory the operator named" do
      with_config_home do |dir|
        parent = File.join(dir, "shared")
        Dir.mkdir_p(parent)
        File.chmod(parent, 0o755)
        Gori::Settings.path_override = File.join(parent, "profile.json")
        Gori::Settings.save.should be_true
        (File.info(parent).permissions.value & 0o777).should eq(0o755)
      end
    end
  end

  describe ".document_keys" do
    # Derived from the live serialization rather than a hand-kept list, so a new section is
    # exportable the moment it is written.
    it "lists the keys the current settings actually serialize" do
      with_config_home do
        keys = Gori::Settings.document_keys
        keys.should contain("network")
        keys.should contain("theme")
        # An optional section that is at its default is absent from both, consistently.
        Gori::Settings.retention_max_flows.should eq(Gori::Settings::DEFAULT_RETENTION_FLOWS)
        keys.should_not contain("retention")
      end
    end
  end

  describe ".export_document" do
    it "omits secret-bearing sections by default" do
      with_config_home do
        Gori::Settings.env_vars = [{"TOKEN", "super-secret"}]
        doc = JSON.parse(Gori::Settings.export_document).as_h
        doc.has_key?("env").should be_false
        doc.has_key?("network").should be_true
      end
    end

    # Naming a secret section IS the consent to include it — there is no separate flag to
    # forget, and no way to leak one without having typed its name.
    it "includes a secret section when it is named explicitly" do
      with_config_home do
        Gori::Settings.env_vars = [{"TOKEN", "super-secret"}]
        doc = JSON.parse(Gori::Settings.export_document(["env"])).as_h
        doc.keys.should eq(["env"])
        doc["env"].to_json.should contain("super-secret")
      end
    end

    it "narrows to the named sections" do
      with_config_home do
        doc = JSON.parse(Gori::Settings.export_document(["network", "theme"])).as_h
        doc.keys.sort.should eq(["network", "theme"])
      end
    end
  end

  # Drives the export file's 0600. Must track what the document ACTUALLY carries, not just
  # what was named: warning on an `env`-named export of an empty env block would train the
  # operator to ignore the notice on the one that matters.
  describe ".exported_secret_sections" do
    it "is empty for the default export and for a non-secret selection" do
      with_config_home do
        Gori::Settings.env_vars = [{"TOKEN", "super-secret"}]
        Gori::Settings.exported_secret_sections.should be_empty
        Gori::Settings.exported_secret_sections(["network", "theme"]).should be_empty
      end
    end

    it "names the secret sections that are both selected AND non-empty" do
      with_config_home do
        Gori::Settings.env_vars = [{"TOKEN", "super-secret"}]
        Gori::Settings.exported_secret_sections(["env"]).should eq(["env"])
        Gori::Settings.exported_secret_sections(["network", "env"]).should eq(["env"])
      end
    end

    it "is empty when the named secret section has nothing in it (nothing to protect)" do
      with_config_home do
        Gori::Settings.env_vars = [] of {String, String}
        Gori::Settings.document_keys.should_not contain("env")
        Gori::Settings.exported_secret_sections(["env"]).should be_empty
      end
    end
  end

  describe ".import_preview" do
    it "reports only the sections that would actually change, plus unknown keys" do
      with_config_home do
        Gori::Settings.theme = "goridark"
        raw = %({"theme":"goriday","mouse":#{Gori::Settings.mouse},"bogus":{"a":1}})
        applicable, changed, unknown = Gori::Settings.import_preview(raw)
        applicable.should eq(["theme", "mouse"]) # both recognised, both would be applied
        changed.should contain("theme")
        changed.should_not contain("mouse") # identical to current → not a change
        unknown.should eq(["bogus"])
      end
    end

    # `applicable` is what BOTH `--dry-run` and the real run report, so the two commands agree
    # on the count. Reporting `changed` from one and `applied` from the other let a six-section
    # profile preview as "would apply 1 section(s)" and then import as "imported 6".
    it "returns the set a real import would apply, not just the differing subset" do
      with_config_home do
        Gori::Settings.theme = "goridark"
        raw = %({"theme":"goridark","network":{"bind_port":9999}})
        applicable, changed, _ = Gori::Settings.import_preview(raw)
        changed.should eq(["network"])             # theme already matches
        applicable.should eq(["theme", "network"]) # …but both are still applied
        Gori::Settings.import_document(raw).should eq(applicable)
      end
    end

    it "honours a section filter" do
      with_config_home do
        raw = %({"theme":"goriday","network":{"bind_port":9999}})
        _, changed, _ = Gori::Settings.import_preview(raw, ["network"])
        changed.should eq(["network"])
      end
    end
  end

  describe ".import_document" do
    # The core guarantee: a section the operator did not select is left alone.
    it "applies only the selected sections and leaves the rest untouched" do
      with_config_home do
        Gori::Settings.theme = "goridark"
        Gori::Settings.save
        raw = %({"theme":"goriday","network":{"bind_port":9191}})
        Gori::Settings.import_document(raw, ["network"])

        Gori::Settings.bind_port.should eq(9191)
        Gori::Settings.theme.should eq("goridark") # not selected → unchanged
        JSON.parse(File.read(Gori::Settings.path)).as_h["theme"].as_s.should eq("goridark")
      end
    end

    # The two halves of what "section" means here, pinned because the difference is exactly
    # what surprises: a LIST section replaces wholesale, an OBJECT-of-scalars section applies
    # key by key. Documented in cli.md; a drift in either direction is a silent data change.
    it "replaces a table section wholesale, including with an empty list" do
      with_config_home do
        Gori::Settings.upstream_rules = [
          Gori::Settings::UpstreamRule.new("*.corp", "http", "proxy:3128"),
        ]
        Gori::Settings.import_document(%({"upstream_rules":[{"host":"*.dev","kind":"direct"}]}))
        Gori::Settings.upstream_rules.map(&.host).should eq(["*.dev"])

        # An empty list is how a profile says "no rules" — it must clear, not be ignored.
        Gori::Settings.import_document(%({"upstream_rules":[]}))
        Gori::Settings.upstream_rules.should be_empty
      end
    end

    it "applies an object-of-scalars section key by key, keeping keys the profile omits" do
      with_config_home do
        Gori::Settings.bind_port = 9000
        Gori::Settings.upstream_proxy = ""
        # A team profile that pins ONLY the upstream must not reset the bind port it never
        # mentioned — that is why `network` merges rather than replacing.
        Gori::Settings.import_document(%({"network":{"upstream_proxy":"corp:3128"}}))
        Gori::Settings.upstream_proxy.should eq("corp:3128")
        Gori::Settings.bind_port.should eq(9000)
      end
    end

    it "runs the same tolerant per-section parse as a normal load" do
      with_config_home do
        # An out-of-range value falls back rather than failing the import — the behaviour
        # apply_sections already guarantees, reused rather than reimplemented.
        Gori::Settings.import_document(%({"network":{"http2":"h3","bind_port":8080}}))
        Gori::Settings.http2.should eq("auto")
        Gori::Settings.bind_port.should eq(8080)
      end
    end

    it "persists through save, leaving a parseable file on disk" do
      with_config_home do
        Gori::Settings.import_document(%({"network":{"bind_port":7171}}))
        on_disk = JSON.parse(File.read(Gori::Settings.path)).as_h
        on_disk["network"].as_h["bind_port"].as_i.should eq(7171)
      end
    end

    # A profile is meant to survive a round trip: export, import elsewhere, same values.
    it "round-trips an exported profile" do
      exported = ""
      with_config_home do
        Gori::Settings.upstream_proxy = "corp.test:3128"
        Gori::Settings.theme = "goriday"
        exported = Gori::Settings.export_document(["network", "theme"])
      end
      with_config_home do
        Gori::Settings.upstream_proxy.should eq("") # a genuinely fresh config
        Gori::Settings.import_document(exported)
        Gori::Settings.upstream_proxy.should eq("corp.test:3128")
        Gori::Settings.theme.should eq("goriday")
      end
    end
  end
end

# #594 fixed a settings loader that overwrote the operator's own file: one `as_i?` OverflowError
# aborted `apply_sections` partway, every section BELOW it kept its factory default, and the next
# `save` wrote those defaults to disk. The same failure was still reachable through a different
# coercion — `JSON::Any#[]?(String)` RAISES on a non-object ("Expected Hash for #[]?(key : String),
# not String"), and four sections dereferenced their node with no `as_h?` guard. `"editor": "nvim"`
# is enough, and `gori settings import` accepts such a profile after validating only the TOP level.
#
# `mine` is the probe: `parse_mine_prefs(root["mine"]?)` is declared AFTER all four guarded
# sections, so it is applied only if none of them aborted the pass.
describe "Settings.apply_sections — a non-object section must not abandon the rest" do
  {"editor", "network", "decoder", "rewriter"}.each do |section|
    {"\"not-an-object\"", "null", "42", "[1,2]"}.each do |bad|
      it "survives #{section} = #{bad} and still applies the sections after it" do
        with_config_home do
          prev = Gori::Settings.mine_concurrency
          begin
            Gori::Settings.mine_concurrency = 3
            Gori::Settings.import_document(%({"#{section}": #{bad}, "mine": {"concurrency": 7}}))
            Gori::Settings.mine_concurrency.should eq(7)
          ensure
            Gori::Settings.mine_concurrency = prev
          end
        end
      end
    end
  end

  it "still reads a well-formed editor and network section (regression guard)" do
    with_config_home do
      Gori::Settings.import_document(
        %({"editor": {"command": "nvim"}, "network": {"bind_port": 9123}, "theme": "goriday"}))
      Gori::Settings.editor.should eq("nvim")
      Gori::Settings.bind_port.should eq(9123)
      Gori::Settings.theme.should eq("goriday")
    end
  end
end

# `document_keys` is derived from `serialize`, so a section sitting at its factory default is
# absent from it. Using it as the VALIDITY oracle made a section's NAME valid or invalid
# depending on the machine: `gori settings export --sections network,scan_rules` — the example
# in docs/reference/cli.md — aborted with "unknown section(s): scan_rules" on any install where
# scan_rules was untouched, and `gori settings import` called a well-known section
# "unrecognised … ignored" and then applied it anyway. Settings::SECTION_KEYS is the static
# answer to "does gori know this name?"; these pin the two apart.
describe "Settings::SECTION_KEYS" do
  it "matches every key `serialize` can emit, in both directions" do
    with_every_section_populated do
      with_config_home do
        # The RETURN value matters as much as the on-disk keys: import_document filters
        # `selected` through SECTION_KEYS, so a name missing from the registry is silently
        # dropped on the way IN — it would never reach `apply_sections` and would never show up
        # in document_keys either, leaving the comparison below trivially satisfied.
        applied = Gori::Settings.import_document(MAXIMAL_PROFILE)
        applied.sort.should eq(Gori::Settings::SECTION_KEYS.sort)

        keys = Gori::Settings.document_keys
        # A section added to `serialize` without a SECTION_KEYS entry — the regression that
        # reintroduces the export abort and the bogus "unrecognised" warning.
        (keys - Gori::Settings::SECTION_KEYS).should be_empty
        # A SECTION_KEYS entry naming nothing real (a typo, or a section since removed), which
        # would advertise a name in `gori settings sections` that export then silently drops.
        (Gori::Settings::SECTION_KEYS - keys).should be_empty
      end
    end
  end

  it "still knows a section this install has never touched" do
    with_config_home do
      Gori::Settings.document_keys.should_not contain("scan_rules") # at its default → not serialized
      Gori::Settings::SECTION_KEYS.should contain("scan_rules")     # …but gori knows the name
    end
  end
end

describe "Settings.import_preview / import_document — recognised vs applied" do
  # The headline: a valid section at its factory default was reported "unrecognised … ignored"
  # and then written anyway. `env` is the sharp case — on a fresh config it is empty, so gori
  # told the operator the credential-bearing section had been ignored while writing the token
  # values to disk.
  it "does not call a valid-but-default section unrecognised, and counts it as applied" do
    with_config_home do
      raw = %({"env":{"vars":[{"key":"TOKEN","value":"leaked"}]}})
      applicable, changed, unknown = Gori::Settings.import_preview(raw, ["env"])
      unknown.should be_empty
      applicable.should eq(["env"])
      changed.should eq(["env"])

      Gori::Settings.import_document(raw, ["env"]).should eq(["env"])
      Gori::Settings.env_vars.should eq([{"TOKEN", "leaked"}])
    end
  end

  it "reports a genuinely unknown section AND leaves it out of the applied set" do
    with_config_home do
      raw = %({"network":{"bind_port":9191},"bogus":{"a":1}})
      applicable, changed, unknown = Gori::Settings.import_preview(raw)
      unknown.should eq(["bogus"])
      applicable.should eq(["network"]) # the unknown key is not offered for application
      changed.should eq(["network"])

      # "ignored" has to be TRUE: the key is dropped before apply_sections, so it reaches
      # neither the live settings nor the file, and the returned list is exactly what landed.
      Gori::Settings.import_document(raw).should eq(["network"])
      JSON.parse(File.read(Gori::Settings.path)).as_h.has_key?("bogus").should be_false
    end
  end
end

# The 3-way merge exists so persisting one field cannot discard a concurrent writer's edit to
# an unrelated one. It got EDITS right and DELETIONS wrong: a `disk_h[k]? || cur_v` fallback
# treated "the peer removed this section" as "the peer has nothing to say about it" and wrote
# our stale copy back. Sections vanish from `serialize` the moment they are emptied, so
# clearing your env vars in one gori window and saving anything in another resurrected the
# token values.
describe "Settings.save — merging against a concurrent writer" do
  it "honours a peer's deletion of a section this process did not change" do
    with_config_home do
      Gori::Settings.env_vars = [{"TOKEN", "super-secret"}]
      Gori::Settings.upstream_rules = [Gori::Settings::UpstreamRule.new("*.corp", "http", "proxy:3128")]
      Gori::Settings.save
      Gori::Settings.load # this read is the merge BASE

      # A peer clears both sections (they stop serializing) and changes something of its own.
      peer = JSON.parse(File.read(Gori::Settings.path)).as_h
      peer.delete("env")
      peer.delete("upstream_rules")
      peer["theme"] = JSON::Any.new("goriday")
      File.write(Gori::Settings.path, peer.to_pretty_json)

      Gori::Settings.mouse = !Gori::Settings.mouse # an unrelated change of ours
      Gori::Settings.save

      on_disk = JSON.parse(File.read(Gori::Settings.path)).as_h
      on_disk.has_key?("env").should be_false
      on_disk.has_key?("upstream_rules").should be_false
      on_disk["theme"].as_s.should eq("goriday") # their EDIT still merges through
    end
  end

  it "still lets a section THIS process changed win over disk" do
    with_config_home do
      Gori::Settings.save
      Gori::Settings.load
      peer = JSON.parse(File.read(Gori::Settings.path)).as_h
      peer.delete("env")
      peer["theme"] = JSON::Any.new("goriday")
      File.write(Gori::Settings.path, peer.to_pretty_json)

      # We add env AFTER loading, so mine != base for it — the deletion rule must not eat it.
      Gori::Settings.env_vars = [{"TOKEN", "ours"}]
      Gori::Settings.save

      on_disk = JSON.parse(File.read(Gori::Settings.path)).as_h
      on_disk["env"].to_json.should contain("ours")
      on_disk["theme"].as_s.should eq("goriday")
    end
  end
end

describe "Settings.import_document — absent mine/discover leave overlay prefs alone" do
  it "does not clear mine_prefs_saved when the profile omits mine" do
    with_config_home do
      Gori::Settings.save_mine_prefs(["query", "headers"], 12, "always")
      Gori::Settings.mine_prefs_saved?.should be_true
      Gori::Settings.mine_concurrency.should eq(12)
      # network-only import used to call parse_mine_prefs(nil) and wipe the saved flag.
      Gori::Settings.import_document(%({"network":{"bind_port":9199}}), ["network"])
      Gori::Settings.mine_prefs_saved?.should be_true
      Gori::Settings.mine_concurrency.should eq(12)
      Gori::Settings.mine_locations.should eq(["query", "headers"])
    end
  end

  it "does not clear discover_prefs_saved when the profile omits discover" do
    with_config_home do
      Gori::Settings.save_discover_prefs("strict", 3, 8, true, false, true, true)
      Gori::Settings.discover_prefs_saved?.should be_true
      Gori::Settings.import_document(%({"theme":"goriday"}), ["theme"])
      Gori::Settings.discover_prefs_saved?.should be_true
      Gori::Settings.discover_max_depth.should eq(3)
      Gori::Settings.discover_concurrency.should eq(8)
    end
  end
end
