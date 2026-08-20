require "../spec_helper"

# `gori run fuzz`'s size refusal must be the LAST word before any traffic, not the first line
# of the streaming loop.
#
# It used to live at the top of `run_fuzz_stream`, which the command reaches only AFTER two
# things that put real requests on the wire — `--bind-from`'s replay (`seed_bindings`) and
# `--ac`'s `CALIBRATION_SAMPLES` synthetic sends (`calibrate_baseline`). Measured against a
# recording origin:
#
#   gori run fuzz --request r.txt --target http://127.0.0.1:8901 --mark SEED \
#                 --brute 'abcdefgh:1-8' --ac
#   → "refusing to send 19173960 requests without --force"   …with 6 requests already served.
#
# A refusal that fires after the traffic is not a refusal, and this is the gate a tester
# working inside an agreed request budget relies on. The other two surfaces already order it
# this way — MCP checks `FUZZ_MAX_REQUESTS` in `fuzz_start` before spawning the job fiber, and
# the TUI's confirm dialog gates `start_run`, which is what calibrates.
#
# Asserted over the SOURCE, in the shape `spec/cli_spec.cr`'s `unknown_args` guard uses: the
# defect is an ORDERING inside one command function, so there is no value to assert and no
# in-process seam to drive `cmd_fuzz` through. Line order in the one file that decides it is
# the fact, and a future edit that moves the gate back below a send trips this.
describe "gori run fuzz — the --force size gate precedes every send" do
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "cli", "run", "fuzz.cr"))
  lines = src.lines

  # The call site inside `cmd_fuzz` (the `private def self.fuzz_preflight` definition is
  # further down the file and must not be mistaken for it).
  gate = lines.index(&.includes?("total = fuzz_preflight("))
  calibrate = lines.index(&.includes?("calibrate_baseline"))
  seed = lines.index(&.includes?("seed_bindings("))
  stream = lines.index(&.includes?("run_fuzz_stream(plan.engine"))

  it "runs the preflight before --ac's calibration sends" do
    gate.should_not be_nil
    calibrate.should_not be_nil
    gate.not_nil!.should be < calibrate.not_nil!
  end

  it "runs the preflight before --bind-from's replay" do
    seed.should_not be_nil
    gate.not_nil!.should be < seed.not_nil!
  end

  it "runs the preflight before the sweep itself" do
    stream.should_not be_nil
    gate.not_nil!.should be < stream.not_nil!
  end

  # The other half of the fix: `run_fuzz_stream` takes the already-gated `total` and no longer
  # decides whether the run may proceed. If the preflight moved back inside it, the ordering
  # assertions above would still pass on the hoisted call while the real gate ran late again.
  it "leaves the streaming loop with no gate of its own" do
    body_start = lines.index(&.includes?("private def self.run_fuzz_stream")).not_nil!
    body_end = lines.index(&.includes?("private def self.fuzz_preflight")).not_nil!
    lines[body_start...body_end].any?(&.includes?("fuzz_preflight(")).should be_false
  end
end
