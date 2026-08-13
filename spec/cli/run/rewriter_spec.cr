require "../../spec_helper"
require "json"

# `gori run rewriter` — the Match & Replace CLI, plus the `extract` sub-CRUD that mints
# session bindings (#501).
#
# What is under test here is the part of the subcommand that has no I/O: the flag → enum
# parses, the row/JSON projections a script reads, and the refusals `add` makes before a
# rule ever reaches a store. That is where this surface can be wrong quietly — a rule row
# that prints the wrong scope letter addresses a different store than the operator's next
# command does, and a JSON field that changes name breaks a script with no error anywhere.
#
# The `abort` branches (`--scope=nope`, `--range=x`, an unparseable stub) are NOT reachable
# from a spec: `abort` calls `exit`, which would take the whole suite down. Only success
# paths run here, the same limit spec/cli/run/links_spec.cr works under.

# Private CLI glue — reopen the module for bare-call wrappers.
module Gori::CLI::Run
  def self.parse_rule_scope_for_spec(s : String) : Store::RuleScope
    parse_rule_scope(s)
  end

  def self.parse_rewriter_op_for_spec(s : String) : Store::RuleOp
    parse_rewriter_op(s)
  end

  def self.rewriter_op_tag_for_spec(r : Store::MatchRule) : String
    rewriter_op_tag(r)
  end

  def self.rewriter_rule_body_for_spec(r : Store::MatchRule) : String
    rewriter_rule_body(r)
  end

  def self.rewriter_rule_row_for_spec(r : Store::MatchRule) : String
    rewriter_rule_row(r)
  end

  def self.rewriter_rule_json_for_spec(r : Store::MatchRule) : String
    JSON.build { |j| rewriter_rule_json(j, r) }
  end

  def self.extract_rule_row_for_spec(r : Store::ExtractRule) : String
    extract_rule_row(r)
  end

  def self.extract_rule_json_for_spec(r : Store::ExtractRule) : String
    JSON.build { |j| extract_rule_json(j, r) }
  end

  def self.parse_extract_range_for_spec(raw : String) : {Int32, Int32}
    parse_extract_range(raw)
  end

  def self.check_short_circuit_args_for_spec(op : Store::RuleOp, value : String,
                                             response_file : String?, body_file : String) : String
    check_short_circuit_args(op, value, response_file, body_file)
  end

  def self.check_ws_part_for_spec(op : Store::RuleOp, part : Store::RulePart, verb : String) : Nil
    check_ws_part(op, part, verb)
  end

  def self.valid_regex_for_spec?(pattern : String) : Bool
    valid_regex?(pattern)
  end

  def self.read_stub_response_for_spec(path : String) : String
    read_stub_response(path)
  end
end

private def rule(id = 1_i64, enabled = true,
                 target = Gori::Store::RuleTarget::Request,
                 part = Gori::Store::RulePart::Head,
                 pattern = "old", replacement = "new",
                 op = Gori::Store::RuleOp::Replace,
                 match_kind = Gori::Store::MatchKind::Literal,
                 name = "", host = "", body_file = "",
                 scope = Gori::Store::RuleScope::Project,
                 overridden = false) : Gori::Store::MatchRule
  Gori::Store::MatchRule.new(id, enabled, target, part, pattern, replacement,
    op, match_kind, name, host, body_file, scope, overridden)
end

private def extract_rule(id = 1_i64, enabled = true, name = "SESSION", match_filter = "",
                         kind = Gori::ExtractKind::Cookie, selector = "sid",
                         pos_start = 0, pos_end = 0, host = "") : Gori::Store::ExtractRule
  Gori::Store::ExtractRule.new(id, enabled, name, match_filter, kind,
    selector, pos_start, pos_end, host)
end

