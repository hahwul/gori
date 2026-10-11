require "../../spec_helper"

# `cmd_repeater_minimize` prints and exits, so its output split is pinned on the source: on a
# live terminal the minimized wire (the target's bytes) and the removed-item labels are badged,
# and only a pipe gets the exact bytes — the split `gori run decoder` draws.
private def minimize_code : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "repeater_minimize.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "gori run repeater minimize text output" do
  it "badges the wire and the labels on a terminal and keeps the bytes for a pipe" do
    code = minimize_code
    code.should_not contain("write_value(STDOUT, wire, STDOUT.tty?)")
    code.should contain("term_safe_multiline(String.new(wire))")
    code.should contain("term_line(r.label)")
  end
end
