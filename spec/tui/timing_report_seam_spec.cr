require "../spec_helper"

# A finished differential-timing run (#1246) opens `TimingReportOverlay` from the Runner's
# tick. The gate excluded modals, menus, pickers and prompts but not TEXT ENTRY, so the card
# popped up mid-typing in a Repeater INSERT editor or Notes and swallowed the next keys (and a
# paste's tail). `Runner.new` owns a terminal, so the gate is pinned by source.
describe "the timing report's open gate" do
  it "waits while text entry or a paste is in progress" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    gate = src[/if @overlay\.none\?[^\n]*\n(?:[^\n]*\n){0,3}?[^\n]*take_timing_report/m]?
    gate.should_not be_nil
    gate = gate.not_nil!
    gate.should contain("!text_input_active?")
    gate.should contain("!@paste_newline.pasting?")
  end
end
