require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/comparer.cr — the Comparer tab (A/B flow diff, multi-pair sub-tabs).
private def in_comparer(sessions : Int32 = 0) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :comparer
  ctx.subtab_search_tab_count = sessions
  ctx
end

describe "Gori::Verbs.register_comparer" do
  r = Gori::Verbs.registry

  it "passes the slot symbol through to comparer_pick, one verb per slot" do
    # One handler taking :a/:b — a copy-paste slip here silently makes 'b' overwrite A.
    {"comparer.pick-a" => {"a", "a"}, "comparer.pick-b" => {"b", "b"}}.each do |id, (key, slot)|
      ctx = in_comparer
      r[id].chords.should eq([Gori::Verb::Chord.new(key)])
      r[id].call(ctx)
      ctx.call_names.should eq([:comparer_pick])
      ctx.args_for(:comparer_pick).should eq([slot])
    end
  end

  it "gates every Comparer verb on the Comparer tab" do
    elsewhere = FakeExecContext.new
    {"comparer.swap"             => :comparer_swap,
     "comparer.toggle-pane"      => :comparer_toggle_pane,
     "comparer.new"              => :comparer_new,
     "comparer.rename-subtab"    => :comparer_rename_subtab,
     "comparer.close-subtab"     => :comparer_close_subtab,
     "comparer.duplicate-subtab" => :comparer_duplicate_subtab,
    }.each do |id, intent|
      r[id].available?(elsewhere).should be_false
      r[id].available?(in_comparer).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  it "keeps New in :common and the chip actions on :subtab" do
    r["comparer.new"].section.should eq(:common)
    %w[comparer.rename-subtab comparer.close-subtab comparer.duplicate-subtab].each do |id|
      r[id].section.should eq(:subtab)
    end
  end

  it "shows the sub-tab search/filter only with two or more comparisons open" do
    %w[comparer.find-subtab comparer.filter-subtabs].each do |id|
      r[id].section.should eq(:tab)
      r[id].available?(in_comparer(sessions: 1)).should be_false
      r[id].available?(in_comparer(sessions: 2)).should be_true
    end
    verb_intents(r, "comparer.find-subtab").should eq([:subtab_search_open])
    verb_intents(r, "comparer.filter-subtabs").should eq([:subtab_filter_open])
  end
end
