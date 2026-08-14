require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/notes.cr — the Notes tab's space-menu / palette actions.
private def in_notes(sessions : Int32 = 0) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :notes
  ctx.subtab_search_tab_count = sessions
  ctx
end

describe "Gori::Verbs.register_notes" do
  r = Gori::Verbs.registry

  it "gates every Notes verb on the Notes tab" do
    elsewhere = FakeExecContext.new # :history
    {"notes.new"    => :notes_new,
     "notes.close"  => :notes_close,
     "notes.clear"  => :notes_clear,
     "notes.edit"   => :notes_edit,
     "notes.goto"   => :notes_goto,
     "notes.find"   => :notes_find,
     "notes.links"  => :notes_links,
     "notes.export" => :notes_export,
     "notes.copy"   => :read_copy,
    }.each do |id, intent|
      r[id].scope.should eq(Gori::Verb::Scope::Notes)
      r[id].available?(elsewhere).should be_false
      r[id].available?(in_notes).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  it "puts export on the space menu with no chord, under a capital mnemonic" do
    # 'e' is Edit-in-$EDITOR and 'x' is read_edit.cr's Select line, both already in this
    # scope — hence the capital, following 'S' (Send selection to). A CHORD would be dead
    # weight: the Notes body swallows every printable key, so the space menu and the palette
    # are the only ways in.
    r["notes.export"].menu_key.should eq('E')
    r["notes.export"].section.should eq(:common)
    r["notes.export"].chords.should be_empty
    r["notes.export"].hidden?.should be_false
  end

  it "keeps every mnemonic distinct within the scope" do
    # The space menu is a first-match find, so a duplicate key would silently make the
    # later verb unreachable. Registry#validate_menu_keys! guards this at boot; assert the
    # Notes scope explicitly since its body swallows every printable key.
    keys = r.select { |v| v.scope.notes? && !v.hidden? }.compact_map(&.menu_key)
    keys.should eq(keys.uniq)
  end

  it "shows the sub-tab search from the first note, and the filter only from the second" do
    %w[notes.find-subtab notes.filter-subtabs].each { |id| r[id].section.should eq(:tab) }
    # See comparer_spec: the strip's ⌕ affordance opens this picker from the first session,
    # so the menu entry must not disagree about whether the action exists.
    r["notes.find-subtab"].available?(in_notes(sessions: 1)).should be_true
    r["notes.filter-subtabs"].available?(in_notes(sessions: 1)).should be_false
    %w[notes.find-subtab notes.filter-subtabs].each do |id|
      r[id].available?(in_notes(sessions: 2)).should be_true
    end
    verb_intents(r, "notes.find-subtab").should eq([:subtab_search_open])
    verb_intents(r, "notes.filter-subtabs").should eq([:subtab_filter_open])
    r["notes.duplicate-subtab"].section.should eq(:subtab)
    verb_intents(r, "notes.duplicate-subtab").should eq([:notes_duplicate_subtab])
  end
end
