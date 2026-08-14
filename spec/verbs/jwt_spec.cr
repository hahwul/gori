require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/jwt.cr — the JWT workbench tab.
private def in_jwt(read : Bool = false, sessions : Int32 = 0) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :jwt
  ctx.jwt_read_mode = read
  ctx.subtab_search_tab_count = sessions
  ctx
end

describe "Gori::Verbs.register_jwt" do
  r = Gori::Verbs.registry

  it "keeps session management and the lens toggles in :common (reachable from every pane)" do
    {"jwt.new"          => :jwt_new,
     "jwt.close"        => :jwt_close,
     "jwt.toggle-mode"  => :jwt_toggle_mode,
     "jwt.cycle-alg"    => :jwt_cycle_alg,
     "jwt.load-decoded" => :jwt_load_decoded,
     "jwt.clear"        => :jwt_clear,
    }.each do |id, intent|
      r[id].section.should eq(:common)
      r[id].available?(FakeExecContext.new).should be_false # gated on the JWT tab
      r[id].available?(in_jwt).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  # `y` in READ, `^Y` in INS too — see decoder.copy for the reasoning. `^Y` used to be a
  # hardcoded copy-all chord in JwtController; folded in here so the INPUT/header/payload
  # editors get it while typing, and so it is rebindable.
  it "gates the smart Copy on a read-mode pane OR a focused editor, but not the pane-specific copies" do
    r["jwt.copy"].available?(in_jwt).should be_false
    r["jwt.copy"].available?(in_jwt(read: true)).should be_true
    r["jwt.copy"].chords.should eq([
      Gori::Verb::Chord.new("y"), Gori::Verb::Chord.new("y", ctrl: true),
    ])
    verb_intents(r, "jwt.copy").should eq([:jwt_copy])

    ins = in_jwt # read_mode false — an editable pane in INSERT
    ins.editor_focused = true
    r["jwt.copy"].available?(ins).should be_true

    # copy-token / copy-attack copy a computed value, not a text selection, so they only
    # need the tab — and they live in the section of the pane that value comes from.
    r["jwt.copy-token"].section.should eq(:output)
    r["jwt.copy-attack"].section.should eq(:attacks)
    r["jwt.copy-token"].available?(in_jwt).should be_true
    r["jwt.copy-attack"].available?(in_jwt).should be_true
    verb_intents(r, "jwt.copy-token").should eq([:jwt_copy_token])
    verb_intents(r, "jwt.copy-attack").should eq([:jwt_copy_attack])
  end

  it "puts rename/duplicate on :subtab and search/filter on :tab" do
    r["jwt.rename-subtab"].section.should eq(:subtab)
    r["jwt.duplicate-subtab"].section.should eq(:subtab)
    verb_intents(r, "jwt.rename-subtab").should eq([:jwt_rename_subtab])
    verb_intents(r, "jwt.duplicate-subtab").should eq([:jwt_duplicate_subtab])

    %w[jwt.find-subtab jwt.filter-subtabs].each { |id| r[id].section.should eq(:tab) }
    # These two used to share one `has_many` lambda. They no longer can: the strip's ⌕
    # affordance opens the picker from the first session, while filtering one chip narrows
    # nothing. Asserted apart so re-merging the lambda fails here.
    r["jwt.find-subtab"].available?(in_jwt(sessions: 1)).should be_true
    r["jwt.filter-subtabs"].available?(in_jwt(sessions: 1)).should be_false
    %w[jwt.find-subtab jwt.filter-subtabs].each do |id|
      r[id].available?(in_jwt(sessions: 2)).should be_true
    end
    verb_intents(r, "jwt.find-subtab").should eq([:subtab_search_open])
    verb_intents(r, "jwt.filter-subtabs").should eq([:subtab_filter_open])
  end
end
