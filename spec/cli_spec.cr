require "./spec_helper"

# Top-level `gori` dispatch (src/gori/cli.cr). Only the pure argv helpers are exercised
# here — CLI.run itself starts a TUI / server or calls `exit`, so it is not spec-callable.
#
# `global_version_flag?` is private; expose it the way the other CLI specs expose theirs
# (spec/cli/run/links_spec.cr does the same for resolve_link_ends / parse_link_id).
module Gori::CLI
  # Mirrors what CLI.run does: split off the top-level subcommand, then ask about the tail. Kept
  # at full-argv granularity so these cases read as real command lines.
  def self.global_version_flag_for_spec(argv : Array(String)) : Bool
    _, subargs = split_subcommand(argv)
    global_version_flag?(subargs)
  end

  # `gori settings` helpers. Only the PURE ones are reachable: the guards themselves end in
  # `abort`, which calls `exit` and is not catchable, so each of these is the decision the
  # abort is made on rather than the abort itself.
  def self.unknown_settings_verb_for_spec(args : Array(String)) : Bool
    unknown_settings_verb?(args)
  end

  def self.parse_sections_value_for_spec(value : String) : Array(String)
    parse_sections_value(value)
  end

  def self.unknown_sections_for_spec(list : Array(String)) : Array(String)
    unknown_sections(list)
  end
end

