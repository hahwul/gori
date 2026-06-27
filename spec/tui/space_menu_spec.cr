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

  it "no-ops (empty entries) for a scope with only hidden nav verbs" do
    ctx = FakeExecContext.new
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::HistoryDetail, ctx) # detail verbs are all hidden
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
    backend.contains?(last).should be_true   # scrolled into view
    backend.contains?(first).should be_false # the top entries scrolled off
  end

  # Every menu-bearing scope's non-hidden verbs must each have a UNIQUE menu key —
  # else two entries would answer the same keypress. Bypasses available? (which is
  # ctx-gated) by reading the registry directly, so coverage is exhaustive.
  it "assigns a unique, non-nil menu key to every non-hidden verb in each menu scope" do
    registry = Gori::Verbs.registry
    menu_scopes = [
      Gori::Verb::Scope::Body, Gori::Verb::Scope::Replay, Gori::Verb::Scope::Findings,
      Gori::Verb::Scope::Comparer, Gori::Verb::Scope::Fuzzer, Gori::Verb::Scope::Intercept,
    ]
    menu_scopes.each do |scope|
      verbs = registry.select { |v| v.scope == scope && !v.hidden? }
      keys = verbs.compact_map(&.menu_key)
      keys.size.should eq(verbs.size)     # no non-hidden verb is left without a key
      keys.uniq.size.should eq(keys.size) # and no two entries collide on one key
    end
  end
end
