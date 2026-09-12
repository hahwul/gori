require "../spec_helper"

# CONTRACT: `^N` / `^W` create and close a sub-tab from ANY focus level, on every tab that
# has a strip — the same `subtab_new` / `subtab_close` contract the strip's own handler runs.
#
# They were per-tab guards before, and the coverage was ragged in a way nothing announced:
# `^N` answered on Repeater/Fuzzer/Notes (three hardcoded arms in `Runner#handle_key`), while
# `^W` answered from the strip, or from whichever of the six controllers had grown its own
# arm — so a Fuzzer/Miner/Sequencer BODY had no close at all. Since #1055 the space menu draws
# the chord beside the row it belongs to, which turns a ragged guard into an advertised dead
# key. One guard in the shell, routed through the two contract methods, is the fix.
#
# Asserted against the SOURCE because the alternative is standing up a Runner (a terminal, a
# session, nine controllers) to press two keys; the shape of the guard is the whole claim.
private RUNNER  = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
private SUBTABS = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "subtabs.cr"))

describe "^N / ^W on the nine sub-tab strips" do
  it "routes both through the strip's own contract, in ONE guard each" do
    guard = RUNNER[/\^N \/ \^W create and close a sub-tab.*?^      end\n\n      if.*?^      end/m]
    guard.should_not be_nil
    g = guard.not_nil!
    g.should contain("ev.key.lower_n? && subtab_new_supported?")
    g.should contain("subtab_new")
    g.should contain("ev.key.lower_w? && subtab_close_supported?")
    g.should contain("subtab_close")
    # A close that empties the strip must not leave focus on a row nothing draws.
    g.should contain("resolve_subtab_focus")
  end

  it "keeps no per-tab ^N arm behind in the shell" do
    # The three that used to be there, by name.
    RUNNER.should_not contain("@active_tab == :repeater && @overlay.none? && ev.ctrl? && ev.key.lower_n?")
    RUNNER.should_not contain("@active_tab == :fuzzer && @overlay.none? && ev.ctrl? && ev.key.lower_n?")
    RUNNER.should_not contain("@active_tab == :notes && @overlay.none? && ev.ctrl? && ev.key.lower_n?")
  end

  it "lists every strip in subtab_close_supported?, and subtab_new's own seven in the other" do
    close = SUBTABS[/def subtab_close_supported\?.*?^  end/m].not_nil!
    %w[repeater fuzzer miner sequencer decoder jwt cookie notes comparer].each do |tab|
      close.should contain(":#{tab}")
    end
    # Miner and the Sequencer seed their sessions from a job, not from ^N — the strip hint
    # omits "^N new" there for the same reason, so the two lists differ ON PURPOSE.
    new = SUBTABS[/def subtab_new_supported\?.*?^  end/m].not_nil!
    %w[repeater fuzzer decoder jwt cookie notes comparer].each { |tab| new.should contain(":#{tab}") }
    new.should_not contain(":miner")
    new.should_not contain(":sequencer")
  end

  it "keeps the two supported? lists in step with what the dispatchers can actually do" do
    # A tab named as supported but missing from the dispatcher's `case` would be a silent
    # no-op — the guard returns, and nothing happens.
    dispatch_new = SUBTABS[/def subtab_new : Nil.*?^  end/m].not_nil!
    %w[repeater fuzzer decoder jwt cookie notes comparer].each { |t| dispatch_new.should contain(":#{t}") }
    dispatch_close = SUBTABS[/def subtab_close : Nil.*?^  end/m].not_nil!
    %w[repeater fuzzer miner sequencer decoder jwt cookie notes comparer].each do |t|
      dispatch_close.should contain(":#{t}")
    end
  end
end
