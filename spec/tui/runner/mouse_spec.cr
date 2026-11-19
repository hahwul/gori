require "../../spec_helper"

# `Runner.new` owns a terminal and appears nowhere under spec/, so the press path is pinned by
# reading the source with comments stripped.
describe "Runner left press" do
  it "clears the toast's stamp with the toast, as a key does" do
    code = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "mouse.cr"))
      .lines.reject(&.lstrip.starts_with?('#')).join('\n')
    press = code[/@toast = nil\n.*?press_left\(layout, mx, my\)/m].not_nil!
    press.should contain("@toast_seen = nil")
  end
end
