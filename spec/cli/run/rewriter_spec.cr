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
                                             response_file : String?, body_file : String) : String?
    check_short_circuit_args(op, value, response_file, body_file)
  end

  def self.mock_respond_for_spec(op : Store::RuleOp, body_file : String, map_dir : String? = nil,
                                 strip_prefix = "", fallthrough = false, fault : String? = nil,
                                 delay_ms = 0, hang_ms : Int32? = nil) : {Store::RespondKind, String}
    mock = MockFlags.new
    mock.map_dir = map_dir
    mock.strip_prefix = strip_prefix
    mock.fallthrough = fallthrough
    mock.fault = fault
    mock.delay_ms = delay_ms
    mock.hang_ms = hang_ms
    mock_respond(op, mock, body_file)
  end

  def self.add_find_for_spec(respond : Store::RespondKind, find : String?, strip_prefix = "",
                             from_flow : Int64? = nil) : {String?, Store::MatchKind}
    mock = MockFlags.new
    mock.strip_prefix = strip_prefix
    mock.from_flow = from_flow
    add_find(Store::RuleOp::ShortCircuit, respond, mock, find, Store::MatchKind::Literal)
  end

  def self.add_fill_for_spec(store : Store, flow_id : Int64, find : String?, host : String?,
                             value : String?) : {String, Store::MatchKind, String, String}
    mock = MockFlags.new
    mock.from_flow = flow_id
    add_fill(store, Store::RuleOp::ShortCircuit, mock, Store::RespondKind::Inline, "", "",
      find, Store::MatchKind::Literal, host, value)
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

  def self.rewriter_added_output_for_spec(store : Store, id : Int64, scope : Store::RuleScope,
                                          format : Symbol) : String
    rewriter_added_output(store, id, scope, format)
  end

  def self.extract_added_output_for_spec(store : Store, id : Int64, name : String,
                                         kind : ExtractKind, format : Symbol) : String
    extract_added_output(store, id, name, kind, format)
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

  it "shows the raw unknown labels and marks the row inert" do
    rule = Gori::Store::MatchRule.new(12_i64, true,
      Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
      "POST /pay", "HTTP/1.1 200 OK", Gori::Store::RuleOp::Replace,
      Gori::Store::MatchKind::Literal, "future", "", "",
      unknown_target: "future_side", unknown_part: "future_head",
      unknown_op: "future_short_circuit", unknown_match_kind: "future_match")
    j = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(rule))
    j["target"].as_s.should eq("future_side")
    j["part"].as_s.should eq("future_head")
    j["op"].as_s.should eq("future_short_circuit")
    j["match"].as_s.should eq("future_match")
    j["inert"].as_bool.should be_true
    j["inert_reason"].as_s.should contain("unknown op \"future_short_circuit\"")

    row = Gori::CLI::Run.rewriter_rule_row_for_spec(rule)
    row.should contain("[?]")
    row.should contain("future_short_circuit")
    row.should contain("future_head")
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

# `rewriter add --format json` and `extract add --format json` (#1117): the listing's object
# for the rule just written, read back after the commit.
describe "gori run rewriter add --format json" do
  it "prints the new rule's listing object, id included" do
    with_store do |store|
      # `--op=add_header` with the default `--part`: `Rules.normalize_shape` rewrites the
      # shape, and the object says what was STORED, which is what the listing will say.
      id = Gori::Rules.load(store).create(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-Trace", "on", Gori::Store::RuleOp::AddHeader, name: "trace", enabled: false)
      o = JSON.parse(Gori::CLI::Run.rewriter_added_output_for_spec(store, id,
        Gori::Store::RuleScope::Project, :json))
      o["id"].as_i64.should eq(id)
      o["scope"].as_s.should eq("project")
      o["enabled"].as_bool.should be_false
      o["op"].as_s.should eq("add_header")

      listed = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(
        Gori::Rules.merged(store).find! { |r| !r.global? && r.id == id }))
      o.as_h.keys.should eq(listed.as_h.keys)
      o.should eq(listed)
    end
  end

  it "keeps both text sentences unchanged" do
    with_store do |store|
      Gori::CLI::Run.rewriter_added_output_for_spec(store, 3_i64, Gori::Store::RuleScope::Project, :text)
        .should eq("Rule #3 added.")
      Gori::CLI::Run.rewriter_added_output_for_spec(store, 3_i64, Gori::Store::RuleScope::Global, :text)
        .should eq("Global rule #3 added — it applies in every project.")
    end
  end
end

describe "gori run rewriter extract add --format json" do
  it "prints the new rule's listing object, with the state that landed" do
    with_store do |store|
      id = store.insert_extract_rule("SESSION", "status:200", Gori::ExtractKind::Cookie, "sid")
      store.set_extract_rule_enabled(id, false).should be_true # what `--disabled` does next
      o = JSON.parse(Gori::CLI::Run.extract_added_output_for_spec(store, id, "SESSION",
        Gori::ExtractKind::Cookie, :json))
      o["id"].as_i64.should eq(id)
      o["enabled"].as_bool.should be_false

      listed = JSON.parse(Gori::CLI::Run.extract_rule_json_for_spec(store.extract_rules.find! { |r| r.id == id }))
      o.as_h.keys.should eq(listed.as_h.keys)
      o.should eq(listed)
    end
  end

  it "keeps the text sentence unchanged" do
    with_store do |store|
      Gori::CLI::Run.extract_added_output_for_spec(store, 2_i64, "SESSION", Gori::ExtractKind::Header, :text)
        .should eq("Extract rule #2 added — #{Gori::Env.spell("SESSION", Gori::Env::Namespace::Bind)} binds from header.")
    end
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

