require "./spec_helper"
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
    FileUtils.rm_rf(dir)
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
        changed, unknown = Gori::Settings.import_preview(raw)
        changed.should contain("theme")
        changed.should_not contain("mouse") # identical to current → not a change
        unknown.should eq(["bogus"])
      end
    end

    it "honours a section filter" do
      with_config_home do
        raw = %({"theme":"goriday","network":{"bind_port":9999}})
        changed, _ = Gori::Settings.import_preview(raw, ["network"])
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
