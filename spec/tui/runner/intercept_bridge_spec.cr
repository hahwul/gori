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

# #1418: the operator's time on the Intercept tab is watching, so it has to be RECORDED — the
# reaper used to only skip while they were on it, and a two-second glance at History then
# released every hold they had sat watching past the window.
describe "the auto-forward reaper and the operator's time on the Intercept tab" do
  max = 30_000_i64
  now = 1_000_000_000_i64

  it "gives a hold the operator watched a fresh window from when they left the tab" do
    # The issue's repro: held 33 s ago, watched the whole time, left 2 s ago.
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 33_000, 0_i64, now - 2_000).should be_false
    # …and released once they have been away for the whole window.
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 63_000, 0_i64, now - 30_000).should be_true
  end

  it "still releases a hold nobody watched for the window" do
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 31_000, 0_i64, 0_i64).should be_true
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 29_000, 0_i64, 0_i64).should be_false
  end

  it "judges a hold that arrived after the operator left by its own age" do
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 10_000, 0_i64, now - 40_000).should be_false
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 30_000, 0_i64, now - 40_000).should be_true
  end

  it "keeps an agent's recent look as watching" do
    Gori::Tui::Runner.hold_reap_due?(now, max, now - 60_000, now - 5_000, now - 50_000).should be_false
  end

  it "never fires when the window is disabled" do
    Gori::Tui::Runner.hold_reap_due?(now, 0_i64, 0_i64, 0_i64, 0_i64).should be_false
  end

  it "stamps the tab time before any return and judges every hold by it" do
    # Source-pinned for the reason the forward_edit receipt above is: the reaper only runs on a
    # Runner's tick. The stamp has to precede the on-tab early return — placed after it, the
    # last tick on the tab is exactly the one that never records anything.
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "intercept_bridge.cr"))
    body = src.lines.reject(&.lstrip.starts_with?('#')).join('\n')
    from = body.index("private def reap_stale_holds")
    from.should_not be_nil
    reap = body[from.not_nil!..]
    reap = reap[0, reap.index("\n  end\n").not_nil!] # the method's own `end`, at def indent
    stamp_at = reap.index(/@intercept_operator_watched_at = .* if @active_tab == :intercept/)
    stamp_at.should_not be_nil
    stamp_at.not_nil!.should be < reap.index("return false").not_nil!
    # The operator's time rides the predicate's LAST slot, the one that covers the whole queue.
    reap.should match(/hold_reap_due\?\([^)]*,\s*operator_ms\)/m)
  end
end
