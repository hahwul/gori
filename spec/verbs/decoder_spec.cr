require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/decoder.cr — the Decoder tab. Its body captures every printable key as
# literal text, so these verbs are reachable only from the space menu and the palette;
# the section each one carries decides which pane's menu lists it.
private def in_decoder(read : Bool = false, sessions : Int32 = 0) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :decoder
  ctx.decoder_read_mode = read
  ctx.subtab_search_tab_count = sessions
  ctx
end

describe "Gori::Verbs.register_decoder" do
  r = Gori::Verbs.registry

  it "gates every Decoder verb on the Decoder tab" do
    elsewhere = FakeExecContext.new # :history
    %w[decoder.new decoder.close decoder.rename-subtab decoder.duplicate-subtab
      decoder.clear decoder.mode decoder.save decoder.load].each do |id|
      r[id].scope.should eq(Gori::Verb::Scope::Decoder)
      r[id].available?(elsewhere).should be_false
      r[id].available?(in_decoder).should be_true
    end
  end

  it "keeps New/Close in :common so session management works from inside the body panes" do
    # Tagged :tab/:subtab they were invisible from INPUT/CHAIN/OUTPUT, since the space menu
    # renders COMMON ∪ the focused pane's section only.
    r["decoder.new"].section.should eq(:common)
    r["decoder.close"].section.should eq(:common)
    verb_intents(r, "decoder.new").should eq([:decoder_new])
    verb_intents(r, "decoder.close").should eq([:decoder_close])
  end

  it "routes the pane actions to their own intents, in their own sections" do
    r["decoder.clear"].section.should eq(:input)
    r["decoder.mode"].section.should eq(:output)
    r["decoder.rename-subtab"].section.should eq(:subtab)
    r["decoder.duplicate-subtab"].section.should eq(:subtab)
    {"decoder.clear"            => :decoder_clear,
     "decoder.mode"             => :decoder_cycle_mode,
     "decoder.rename-subtab"    => :decoder_rename_subtab,
     "decoder.duplicate-subtab" => :decoder_duplicate_subtab,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  it "puts save/load in :tab so the tab-bar menu has a group of its own" do
    # This is what seeds has_section?(Decoder, :tab); without it the tab-bar space menu
    # falls back to whichever body pane happened to be focused last.
    r["decoder.save"].section.should eq(:tab)
    r["decoder.load"].section.should eq(:tab)
    verb_intents(r, "decoder.save").should eq([:decoder_save])
    verb_intents(r, "decoder.load").should eq([:decoder_load])
  end

  it "gates Copy on a read-mode pane and routes it through the shared read_copy" do
    r["decoder.copy"].available?(in_decoder).should be_false
    r["decoder.copy"].available?(in_decoder(read: true)).should be_true
    r["decoder.copy"].chords.should eq([Gori::Verb::Chord.new("y")])
    verb_intents(r, "decoder.copy").should eq([:read_copy])
  end

  it "shows the sub-tab search/filter only with two or more conversions open" do
    %w[decoder.find-subtab decoder.filter-subtabs].each do |id|
      r[id].available?(in_decoder(sessions: 1)).should be_false
      r[id].available?(in_decoder(sessions: 2)).should be_true
      r[id].section.should eq(:tab)
    end
    verb_intents(r, "decoder.find-subtab").should eq([:subtab_search_open])
    verb_intents(r, "decoder.filter-subtabs").should eq([:subtab_filter_open])
  end
end
