require "../spec_helper"
require "file_utils"

# `gori settings env-syntax [bare|namespaced]` — the headless switch for the token grammar.
#
# A GLOBAL setting, so it lives under `gori settings` and not under `gori run project env`: that
# one writes the PROJECT database, and this decides how the tokens in every project are read.
#
# The verb has NO flags any more. It used to carry `--migrate` (plus `--dry-run` / `--project` /
# `--db` / `--all-projects`) because a switch only changed how stored bytes were READ; now every
# project re-spells itself the first time it opens (spec/env_migration_spec.cr) and the verb's
# whole job is to say so.
#
# Only the pure pieces are reachable from a spec — the verb's guards end in `abort`, which calls
# `exit` and is not catchable — so the decisions and the wording are exposed the way
# spec/cli_spec.cr exposes its own (`*_for_spec`), and the effect is asserted through
# `Settings`/the file it writes.
module Gori::CLI
  # `unknown_settings_verb?` is also exposed in spec/cli_spec.cr; a second wrapper under a
  # different name keeps these two files independent of each other's load order.
  def self.unknown_settings_verb_for_env_syntax_spec(args : Array(String)) : Bool
    unknown_settings_verb?(args)
  end

  def self.env_syntax_read_lines_for_spec : Array(String)
    env_syntax_read_lines
  end

  def self.env_syntax_write_lines_for_spec(was : Gori::Env::Syntax,
                                           now : Gori::Env::Syntax) : Array(String)
    env_syntax_write_lines(was, now)
  end

  def self.env_syntax_values_for_spec : String
    env_syntax_values
  end

  def self.env_syntax_origin_for_spec : String
    env_syntax_origin
  end

  def self.guessed_env_syntax_refusal_for_spec(was : Gori::Env::Syntax,
                                               want : Gori::Env::Syntax) : String?
    guessed_env_syntax_refusal(was, want)
  end
end

private def with_cli_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-cli-env-syntax")
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
    # they were, so without this the previous example's `"prefix": "%"` survives the restore below.
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    yield dir
  ensure
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
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

