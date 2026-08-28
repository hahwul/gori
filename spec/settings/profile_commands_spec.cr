require "../spec_helper"

# `Settings.command_rules` — what a PROFILE would run on the machine that imports it (#842).
#
# The unit under test is deliberately the same reader both doors use: `gori settings export`
# runs it over the document it is about to write, `gori settings import` over the document it
# is about to apply. An example here that passes for one of them passes for both.
private def rules_in(json : String, only : Array(String)? = nil) : Array(Gori::Settings::CommandRule)
  Gori::Settings.command_rules(JSON.parse(json), only)
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
    found = Gori::Settings.command_rules(JSON.parse(raw))
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

describe "Settings::COMMAND_SECTIONS" do
  it "names only sections gori actually exports" do
    # A name here that SECTION_KEYS does not carry would be a dispatch arm no document can
    # reach, and the operator would never be told about the section it was meant to cover.
    (Gori::Settings::COMMAND_SECTIONS - Gori::Settings::SECTION_KEYS).should be_empty
  end

  it "covers every section whose vocabulary admits a command" do
    # The guard against the failure this issue is about: a rule kind grew a command-carrying
    # variant and the export contract was never revisited. If either list grows a new
    # command-carrying entry, its section has to be here.
    Gori::Settings::RULE_OPS.should contain("pipe")
    Gori::Settings::SCAN_RULE_KINDS.should contain(Gori::Settings::SCAN_RULE_EXEC_KIND)
    Gori::Settings::COMMAND_SECTIONS.should contain("rewriter")
    Gori::Settings::COMMAND_SECTIONS.should contain("scan_rules")
    Gori::Settings::COMMAND_SECTIONS.should contain("decoder")
  end
end
