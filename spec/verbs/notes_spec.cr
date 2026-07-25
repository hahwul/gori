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
    {"notes.new"   => :notes_new,
     "notes.close" => :notes_close,
     "notes.clear" => :notes_clear,
     "notes.edit"  => :notes_edit,
     "notes.goto"  => :notes_goto,
     "notes.find"  => :notes_find,
     "notes.links" => :notes_links,
     "notes.copy"  => :read_copy,
    }.each do |id, intent|
      r[id].scope.should eq(Gori::Verb::Scope::Notes)
      r[id].available?(elsewhere).should be_false
      r[id].available?(in_notes).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  it "keeps every mnemonic distinct within the scope" do
    # The space menu is a first-match find, so a duplicate key would silently make the
    # later verb unreachable. Registry#validate_menu_keys! guards this at boot; assert the
    # Notes scope explicitly since its body swallows every printable key.
    keys = r.select { |v| v.scope.notes? && !v.hidden? }.compact_map(&.menu_key)
    keys.should eq(keys.uniq)
  end

  it "shows the sub-tab search/filter only with two or more notes open" do
    %w[notes.find-subtab notes.filter-subtabs].each do |id|
      r[id].section.should eq(:tab)
      r[id].available?(in_notes(sessions: 1)).should be_false
      r[id].available?(in_notes(sessions: 2)).should be_true
    end
    verb_intents(r, "notes.find-subtab").should eq([:subtab_search_open])
    verb_intents(r, "notes.filter-subtabs").should eq([:subtab_filter_open])
    r["notes.duplicate-subtab"].section.should eq(:subtab)
    verb_intents(r, "notes.duplicate-subtab").should eq([:notes_duplicate_subtab])
  end
end
