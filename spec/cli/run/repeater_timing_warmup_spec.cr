require "../../spec_helper"

# `gori run repeater timing --warmup=0` — measure from the very first pair. MCP `send_request`
# takes `warmup: 0`, and `Timing.run` clamps to `0..iterations-1`, but the CLI parsed the flag
# with `parse_count`, which refuses anything below 1, so the same run was only reachable from
# one surface.
#
# Asserted over the source, as spec/cli/run/links_spec.cr does: the refusal is an `abort`,
# which exits the process rather than raising anything a spec could catch.
private def timing_command_source : String
  source = File.read(File.join(__DIR__, "../../../src/gori/cli/run/repeater.cr"))
  tail = source[source.index!("private def self.cmd_repeater_timing")..]
  tail[0, tail.index("\n      private def self.", 1) || tail.size]
end

describe "gori run repeater timing --warmup" do
  it "accepts 0, like MCP's warmup" do
    line = timing_command_source.lines.find(&.includes?(%("--warmup=N"))).should_not be_nil
    line.should contain(%(parse_nonneg(v, "--warmup")))
    line.should_not contain("parse_count")
  end
end
