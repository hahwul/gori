require "../spec_helper"

include Gori::Verb

private def conflict_reg : Registry
  r = Registry.new
  r.register(Definition.new("g.cap", "g.cap", "", Scope::Global, [Chord.new("c")]) { |_| nil })
  r.register(Definition.new("b.copy", "b.copy", "", Scope::Body, [Chord.new("y")]) { |_| nil })
  r.register(Definition.new("rep.send", "rep.send", "", Scope::Replay, [Chord.new("r", ctrl: true)]) { |_| nil })
  r.register(Definition.new("cmp.swap", "cmp.swap", "", Scope::Comparer, [Chord.new("s")]) { |_| nil })
  r
end

describe Gori::Verb::Conflicts do
  it "blocks a same-scope duplicate" do
    reg = conflict_reg
    c = Conflicts.detect(reg, OsProfile::Os::Linux, Keymap::NO_OVERRIDES, "rep.send", Chord.new("r", ctrl: true))
    # rep.send already holds ctrl-r in Replay; proposing it for a *different* Replay verb conflicts.
    reg.register(Definition.new("rep.other", "rep.other", "", Scope::Replay) { |_| nil })
    c2 = Conflicts.detect(reg, OsProfile::Os::Linux, Keymap::NO_OVERRIDES, "rep.other", Chord.new("r", ctrl: true))
    c2.should_not be_nil
    c2.not_nil!.verb_id.should eq("rep.send")
    c2.not_nil!.scope.should eq(Scope::Replay)
  end

  it "allows the same key across DIFFERENT scopes (incl. shadowing a Global chord)" do
    reg = conflict_reg
    # cmp.swap wants `s`; `s` is free in Comparer even though other tabs use it. And a Body
    # verb taking Global `c` is allowed (it shadows capture only on that tab).
    Conflicts.detect(reg, OsProfile::Os::Linux, Keymap::NO_OVERRIDES, "b.copy", Chord.new("c")).should be_nil
  end

  it "does not treat a verb's own chord as a conflict" do
    reg = conflict_reg
    Conflicts.detect(reg, OsProfile::Os::Linux, Keymap::NO_OVERRIDES, "g.cap", Chord.new("c")).should be_nil
  end

  it "evaluates the proposal against the in-progress overrides (pending rebinds count)" do
    reg = conflict_reg
    # Pending: b.copy is being rebound from `y` to `k`. Now proposing `k` for another Body
    # verb must see the pending `k`, and `y` must be free.
    reg.register(Definition.new("b.other", "b.other", "", Scope::Body) { |_| nil })
    working = {"b.copy" => [Chord.new("k")]}
    Conflicts.detect(reg, OsProfile::Os::Linux, working, "b.other", Chord.new("k")).should_not be_nil
    Conflicts.detect(reg, OsProfile::Os::Linux, working, "b.other", Chord.new("y")).should be_nil
  end

  it "formats a readable conflict message" do
    msg = Conflicts::Conflict.new(Chord.new("s", shift: true), "scope.toggle", Scope::Body).message
    msg.should eq("shift-s already bound to scope.toggle in Body")
  end
end
