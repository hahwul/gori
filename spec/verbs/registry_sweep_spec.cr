require "../spec_helper"
require "../support/fake_context"

# A chord that fires on a single unmodified keypress (a lone letter / named key).
private def bare_chord?(chord : Gori::Verb::Chord) : Bool
  !chord.ctrl && !chord.alt && !chord.shift
end

# Whole-registry invariants over EVERY verb file under src/gori/verbs/, not just one.
# Kept out of the per-file specs on purpose: a failure here names the offending verb id,
# and filing it under any single register_* group would send the reader to the wrong file.
describe "Gori::Verbs.registry (every verb)" do
  r = Gori::Verbs.registry

  it "registers a non-trivial number of verbs" do
    # Guards the two sweeps below: if the registry ever came back empty (or nearly so),
    # `select`/`each` over it would assert nothing and both would pass vacuously.
    r.size.should be > 100
  end

  # A verb whose handler dispatches nothing is a dead palette/menu entry: it renders, it
  # fires, and nothing happens. Nothing in the type system catches that.
  it "dispatches at least one ExecContext intent per verb" do
    dead = r.select { |v| verb_intents(r, v.id).empty? }.map(&.id)
    dead.should be_empty
  end

  # available? runs on every keypress and on every palette / space-menu render, over a
  # context whose panes may be empty — a raise there takes the whole TUI down.
  it "answers available? on a bare context without raising, for every verb" do
    ctx = FakeExecContext.new
    answered = r.count { |v| !v.available?(ctx).nil? }
    answered.should eq(r.size)
  end

  # #442 made the History verbs act on N flows by widening what they TARGET, not by adding a
  # second set of ids. A `history.batch-delete` beside `history.delete` would be two
  # declarations of one feature — two menu rows, two keybindings to keep in sync, two places
  # to fix a bug (P1, one execution path). This is the cheap guard against that drifting back.
  it "has no parallel batch-* twin of an existing verb" do
    ids = r.map(&.id).to_set
    twins = ids.select do |id|
      parts = id.split('.', 2)
      parts.size == 2 && parts[1].starts_with?("batch-") &&
        ids.includes?("#{parts[0]}.#{parts[1].lchop("batch-")}")
    end
    twins.should be_empty
  end

  it "gives every verb a non-empty id, title and description" do
    # All three are user-visible in the palette; a blank one ships as an unlabelled row.
    r.each do |v|
      v.id.should_not be_empty
      v.title.should_not be_empty
      v.description.should_not be_empty
    end
  end

  # The ⇧X convention (#899) modelled as a group: a store-emptying verb is :wipe, a
  # selection-delete is :danger. The one part of the policy that is genuinely checkable
  # from the registry alone: a WIPE verb's chord, if it has one, must be MODIFIED —
  # never a bare unmodified letter — so "empty the whole tab" can't ride a single tap.
  # Selection-deletes (:danger) on a bare `d` stay legal; that is the established shape.
  # (Confirm-gating is NOT checkable here — the @host.confirm call lives in the
  # controller, not the registry — so it stays a documented convention, not a spec.)
  #
  # This goes by Verb::Definition#group (a hand-assigned semantic band), never by an id
  # regex: the eighteen *.clear-selection and five *.mark-clear verbs are :none and drop
  # out on their own, which is the point — a name match would mislabel every one of them.
  it "gives every :wipe verb a modified chord (or none)" do
    wipes = r.select(&.group.==(:wipe))
    wipes.should_not be_empty # would pass vacuously if the band ever emptied
    wipes.each do |v|
      v.chords.each do |c|
        bare_chord?(c).should be_false # e.g. shift-x, ctrl-…, never a lone letter
      end
    end
  end

  it "flags a bare-chord :wipe verb (proves the guard bites)" do
    reg = Gori::Verb::Registry.new
    reg.register(Gori::Verb::Definition.new(
      "demo.wipe", "Wipe", "x", Gori::Verb::Scope::Body,
      [Gori::Verb::Chord.new("z")], group: :wipe) { |_| nil })
    offenders = reg.select(&.group.==(:wipe)).select { |v| v.chords.any? { |c| bare_chord?(c) } }
    offenders.map(&.id).should eq(["demo.wipe"])
  end

  it "keeps sibling deletes in the same severity band (probe.delete ⇔ probe.delete-selected)" do
    # The list-scope and detail-scope forms of one delete are the same action; they must
    # not drift apart the way they had (:danger vs :none) before #899's convention landed.
    r["probe.delete"].group.should eq(r["probe.delete-selected"].group)
  end

  it "tags the five ⇧X store-wipes as :wipe, so the convention reads off the registry" do
    %w[history.clear probe.clear authorize.clear activity.clear issues.clear].each do |id|
      r[id].group.should eq(:wipe)
    end
  end
end