describe "gori run rewriter — flag parsing" do
  it "parses both --scope spellings, case-insensitively" do
    Gori::CLI::Run.parse_rule_scope_for_spec("project").project?.should be_true
    Gori::CLI::Run.parse_rule_scope_for_spec("global").global?.should be_true
    Gori::CLI::Run.parse_rule_scope_for_spec("GLOBAL").global?.should be_true
    Gori::CLI::Run.parse_rule_scope_for_spec("Project").project?.should be_true
  end

  # Unlike `RuleScope.from_label` (tolerant: unknown → Project, the safe direction for a
  # STORED label), the CLI parse aborts on an unknown word. A typo'd `--op` must not
  # silently create a `replace` rule the operator did not ask for.
  it "parses every --op label, case-insensitively" do
    Gori::CLI::Run.parse_rewriter_op_for_spec("replace").should eq(Gori::Store::RuleOp::Replace)
    Gori::CLI::Run.parse_rewriter_op_for_spec("add_header").should eq(Gori::Store::RuleOp::AddHeader)
    Gori::CLI::Run.parse_rewriter_op_for_spec("set_header").should eq(Gori::Store::RuleOp::SetHeader)
    Gori::CLI::Run.parse_rewriter_op_for_spec("remove_header").should eq(Gori::Store::RuleOp::RemoveHeader)
    Gori::CLI::Run.parse_rewriter_op_for_spec("short_circuit").should eq(Gori::Store::RuleOp::ShortCircuit)
    Gori::CLI::Run.parse_rewriter_op_for_spec("SHORT_CIRCUIT").should eq(Gori::Store::RuleOp::ShortCircuit)
  end

  it "reads an empty --range as 'no range', and A:B as a half-open pair" do
    Gori::CLI::Run.parse_extract_range_for_spec("").should eq({0, 0})
    Gori::CLI::Run.parse_extract_range_for_spec("3:9").should eq({3, 9})
    Gori::CLI::Run.parse_extract_range_for_spec("0:1").should eq({0, 1})
  end

  it "answers whether --find compiles as a regex without raising out of the parse" do
    Gori::CLI::Run.valid_regex_for_spec?("^sess_[0-9a-f]{8}$").should be_true
    Gori::CLI::Run.valid_regex_for_spec?("(unclosed").should be_false
    Gori::CLI::Run.valid_regex_for_spec?("a{2,1}").should be_false
  end
end

describe "gori run rewriter — rule rows" do
  # The op tag is the only thing in the row that says WHICH part a replace rule rewrites,
  # so a ws rule rendering as `sub/H` would read as an HTTP head rule — the exact confusion
  # RulePart#badge is exhaustive to prevent.
  it "tags every op, carrying the match kind and part for a replace" do
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule).should eq("sub/H")
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(part: Gori::Store::RulePart::Body)).should eq("sub/B")
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(part: Gori::Store::RulePart::Ws)).should eq("sub/W")
    Gori::CLI::Run.rewriter_op_tag_for_spec(
      rule(match_kind: Gori::Store::MatchKind::Regex)).should eq("re/H")
    Gori::CLI::Run.rewriter_op_tag_for_spec(
      rule(match_kind: Gori::Store::MatchKind::Regex, part: Gori::Store::RulePart::Body)).should eq("re/B")

    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(op: Gori::Store::RuleOp::AddHeader)).should eq("+hdr")
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(op: Gori::Store::RuleOp::SetHeader)).should eq("~hdr")
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(op: Gori::Store::RuleOp::RemoveHeader)).should eq("-hdr")
    Gori::CLI::Run.rewriter_op_tag_for_spec(rule(op: Gori::Store::RuleOp::ShortCircuit)).should eq("stub")
  end

  it "prints the pattern alone for remove_header, which has no replacement" do
    Gori::CLI::Run.rewriter_rule_body_for_spec(
      rule(op: Gori::Store::RuleOp::RemoveHeader, pattern: "X-Trace", replacement: "")).should eq("X-Trace")
  end

  # `=>` not `->`: a stub ANSWERS instead of forwarding, and the body is summarised rather
  # than printed — a canned response is a whole HTTP message and would swallow the row.
  it "summarises a short-circuit stub with => instead of ->" do
    Gori::CLI::Run.rewriter_rule_body_for_spec(
      rule(op: Gori::Store::RuleOp::ShortCircuit, pattern: "/admin",
        replacement: "200 OK\n\nhi")).should eq("/admin => 200 OK · 2B inline")

    Gori::CLI::Run.rewriter_rule_body_for_spec(
      rule(op: Gori::Store::RuleOp::ShortCircuit, pattern: "/admin",
        replacement: "404", body_file: "/tmp/stub.json"))
      .should eq("/admin => 404 Not Found · file:/tmp/stub.json") # bare status → registered phrase

    Gori::CLI::Run.rewriter_rule_body_for_spec(
      rule(op: Gori::Store::RuleOp::ShortCircuit, pattern: "/admin",
        replacement: "not a status line")).should eq("/admin => (unparseable stub response)")
  end

  it "prints pattern -> replacement for the four rewrite ops" do
    Gori::CLI::Run.rewriter_rule_body_for_spec(rule(pattern: "a", replacement: "b")).should eq("a -> b")
    Gori::CLI::Run.rewriter_rule_body_for_spec(
      rule(op: Gori::Store::RuleOp::AddHeader, pattern: "X-T", replacement: "1")).should eq("X-T -> 1")
  end

  # The scope letter LEADS the row because the two stores number independently: `#3` alone
  # does not say which rule `gori run rewriter rm 3` would address.
  it "leads a row with the scope badge, and marks a project override with *" do
    Gori::CLI::Run.rewriter_rule_row_for_spec(rule(id: 3_i64))
      .should eq("P#3 [x] REQ sub/H  old -> new")

    Gori::CLI::Run.rewriter_rule_row_for_spec(
      rule(id: 3_i64, scope: Gori::Store::RuleScope::Global))
      .should eq("G#3 [x] REQ sub/H  old -> new")

    Gori::CLI::Run.rewriter_rule_row_for_spec(
      rule(id: 3_i64, scope: Gori::Store::RuleScope::Global, overridden: true, enabled: false))
      .should eq("G*#3 [ ] REQ sub/H  old -> new")
  end

  it "shows the side, the disabled mark, and the optional name/host" do
    Gori::CLI::Run.rewriter_rule_row_for_spec(
      rule(id: 7_i64, enabled: false, target: Gori::Store::RuleTarget::Response,
        name: "strip csp", host: "*.corp.internal",
        op: Gori::Store::RuleOp::RemoveHeader, pattern: "Content-Security-Policy", replacement: ""))
      .should eq("P#7 [ ] RES -hdr  [strip csp] @*.corp.internal  Content-Security-Policy")
  end

  # ljust(5) is what keeps the body column aligned across ops; the shortest tag is 4 chars.
  it "pads the op tag so the body column lines up across ops" do
    rows = [
      Gori::CLI::Run.rewriter_rule_row_for_spec(rule(op: Gori::Store::RuleOp::AddHeader)),
      Gori::CLI::Run.rewriter_rule_row_for_spec(rule),
    ]
    rows.map(&.index("  old")).uniq!.size.should eq(1)
  end
