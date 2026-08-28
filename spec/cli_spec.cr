require "./spec_helper"
require "file_utils"

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

  # What the guards actually decide on. Routed through the PRODUCTION `stray_args` — its
  # `unknown_args` wiring included — so dropping the `after` half again fails these examples;
  # re-implementing the join here would have specced the spec. Only the parser is local, shaped
  # like bare `gori settings`'s, since the guards themselves end in `abort` (not catchable).
  # `edit` comes back too so that case can pin the ENTIRE original failure: nothing left over
  # AND the flag never fired — i.e. "printed the path and exited 0".
  def self.settings_argv_for_spec(args : Array(String)) : {Array(String), Bool}
    edit = false
    parser = OptionParser.new do |p|
      p.on("--edit", "Open the settings file in your editor") { edit = true }
      p.on("-h", "--help", "Show this help") { }
    end
    {stray_args(parser, args), edit}
  end

  # Same call, `import`'s parser — where the leftovers are FILENAMES rather than an error.
  def self.import_files_for_spec(args : Array(String)) : Array(String)
    parser = OptionParser.new do |p|
      p.on("--sections=LIST", "Sections to apply") { }
      p.on("--dry-run", "Print what would be applied") { }
      p.on("-h", "--help", "Show this help") { }
    end
    stray_args(parser, args)
  end

  def self.same_file_for_spec(a : String, b : String) : Bool
    same_file?(a, b)
  end

  # The profile execution report (#842). Both wordings are pure by design — the guards around
  # them end in `abort`, which is not catchable — so what a spec can reach is the sentence
  # itself, which is the part that has to be right.
  def self.command_report_for_spec(found : Array(Settings::CommandEntry), dry : Bool,
                                   allowed : Bool = false) : Array(String)
    command_report(found, dry, allowed)
  end

  def self.exported_commands_note_for_spec(rules : Array(Settings::CommandEntry)) : String
    exported_commands_note(rules)
  end

  def self.printable_for_spec(s : String) : String
    printable(s)
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

# The `--` separator used to switch every guard above back off. OptionParser strips the run
# after it and hands it over as a SECOND list, which `gori settings` discarded — so two
# characters turned each of these back into the silent-no-op-at-exit-0 the guards exist to
# stop. `gori wizard` / `gori tutorial` already handled it (reject_extra_args); settings did not.
describe "gori settings — arguments after a `--` separator" do
  it "sees a flag pushed past `--` as the stray argument it is" do
    # `gori settings -- --edit` printed the settings path and exited 0, editor never opened.
    rest, edit = Gori::CLI.settings_argv_for_spec(["--", "--edit"])
    edit.should be_false # OptionParser will not claim it, which is exactly why it must be refused
    rest.should eq(["--edit"])
  end

  it "sees a bare word pushed past `--`" do
    # `gori settings export -- team.json` (a `--` where `-o` was meant) dumped the profile to
    # stdout, created no file, and exited 0 — verbatim the failure reject_stray_args! was
    # written for, reached around it.
    Gori::CLI.settings_argv_for_spec(["--", "team.json"]).should eq({["team.json"], false})
    Gori::CLI.settings_argv_for_spec(["--", "foo"]).should eq({["foo"], false})
  end

  it "leaves an ordinary invocation alone" do
    # No `--` at all, and a bare `--` with nothing after it, must both stay clean — the guard
    # aborts on any leftover, so a false positive here breaks a working command.
    Gori::CLI.settings_argv_for_spec(["--edit"]).should eq({[] of String, true})
    Gori::CLI.settings_argv_for_spec([] of String).should eq({[] of String, false})
    Gori::CLI.settings_argv_for_spec(["--"]).should eq({[] of String, false})
    Gori::CLI.settings_argv_for_spec(["--edit", "--"]).should eq({[] of String, true})
  end
end

