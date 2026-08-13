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
