require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/sequencer.cr — "Send to Sequencer" from four surfaces, plus the
# Sequencer tab's own run/stop/configure.
describe "Gori::Verbs.register_sequencer" do
  r = Gori::Verbs.registry

  it "sends from History only with a flow selected, and from the detail unconditionally" do
    ctx = FakeExecContext.new # :history, nothing selected
    r["history.sequence"].available?(ctx).should be_false
    ctx.selected = 4_i64
    r["history.sequence"].available?(ctx).should be_true
    verb_intents(r, "history.sequence").should eq([:sequence_selected])
    # The detail can only be open over a flow, so it needs no gate — but it must close
    # first so the overlay doesn't float over the Sequencer tab.
    verb_intents(r, "detail.sequence").should eq([:close_detail, :sequence_selected])
  end

  it "sends from Repeater and from the Sitemap through their own intents" do
    repeater = FakeExecContext.new
    repeater.current_tab = :repeater
    r["repeater.sequence"].available?(repeater).should be_true
    r["repeater.sequence"].available?(FakeExecContext.new).should be_false
    verb_intents(r, "repeater.sequence").should eq([:sequence_from_repeater])

    # Scope::Sitemap already means the Target/Sitemap sub-tab has focus; a current_tab
    # predicate would test the retired :sitemap top-level symbol and never fire.
    r["sitemap.sequence"].scope.should eq(Gori::Verb::Scope::Sitemap)
    r["sitemap.sequence"].available?(FakeExecContext.new).should be_true
    verb_intents(r, "sitemap.sequence").should eq([:sequence_from_sitemap])
  end

  it "shares the 'q' menu key across all four send-to-Sequencer surfaces" do
    %w[history.sequence detail.sequence repeater.sequence sitemap.sequence].each do |id|
      r[id].menu_key.should eq('q')
    end
  end

  it "gates run / stop / configure on the Sequencer tab" do
    ctx = FakeExecContext.new
    ctx.current_tab = :sequencer
    {"sequence.run"       => :sequence_run,
     "sequence.stop"      => :sequence_stop,
     "sequence.configure" => :sequence_configure,
    }.each do |id, intent|
      r[id].available?(ctx).should be_true
      r[id].available?(FakeExecContext.new).should be_false
      verb_intents(r, id).should eq([intent])
    end
  end

  it "shows the sub-tab search/filter only with two or more sessions open" do
    ctx = FakeExecContext.new
    ctx.current_tab = :sequencer
    %w[sequence.find-subtab sequence.filter-subtabs].each do |id|
      r[id].available?(ctx).should be_false
      r[id].section.should eq(:tab)
    end
    ctx.subtab_search_tab_count = 2
    r["sequence.find-subtab"].available?(ctx).should be_true
    r["sequence.filter-subtabs"].available?(ctx).should be_true
  end
end
