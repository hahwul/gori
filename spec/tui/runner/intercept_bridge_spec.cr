require "../../spec_helper"

# #1430. The agent's `forward_edit` receipt has to name the EDITED request, which only
# `Interceptor::Item#edited_label` reads (spec/interceptor_spec.cr pins its parse). Source-pinned
# for the reason spec/tui/peer_edit_sync_spec.cr gives: `Runner.new` owns a terminal and
# appears nowhere under spec/, and this branch runs only on the bridge drain.
describe "Runner#apply_intercept_command forward_edit receipt" do
  it "labels the ack and the agent note from the forwarded bytes" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "intercept_bridge.cr"))
    body = src.lines.reject(&.lstrip.starts_with?('#')).join('\n')
    branch = body[/^ *when "forward_edit"\n.*?\n *end\n *true\n/m]?
    branch.should_not be_nil
    branch = branch.not_nil!
    branch.should contain("edited_desc = item.edited_label(bytes)")
    branch.should contain(%(store.ack_intercept_command(cmd.id, "edited", edited_desc)))
    branch.should contain(%(push_agent_note(:success, "forwarded (edited) \#{edited_desc}", item)))
    # The held-metadata label (`item.label` with no edited method/target) is the bug.
    branch.should_not match(/item\.label\(/)
  end
end
