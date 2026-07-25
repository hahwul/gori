require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/links.cr — "Link to issue / note" from History, the History detail, and
# the Miner. (Repeater's and the Fuzzer's own pair is registered in verbs/history.cr so
# their COMMON menu order lands after Fuzz/Mine — asserted in spec/verbs/history_spec.cr.)
describe "Gori::Verbs.register_links" do
  r = Gori::Verbs.registry

  it "registers the issue/note pair in each linkable scope, on the same menu keys" do
    {"link.history.to-issue"        => Gori::Verb::Scope::Body,
     "link.history-detail.to-issue" => Gori::Verb::Scope::HistoryDetail,
     "link.miner.to-issue"          => Gori::Verb::Scope::Miner,
    }.each do |id, scope|
      r[id].scope.should eq(scope)
      r[id].menu_key.should eq('k')
      verb_intents(r, id).should eq([:link_to_issue])
    end

    {"link.history.to-note"        => Gori::Verb::Scope::Body,
     "link.history-detail.to-note" => Gori::Verb::Scope::HistoryDetail,
     "link.miner.to-note"          => Gori::Verb::Scope::Miner,
    }.each do |id, scope|
      r[id].scope.should eq(scope)
      r[id].menu_key.should eq('u')
      verb_intents(r, id).should eq([:link_to_note])
    end
  end

  it "gates on the LINK id, not the selection — a flow with no row cannot be linked" do
    # link_flow_id is nil on the fake, so being on the History tab is not enough. Attaching
    # evidence to an id that does not exist would file an orphan row.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    ctx.selected = 9_i64
    r["link.history.to-issue"].available?(ctx).should be_false
    r["link.history.to-note"].available?(ctx).should be_false
    ctx.link_flow = 9_i64
    r["link.history.to-issue"].available?(ctx).should be_true
    r["link.history.to-note"].available?(ctx).should be_true

    ctx.current_tab = :miner
    r["link.history.to-issue"].available?(ctx).should be_false # linkable flow, wrong tab
    r["link.miner.to-issue"].available?(ctx).should be_false   # right tab, no miner session
    ctx.link_miner = 2_i64
    r["link.miner.to-issue"].available?(ctx).should be_true
  end
end