end

describe "gori run rewriter --format=json" do
  # A script reads these names. `enabled` is the EFFECTIVE state in this project; the two
  # override fields exist only where the two answers can differ.
  it "omits overridden/default_enabled for a project rule, which has no default" do
    j = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(
      rule(id: 4_i64, name: "n", host: "h", pattern: "p", replacement: "r")))
    j["id"].as_i64.should eq(4)
    j["scope"].as_s.should eq("project")
    j["enabled"].as_bool.should be_true
    j["target"].as_s.should eq("request")
    j["part"].as_s.should eq("head")
    j["op"].as_s.should eq("replace")
    j["match"].as_s.should eq("literal")
    j["name"].as_s.should eq("n")
    j["host"].as_s.should eq("h")
    j["pattern"].as_s.should eq("p")
    j["replacement"].as_s.should eq("r")
    j["body_file"].as_s.should eq("")
    j.as_h.has_key?("overridden").should be_false
    j.as_h.has_key?("default_enabled").should be_false
  end

  # `default_enabled` is read back out of the global library, so a rule this project has
  # switched OFF still reports the library's ON — that difference is the whole point of the
  # field, and a script that only read `enabled` could not tell an override from a default.
  it "reports a global rule's own default beside this project's effective state" do
    before = Gori::Settings.rewriter_rules
    begin
      Gori::Settings.rewriter_rules = [
        Gori::Settings::RewriterRule.new(9_i64, true, "lib", "request", "head",
          "old", "new", "replace", "literal", "", ""),
      ]
      j = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(
        rule(id: 9_i64, enabled: false, scope: Gori::Store::RuleScope::Global, overridden: true)))
      j["scope"].as_s.should eq("global")
      j["enabled"].as_bool.should be_false        # off HERE
      j["overridden"].as_bool.should be_true      # …because this project said so
      j["default_enabled"].as_bool.should be_true # the library still says on
    ensure
      Gori::Settings.rewriter_rules = before
    end
  end

  # A global rule whose id is not in the library any more (deleted between the read and the
  # render) must still produce a row rather than raising — `find` yields nil, and the field
  # says so instead of guessing a default.
  it "emits a null default_enabled for a global id the library no longer has" do
    before = Gori::Settings.rewriter_rules
    begin
      Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
      j = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(
        rule(id: 9_i64, scope: Gori::Store::RuleScope::Global)))
      j["default_enabled"].raw.should be_nil
    ensure
      Gori::Settings.rewriter_rules = before
    end
  end
end