# Comments stripped, the way spec/peer_notices_spec.cr reads a wiring: the prose here names the
# flags, and a grep that matched its own explanation would pass forever.
private def cli_src(*parts : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", *parts)).lines
    .reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "gori settings env-syntax" do
  it "is a known settings verb, so a typo is still rejected" do
    Gori::CLI.unknown_settings_verb_for_env_syntax_spec(["env-syntax"]).should be_false
    Gori::CLI.unknown_settings_verb_for_env_syntax_spec(["env-syntax", "namespaced"]).should be_false
    Gori::CLI.unknown_settings_verb_for_env_syntax_spec(["env-sytnax"]).should be_true
  end

  it "names both values in its usage" do
    Gori::CLI.env_syntax_values_for_spec.should eq("bare|namespaced")
  end

  # The flags are GONE, in the parser and in the usage. Asserted by grep because every path that
  # would reject one ends in `abort`: the parser declares no `--migrate`, so OptionParser's
  # `invalid_option` is what an operator who types it now hits.
  it "declares no migration flags anywhere" do
    verb = cli_src("gori", "cli", "settings.cr")
    %w[--migrate --all-projects].each { |flag| verb.should_not contain(flag) }
    usage = cli_src("gori", "cli.cr")
    usage.should contain("gori settings env-syntax [bare|namespaced]")
    usage.lines.select(&.includes?("env-syntax")).each(&.should_not(contain("--migrate")))
  end

  it "prints the value and WHERE it came from" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      # No file at all: the grammar the absence rule settled, and the reason said out loud.
      Gori::Settings.load
      lines = Gori::CLI.env_syntax_read_lines_for_spec
      lines[0].should start_with("bare") # the suite pins what absence means; production is namespaced
      lines[0].should contain("does not exist")
      lines[1].should contain("$KEY")
      # No hint about a dry run any more: there is no flag to offer, and the thing an operator
      # reading this wants to know ("what happens to my projects?") is on the WRITE lines.
      lines.size.should eq(2)
      lines.each(&.should_not(contain("--migrate")))

      # A file that does not name the key: adopted for this run, which is NOT the same fact as
      # "the file says bare" — and reading it here means the write did not land.
      File.write(path, %({"theme":"gori"}))
      Gori::Settings.load
      Gori::CLI.env_syntax_read_lines_for_spec[0]
        .should eq("bare  (adopted for this run — #{path} does not set env.syntax)")

      File.write(path, %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      read = Gori::CLI.env_syntax_read_lines_for_spec
      read[0].should eq("namespaced  (from #{path})")
      read[1].should contain("$ENV.KEY")
      read[1].should contain("$BIND.NAME")
    end
  end

  it "spells the example with the operator's own prefix" do
    with_cli_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"namespaced","prefix":"%"}}))
      Gori::Settings.load
      Gori::CLI.env_syntax_read_lines_for_spec[1].should contain("%ENV.KEY")
    end
  end

  # THE sentence the switch owes the operator: the projects ARE re-spelled, but not here and not
  # now — each one when it is next opened. A running TUI or MCP server keeps the old spelling until
  # it is restarted, which is exactly why the line says "the next time it opens".
  it "says that each project is re-spelled the next time it opens" do
    with_cli_home do
      lines = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Bare,
        Gori::Env::Syntax::Namespaced)
      lines[0].should contain("env syntax: namespaced")
      lines[1].should contain("re-spelled the next time it opens")
      lines[1].should contain("backup")
      lines[1].should contain("evidence")
      lines[1].should contain("gori settings env-syntax bare")
      # Nothing about the old opt-in: there is no flag to run and no table to read first.
      lines.each(&.should_not(contain("--migrate")))
      lines[1].should_not contain("NOT rewritten")

      back = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Namespaced,
        Gori::Env::Syntax::Bare)
      back[1].should contain("gori settings env-syntax namespaced")
      # Setting the value it already has says so rather than promising a migration.
      same = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Bare,
        Gori::Env::Syntax::Bare)
      same.should eq(["env syntax: bare (unchanged)"])
    end
  end

  # The verb re-spells the GLOBAL rewrite rules itself, `from` the grammar in memory — so that
  # grammar has to be one the install SAID. `abort_on_degraded_settings!` catches the file-shaped
  # guesses; this is the one that leaves a perfectly loadable file behind: `env.syntax` is there and
  # names no grammar, so nothing says which way those replacements are spelled and re-spelling them
  # would rewrite traffic in every project in a direction picked by a typo.
  it "refuses to migrate the global rules from a GUESSED grammar" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, <<-JSON)
        {"env":{"syntax":"NAMESPACED!"},
         "rewriter":{"rules":[{"id":1,"enabled":true,"name":"auth","target":"request",
                               "part":"head","pattern":"X-A: .*","replacement":"X-A: $TOKEN",
                               "op":"replace","match_kind":"regex","host":"","body_file":""}]}}
        JSON
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Unreadable)
      was = Gori::Settings.env_syntax
      was.should eq(Gori::Env::Syntax::Bare) # the unreadable reading, not DEFAULT_ENV_SYNTAX

      msg = Gori::CLI.guessed_env_syntax_refusal_for_spec(was, Gori::Env::Syntax::Namespaced).not_nil!
      msg.should contain(path)                   # the file
      msg.should contain(%("NAMESPACED!"))       # the bad value, quoted as the file spells it
      msg.should contain("bare|namespaced")      # what it should have been
      msg.should contain("global rewrite rules") # why this verb in particular refuses
      msg.should contain("Fix or delete `env.syntax`")
      msg.should contain("then retry")
      # …and the rule is untouched, because the refusal lands before the re-spelling.
      Gori::Settings.rewriter_rules.map(&.replacement).should eq(["X-A: $TOKEN"])
      Dir.glob("#{path}.pre-*").should be_empty

      # The repair the message names is NOT refused: asking for the grammar gori is already reading
      # re-spells nothing (`was == want` skips the migration) and just writes the value down, so the
      # next run can move the grammar with the rules in hand.
      Gori::CLI.guessed_env_syntax_refusal_for_spec(was, was).should be_nil
    end
  end

  # A STATED grammar is not a guess, in either direction — the guard must not fire on the ordinary
  # switch it sits in front of.
  it "does not refuse when the grammar was stated" do
    with_cli_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"bare"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax_origin.should eq(Gori::Settings::EnvSyntaxOrigin::Stated)
      Gori::CLI.guessed_env_syntax_refusal_for_spec(Gori::Env::Syntax::Bare,
        Gori::Env::Syntax::Namespaced).should be_nil
    end
  end

  it "refuses a value that is not one of the two" do
    Gori::Env::Syntax.parse?("namespaced").should eq(Gori::Env::Syntax::Namespaced)
    Gori::Env::Syntax.parse?("bare").should eq(Gori::Env::Syntax::Bare)
    Gori::Env::Syntax.parse?("nampsaced").should be_nil
    Gori::Env::Syntax.parse?("").should be_nil
  end

  # The verb's effect, asserted through the state and the file it writes (the `puts` half is the
  # pure builder above).
  it "sets the grammar and persists it, in both directions" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.save.should be_true
      JSON.parse(File.read(path)).as_h["env"].as_h["syntax"].as_s.should eq("namespaced")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # …and back. The key STAYS, because an absence no longer means bare — it would be read as
      # "this file predates namespaces" and flip the opt-out back on the next start.
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.save.should be_true
      JSON.parse(File.read(path)).as_h["env"].as_h["syntax"].as_s.should eq("bare")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  # The one thing the verb still re-spells ITSELF: the global rewrite rules live in settings.json,
  # so no project open will ever reach them. Both directions, with the file copied aside first.
  it "re-spells the global rewrite rules on an explicit switch, both ways" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, <<-JSON)
        {"env":{"syntax":"bare","vars":[{"key":"TOKEN","value":"t"}]},
         "rewriter":{"rules":[{"id":1,"enabled":true,"name":"auth","target":"request",
                               "part":"head","pattern":"X-A: .*","replacement":"X-A: $TOKEN",
                               "op":"replace","match_kind":"regex","host":"","body_file":""}]}}
        JSON
      Gori::Settings.load
      report = Gori::EnvMigration.migrate_global_rules(from: Gori::Env::Syntax::Bare,
        to: Gori::Env::Syntax::Namespaced).not_nil!
      Gori::Settings.rewriter_rules.map(&.replacement).should eq(["X-A: $ENV.TOKEN"])
      report.backup.not_nil!.should start_with("#{path}.pre-namespaced-")

      # …and back, where the sigil in front of a resolvable name has to be ESCAPED or the rule
      # starts substituting into traffic nobody asked it to.
      Gori::Settings.rewriter_rules = [Gori::Settings.rewriter_rules[0]
        .copy_with(replacement: "X-A: $ENV.TOKEN $TOKEN")]
      Gori::EnvMigration.migrate_global_rules(from: Gori::Env::Syntax::Namespaced,
        to: Gori::Env::Syntax::Bare).not_nil!.tokens.should eq(2)
      Gori::Settings.rewriter_rules.map(&.replacement).should eq(["X-A: $TOKEN $$TOKEN"])
    end
  end
end
