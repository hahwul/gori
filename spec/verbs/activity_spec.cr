require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/activity.cr — the Project tab's ACTIVITY pane (#864), a read-only window over
# the event feed plus one destructive verb.
describe "Gori::Verbs.register_activity" do
  r = Gori::Verbs.registry

  it "registers every activity verb in its own pane scope" do
    {"activity.open"          => :activity_open,
     "activity.filter-source" => :activity_filter_source,
     "activity.filter-level"  => :activity_filter_level,
     "activity.find"          => :activity_find,
     "activity.clear-filters" => :activity_clear_filters,
     "activity.clear"         => :activity_clear,
    }.each do |id, intent|
      r[id].scope.should eq(Gori::Verb::Scope::ProjectActivity)
      verb_intents(r, id).should eq([intent])
    end
  end

  # The one that matters, and it is now about BOTH letters. `c` is `capture.toggle` in Global
  # scope and a scoped chord beats the Global fallback, so binding the feed wipe to bare `c`
  # would silently replace "stop capture" with "destroy the audit trail" on this one pane, for
  # the key an operator hits by reflex. ⇧C cleared that bar and still left the wipe one shift
  # above it; ⇧X clears it with room, because bare `x` is bound in none of the clear-all scopes
  # at all — there is no unmodified neighbour for the shift to slip off.
  it "keeps the destructive clear off the capture-toggle key, and off its shift" do
    r["capture.toggle"].scope.should eq(Gori::Verb::Scope::Global)
    r["capture.toggle"].chords.should eq([typed_chord("c")])

    # `shift_chord` round-trips through `Keybind.from_event`, NOT a hand-written chord: a
    # capital spelling (`typed_chord("X")`) satisfies an equality assertion perfectly and still
    # never fires, because from_event normalises a typed capital to shift+lowercase. Asserting
    # the DECLARATION against a twin of itself is what let that dead binding ship.
    r["activity.clear"].chords.should eq([shift_chord('X')])
    r["activity.clear"].chords.should_not contain(typed_chord("c"))
    r["activity.clear"].chords.should_not contain(shift_chord('C'))
    r["activity.clear"].chords.should_not contain(typed_chord("x"))
    r["activity.clear"].menu_key.should eq('X')
    r["activity.clear"].group.should eq(:wipe)
  end

  # One chord, five scopes — History, Probe, Authorize, the Issues list and this pane all spell
  # the wipe the same way, and all five hang the space menu off `X`.
  #
  # Enumerated from the `:wipe` BAND, not from a list of ids restated here. The four-id literal
  # this replaces claimed a sixth member picking its own letter would fail here, and it could
  # not: a hand-written list only ever checks itself. The Issues tab was the proof — it had no
  # clear verb at all while the family was advertised app-wide as "one chord clears a tab", so
  # ⇧X there did nothing and no spec in the suite could notice. Membership is pinned below so
  # a verb dropping OUT of the band is a failure rather than a silently shorter loop.
  it "spells the wipe the way every other clear-all verb does" do
    wipes = r.select(&.group.==(:wipe))
    wipes.map(&.id).sort!.should eq(
      %w[activity.clear authorize.clear history.clear issues.clear probe.clear])
    wipes.each do |v|
      v.chords.should eq([shift_chord('X')]), v.id
      v.menu_key.should eq('X'), v.id
      # The letter under the shift is free in each of those scopes — that is the property that
      # made ⇧X the right key, and it is the one a later bare-`x` binding would quietly break.
      r.select { |o| o.scope == v.scope && o.chords.includes?(typed_chord("x")) }
        .map(&.id).should be_empty, "bare `x` is bound in #{v.scope}, under #{v.id}'s shift"
    end
  end

  # The declaration says ⇧X; this says the DISPATCH agrees. `Keymap#lookup` is what the runner
  # asks on a keypress, so a chord spelled in a way `Keybind.from_event` never produces —
  # `typed_chord("X")` — is dead here and nowhere else: every assertion above would still pass.
  # Bare `c` rides along because it is the reason the letter is ⇧X and not ⇧C: it is LIVE in
  # every one of those scopes — `capture.toggle` by Global fallback in four, and
  # `probe.dismiss-selected` shadowing it on the Probe list — so ⇧C would have put a project
  # wipe one shift above a key that does something harmless and frequent. Asserted as "resolves, and never to the wipe"
  # rather than to one id, because which harmless verb answers it is not the point.
  it "dispatches ⇧X to the right wipe in every scope that has one" do
    km = Gori::Verb::Keymap.build(Gori::Verbs.registry)
    x = shift_chord('X')
    r.select(&.group.==(:wipe)).each do |v|
      km.lookup(x, v.scope).should eq(v.id)
      under_c = km.lookup(typed_chord("c"), v.scope)
      under_c.should_not be_nil, "bare `c` is unbound in #{v.scope}"
      under_c.should_not eq(v.id)
    end

    # And the two scopes that used to spend ⇧X on "Enable/disable everywhere" — a toggle with
    # no confirm — no longer do: ⇧X is the wipe chord and nothing quieter, so a hand trained
    # on the five wipes cannot flip every default rule off where it expected a card.
    km.lookup(x, Gori::Verb::Scope::Rewriter).should be_nil
    km.lookup(x, Gori::Verb::Scope::Colormarker).should be_nil
  end

  # ↵ is the second chord on `open` rather than a hard-coded twin in the key handler, so the
  # Hotkeys editor can see it — the same shape `discover.open-flow` uses.
  it "reaches the jump from both ↵ and o" do
    r["activity.open"].chords.should eq([typed_chord("o"), typed_chord("enter")])
  end

  # Each chip cycles back to "all" where it was set, so releasing all three at once does not
  # need a top-level key.
  #
  # 'N' and NOT the 'x' it used to hold: `activity.clear` owns the house `X`, and `x Clear
  # filters` directly above `X Clear activity` would put "reset a narrowing" and "permanently
  # delete the agent audit trail" in adjacent menu rows separated by nothing but the shift.
  # The pair is asserted together, because the defect is the RELATIONSHIP, not either letter.
  it "keeps the filter reset a full letter away from the feed wipe in the menu" do
    r["activity.clear-filters"].chords.should be_empty
    r["activity.clear-filters"].menu_key.should eq('N')
    r["activity.clear-filters"].menu_key.try(&.upcase).should_not eq(r["activity.clear"].menu_key)
    # 'N' is what `history.mark-clear` already spends on the same word.
    r["history.mark-clear"].menu_key.should eq('N')
  end

  it "routes the pane's verbs through the context" do
    ctx = FakeExecContext.new
    r["activity.clear"].call(ctx)
    ctx.calls.map(&.name).should contain(:activity_clear)
  end
end
