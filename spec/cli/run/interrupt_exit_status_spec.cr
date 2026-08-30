require "../../spec_helper"

# The two halves of an interrupted sweep, as a CLASS.
#
# `Run.install_interrupt_trap` stops the engine and flushes; `Run.report_interrupted` is the
# other half — it says how much survived and `exit 130`s, so a scripted
# `gori run … && ./triage.sh` does not treat a truncated run as a finished one.
#
# `gori run discover` had the trap and NOT the exit: it called a file-local reporter that only
# wrote a line to STDERR and returned, so an interrupted-but-error-free crawl fell through to
# exit 0 while its three siblings exited 130 for the same Ctrl-C. That local reporter predated
# the shared helper and survived the extraction; nothing failed when it did, because both
# halves end in `exit` and neither can be exercised in-process. So the pairing is asserted over
# the SOURCE, the way spec/cli_spec.cr pins `unknown_args`.
describe "gori run — interrupt trap and non-zero exit are one pair" do
  it "is honoured by every subcommand that installs the trap" do
    dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    offenders = [] of String
    Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "interrupt.cr" # where the pair is defined
      src = File.read(path)
      next unless src.includes?("install_interrupt_trap(")
      offenders << File.basename(path) unless src.includes?("Run.report_interrupted(")
    end
    offenders.should be_empty
  end
end

# …and the converse: the pair is worthless on a sweep that never installs it.
#
# `gori run repeater minimize` drives `Repeater::Minimize` through a `Fuzz::CappedBackend` —
# up to `Minimize::SEND_CAP` real sends at one origin, minutes of wall clock — and printed
# NOTHING until the report at the very end. It shipped without the trap, so a Ctrl-C threw the
# whole run away: every removal already proven by a real request went to the garbage collector,
# which is the exact defect `interrupt.cr` was extracted to stop copying. Nothing failed when
# it was added, because the check above only looks at files that ALREADY install the trap.
#
# So: naming one of the many-send engines is what obliges a file to install it. The list is
# the engines themselves rather than a count of sends, because "how many requests does this
# command make" is not a property source can be grepped for — "which engine is it driving" is.
#
# WHAT THIS DOES NOT COVER, so nobody reads it as more than it is. Two `gori run` surfaces send
# in bulk without driving any of these engines, and both still lack the pairing:
#
#   * `gori run probe --active` / `--aggressive` calls `Probe::Scan.scan_all(active: true)`,
#     which sends real probes across every captured flow and prints nothing until the end.
#     `Probe::Scan` has no cancellation seam at all — no `Stop`, no stop-checked loop — so
#     giving it one is an engine change with an MCP caller to keep in step, not a CLI fix.
#   * `gori run oast listen` / `resume` hand-roll `install_oast_stop_trap`, a copy of the
#     helper minus the `interrupted` flag, and exit 0 on Ctrl-C. That is arguably right for a
#     listener — Ctrl-C is the documented way to end one, and callbacks are persisted as they
#     land, not buffered — but it is a second implementation of one rule either way.
#
# Both are recorded here rather than silently omitted: a gate that reads as clean while never
# having looked is worse than no gate.
RUN_MANY_SEND_ENGINES = [
  "Fuzz::Engine", "Fuzz::CappedBackend", "Miner::Engine",
  "Sequencer::Engine", "Discover::Engine", "Authorize::Plan",
]

describe "gori run — every engine-driven sweep installs the interrupt trap" do
  it "leaves no long active sweep killable only by SIGKILL-or-lose-everything" do
    dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    offenders = [] of String
    Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
      src = File.read(path)
      next unless RUN_MANY_SEND_ENGINES.any? { |engine| src.includes?(engine) }
      offenders << File.basename(path) unless src.includes?("install_interrupt_trap(")
    end
    offenders.should be_empty
  end

  # The rule is only worth its upkeep if it actually selects something. A typo in a constant
  # name would quietly make the check above vacuous.
  it "selects exactly the six engine-driven subcommands" do
    dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    matched = Dir.glob(File.join(dir, "**", "*.cr")).sort.select do |path|
      src = File.read(path)
      RUN_MANY_SEND_ENGINES.any? { |engine| src.includes?(engine) }
    end
    matched.map { |p| File.basename(p, ".cr") }.should eq(
      ["authorize", "discover", "fuzz", "mine", "repeater_minimize", "sequence"])
  end
end
