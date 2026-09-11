require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/links.cr — "Link…" from History, the History detail, and the Miner.
# (Repeater's and the Fuzzer's own registration lives in verbs/history.cr so their COMMON
# menu order lands after Fuzz/Mine — asserted in spec/verbs/history_spec.cr.)
describe "Gori::Verbs.register_links" do
  r = Gori::Verbs.registry

  it "registers ONE attach verb per linkable scope, on the same menu key" do
    # One verb, not the `to-issue`/`to-note` pair it replaced: the owner kind is a row in
    # LinkPicker now, so it must not also be a choice of verb. `u` is freed by that merge —
    # the last assertion is what fails if a to-note twin ever creeps back in.
    {"link.history.attach"        => Gori::Verb::Scope::Body,
     "link.history-detail.attach" => Gori::Verb::Scope::HistoryDetail,
     "link.miner.attach"          => Gori::Verb::Scope::Miner,
    }.each do |id, scope|
      r[id].scope.should eq(scope)
      r[id].menu_key.should eq('k')
      r[id].title.should eq("Link…")
      verb_intents(r, id).should eq([:link_attach])
    end

    ids = [] of String
    r.each { |d| ids << d.id if d.id.starts_with?("link.") }
    ids.sort.should eq(
      ["link.fuzzer.attach", "link.history-detail.attach", "link.history-detail.freeze",
       "link.history.attach", "link.history.freeze",
       "link.miner.attach", "link.repeater.attach", "link.repeater.freeze"])
  end

  it "offers Link & freeze beside Link on the same gate, and only where one exchange exists" do
    # A freeze copies ONE request/response pair (#1038). A flow and a Repeater tab have one;
    # a fuzz or miner session is a template plus a run, so neither gets the verb.
    {"link.history.freeze"        => Gori::Verb::Scope::Body,
     "link.history-detail.freeze" => Gori::Verb::Scope::HistoryDetail,
     "link.repeater.freeze"       => Gori::Verb::Scope::Repeater,
    }.each do |id, scope|
      r[id].scope.should eq(scope)
      r[id].menu_key.should eq('Z')
      r[id].title.should eq("Link & freeze…")
      verb_intents(r, id).should eq([:link_attach_freeze])
    end
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    r["link.history.freeze"].available?(ctx).should be_false
    ctx.link_flow = 9_i64
    r["link.history.freeze"].available?(ctx).should be_true
    ctx.current_tab = :repeater
    r["link.repeater.freeze"].available?(ctx).should be_false
    ctx.link_repeater = 3_i64
    r["link.repeater.freeze"].available?(ctx).should be_true
  end

  it "gates on the LINK id, not the selection — a flow with no row cannot be linked" do
    # link_flow_id is nil on the fake, so being on the History tab is not enough. Attaching
    # evidence to an id that does not exist would file an orphan row.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    ctx.selected = 9_i64
    r["link.history.attach"].available?(ctx).should be_false
    ctx.link_flow = 9_i64
    r["link.history.attach"].available?(ctx).should be_true

    ctx.current_tab = :miner
    r["link.history.attach"].available?(ctx).should be_false # linkable flow, wrong tab
    r["link.miner.attach"].available?(ctx).should be_false   # right tab, no miner session
    ctx.link_miner = 2_i64
    r["link.miner.attach"].available?(ctx).should be_true
  end
end