# `import` joins the same run instead of rejecting it, because there `--` carries its POSIX
# meaning: everything after it is a FILENAME.
describe "gori settings import — arguments after a `--` separator" do
  it "takes a file named past `--`" do
    # Aborted with "needs a file", so a profile whose name starts with a dash — the one case
    # `--` exists for — could not be imported at all.
    Gori::CLI.import_files_for_spec(["--", "p.json"]).should eq(["p.json"])
    Gori::CLI.import_files_for_spec(["--", "./--odd.json"]).should eq(["./--odd.json"])
  end

  it "counts a second file hidden past `--`, so the one-file guard fires" do
    # Imported a.json, discarded b.json, and reported success — defeating the `rest.size > 1`
    # guard whose whole purpose is catching a glob that matched two files.
    Gori::CLI.import_files_for_spec(["a.json", "--", "b.json"]).size.should eq(2)
    Gori::CLI.import_files_for_spec(["--", "a.json", "b.json"]).size.should eq(2)
  end

  it "still parses its own flags before the separator" do
    Gori::CLI.import_files_for_spec(["p.json", "--dry-run"]).should eq(["p.json"])
    Gori::CLI.import_files_for_spec(["--sections=network", "p.json"]).should eq(["p.json"])
  end
end

# `-o` pointing at the live settings file is data loss, not an export: the document omits every
# section at its default and both secret sections, and write_export is a plain truncate — so it
# DELETES `env` (token values) and `decoder` in place, says "wrote <path>", and exits 0.
describe "gori settings export — same-file detection for -o" do
  it "matches the same file through `..`, a relative path and a symlink" do
    dir = File.tempname("gori-cli-samefile")
    Dir.mkdir_p(File.join(dir, "home"))
    settings = File.join(dir, "home", "settings.json")
    File.write(settings, "{}")
    begin
      Gori::CLI.same_file_for_spec(settings, settings).should be_true
      Gori::CLI.same_file_for_spec(File.join(dir, "home", "..", "home", "settings.json"), settings).should be_true
      # A symlinked config directory is the same overwrite spelled differently.
      link = File.join(dir, "link")
      File.symlink(File.join(dir, "home"), link)
      Gori::CLI.same_file_for_spec(File.join(link, "settings.json"), settings).should be_true
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not match an ordinary export target beside it" do
    # A false positive would refuse a perfectly good export, so the negative side matters as
    # much: same directory, and a target that does not exist yet (the ordinary case).
    dir = File.tempname("gori-cli-samefile-neg")
    Dir.mkdir_p(dir)
    settings = File.join(dir, "settings.json")
    File.write(settings, "{}")
    begin
      Gori::CLI.same_file_for_spec(File.join(dir, "team-profile.json"), settings).should be_false
      Gori::CLI.same_file_for_spec(File.join(dir, "settings.json.bak"), settings).should be_false
      Gori::CLI.same_file_for_spec(File.join(dir, "nested", "settings.json"), settings).should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
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

