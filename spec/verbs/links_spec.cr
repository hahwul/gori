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
      ["link.fuzzer.attach", "link.history-detail.attach",
       "link.history.attach", "link.miner.attach", "link.repeater.attach"])
  end

  it "has NO freeze twin any more — Link… freezes, and the picker says so per row" do
    # The `Z` pair (#1038) is gone: offering both made the operator answer "pointer or
    # bytes?" at the moment of filing, which is a question about the storage model asked
    # while their attention is on the finding — and the answer was almost always "bytes".
    # The remaining verb's DESCRIPTION has to carry that, because it is what the palette
    # and the menu show before the card opens.
    ids = [] of String
    r.each { |d| ids << d.id if d.id.includes?("freeze") }
    ids.should eq(["issue.freeze-link"]) # the RELATED row's `f`, which is a different act

    r.each do |d|
      d.title.should_not eq("Link & freeze…") if d.id.starts_with?("link.")
    end
    {"link.history.attach", "link.history-detail.attach", "link.repeater.attach"}.each do |id|
      r[id].description.should contain("freezing")
      r[id].menu_key.should eq('k')
    end
    # Not the Miner or the Fuzzer: a template plus a run is not one exchange
    # (`Evidence.freezable?`), so their descriptions must not promise a copy.
    {"link.miner.attach", "link.fuzzer.attach"}.each do |id|
      r[id].description.should_not contain("freez")
    end
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
