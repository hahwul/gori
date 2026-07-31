require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/sitemap.cr — the Sitemap sub-tab (under Target).
describe "Gori::Verbs.register_sitemap" do
  r = Gori::Verbs.registry

  it "navigates the tree, leaving `space` free for the action menu" do
    ctx = FakeExecContext.new
    r["sitemap.down"].call(ctx)
    ctx.args_for(:sitemap_move).should eq(["1"])
    ctx = FakeExecContext.new
    r["sitemap.up"].call(ctx)
    ctx.args_for(:sitemap_move).should eq(["-1"])

    verb_intents(r, "sitemap.toggle").should eq([:sitemap_toggle])
    verb_intents(r, "sitemap.expand").should eq([:sitemap_expand])
    verb_intents(r, "sitemap.collapse").should eq([:sitemap_collapse])
    # `enter` toggles; a redundant `space` expand binding would shadow the helix leader.
    sitemap_verbs = r.select(&.scope.sitemap?)
    sitemap_verbs.should_not be_empty # else the sweep below asserts nothing
    sitemap_verbs.each { |v| v.chords.should_not contain(Gori::Verb::Chord.new("space")) }
  end

  it "routes the tree actions to their own intents" do
    {"sitemap.query"           => :sitemap_query,
     "sitemap.tag"             => :sitemap_tag,
     "sitemap.toggle-grouping" => :sitemap_toggle_grouping,
     "sitemap.scope-toggle"    => :scope_toggle_lens,
     "sitemap.discover"        => :sitemap_discover,
     "sitemap.repeater"        => :sitemap_repeater,
     "sitemap.open-flow"       => :sitemap_open_flow,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  # #539: the action existed nowhere — no chord, no registry entry — so the space menu could
  # not reach the bytes behind a tree node. Registering it is what wires BOTH surfaces.
  it "opens the selected endpoint's flow on `o`, and shows it in the action menu" do
    verb = r["sitemap.open-flow"]
    verb.chords.should eq([Gori::Verb::Chord.new("o")])
    verb.hidden?.should be_false # else it reaches neither the space menu nor Help
    verb.menu_key.should eq('o') # what for_scope+SpaceMenu need to render a row
    # Same chord as the two siblings that make the same jump, so `o` means one thing.
    r["issue.open-flow"].chords.should eq([Gori::Verb::Chord.new("o")])
    r["probe.open-flow"].chords.should eq([Gori::Verb::Chord.new("o")])
  end

  # The space menu filters on available? while validate_menu_keys! does not, so an entry can
  # pass boot validation and still never render. Assert the gate the MENU actually applies.
  it "stays available in the Sitemap scope with no marks set (the space menu's own gate)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :target
    r["sitemap.open-flow"].available?(ctx).should be_true
  end

  it "gives the scope toggle an explicit 's' menu key (its only chord is ⇧S)" do
    verb = r["sitemap.scope-toggle"]
    verb.chords.should eq([Gori::Verb::Chord.new("s", shift: true)])
    verb.menu_key.should eq('s') # a shifted chord yields no menu key on its own
  end

  it "escapes back to the Sitemap/Discover strip, not the tab bar" do
    ctx = FakeExecContext.new
    r["sitemap.to-menu"].call(ctx)
    ctx.args_for(:focus_pane).should eq(["subtabs"])
  end

  it "leaves every Sitemap verb ungated by the TAB — the scope alone means the sub-tab has focus" do
    # command_scope returns Sitemap only when that sub-tab is focused, so a current_tab
    # predicate here would check the retired :sitemap top-level symbol and never fire.
    ctx = FakeExecContext.new
    ctx.current_tab = :target
    ctx.sitemap_marked_count = 1 # the one legitimate state gate (see mark-clear below)
    sitemap_verbs = r.select(&.scope.sitemap?)
    sitemap_verbs.should_not be_empty # else the sweep below asserts nothing
    sitemap_verbs.each(&.available?(ctx).should(be_true))
  end

  it "routes the mark gestures, and hides Clear marks until something is marked" do
    {"sitemap.mark-toggle" => :sitemap_mark_toggle,
     "sitemap.mark-clear"  => :sitemap_mark_clear,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }

    ctx = FakeExecContext.new
    r["sitemap.mark-extend-down"].call(ctx)
    ctx.args_for(:sitemap_mark_extend).should eq(["1"])
    ctx = FakeExecContext.new
    r["sitemap.mark-extend-up"].call(ctx)
    ctx.args_for(:sitemap_mark_extend).should eq(["-1"])

    # Menu-only, and only while a mark is set — an always-listed "Clear marks" is a dead row.
    clear = r["sitemap.mark-clear"]
    clear.chords.should be_empty
    clear.menu_key.should eq('N')
    ctx = FakeExecContext.new
    clear.available?(ctx).should be_false
    ctx.sitemap_marked_count = 2
    clear.available?(ctx).should be_true
  end

  it "gives `t` to marking and moves tagging to ⇧T (with an explicit menu key)" do
    # The two lists agree on `t` = mark; a shifted chord yields no menu key on its own, so the
    # tag entry carries 'T' explicitly.
    r["sitemap.mark-toggle"].chords.should eq([Gori::Verb::Chord.new("t")])
    r["sitemap.mark-toggle"].menu_key.should eq('t')
    tag = r["sitemap.tag"]
    tag.chords.should eq([Gori::Verb::Chord.new("t", shift: true)])
    tag.menu_key.should eq('T')
  end

  it "extends the range on ⇧arrows without shadowing plain tree nav" do
    # Keymap#lookup matches a Chord EXACTLY, so these never collide with sitemap.up/down.
    r["sitemap.mark-extend-up"].chords.should eq([Gori::Verb::Chord.new("up", shift: true)])
    r["sitemap.mark-extend-down"].chords.should eq([Gori::Verb::Chord.new("down", shift: true)])
    r["sitemap.up"].chords.should contain(Gori::Verb::Chord.new("up"))
    r["sitemap.down"].chords.should contain(Gori::Verb::Chord.new("down"))
    # Hidden like the other nav primitives — they're a gesture, not a menu row.
    r["sitemap.mark-extend-up"].hidden?.should be_true
    r["sitemap.mark-extend-down"].hidden?.should be_true
  end
end
