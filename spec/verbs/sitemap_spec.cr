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
    sitemap_verbs.each { |v| v.chords.should_not contain(typed_chord("space")) }
  end

  it "routes the tree actions to their own intents" do
    {"sitemap.query"             => :sitemap_query,
     "sitemap.tag"               => :sitemap_tag,
     "sitemap.toggle-grouping"   => :sitemap_toggle_grouping,
     "sitemap.toggle-query-fold" => :sitemap_toggle_query_fold,
     "sitemap.scope-toggle"      => :scope_toggle_lens,
     "sitemap.discover"          => :sitemap_discover,
     "sitemap.repeater"          => :sitemap_repeater,
     "sitemap.open-flow"         => :sitemap_open_flow,
     "sitemap.scope-add"         => :sitemap_scope_add,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  # The tree is where you SEE what is worth scoping, but the rule editor lived only in the
  # Project tab — so scoping a host you just found meant retyping it there.
  it "adds the cursor row to the scope on `a`, the same chord the Project scope pane uses" do
    verb = r["sitemap.scope-add"]
    verb.chords.should eq([typed_chord("a")])
    verb.hidden?.should be_false # else it reaches neither the space menu nor Help
    verb.menu_key.should eq('a')
    # Same gesture as the popup's other door, so `a` means "add a scope rule" in both places.
    r["scope.add-rule"].chords.should eq([typed_chord("a")])
    # 's' still belongs to the LENS toggle here — adding a rule and filtering by it are
    # distinct actions, and the toast after a save points at 's'.
    r["sitemap.scope-toggle"].menu_key.should eq('s')
  end

  # Query folding is its OWN axis: `g` hides ids, ⇧G hides the query strings a fuzzed
  # endpoint fills the tree with. Overloading `g` with both would make "show me every
  # literal id" also dump every payload ever sent to /search.
  it "puts query folding on ⇧G, its own chord and its own menu key" do
    verb = r["sitemap.toggle-query-fold"]
    verb.chords.should eq([typed_chord("g", shift: true)])
    r["sitemap.toggle-grouping"].chords.should eq([typed_chord("g")]) # unchanged
    verb.hidden?.should be_false                                      # else it reaches neither the space menu nor Help
    # A shift chord yields no menu key, so the mnemonic is what the action menu renders —
    # and it must not collide with the id toggle's chord-derived 'g'.
    verb.menu_key.should eq('Q')
    keys = r.select(&.scope.sitemap?).compact_map(&.menu_key)
    keys.size.should eq(keys.uniq.size)
  end

  # #539: the action existed nowhere — no chord, no registry entry — so the space menu could
  # not reach the bytes behind a tree node. Registering it is what wires BOTH surfaces.
  it "opens the selected endpoint's flow on `o`, and shows it in the action menu" do
    verb = r["sitemap.open-flow"]
    verb.chords.should eq([typed_chord("o")])
    verb.hidden?.should be_false # else it reaches neither the space menu nor Help
    verb.menu_key.should eq('o') # what for_scope+SpaceMenu need to render a row
    # Same chord as the two siblings that make the same jump, so `o` means one thing.
    r["issue.open-flow"].chords.should eq([typed_chord("o")])
    r["probe.open-flow"].chords.should eq([typed_chord("o")])
  end

  # The space menu filters on available? while validate_menu_keys! does not, so an entry can
  # pass boot validation and still never render. Assert the gate the MENU actually applies.
  it "stays available in the Sitemap scope with no marks set (the space menu's own gate)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :target
    r["sitemap.open-flow"].available?(ctx).should be_true
  end

  it "keeps the scope toggle a menu row under 's' — the Global `s` is its key" do
    verb = r["sitemap.scope-toggle"]
    verb.chords.should be_empty # the ⇧S twin of the Global lens toggle is gone
    verb.menu_key.should eq('s')
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

  it "gives `t` to marking and leaves ⇧T unbound, with tagging menu-only" do
    # The lists agree on `t` = mark. ⇧T is where they STOPPED agreeing: History, Issues and
    # Intercept all read it as "mark all", so a hand that learnt the `t`/⇧T pair there opened
    # a text prompt here. Tagging is a space-menu entry now, like `sitemap.mark-clear`, and
    # ⇧T is deliberately left free rather than reassigned — a tree has no useful "mark every
    # row" today (see sitemap.mark-toggle), and this keeps the letter for the day it does.
    r["sitemap.mark-toggle"].chords.should eq([typed_chord("t")])
    r["sitemap.mark-toggle"].menu_key.should eq('t')
    tag = r["sitemap.tag"]
    tag.chords.should be_empty
    tag.menu_key.should eq('T')
    shift_t = typed_chord("t", shift: true)
    sitemap_verbs = [] of Gori::Verb::Definition
    r.each { |v| sitemap_verbs << v if v.scope.sitemap? }
    sitemap_verbs.none? { |v| v.chords.includes?(shift_t) }.should be_true
  end

  it "extends the range on ⇧arrows without shadowing plain tree nav" do
    # Keymap#lookup matches a Chord EXACTLY, so these never collide with sitemap.up/down.
    r["sitemap.mark-extend-up"].chords.should eq([typed_chord("up", shift: true)])
    r["sitemap.mark-extend-down"].chords.should eq([typed_chord("down", shift: true)])
    r["sitemap.up"].chords.should contain(typed_chord("up"))
    r["sitemap.down"].chords.should contain(typed_chord("down"))
    # Hidden like the other nav primitives — they're a gesture, not a menu row.
    r["sitemap.mark-extend-up"].hidden?.should be_true
    r["sitemap.mark-extend-down"].hidden?.should be_true
  end
end