# #1237 — the mocking flags. The refusals abort (and so cannot run here); what is pinned is the
# rule each accepted combination becomes, and the listing a script reads back.
describe "gori run rewriter add — mocking (#1237)" do
  it "turns each answer's flags into its sub-kind and stored args" do
    sc = Gori::Store::RuleOp::ShortCircuit
    Gori::CLI::Run.mock_respond_for_spec(sc, "").should eq({Gori::Store::RespondKind::Inline, ""})
    Gori::CLI::Run.mock_respond_for_spec(sc, "/tmp/b.json").should eq({Gori::Store::RespondKind::File, ""})
    Gori::CLI::Run.mock_respond_for_spec(sc, "", map_dir: "/srv", strip_prefix: "/static/", fallthrough: true)
      .should eq({Gori::Store::RespondKind::Dir, %({"strip_prefix":"/static/","fallthrough":true})})
    Gori::CLI::Run.mock_respond_for_spec(sc, "", fault: "RESET", delay_ms: 250)
      .should eq({Gori::Store::RespondKind::Fault, %({"fault":"reset","delay_ms":250})})
    Gori::CLI::Run.mock_respond_for_spec(sc, "", fault: "hang", hang_ms: 2000)
      .should eq({Gori::Store::RespondKind::Fault, %({"fault":"hang","hang_ms":2000})})
    Gori::CLI::Run.mock_respond_for_spec(Gori::Store::RuleOp::Replace, "")
      .should eq({Gori::Store::RespondKind::Inline, ""})
  end

  it "claims a map-dir prefix on the request line when --find is left out" do
    find, match = Gori::CLI::Run.add_find_for_spec(Gori::Store::RespondKind::Dir, nil, "/static/")
    match.should eq(Gori::Store::MatchKind::Regex)
    re = Regex.new(find.not_nil!)
    re.matches?("GET /static/app.js HTTP/1.1\r\n").should be_true
    re.matches?("GET /x HTTP/1.1\r\nReferer: https://a/static/\r\n").should be_false
    # --from-flow may leave the match to the flow's draft.
    Gori::CLI::Run.add_find_for_spec(Gori::Store::RespondKind::Inline, nil, from_flow: 7_i64)
      .should eq({nil, Gori::Store::MatchKind::Literal})
  end

  it "fills an unsaid match, host and response from --from-flow, and keeps what was said" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/api/me", http_version: "HTTP/1.1",
        head: "GET /api/me HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: %({"a":1}).to_slice))
      find, match, host, value = Gori::CLI::Run.add_fill_for_spec(store, id, nil, nil, nil)
      find.should eq("\\AGET /api/me(\\?| )")
      match.should eq(Gori::Store::MatchKind::Regex)
      host.should eq("acme.test")
      value.should eq("HTTP/1.1 200 OK\n\n{\"a\":1}")
      Gori::CLI::Run.add_fill_for_spec(store, id, "/api/me", "*.acme.test", nil)
        .should eq({"/api/me", Gori::Store::MatchKind::Literal, "*.acme.test", "HTTP/1.1 200 OK\n\n{\"a\":1}"})
    end
  end

  it "lists a mock rule's answer, and prints its sub-kind in JSON" do
    dir = Gori::Store::MatchRule.new(4_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "GET /static/", "", Gori::Store::RuleOp::ShortCircuit,
      body_file: "/srv/js", respond: Gori::Store::RespondKind::Dir,
      respond_args: %({"strip_prefix":"/static/","fallthrough":true}))
    Gori::CLI::Run.rewriter_rule_body_for_spec(dir).should eq("GET /static/ => /static/ → dir:/srv/js (fallthrough)")
    json = JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(dir))
    json["respond"].as_s.should eq("dir")
    json["respond_args"]["strip_prefix"].as_s.should eq("/static/")
    json["respond_args"]["fault"].raw.should be_nil
    json["fallthrough"].as_bool.should be_true

    fault = Gori::Store::MatchRule.new(5_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "/pay", "", Gori::Store::RuleOp::ShortCircuit,
      respond: Gori::Store::RespondKind::Fault, respond_args: %({"fault":"reset","delay_ms":500}))
    Gori::CLI::Run.rewriter_rule_body_for_spec(fault).should eq("/pay => fault:reset +500ms")
    JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(fault))["fallthrough"].as_bool.should be_false

    # Args this binary cannot read print RAW — the row is inert and says why.
    future = Gori::Store::MatchRule.new(6_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "/x", "", Gori::Store::RuleOp::ShortCircuit,
      respond: Gori::Store::RespondKind::Fault, respond_args: %({"fault":"reset","throttle":1}))
    JSON.parse(Gori::CLI::Run.rewriter_rule_json_for_spec(future))["respond_args"].as_s
      .should eq(%({"fault":"reset","throttle":1}))
  end
end