# Every `gori run` subcommand, as a CLASS.
#
# `OptionParser#unknown_args` yields TWO lists — the words it could not claim, and the run
# following a `--` separator, which it strips and hands over separately. A handler that binds
# only the first silently DISCARDS everything past a `--`, which switches the subcommand's own
# argument handling off at exit 0. `gori settings` was fixed for exactly this (see the two
# describes above); every `src/gori/cli/run/*.cr` site had the same hole, reproduced through the
# built binary:
#
#   gori run decoder base64-encode hello       → aGVsbG8=
#   gori run decoder base64-encode -- hello    → nothing, exit 0 (input dropped, reads STDIN)
#   gori run links add --owner=… -- junk       → sailed past the guard that refuses positionals
#
# Asserted over the SOURCE rather than per-command, because the defect is one a new subcommand
# reintroduces by copying the idiom from its neighbours — which is how all ~60 of them got it.
# A per-command example would only ever cover the commands someone remembered to write one for.
#
# No `gori` command uses `--` as a pass-through separator (nothing forwards argv to a
# subprocess), so joining both halves is right everywhere: each site either refuses the
# leftovers or reads them as positionals, and both want the full set.
describe "gori run — the `--` half of unknown_args" do
  it "is bound by every subcommand parser" do
    dir = File.join(__DIR__, "..", "src", "gori", "cli", "run")
    offenders = [] of String
    Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
      File.read_lines(path).each_with_index do |line, i|
        next unless line.includes?("unknown_args")
        # The second block parameter discarded as `_` — the whole defect, in one token.
        next unless line.matches?(/unknown_args\s*(\{|do)\s*\|\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*_\s*\|/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end
end

# `gori settings export|import` — the sentence a profile's two ends say about the commands it
# carries (#842). Since #818 an exported section can hold an ARGV (`rewriter.rules` with
# `op: pipe`, `scan_rules` with `kind: exec`, a `decoder` chain step), and importing one arms
# it on the proxy data path for every project.
private def cmd_rule(section : String, kind : String, name : String, command : String,
                     enabled : Bool = true) : Gori::Settings::CommandEntry
  Gori::Settings::CommandEntry.new(section, kind, name, command, enabled)
end

describe "gori settings export — the note about what the profile will run" do
  it "counts the rules and breaks them down by section and kind" do
    note = Gori::CLI.exported_commands_note_for_spec([
      cmd_rule("rewriter", "pipe", "resign", "./resign.sh"),
      cmd_rule("rewriter", "pipe", "hmac", "/usr/local/bin/hmac"),
      cmd_rule("scan_rules", "exec", "leak", "./detect.py"),
    ])
    note.should contain("3 entries in this profile run a local command")
    note.should contain("2 rewriter pipe, 1 scan_rules exec")
    # "their own", not `PeerNotices`' "your": the file is leaving this machine, and whose
    # privileges are at stake is the one thing that differs between the two ends of a profile.
    note.should contain("whoever imports it runs them with their own privileges")
  end

  it "reads as one rule in the singular" do
    note = Gori::CLI.exported_commands_note_for_spec([cmd_rule("decoder", "exec", "d", "./d.sh")])
    note.should contain("1 entry in this profile runs a local command")
    note.should contain("1 decoder exec")
    note.should contain("runs it with their own privileges")
  end
end

describe "gori settings export — the two sections that are not rule tables" do
  it "names statusline as the SHELL it is, and editor beside it" do
    # `statusline.command` goes to `/bin/sh -c` on a timer, which is a bigger thing than the
    # three no-shell hook seams — the breakdown has to say which mechanism each one is.
    note = Gori::CLI.exported_commands_note_for_spec([
      cmd_rule("statusline", "sh -c", "command", "~/bin/status.sh"),
      cmd_rule("editor", "exec", "command", "nvim"),
    ])
    note.should contain("2 entries in this profile run a local command")
    note.should contain("1 statusline sh -c, 1 editor exec")
  end
end

describe "gori settings import — the per-rule listing" do
  it "names each rule individually, with its argv" do
    # Section granularity cannot say this: "would apply 1 section(s): rewriter" is equally true
    # of a profile that restyles header rewrites and of one that installs a hook.
    lines = Gori::CLI.command_report_for_spec([
      cmd_rule("rewriter", "pipe", "resign", "./resign.sh --key $TOKEN"),
      cmd_rule("scan_rules", "exec", "leak", "./detect.py"),
    ], dry: false)
    # The headline is PeerNotices' sentence, verbatim in the part that carries the weight.
    lines[0].should contain("2 entries in this profile run a local command here, with your privileges:")
    lines[1].should contain("rewriter pipe")
    lines[1].should contain("resign")
    lines[1].should contain("./resign.sh --key $TOKEN")
    lines[2].should contain("scan_rules exec")
    lines[2].should contain("./detect.py")
    lines.last.should contain("the same trust decision as running the author's script")
  end

  it "marks a rule the profile carries but does not arm" do
    lines = Gori::CLI.command_report_for_spec([cmd_rule("rewriter", "pipe", "off", "/bin/echo", false)], dry: false)
    lines[1].should contain("[disabled]")
    Gori::CLI.command_report_for_spec([cmd_rule("rewriter", "pipe", "on", "/bin/echo")], dry: false)[1]
      .should_not contain("[disabled]")
  end

  it "names the flag that answers it, and only on the dry run says nothing was written" do
    dry = Gori::CLI.command_report_for_spec([cmd_rule("rewriter", "pipe", "r", "./r.sh")], dry: true)
    dry.last.should contain("--dry-run writes nothing")
    dry.last.should contain("--allow-commands")
  end

  it "fills in a rule with no name" do
    lines = Gori::CLI.command_report_for_spec([cmd_rule("rewriter", "pipe", "", "./r.sh")], dry: false)
    lines[1].should contain("(unnamed)")
  end

  it "does not tell you to pass a flag you already passed" do
    # `--dry-run --allow-commands` used to end on "a real import needs --allow-commands",
    # which reads as though the dry run had rejected the flag.
    dry = Gori::CLI.command_report_for_spec([cmd_rule("rewriter", "pipe", "r", "./r.sh")],
      dry: true, allowed: true)
    dry.last.should contain("--allow-commands is set")
    dry.last.should_not contain("needs --allow-commands")
  end

  it "aligns the columns by TERMINAL width, not codepoint count" do
    # A CJK name is two cells per character. Measuring `String#size` under-padded its column
    # and stepped the command beside it out of line — in a listing meant to be read carefully.
    lines = Gori::CLI.command_report_for_spec([
      cmd_rule("rewriter", "pipe", "재서명훅", "./a.sh"),
      cmd_rule("rewriter", "pipe", "resign", "./b.sh"),
    ], dry: false)
    a = Gori::Tui::Screen.display_width(lines[1].split("./a.sh").first)
    b = Gori::Tui::Screen.display_width(lines[2].split("./b.sh").first)
    a.should eq(b)
  end

  it "says nothing at all for a profile that carries no command" do
    Gori::CLI.command_report_for_spec([] of Gori::Settings::CommandEntry, dry: false).should be_empty
    Gori::CLI.command_report_for_spec([] of Gori::Settings::CommandEntry, dry: true).should be_empty
  end
end

# The listing exists to be READ before a trust decision, and both columns it prints are text
# out of a file someone else wrote.
describe "gori settings import — a hostile name or argv cannot rewrite the listing" do
  it "escapes control characters instead of emitting them" do
    # `\e[1A\e[2K` would erase the line above — which is the count of how many commands are in
    # the profile, i.e. the one number the operator is deciding on.
    out = Gori::CLI.printable_for_spec("evil\e[1A\e[2Kharmless")
    out.should_not contain('\e')
    out.should contain("\\u{1b}")
    Gori::CLI.printable_for_spec("a\nb").should_not contain('\n')
    Gori::CLI.printable_for_spec("a\rb").should_not contain('\r')
  end

  it "escapes the invisible-format class, bidi overrides included" do
    # Trojan Source: `U+202E` renders the command as something other than what runs, without
    # changing a byte of it. Crystal's `Char#control?` is Cc AND Cf, so it covers the bidi
    # controls, the zero-width joiners, the soft hyphen and the BOM — this pins that, because
    # a listing whose whole job is to show a command before it is armed is what the trick is
    # for, and because the predicate's own comment now rests on that fact.
    out = Gori::CLI.printable_for_spec("./evil.sh \u{202E} --quiet")
    out.should contain("\\u{202e}")
    out.should_not contain('\u{202E}')
    {0x2066, 0x200B, 0x200D, 0x00AD, 0xFEFF, 0x061C}.each do |cp|
      Gori::CLI.printable_for_spec("a#{cp.unsafe_chr}b").should eq("a\\u{#{cp.to_s(16)}}b")
    end
    # U+2028/U+2029 are Zl/Zp, NOT Cf — `control?` is false for them and a terminal may break
    # the line there, splitting one entry's row in two. They are the pair added by hand.
    Gori::CLI.printable_for_spec("a\u{2028}b").should contain("\\u{2028}")
    Gori::CLI.printable_for_spec("a\u{2029}b").should contain("\\u{2029}")
  end

  it "leaves ordinary text, including non-ASCII, alone" do
    # Escaping by codepoint rather than by byte: a path with a non-ASCII component stays
    # readable instead of turning into a run of `\xNN`.
    Gori::CLI.printable_for_spec("./재서명.sh --key $TOKEN").should eq("./재서명.sh --key $TOKEN")
    Gori::CLI.printable_for_spec("").should eq("")
  end

  it "reaches the rendered listing, not just the helper" do
    lines = Gori::CLI.command_report_for_spec([
      cmd_rule("rewriter", "pipe", "n\e[2Kame", "./r.sh\e[2K"),
    ], dry: false)
    lines[1].should_not contain('\e')
  end
end
