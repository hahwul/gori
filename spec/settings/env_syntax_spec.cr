require "../spec_helper"
require "file_utils"

# `env.syntax` — which token grammar an install reads and writes.
#
# The rule, in one sentence: NAMESPACED is the grammar for everyone, and the ABSENCE of the key on a
# settings file read in full is not a grammar — it means the file PREDATES namespaces. So absence is
# a migration: the global rewrite rules are re-spelled (a copy of settings.json kept beside it, and
# the one thing that makes the load save) and every project re-spells itself the first time it opens
# (spec/env_migration_spec.cr). The KEY itself is not written by the load — a load is a read — it
# rides out on the next ordinary save. `bare` stays as an explicit opt-out, and because it is
# explicit the key is ALWAYS serialized: a grammar nobody wrote down is a grammar that gets
# re-derived.
#
# Every example runs in its own temp home and restores the process-global settings through a load
# of their serialization (the same discipline as reset_spec).
private def with_syntax_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  prev_absent = Gori::Settings.env_syntax_when_absent
  dir = File.tempname("gori-env-syntax")
  Dir.mkdir_p(dir)
  # The GLOBAL rewrite rules are class state `Settings.load` only overwrites when the file has a
  # `rewriter` section: a restore that loads a snapshot without one keeps the rules an example
  # migrated in place, and they then leak into every later spec file of the shard.
  prev_rules = Gori::Settings.rewriter_rules
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    # `load` is TOLERANT: a file with no `env` section leaves the prefix and the vars exactly as
    # they were, and `export_document` omits an empty `env` — so without this the previous
    # example's `"prefix": "%"` survives the restore below and decides whether the section
    # serializes at all.
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    yield dir
  ensure
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.env_syntax_when_absent = prev_absent
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    Gori::Settings.rewriter_rules = prev_rules
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

private def env_section(path : String) : Hash(String, JSON::Any)?
  JSON.parse(File.read(path)).as_h["env"]?.try(&.as_h)
end