describe "gori — global version flag" do
  it "claims a version flag standing alone" do
    Gori::CLI.global_version_flag_for_spec(["-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["-V"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["--version"]).should be_true
  end

  it "claims a version flag against a TOP-LEVEL subcommand" do
    # print_main_help promises version/help work "at the top level too", and one non-flag
    # token — the top-level subcommand — is still the top level.
    Gori::CLI.global_version_flag_for_spec(["run", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["run", "--version"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["mcp", "-V"]).should be_true
    # CLI.run strips `--config PATH` before asking, so the PATH never counts against the
    # one-non-flag-token budget — `gori --config x.json tui -v` arrives here as ["tui", "-v"].
    Gori::CLI.global_version_flag_for_spec(["tui", "-v"]).should be_true
  end

  # The regression this helper exists for: a bare `-v` ANYWHERE in argv used to print the
  # version and return 0 without running the command — a silent no-op with a SUCCESS status.
  it "leaves a NESTED subcommand's own -v alone" do
    # rewriter add / preview document `-vVALUE, --value=VALUE`; this used to create no rule
    # and still exit 0.
    Gori::CLI.global_version_flag_for_spec(
      ["run", "rewriter", "add", "--op", "set_header", "--find", "X", "-v", "boom"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "rewriter", "preview", "-v", "x"]).should be_false
  end

  it "leaves a nested option VALUE that happens to be a version flag alone" do
    # These sent zero requests / encoded nothing, and reported success.
    Gori::CLI.global_version_flag_for_spec(
      ["run", "decoder", "base64-encode", "--input", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "fuzz", "--payloads", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "fuzz", "--payloads", "--version"]).should be_false
    Gori::CLI.global_version_flag_for_spec(
      ["run", "history", "--query", "-V"]).should be_false
  end

  it "does not claim a version flag once a nested subcommand has been named" do
    Gori::CLI.global_version_flag_for_spec(["run", "capture", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "show", "1", "--version"]).should be_false
  end

  # Regression: keying on subargs[0] ALONE was too narrow. A version flag after a top-level
  # subcommand's own flag reached that subcommand's parser and aborted with "unknown option",
  # while `--help` in the same position worked because every parser owns `-h` — and
  # print_main_help plus docs/reference/cli.md both promise version works at the top level.
  it "claims a version flag after a top-level subcommand's own flags" do
    Gori::CLI.global_version_flag_for_spec(["mcp", "--read-only", "--version"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["ca", "--pem", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["tui", "--insecure-upstream", "-V"]).should be_true
  end

  # The scan stops dead at the first bare word, because that word is a nested verb and owns
  # everything after it. This is what keeps every case from the original bug excluded.
  it "stops at the first bare word, so a nested verb owns its own flags" do
    Gori::CLI.global_version_flag_for_spec(["run", "oast", "listen", "--version"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "probe", "rules", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "issues", "create", "-v", "x"]).should be_false
  end

  # KNOWN RESIDUAL, pinned so it is a decision and not a surprise: a `-v` that is the VALUE of a
  # top-level flag still reads as the flag, because telling a value from a flag needs to know
  # which flags take values, and that lives in each subcommand's OptionParser. Accepted because
  # it only misfires on input that is already invalid (`gori run --project x` is not a
  # subcommand either), whereas excluding it broke `gori mcp --read-only --version` above.
  it "still misreads a version flag used as a top-level flag's value" do
    Gori::CLI.global_version_flag_for_spec(["run", "--project", "-v"]).should be_true
    Gori::CLI.global_version_flag_for_spec(["tui", "--db", "-v"]).should be_true
  end

  it "is false when there is no version flag at all" do
    Gori::CLI.global_version_flag_for_spec([] of String).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "history"]).should be_false
    # A near-miss must not match: only the exact tokens count.
    Gori::CLI.global_version_flag_for_spec(["--verbose"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["-vv"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "decoder", "--input", "-vsomething"]).should be_false
  end
end

# `gori settings` argv guards. Each one closes a silent-no-op-carrying-SUCCESS hole — the
# failure mode the `global_version_flag?` comment above condemns at length, which `gori
# settings` was reproducing on a typo'd verb, an empty `--sections`, and a misspelt one.
describe "gori settings — subcommand dispatch" do
  it "rejects a bare word that is not one of the three verbs" do
    # `gori settings expor -o profile.json` used to print the settings path and exit 0: no
    # export, no file, and `… || die` never fires.
    Gori::CLI.unknown_settings_verb_for_spec(["expor"]).should be_true
    Gori::CLI.unknown_settings_verb_for_spec(["expor", "-o", "p.json"]).should be_true
    Gori::CLI.unknown_settings_verb_for_spec(["blahblah", "nonsense"]).should be_true
  end

  it "accepts the three verbs and every flag-only form" do
    Gori::CLI.unknown_settings_verb_for_spec(["export"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["import", "p.json"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["sections"]).should be_false
    # Bare `gori settings`, and the flag forms it has always taken.
    Gori::CLI.unknown_settings_verb_for_spec([] of String).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["--edit"]).should be_false
    Gori::CLI.unknown_settings_verb_for_spec(["-h"]).should be_false
  end
end

describe "gori settings — --sections parsing" do
  it "trims and drops empties" do
    Gori::CLI.parse_sections_value_for_spec("network, theme ").should eq(["network", "theme"])
    Gori::CLI.parse_sections_value_for_spec("network,,theme").should eq(["network", "theme"])
  end

  # The caller aborts on an empty result. It has to check emptiness explicitly: `[] of String`
  # is TRUTHY in Crystal, so `if list = sections` used to pass with nothing in it, and
  # `--sections=""` exported `{}` / imported nothing at exit 0 — where a shell expanding an
  # unset variable lands.
  it "yields nothing for an empty or all-comma value" do
    Gori::CLI.parse_sections_value_for_spec("").should be_empty
    Gori::CLI.parse_sections_value_for_spec(",,,").should be_empty
    Gori::CLI.parse_sections_value_for_spec("  ").should be_empty
  end
end

describe "gori settings — section-name validation" do
  # Static SECTION_KEYS, never `document_keys`: a section at its factory default is absent from
  # the latter, which is how `--sections network,scan_rules` (the example in the CLI reference)
  # aborted as "unknown" on every fresh install.
  it "accepts a known section this install has no value for" do
    Gori::CLI.unknown_sections_for_spec(["network", "scan_rules"]).should be_empty
    Gori::CLI.unknown_sections_for_spec(Gori::Settings::SECTION_KEYS).should be_empty
  end

  it "names the ones gori does not know" do
    # Import used not to validate at all, so `--sections netwrok` selected nothing and reported
    # "imported 0 section(s)" with exit 0.
    Gori::CLI.unknown_sections_for_spec(["netwrok"]).should eq(["netwrok"])
    Gori::CLI.unknown_sections_for_spec(["network", "bogus", "theme"]).should eq(["bogus"])
  end
end

describe "gori ca — leftover positionals" do
  # The one that bit: `gori ca --ca-dir=DIR regenerate`. A verb is recognised in FIRST position
  # only, so behind a flag it reached the show path, where the parser DISCARDED it — gori printed
  # the CA path and exited 0, having regenerated nothing, in output identical to a successful
  # `gori ca`. Same shape as Run.list_leftover_error, for the same reason.
  it "names the ordering when a verb was written after the flags" do
    msg = Gori::CLI.ca_leftover_error("ca", ["regenerate"])
    msg.should_not be_nil
    msg.not_nil!.should contain("must come FIRST")
    msg.not_nil!.should contain("nothing was regenerated")
    Gori::CLI.ca_leftover_error("ca", ["import"]).not_nil!.should contain("nothing was imported")
  end

  it "rejects a stray word on every ca command" do
    # `gori ca regenerate --yes bogusword` regenerated and ignored the word; `gori ca --pem
    # strayword` printed the PEM and ignored it. Neither is a typo worth guessing at.
    Gori::CLI.ca_leftover_error("ca", ["strayword"]).not_nil!.should contain("unexpected argument")
    Gori::CLI.ca_leftover_error("ca", ["strayword"]).not_nil!.should contain("verbs: regenerate, import")
    Gori::CLI.ca_leftover_error("ca regenerate", ["bogusword"]).not_nil!
      .should contain("`gori ca regenerate` takes no positional arguments")
    Gori::CLI.ca_leftover_error("ca import", ["STRAY"]).not_nil!.should contain("unexpected argument")
  end

  it "does not name the verbs where they are not accepted" do
    # `gori ca regenerate import` is not an ordering mistake, and the show path's verb list
    # would be a false lead there.
    Gori::CLI.ca_leftover_error("ca regenerate", ["import"]).not_nil!.should_not contain("verbs:")
    Gori::CLI.ca_leftover_error("ca regenerate", ["import"]).not_nil!.should_not contain("must come FIRST")
  end

  it "passes an empty leftover through" do
    Gori::CLI.ca_leftover_error("ca", [] of String).should be_nil
    Gori::CLI.ca_leftover_error("ca regenerate", [] of String).should be_nil
  end
end
