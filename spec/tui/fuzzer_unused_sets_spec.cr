require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The TUI's half of `Fuzz::Plan#unused_payload_sets` — the run-start line's third segment.
#
# The CONFIG pane lets an operator stack payload-set rows and pick a mode independently, so this
# is the surface where the two disagree most easily: adding a second set and leaving the mode at
# Sniper is one keystroke that was not there and no keystroke to undo. `Generator` then draws
# from row 0 alone, and every row on screen says the run went fine.
#
# `@unused_sets` is written on EVERY `build_engine` (0 included) rather than revision-scoped the
# way the two framing notes are — the set list and the mode have no edit counter — so the pin
# that matters is that a rebuild RETRACTS a claim the previous build made.
private def fuzzer(*specs : Gori::Tui::SetSpec) : FuzzerView
  view = FuzzerView.new
  view.load_request("http://127.0.0.1:9", "GET /?x=§1§&y=§2§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  specs.each { |s| view.apply_set(nil, s) }
  view
end

private def built(view : FuzzerView) : FuzzerView
  path = File.tempname("gori-fuzz-unused", ".db")
  store = Gori::Store.open(path)
  begin
    engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
    err.should be_nil
    engine.should_not be_nil
    view
  ensure
    store.close
    File.delete?(path)
  end
end

describe "FuzzerView unused payload sets" do
  it "counts and words the sets Sniper will never draw from" do
    v = built(fuzzer(SetSpec.list(["a"]), SetSpec.list(["b"])))
    v.unused_payload_sets.should eq(1)
    note = v.unused_sets_note
    note.should contain("1 payload set will not be used")
    note.should contain("sniper")
    note.should contain("Mode") # names the config row that fixes it, not a CLI flag
  end

  it "says nothing when the one set is the one Sniper uses" do
    built(fuzzer(SetSpec.list(["a"]))).unused_payload_sets.should eq(0)
  end

  it "retracts the claim when the mode changes to one that consumes both sets" do
    v = fuzzer(SetSpec.list(["a"]), SetSpec.list(["b"]))
    built(v).unused_payload_sets.should eq(1)
    v.cycle_mode_forward # sniper -> batteringram: still one shared set
    built(v).unused_payload_sets.should eq(1)
    v.cycle_mode_forward # -> pitchfork: two sets, two marked positions, none dropped
    built(v).unused_payload_sets.should eq(0)
  end

  it "pluralizes, and counts every set past the last marked position in a per-position mode" do
    v = fuzzer(SetSpec.list(["a"]), SetSpec.list(["b"]), SetSpec.list(["c"]), SetSpec.list(["d"]))
    built(v).unused_payload_sets.should eq(3) # sniper: three dropped
    v.unused_sets_note.should contain("3 payload sets will not be used")
    v.cycle_mode_forward
    v.cycle_mode_forward # pitchfork: 2 positions consume 2 of the 4
    built(v).unused_payload_sets.should eq(2)
    v.unused_sets_note.should contain("position")
  end
end