describe "Settings env.syntax" do
  it "round-trips through the file, and always writes the key" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.save.should be_true
      env_section(path).should eq({"syntax" => JSON::Any.new("namespaced")})
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_vars = [{"HOST", "h"}]
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  # THE new absence rule. The key is not missing because the install chose bare — it is missing
  # because the file was written before namespaces existed, which is a MIGRATION and not a value.
  it "reads the ABSENCE of the key as pre-namespace and adopts namespaced IN MEMORY" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      File.write(path, %({"theme":"gori","env":{"vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_vars.should eq([{"A", "1"}])
      # NOT written by the load. A load is a read: with no global rule to re-spell there is nothing
      # that has to be persisted, and a `save` from inside `load` is the thing that used to skip the
      # TUI's first-run wizard and create directories for a `--config` that does not exist.
      env_section(path).not_nil!.has_key?("syntax").should be_false
      # The origin of THIS run is still the absence that settled it — and an absence read out of a
      # file gori got in full is authoritative, which is what lets the projects be re-spelled.
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Absent)
      Gori::Settings.env_syntax_stated?.should be_true
      Gori::Settings.take_env_syntax_global_migration.should be_nil # no global rule to re-spell
      # The key rides out on the next ordinary save, because `serialize_env` always emits it — and
      # from then on the question is a STATED grammar rather than a re-derived one.
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("namespaced")
      Gori::Settings.load
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Stated)
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # …and the rest of the operator's file survived the write.
      JSON.parse(File.read(path)).as_h["theme"].as_s.should eq("gori")
    end
  end

  # A load may not bring a settings.json into existence. The TUI's first-run wizard is gated on
  # `File.exists?(Settings.path)` (app.cr), so the adopt-on-absence path writing the file made the
  # very first `gori` on a fresh machine skip the wizard — and the same write created the parent
  # directory of a `--config` that names nothing during read-only commands.
  it "writes NO settings.json at all on a fresh home" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Absent)
      File.exists?(File.join(dir, "settings.json")).should be_false
    end
  end

  # The GLOBAL rewrite rules are the half no project open can reach: they live in settings.json and
  # rewrite traffic in EVERY project, so the load that adopts the grammar re-spells them — after
  # copying the file aside, because nothing else would give the operator a way back.
  it "re-spells the global rewrite rules on the absence path, keeping a backup" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      File.write(path, <<-JSON)
        {"env":{"vars":[{"key":"TOKEN","value":"t"}]},
         "rewriter":{"rules":[{"id":1,"enabled":true,"name":"auth","target":"request",
                               "part":"head","pattern":"X-A: .*","replacement":"X-A: $TOKEN",
                               "op":"replace","match_kind":"regex","host":"","body_file":""}]}}
        JSON
      Gori::Settings.load
      Gori::Settings.rewriter_rules.map(&.replacement).should eq(["X-A: $ENV.TOKEN"])
      # …persisted, not just in memory.
      JSON.parse(File.read(path)).as_h["rewriter"].as_h["rules"].as_a[0].as_h["replacement"]
        .as_s.should eq("X-A: $ENV.TOKEN")
      # The report is PULLED by whichever surface is about to speak, and cleared so a second one
      # does not repeat it.
      report = Gori::Settings.take_env_syntax_global_migration.not_nil!
      report.tokens.should eq(1)
      report.rules.should eq(1)
      report.line.should contain("global rewrite rules: 1 token re-spelled to $ENV.KEY/$BIND.NAME")
      Gori::Settings.take_env_syntax_global_migration.should be_nil
      backup = report.backup.not_nil!
      backup.should start_with("#{path}.pre-namespaced-")
      # A copy of the file BEFORE the rewrite, so the way back is a diff away.
      JSON.parse(File.read(backup)).as_h["rewriter"].as_h["rules"].as_a[0].as_h["replacement"]
        .as_s.should eq("X-A: $TOKEN")
    end
  end

  # A rule the rewrite does not touch earns no backup and no line: a `$1` backref and a `$$` are
  # `Rules#substitute`'s in both grammars, and a name in neither table is a literal in both.
  it "says nothing and copies nothing when no global rule holds a token" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      File.write(path, <<-JSON)
        {"rewriter":{"rules":[{"id":1,"enabled":true,"name":"n","target":"request",
                               "part":"body","pattern":"(a)","replacement":"$1 $$ $ne",
                               "op":"replace","match_kind":"regex","host":"","body_file":""}]}}
        JSON
      Gori::Settings.load
      Gori::Settings.rewriter_rules.map(&.replacement).should eq(["$1 $$ $ne"])
      Gori::Settings.take_env_syntax_global_migration.should be_nil
      Dir.glob(File.join(dir, "settings.json.pre-*")).should be_empty
    end
  end

  # The opt-out, and the reason the key is always written: a `bare` that serialized as ABSENCE would
  # be re-derived — and re-spelled — on the very next start.
  it "honours an explicit bare, and keeps writing it" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      File.write(path, %({"env":{"syntax":"bare","vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Stated)
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("bare")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  it "does not leak one home's grammar into the NEXT home loaded in one process" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
    end
    # A second home, bare, loaded by the same process — the project picker and `--config` both do
    # exactly this.
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  # A typo is not a date. The value is there and unreadable, so gori reads tokens as BARE — the
  # reading a wrong guess cannot lose data over, and the one the unreadable-FILE sibling already
  # picks — and REWRITES NOTHING. The absence path would have re-spelled every project against a
  # guess, and `DEFAULT_ENV_SYNTAX` here would have read every stored bare `$KEY` as literal text.
  it "warns on an unknown value, stays bare, and re-spells nothing" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"NAMESPACED!"}}))
      io = IO::Memory.new
      prev = Gori::Settings.warning_io
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      begin
        Gori::Settings.load
      ensure
        Gori::Settings.warning_io = prev
      end
      Gori::Settings.env_syntax.should eq(Gori::Settings::UNREADABLE_ENV_SYNTAX)
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Unreadable)
      Gori::Settings.env_syntax_stated?.should be_false
      io.to_s.should contain("env.syntax")
      io.to_s.should contain("reading tokens as bare")
    end
  end

  it "writes nothing at all when absence resolves to the bare opt-out" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Bare
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      # The suite's own pin, and the contract it rests on: a spec home grows no settings.json, and
      # a store opened under it finds a marker (absent = bare) that already agrees.
      File.exists?(File.join(dir, "settings.json")).should be_false
    end
  end

  # `used_before?` is gone. A home full of projects adopts namespaced like any other — the projects
  # are what `EnvMigration.reconcile` re-spells, one at a time, as they open.
  it "adopts namespaced even when the home already holds project databases" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      Dir.mkdir_p(File.join(dir, "projects", "acme"))
      File.write(File.join(dir, "projects", "acme", "gori.db"), "")
      File.write(File.join(dir, "gori.db"), "")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # …and still writes nothing: the projects are re-spelled at their own open, one at a time.
      File.exists?(File.join(dir, "settings.json")).should be_false
    end
  end

  # A settings file that IS there and could not be read: its `env.syntax` may well say bare, and
  # adopting the other grammar would reinterpret — and then REWRITE — every token in every project
  # of an install that has hit a permissions problem.
  it "stays bare, and stated-false, when a settings file exists but cannot be read" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      path = File.join(dir, "settings.json")
      Dir.mkdir_p(path) # a directory where the file should be: `load_raw` rescues, reads nothing
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_stated?.should be_false
    ensure
      Dir.delete(File.join(dir, "settings.json")) rescue nil
    end
  end

  # An absence at the HOME-DERIVED default path is a date gori may act on. An absence at a path the
  # operator TYPED is a typo, and acting on it re-spells the real install's projects against a file
  # gori never read — which the next ordinary run (reading the real `bare` again) reverses lossily.
  it "does not read a nonexistent --config as a fresh home" do
    with_syntax_home do |dir|
      # The real home says bare, with a global rule spelling a token the bare way.
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.env_vars = [{"API", "k"}]
      Gori::Settings.rewriter_rules = [Gori::Settings::RewriterRule.new(1_i64, true, "k",
        "request", "head", "X-Key: .*", "X-Key: $API", "replace", "regex", "", "")]
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced

      io = IO::Memory.new
      prev = Gori::Settings.warning_io
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      missing = File.join(dir, "typo.json")
      begin
        Gori::Settings.path_override = missing
        Gori::Settings.load
      ensure
        Gori::Settings.warning_io = prev
        Gori::Settings.path_override = nil
      end
      # Bare, not the adopted grammar, and nothing may be re-spelled off it.
      Gori::Settings.env_syntax.should eq(Gori::Settings::UNREADABLE_ENV_SYNTAX)
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_stated?.should be_false
      # No global migration, and the rule's bytes are exactly as the operator left them.
      Gori::Settings.take_env_syntax_global_migration.should be_nil
      Gori::Settings.rewriter_rules[0].replacement.should eq("X-Key: $API")
      # And no `settings.json.pre-namespaced-*` copy beside a file that was never rewritten.
      Dir.glob(File.join(dir, "*.pre-namespaced-*")).should be_empty
      # One line, and it names the path the operator typed.
      io.to_s.should contain(missing)
      io.to_s.should contain("reading tokens as bare")
    ensure
      # `with_syntax_home`'s restore replays a document that may carry no `rewriter` section at
      # all, and `load` is tolerant of an absent one — so this list has to be dropped by hand or
      # it outlives the example.
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    end
  end

  it "reads a nonexistent $GORI_CONFIG the same way, and an absent DEFAULT path as a date" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      begin
        ENV["GORI_CONFIG"] = File.join(dir, "nope.json")
        Gori::Settings.reset_load_warning_guard
        Gori::Settings.load
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
        Gori::Settings.env_syntax_stated?.should be_false
        Gori::Settings.load_warning.not_nil!.should contain("nope.json")
      ensure
        ENV.delete("GORI_CONFIG")
      end
      # The SAME home with no explicit path: absence is a date, adopted and stated.
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Absent)
      Gori::Settings.env_syntax_stated?.should be_true
    end
  end

  # An explicitly named file that EXISTS and simply has no `env.syntax` is the pre-namespace
  # headless install: adopting and re-spelling is the whole upgrade, and the explicit path changes
  # nothing about it.
  it "still adopts when an explicitly named file exists without the key" do
    with_syntax_home do |dir|
      cfg = File.join(dir, "elsewhere.json")
      File.write(cfg, %({"theme":"gori"}))
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      begin
        Gori::Settings.path_override = cfg
        Gori::Settings.load
      ensure
        Gori::Settings.path_override = nil
      end
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_syntax_stated?.should be_true
    end
  end

  it "re-spells nothing when the file is unparseable" do
    with_syntax_home do |dir|
      Gori::Settings.env_syntax_when_absent = Gori::Env::Syntax::Namespaced
      File.write(File.join(dir, "settings.json"), "{not json")
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax_stated?.should be_false
      Gori::Settings.take_env_syntax_global_migration.should be_nil
    end
  end

  # An unparseable file does NOT downgrade a namespaced install. `save` stays armed on that path and
  # a `serialize_env` that omitted the section would be read by the next start as "predates
  # namespaces" — a re-derivation over a file the operator can still see the grammar in. So it is
  # recovered textually: the tear is somewhere in a document that is mostly rule tables, and the env
  # section is three keys.
  it "recovers the grammar TEXTUALLY from an unparseable file and does not re-derive it" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"theme":"gori","env":{"syntax":"bare"},"rewriter":{"rules":[{)) # torn
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      # Recovered for READING, never for rewriting: a torn file is not a file gori may re-spell a
      # project against.
      Gori::Settings.env_syntax_stated?.should be_false
      # The defect was the NEXT write, not the read: a save from this state used to persist the
      # absence of the key and make the flip permanent.
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("bare")
      # The corrupt copy is still kept, and its warning still names the file.
      File.exists?("#{path}.corrupt").should be_true
      Gori::Settings.load_warning.not_nil!.should contain("not valid JSON")
    end
  end

  # The two halves of a TORN file, and the line where it tears is what decides them. `save` stays
  # ARMED on this path (nothing was applied from disk, so the next write is a deliberate clean one),
  # which is why the VALUE this leaves in memory is the value the repaired file ends up carrying.
  it "reads a file truncated BEFORE the env section as bare, and writes bare" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      # A namespaced install whose file tears above the env section. Nothing in the bytes says which
      # grammar it speaks, so gori knows it does not know — and bare is the reading a wrong guess
      # cannot lose data over, since a name in neither table is a literal in both grammars.
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      File.write(path, %({"theme":"gori","network":{"bind_port":8080,))
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_stated?.should be_false # nothing is re-spelled off a torn file
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("bare")
    end
  end

  it "recovers the grammar from a file truncated AFTER the env section" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"env":{"syntax":"namespaced"},"listeners":[{"port":1,))
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.env_syntax_stated?.should be_false
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  it "says so when an unparseable file does not spell the grammar either" do
    with_syntax_home do |dir|
      # A bare home first, in the same process — the value this must not leave behind.
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)

      io = IO::Memory.new
      prev = Gori::Settings.warning_io
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      begin
        File.write(File.join(dir, "settings.json"), %({"theme":"gori","network":{)) # no grammar in it
        Gori::Settings.load
      ensure
        Gori::Settings.warning_io = prev
      end
      # BARE, not the default: a torn file with no grammar in it is the state where gori knows it
      # does not know, and reading it as namespaced made every stored bare `$KEY` literal text.
      Gori::Settings.env_syntax.should eq(Gori::Settings::UNREADABLE_ENV_SYNTAX)
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      # …and `save` stays armed on this path, so the value it WRITES is the one that matters: a
      # namespaced fallback here upgraded a bare install permanently, from a comma.
      Gori::Settings.save.should be_true
      env_section(Gori::Settings.path).not_nil!["syntax"].as_s.should eq("bare")
      # ONE line (the warning guard fires once per process), carrying both facts.
      io.to_s.lines.size.should eq(1)
      io.to_s.should contain("not valid JSON")
      io.to_s.should contain("token grammar")
      io.to_s.should contain("gori settings env-syntax")
    end
  end

  # PRESENT but not a string is the typo path, not the absence path: `parse_env` can only assign
  # from a string, so a guard keyed on "is the key there?" would read a `null` as "predates
  # namespaces" and re-spell every project against it.
  it "reads a non-string syntax as unreadable — the default, with a warning, and no migration" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)

      io = IO::Memory.new
      prev = Gori::Settings.warning_io
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      begin
        File.write(File.join(dir, "settings.json"), %({"env":{"syntax":null}}))
        Gori::Settings.load
      ensure
        Gori::Settings.warning_io = prev
      end
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax_stated?.should be_false
      io.to_s.should contain("env.syntax")
    end
  end

  it "reads a NUMBER there the same way" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":1,"vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax_stated?.should be_false
      Gori::Settings.env_vars.should eq([{"A", "1"}]) # the rest of the section still applied
    end
  end

  # The reason the absence rule may NOT live in `parse_env`: an import reuses `apply_sections`
  # over a FILTERED document, so a theme-only profile would otherwise re-derive the grammar.
  it "an import that does not mention env leaves the grammar alone" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.import_document(%({"theme":"goriday"})).should eq(["theme"])
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      env_section(File.join(dir, "settings.json")).not_nil!["syntax"].as_s.should eq("bare")
    end
  end

  # An imported profile NEVER decides the grammar: it decides how the tokens already stored in
  # THIS install's projects are read, and a teammate's export does not speak for those. The
  # import says so on STDERR and points at `gori settings env-syntax`.
  it "an env import does not change the grammar, with or without a syntax key" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      Gori::Settings.import_document(%({"env":{"vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.import_document(%({"env":{"syntax":"bare","vars":[{"key":"B","value":"2"}]}}))
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # The rest of the section applied, so the refusal is scoped to the one key…
      Gori::Settings.env_vars.should eq([{"B", "2"}])
      # …and the grammar it did not flip is still what the file says, so a restart agrees.
      env_section(path).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  # The other direction: a BARE opt-out cannot be silently upgraded either.
  it "an env import cannot flip a bare install to namespaced" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.import_document(%({"env":{"syntax":"namespaced"}}))
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      env_section(path).not_nil!["syntax"].as_s.should eq("bare")
    end
  end

  # An EXPORT still carries no grammar, in either direction: a profile that named one would flip the
  # importing install's reading of its own stored tokens.
  it "always serializes the key, and never exports it" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"A", "1"}]
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("bare")
      Gori::Settings.export_document(["env"]).should_not contain("syntax")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  # An export whose `env` section is NOTHING BUT the grammar carries no env section at all — and an
  # `env` node that says nothing about vars leaves the importer's vars alone.
  #
  # These are the two halves of one data loss. `serialize_env` always writes `syntax`, so a var-less
  # install's whole section is the grammar; `export_document` strips the grammar; what shipped was
  # the literal document `{"env":{}}`, and `parse_env` read the absent `vars` key as an empty table —
  # so importing a teammate's theme-and-env profile emptied the importer's global env var table,
  # token VALUES included, over a profile that mentioned no variable.
  it "an env section that is only the grammar is not exported, and an empty one erases nothing" do
    with_syntax_home do
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [] of {String, String}
      doc = Gori::Settings.export_document(["env"])
      JSON.parse(doc).as_h.has_key?("env").should be_false

      # The other half, pinned directly: the document that USED to ship must still not erase vars.
      Gori::Settings.env_vars = [{"TOKEN", "sekrit"}, {"HOST", "h"}]
      Gori::Settings.import_document(%({"env":{}}))
      Gori::Settings.env_vars.should eq([{"TOKEN", "sekrit"}, {"HOST", "h"}])
      # …and the profile that DOES say "no vars" still says it.
      Gori::Settings.import_document(%({"env":{"vars":[]}}))
      Gori::Settings.env_vars.should be_empty
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  # The round trip the two halves above exist for: a var-less install's profile, imported onto an
  # install that HAS vars, is a no-op on those vars.
  it "an export from a var-less install does not wipe the importer's vars" do
    doc = nil.as(String?)
    with_syntax_home do
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [] of {String, String}
      doc = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
    end
    with_syntax_home do
      Gori::Settings.load
      Gori::Settings.env_vars = [{"TOKEN", "sekrit"}]
      Gori::Settings.save.should be_true
      Gori::Settings.import_document(doc.not_nil!)
      Gori::Settings.env_vars.should eq([{"TOKEN", "sekrit"}])
      Gori::Settings.load
      Gori::Settings.env_vars.should eq([{"TOKEN", "sekrit"}])
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  it "a factory reset PRESERVES the grammar" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"),
        %({"theme":"goriday","env":{"syntax":"namespaced","vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.load
      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)
      # The vars and the prefix are DATA and go; the grammar decides how tokens already stored in
      # project databases are read, and a settings reset does not speak for those.
      Gori::Settings.env_vars.should be_empty
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      env_section(File.join(dir, "settings.json")).should eq({"syntax" => JSON::Any.new("namespaced")})
    end
  end

  # A vars-less install writes `env` — a GRAMMAR, not a credential. Firing the "this file holds
  # secrets" notice over it trains the operator to ignore it.
  it "exported_secret_sections ignores an env section that holds no vars" do
    with_syntax_home do
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.document_keys.includes?("env").should be_true
      Gori::Settings.exported_secret_sections(["env"]).should be_empty
      Gori::Settings.env_vars = [{"TOKEN", "v"}]
      Gori::Settings.exported_secret_sections(["env"]).should eq(["env"])
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  # The 3-way merge asks "did I change this section?". The grammar must survive a peer's write to an
  # unrelated section.
  it "survives a merge against a peer's concurrent write" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      # A peer rewrites the file between our load and our save, touching another section.
      File.write(path, %({"theme":"goriday","env":{"syntax":"namespaced"}}))
      Gori::Settings.mouse = false
      Gori::Settings.save.should be_true
      doc = JSON.parse(File.read(path)).as_h
      doc["theme"].as_s.should eq("goriday") # the peer's edit survived
      doc["env"].as_h["syntax"].as_s.should eq("namespaced")
    end
  end
end
