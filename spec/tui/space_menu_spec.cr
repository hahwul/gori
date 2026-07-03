require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

describe Gori::Tui::SpaceMenu do
  it "lists ONLY the focused area's own verbs that carry a menu key" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64 # flow-gated Body actions available
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.body?).should be_true         # strictly scope-local
    menu.entries.all?(&.menu_key).should be_true            # every shown entry has a key
    menu.entries.map(&.id).should contain("history.replay") # an area action
    menu.entries.map(&.id).should_not contain("app.quit")   # NOT the app-control (palette) surface
  end

  it "resolves a mnemonic key to its verb (and nil for an unmapped key)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx)

    menu.verb_for('y').try(&.id).should eq("history.copy")
    menu.verb_for('r').try(&.id).should eq("history.replay")
    menu.verb_for('Q').should be_nil # no entry bound to this key
  end

  it "moves the selection within entries (clamped both ends)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx)

    menu.move(-5)
    menu.selected.should eq(0)
    menu.move(99)
    menu.selected.should eq(menu.entries.size - 1)
  end

  it "lists the open flow's actions in the History detail scope (mirrors the list menu)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::HistoryDetail, ctx) # detail drill-in is navigable now

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.history_detail?).should be_true # strictly scope-local
    ids = menu.entries.map(&.id)
    ids.should contain("detail.replay")     # flow action carried over from the list
    ids.should contain("detail.toggle-hex") # a detail-only view toggle
    menu.verb_for('r').try(&.id).should eq("detail.replay")
    menu.verb_for('x').try(&.id).should eq("detail.toggle-hex")
  end

  it "lists the scope-rule actions in the Project scope pane (space replaced the lens toggle)" do
    ctx = FakeExecContext.new
    ctx.scope_has_rule = true # edit/delete are gated on a selected rule
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Project, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("scope.lens-toggle") # the lens toggle is now a menu item, not a bare space key
    ids.should contain("scope.add-rule")
    ids.should contain("scope.edit-rule")
    ids.should contain("scope.delete-rule")
    menu.verb_for('s').try(&.id).should eq("scope.lens-toggle")
    menu.verb_for('a').try(&.id).should eq("scope.add-rule")
  end

  it "lists the Notes tab's actions in the Notes scope (reachable from the sub-tab strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :notes
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Notes, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.notes?).should be_true
    menu.entries.all?(&.menu_key).should be_true
    ids = menu.entries.map(&.id)
    ids.should contain("notes.new")
    ids.should contain("notes.close")
    ids.should contain("notes.copy")
    menu.verb_for('y').try(&.id).should eq("notes.copy")
    menu.verb_for('n').try(&.id).should eq("notes.new")
    menu.verb_for('w').try(&.id).should eq("notes.close")
  end

  it "lists the Prism list's detail-parity actions (promote, evidence, delete)" do
    ctx = FakeExecContext.new
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Prism, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("prism.promote-selected")
    ids.should contain("prism.open-evidence")
    ids.should contain("prism.replay-evidence")
    ids.should contain("prism.delete-selected")
    menu.verb_for('p').try(&.id).should eq("prism.promote-selected")
    menu.verb_for('o').try(&.id).should eq("prism.open-evidence")
    menu.verb_for('r').try(&.id).should eq("prism.replay-evidence")
    menu.verb_for('d').try(&.id).should eq("prism.delete-selected")
    menu.verb_for('v').try(&.id).should eq("prism.open")
    menu.verb_for('g').try(&.id).should eq("prism.dismiss-code")
  end

  it "lists the Convert tab's actions in the Convert scope (reachable from the sub-tab strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :convert # the Convert verbs gate on the active tab
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Convert, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.convert?).should be_true # strictly scope-local
    menu.entries.all?(&.menu_key).should be_true       # every shown entry has a key
    ids = menu.entries.map(&.id)
    ids.should contain("convert.new")
    ids.should contain("convert.close")
    ids.should contain("convert.copy")
    menu.verb_for('n').try(&.id).should eq("convert.new")
    menu.verb_for('w').try(&.id).should eq("convert.close")
    menu.verb_for('y').try(&.id).should eq("convert.copy")
  end

  it "hides the scope rule edit/delete entries when no rule is selected" do
    ctx = FakeExecContext.new # scope_has_rule defaults to false
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Project, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("scope.lens-toggle") # always available
    ids.should contain("scope.add-rule")    # always available
    ids.should_not contain("scope.edit-rule")
    ids.should_not contain("scope.delete-rule")
  end

  it "no-ops (empty entries) for a scope with only hidden nav verbs" do
    ctx = FakeExecContext.new
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Sidebar, ctx) # tab-bar nav verbs are all hidden
    menu.entries.empty?.should be_true
  end

  it "renders a bottom-right SPACE popup with the mnemonic key + title" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx)

    backend = MemoryBackend.new(80, 24)
    menu.render(Screen.new(backend), Rect.new(0, 3, 80, 20))
    backend.contains?("SPACE").should be_true     # the card title
    backend.contains?("Copy flow").should be_true # an entry title
  end

  it "scrolls to keep the selection on-screen when the popup is shorter than the list" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx)
    menu.entries.size.should be > 4 # Body has ~10 entries

    last = menu.entries.last.title
    first = menu.entries.first.title
    menu.move(menu.entries.size) # clamp to the last entry

    backend = MemoryBackend.new(40, 8)
    menu.render(Screen.new(backend), Rect.new(0, 0, 40, 6)) # short body → only ~4 rows fit
    backend.contains?(last).should be_true                  # scrolled into view
    backend.contains?(first).should be_false                # the top entries scrolled off
  end

  it "grows past the old 12-row cap to fit a busy scope without scrolling (History Body has 13)" do
    # ctx-independent: 15 synthetic entries on a tall body. Old MAX_ROWS=12 clamped the
    # popup to 14 rows (scrolling 3 off); now it grows to fit all 15 (cap 16).
    reg = Gori::Verb::Registry.new
    15.times do |i|
      reg.register(Gori::Verb::Definition.new(
        "demo.#{i}", "Item #{i}", "x", Gori::Verb::Scope::Body, mnemonic: ('a'.ord + i).unsafe_chr) { |_| nil })
    end
    menu = SpaceMenu.new(reg)
    menu.open(Gori::Verb::Scope::Body, FakeExecContext.new)
    menu.entries.size.should eq(15)

    b = menu.box(Rect.new(0, 0, 60, 40)) # tall body — height is entry-bound, not body-bound
    b.h.should eq(15 + 2)                # all 15 rows + frame; the old cap would have clamped to 14

    backend = MemoryBackend.new(60, 40)
    menu.render(Screen.new(backend), Rect.new(0, 0, 60, 40))
    backend.contains?("Item 0").should be_true  # first entry shown
    backend.contains?("Item 14").should be_true # AND the last — nothing clipped
    backend.contains?("▼").should be_false      # so no scroll marker
  end

  it "draws a ▼ scroll marker when entries are hidden below (short terminal)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, ctx) # selection at the top → list clipped at the bottom

    backend = MemoryBackend.new(40, 8)
    menu.render(Screen.new(backend), Rect.new(0, 0, 40, 6)) # ~4 rows fit, 13 entries
    backend.contains?("▼").should be_true                   # "more below" affordance is visible
    backend.contains?("▲").should be_false                  # nothing hidden above at the top
  end

  # Per menu scope, the keyed entries must never collide, and any verb with NO chord
  # at all must carry a mnemonic (else it's unreachable by ANY single key — the
  # oversight this guards). A verb whose only chord is ctrl/shift (e.g. Replay's
  # ^X/^S/^L toggles, rebindable since the hotkeys feature) legitimately has no
  # single-key handle and is just excluded from the menu. Reads the registry
  # directly to bypass the ctx-gated available?, so coverage is exhaustive.
  it "gives every chordless menu verb a mnemonic, and never collides keys within a scope" do
    registry = Gori::Verbs.registry
    menu_scopes = [
      Gori::Verb::Scope::Body, Gori::Verb::Scope::Replay, Gori::Verb::Scope::Findings,
      Gori::Verb::Scope::Comparer, Gori::Verb::Scope::Fuzzer, Gori::Verb::Scope::Intercept,
      Gori::Verb::Scope::HistoryDetail, Gori::Verb::Scope::FindingsDetail,
      Gori::Verb::Scope::Project, Gori::Verb::Scope::Convert, Gori::Verb::Scope::Notes,
      Gori::Verb::Scope::Sitemap,
      Gori::Verb::Scope::Miner, Gori::Verb::Scope::Prism, Gori::Verb::Scope::PrismDetail,
    ]
    menu_scopes.each do |scope|
      verbs = registry.select { |v| v.scope == scope && !v.hidden? }
      verbs.select(&.chords.empty?).all?(&.menu_key).should be_true # chordless ⇒ keyed
      keys = verbs.compact_map(&.menu_key)
      keys.uniq.size.should eq(keys.size) # no two entries collide on one key
    end
  end

  # Registry#validate_menu_keys! turns the convention above into a BOOT-TIME invariant:
  # Verbs.registry calls it, so a colliding menu key crashes at startup instead of
  # silently shadowing a verb (SpaceMenu#verb_for is a first-match find).
  describe "Registry#validate_menu_keys!" do
    it "passes on the shipped registry" do
      Gori::Verbs.registry.validate_menu_keys! # builds + re-checks; must not raise
    end

    it "raises on two verbs sharing a menu key WITHIN one scope" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "first",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.b", "demo:b", "second",
        Gori::Verb::Scope::Body, mnemonic: 'z') { |_| nil }) # derives the same 'z'
      expect_raises(Gori::Error, /space-menu key collision/) { reg.validate_menu_keys! }
    end

    it "allows the same menu key across DIFFERENT scopes (scoped menu, deliberate reuse)" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "first",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.b", "demo:b", "second",
        Gori::Verb::Scope::Replay, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.validate_menu_keys! # cross-scope reuse must not raise
    end

    it "ignores hidden verbs (not shown in the menu, so their key can't collide)" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "shown",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.hidden", "demo:hidden", "hidden",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")], hidden: true) { |_| nil })
      reg.validate_menu_keys! # the hidden verb never fronts a menu key
    end
  end
end
