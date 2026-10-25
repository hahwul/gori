require "../../spec_helper"

module Gori::CLI::Run
  def self.cmd_rewriter_update_for_spec(args : Array(String)) : Nil
    cmd_rewriter_update(args)
  end

  def self.extract_update_for_spec(args : Array(String)) : Nil
    cmd_extract_update(args)
  end
end

# `with_store`'s shape plus the path, which the command opens on its own (`--db`).
private def with_db_store(&)
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  raised = run_capturing { yield store, path }
  store.close
  delete_db_files(path)
  raise raised if raised
end

# `gori run rewriter extract update <id>`: the headless `update_extract_rule`, in place.
describe "gori run rewriter extract update" do
  it "changes only what a flag names, strips a spelled name, and clears a field given ''" do
    with_db_store do |store, path|
      id = store.insert_extract_rule("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid", host: "acme.test")
      Gori::CLI::Run.extract_update_for_spec([id.to_s, "--db", path, "--name", "$TOKEN",
                                              "--host", "", "--disabled"])
      r = store.extract_rules.find! { |x| x.id == id }
      r.name.should eq("TOKEN")
      r.host.should eq("")
      r.match_filter.should eq("path:/login")
      r.selector.should eq("sid")
      r.enabled?.should be_false
    end
  end

  it "takes a position range, judged by the same Bindings validator" do
    with_db_store do |store, path|
      id = store.insert_extract_rule("SESSION", "", Gori::ExtractKind::Cookie, "sid")
      Gori::CLI::Run.extract_update_for_spec([id.to_s, "--db", path, "--kind", "position", "--range", "4:9"])
      r = store.extract_rules.find! { |x| x.id == id }
      r.kind.position?.should be_true
      {r.pos_start, r.pos_end}.should eq({4, 9})
    end
  end
end

private def mrule(op = Gori::Store::RuleOp::Replace, pattern = "old", replacement = "new",
                  respond = Gori::Store::RespondKind::Inline, respond_args = "") : Gori::Store::MatchRule
  Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
    pattern, replacement, op, Gori::Store::MatchKind::Literal, "label", "", "",
    respond: respond, respond_args: respond_args)
end

private def update_flags(& : Gori::CLI::Run::RewriterUpdateFlags ->) : Gori::CLI::Run::RewriterUpdateFlags
  f = Gori::CLI::Run::RewriterUpdateFlags.new
  yield f
  f
end

# `gori run rewriter update <id>`: the headless `update_rule`. Delete + re-add is not the same
# act: the re-added rule lands last in the apply order, and a global rule's per-project
# overrides are keyed by the id it burns.
describe "gori run rewriter update" do
  it "edits in place, keeping the id, position and every field a flag leaves out" do
    with_db_store do |store, path|
      first = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "a", "b", name: "keep")
      second = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "c", "d")
      Gori::CLI::Run.cmd_rewriter_update_for_spec([first.to_s, "--db", path, "--value", "B", "--disabled"])
      rules = store.match_rules
      rules.map(&.id).should eq([first, second])
      r = rules.first
      {r.pattern, r.replacement, r.name, r.enabled?}.should eq({"a", "B", "keep", false})
    end
  end

  it "clears a field given '' and refuses what the validators MCP calls refuse" do
    edit = Gori::CLI::Run.rewriter_update_edit(update_flags(&.name=("")), mrule).as(Gori::CLI::Run::RewriterEdit)
    {edit.name, edit.pattern, edit.replacement}.should eq({"", "old", "new"})
    Gori::CLI::Run.rewriter_update_edit(update_flags { |f| f.match = "regex"; f.find = "(" }, mrule)
      .should eq("invalid regex --find (failed to compile)")
    Gori::CLI::Run.rewriter_update_edit(update_flags(&.find=("")), mrule).should eq("--find must not be empty")
    Gori::CLI::Run.rewriter_update_edit(update_flags(&.host=("http://x/")), mrule)
      .as(String).should contain("must not include a scheme")
    Gori::CLI::Run.rewriter_update_edit(update_flags(&.response_file=("stub.http")), mrule)
      .should eq("--response-file is only meaningful with --op=short_circuit")
    Gori::CLI::Run.rewriter_update_edit(update_flags { |f| f.op = "add_header"; f.part = "ws" }, mrule)
      .as(String).should contain("cannot use --part=ws")
    Gori::CLI::Run.rewriter_update_edit(update_flags(&.fault=("reset")), mrule)
      .as(String).should contain("need --op=short_circuit")
    # "new" does not parse as a canned response.
    Gori::CLI::Run.rewriter_update_edit(update_flags(&.op=("short_circuit")), mrule)
      .as(String).should contain("the stub response does not parse")
  end

  it "switches a stub to a fault, dropping the response it no longer sends, and keeps a fault's args" do
    stub = mrule(op: Gori::Store::RuleOp::ShortCircuit, pattern: "/admin", replacement: "200 OK\r\n\r\nhi")
    edit = Gori::CLI::Run.rewriter_update_edit(update_flags { |f| f.fault = "hang"; f.hang_ms = 500 }, stub)
      .as(Gori::CLI::Run::RewriterEdit)
    edit.respond.fault?.should be_true
    edit.replacement.should eq("")
    fault = mrule(op: Gori::Store::RuleOp::ShortCircuit, pattern: "/admin", replacement: "",
      respond: Gori::Store::RespondKind::Fault, respond_args: edit.respond_args)
    again = Gori::CLI::Run.rewriter_update_edit(update_flags(&.delay_ms=(100)), fault).as(Gori::CLI::Run::RewriterEdit)
    args = Gori::Store::RespondArgs.parse(again.respond_args).as(Gori::Store::RespondArgs)
    {args.fault, args.hang_ms, args.delay_ms}.should eq({Gori::Store::FaultKind::Hang, 500, 100})
  end
end