describe "gori run rewriter extract" do
  it "renders a rule as name <- condition <- where, with the disabled mark and host" do
    Gori::CLI::Run.extract_rule_row_for_spec(extract_rule(id: 3_i64))
      .should eq(%(#3 [x] $SESSION <- any message <- cookie "sid"))

    Gori::CLI::Run.extract_rule_row_for_spec(
      extract_rule(id: 4_i64, enabled: false, match_filter: "status:200 AND path:/login",
        host: "acme.test"))
      .should eq(%(#4 [ ] $SESSION <- status:200 AND path:/login <- cookie "sid" @acme.test))
  end

  # An empty filter is "read every message", not "read none" — printing the empty string
  # would read as a rule that can never fire.
  it "spells an empty --when as 'any message'" do
    Gori::CLI::Run.extract_rule_row_for_spec(extract_rule).should contain("<- any message <-")
  end

  it "names each extract kind the way the descriptor editor does" do
    Gori::CLI::Run.extract_rule_row_for_spec(
      extract_rule(kind: Gori::ExtractKind::Header, selector: "X-Token")).should contain("<- header X-Token")
    Gori::CLI::Run.extract_rule_row_for_spec(
      extract_rule(kind: Gori::ExtractKind::Regex, selector: "tok=(\\w+)")).should contain("<- regex /tok=(\\w+)/")
    Gori::CLI::Run.extract_rule_row_for_spec(
      extract_rule(kind: Gori::ExtractKind::Position, selector: "", pos_start: 3, pos_end: 9))
      .should contain("<- body[3...9]")
    Gori::CLI::Run.extract_rule_row_for_spec(
      extract_rule(kind: Gori::ExtractKind::JsonPath, selector: "data.token")).should contain("<- jsonpath data.token")
  end

  # `when`, not `match_filter`: the JSON field mirrors the FLAG (`--when`), which is what a
  # script author has in front of them.
  it "emits the flag spellings as JSON field names" do
    j = JSON.parse(Gori::CLI::Run.extract_rule_json_for_spec(
      extract_rule(id: 5_i64, enabled: false, name: "CSRF", match_filter: "path:/login",
        kind: Gori::ExtractKind::Position, selector: "", pos_start: 3, pos_end: 9, host: "acme.test")))
    j["id"].as_i64.should eq(5)
    j["enabled"].as_bool.should be_false
    j["name"].as_s.should eq("CSRF")
    j["when"].as_s.should eq("path:/login")
    j["host"].as_s.should eq("acme.test")
    j["kind"].as_s.should eq("position")
    j["selector"].as_s.should eq("")
    j["pos_start"].as_i.should eq(3)
    j["pos_end"].as_i.should eq(9)
  end
end

describe "gori run rewriter add — the refusals before a rule is stored" do
  it "passes a non-short-circuit value through untouched" do
    Gori::CLI::Run.check_short_circuit_args_for_spec(
      Gori::Store::RuleOp::Replace, "new", nil, "").should eq("new")
    Gori::CLI::Run.check_short_circuit_args_for_spec(
      Gori::Store::RuleOp::AddHeader, "1", nil, "").should eq("1")
  end

  it "keeps an inline stub that parses" do
    stub = "200 OK\nContent-Type: application/json\n\n{\"isAdmin\": true}"
    Gori::CLI::Run.check_short_circuit_args_for_spec(
      Gori::Store::RuleOp::ShortCircuit, stub, nil, "").should eq(stub)
  end

  # --response-file wins over --value: the canned response is multi-line and awkward on a
  # command line, which is the whole reason the flag exists.
  it "reads --response-file in place of --value, byte for byte" do
    path = File.tempname("gori-stub", ".http")
    begin
      File.write(path, "403 Forbidden\r\nX-Stub: 1\r\n\r\nnope\n")
      Gori::CLI::Run.check_short_circuit_args_for_spec(
        Gori::Store::RuleOp::ShortCircuit, "ignored", path, "")
        .should eq("403 Forbidden\r\nX-Stub: 1\r\n\r\nnope\n")
      Gori::CLI::Run.read_stub_response_for_spec(path).should eq("403 Forbidden\r\nX-Stub: 1\r\n\r\nnope\n")
    ensure
      File.delete?(path)
    end
  end

  # A `--body-file` on a short-circuit rule is legal (it is the stub's body source) and is
  # NOT read here — it is read per request, so a file written later is a normal way to work.
  it "accepts a body-file on a short-circuit rule without reading it" do
    Gori::CLI::Run.check_short_circuit_args_for_spec(
      Gori::Store::RuleOp::ShortCircuit, "204 No Content", nil, "/does/not/exist/yet")
      .should eq("204 No Content")
  end

  # Only `replace` acts on a WebSocket message. The other four are refused rather than
  # normalised — `Rules.normalize_shape` would coerce the part to `head`, moving the rule to
  # a different PROTOCOL with nothing on screen to say so.
  it "allows --part=ws for replace, and any part for an op that stays on the head" do
    Gori::CLI::Run.check_ws_part_for_spec(
      Gori::Store::RuleOp::Replace, Gori::Store::RulePart::Ws, "add").should be_nil
    Gori::CLI::Run.check_ws_part_for_spec(
      Gori::Store::RuleOp::AddHeader, Gori::Store::RulePart::Head, "add").should be_nil
    Gori::CLI::Run.check_ws_part_for_spec(
      Gori::Store::RuleOp::ShortCircuit, Gori::Store::RulePart::Head, "preview").should be_nil
  end
end
