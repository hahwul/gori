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

  # The one that matters. `c` is `capture.toggle` in Global scope, and a scoped chord beats the
  # Global fallback — so binding the feed wipe to bare `c` would silently replace "stop capture"
  # with "destroy the audit trail" on this one pane, for the key an operator hits by reflex.
  # The other five Project panes pass `c` straight through, and this one must not be the
  # exception that costs a record.
  it "keeps the destructive clear off the capture-toggle key" do
    r["capture.toggle"].scope.should eq(Gori::Verb::Scope::Global)
    r["capture.toggle"].chords.should eq([Gori::Verb::Chord.new("c")])

    # Round-tripped through `Keybind.from_event`, NOT compared to a hand-written chord: a
    # capital spelling (`Chord.new("C")`) satisfies an equality assertion perfectly and still
    # never fires, because from_event normalises a typed capital to shift+lowercase. Asserting
    # the DECLARATION against itself is what let that dead binding ship.
    shift_c = Gori::Tui::Keybind.from_event(
      Termisu::Event::Key.new(Termisu::Input::Key::LowerC, Termisu::Input::Modifier::Shift, char: 'C'))
    r["activity.clear"].chords.should eq([shift_c])
    r["activity.clear"].chords.should_not contain(Gori::Verb::Chord.new("c"))
    r["activity.clear"].group.should eq(:danger)
  end

  # ↵ is the second chord on `open` rather than a hard-coded twin in the key handler, so the
  # Hotkeys editor can see it — the same shape `discover.open-flow` uses.
  it "reaches the jump from both ↵ and o" do
    r["activity.open"].chords.should eq([Gori::Verb::Chord.new("o"), Gori::Verb::Chord.new("enter")])
  end

  # Each chip cycles back to "all" where it was set, so releasing all three at once does not
  # need a top-level key — which is what freed the letter for the verb above.
  it "leaves clear-filters to the space menu" do
    r["activity.clear-filters"].chords.should be_empty
    r["activity.clear-filters"].menu_key.should eq('x')
  end

  it "routes the pane's verbs through the context" do
    ctx = FakeExecContext.new
    r["activity.clear"].call(ctx)
    ctx.calls.map(&.name).should contain(:activity_clear)
  end
end
