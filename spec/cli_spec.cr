require "./spec_helper"

# Top-level `gori` dispatch (src/gori/cli.cr). Only the pure argv helpers are exercised
# here — CLI.run itself starts a TUI / server or calls `exit`, so it is not spec-callable.
#
# `global_version_flag?` is private; expose it the way the other CLI specs expose theirs
# (spec/cli/run/links_spec.cr does the same for resolve_link_ends / parse_link_id).
module Gori::CLI
  def self.global_version_flag_for_spec(argv : Array(String)) : Bool
    global_version_flag?(argv)
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

  it "does not claim a version flag once any second non-flag token has appeared" do
    Gori::CLI.global_version_flag_for_spec(["run", "capture", "-v"]).should be_false
    Gori::CLI.global_version_flag_for_spec(["run", "show", "1", "--version"]).should be_false
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
