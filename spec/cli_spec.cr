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
