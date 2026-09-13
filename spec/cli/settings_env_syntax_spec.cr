require "../spec_helper"
require "file_utils"

# `gori settings env-syntax [bare|namespaced]` — the headless switch for the token grammar.
#
# A GLOBAL setting, so it lives under `gori settings` and not under `gori run project env`: that
# one writes the PROJECT database, and this decides how the tokens in every project are read.
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
end

private def with_cli_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-cli-env-syntax")
  Dir.mkdir_p(dir)
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
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
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

  it "prints the value and WHERE it came from" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      # No file at all: the default, and the reason said out loud.
      Gori::Settings.load
      lines = Gori::CLI.env_syntax_read_lines_for_spec
      lines[0].should start_with("bare")
      lines[0].should contain("default")
      lines[1].should contain("$KEY")

      # A file that does not name the key: still the default, and still not the same fact as
      # "the file says bare" — which is the whole reason the origin is printed.
      File.write(path, %({"theme":"gori"}))
      Gori::Settings.load
      Gori::CLI.env_syntax_read_lines_for_spec[0].should eq("bare  (default — #{path} does not set env.syntax)")

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

  it "says that stored tokens are NOT rewritten, and how to switch back" do
    with_cli_home do
      lines = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Bare,
        Gori::Env::Syntax::Namespaced)
      lines[0].should contain("env syntax: namespaced")
      lines[1].should contain("NOT rewritten")
      lines[1].should contain("gori settings env-syntax bare")
      back = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Namespaced,
        Gori::Env::Syntax::Bare)
      back[1].should contain("gori settings env-syntax namespaced")
      # Setting the value it already has says so rather than repeating the warning.
      same = Gori::CLI.env_syntax_write_lines_for_spec(Gori::Env::Syntax::Bare,
        Gori::Env::Syntax::Bare)
      same.should eq(["env syntax: bare (unchanged)"])
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
  it "sets the grammar and persists it" do
    with_cli_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.save.should be_true
      JSON.parse(File.read(path)).as_h["env"].as_h["syntax"].as_s.should eq("namespaced")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # …and back, which must leave the key behind rather than an absence that means the same
      # thing (`serialize_env` drops the whole section once there is nothing left to say).
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.save.should be_true
      JSON.parse(File.read(path)).as_h.has_key?("env").should be_false
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end
end
