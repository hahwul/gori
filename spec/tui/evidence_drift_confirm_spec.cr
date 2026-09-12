require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The TUI's half of the freeze drift gate (#1038). A Repeater tab whose request was edited
# after its stored response arrived freezes a pair that never happened — the one thing frozen
# evidence exists not to produce. The headless surfaces REFUSE it; the TUI has an operator
# looking at the tab, so it asks, and the copy is still available to anyone who means it.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, so the card is driven through
# the seam the Runner opens it from (`Runner.drift_confirm`) and the chaining around it is
# pinned by reading the source. Comments are stripped first: a comment explaining a rule
# contains the tokens the rule looks for.
private def evidence_code : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "evidence.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def repeater_controller_code : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "repeater_controller.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "the sent-request digest" do
  it "is taken beside the save, not in the drain — the drain is a round-trip later" do
    body = repeater_controller_code
    # Both send arms. `save_repeater_tab` is what puts these bytes in the row; digesting the
    # same `request_text` immediately after is what makes the stored digest describe the row.
    # Taking it in `drain_results` instead would hash whatever the operator had typed by the
    # time the response landed — which is exactly the edit this is here to catch.
    send = body[/private def send_repeater_tab\(tab.*?\n    end/m].not_nil!
    send.should contain("save_repeater_tab(tab)")
    send.index("Evidence.request_digest(view.request_text.to_slice)").not_nil!
      .should be > send.index("save_repeater_tab(tab)").not_nil!
    ws = body[/private def ws_repeater_send.*?\n    end/m].not_nil!
    ws.should contain("Evidence.request_digest(view.request_text.to_slice)")

    # …and it rides the result channel to the write, rather than being re-derived there.
    drain = body[/def drain_results.*?\n    end/m].not_nil!
    drain.should contain("request_sha256: sent_digest")
    drain.should_not contain("Evidence.request_digest")
  end
end

describe "the freeze drift confirm" do
  it "names the problem in its heading and offers the copy rather than forbidding it" do
    h = OverlayHarness.new(Runner.drift_confirm(1, 1))
    # `title` is the shell's focus badge, the constant every confirm carries; the card's own
    # heading is what names this one.
    h.assert_chrome(OverlayKind::Confirm, "CONFIRM")
    h.overlay.as(ConfirmDialog).heading.should eq("REQUEST EDITED SINCE THIS RESPONSE")
    h.rendered?("edited after the response").should be_true
    h.rendered?("ONE exchange").should be_true
    h.rendered?("Send the tab again").should be_true
    h.rendered?("freeze anyway").should be_true
  end

  it "lights the freeze button, because saying yes destroys nothing" do
    # `danger: false`, asserted where it shows: a bare ↵ commits. A danger card defaults to
    # cancel and would make the operator who already knows hunt for `y` — the wrong lesson
    # for a question whose honest answer is often "yes, and I know why".
    h = OverlayHarness.new(Runner.drift_confirm(1, 1))
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  it "counts the drifted copies out of the batch, so a mixed marked set says which" do
    Runner.drift_confirm_message(1, 1).should contain("This tab's request was edited")
    Runner.drift_confirm_message(3, 3).should contain("All 3 of these tabs")
    mixed = Runner.drift_confirm_message(2, 5)
    mixed.should contain("2 of these 5 copies")
    # Never a number that reads as the whole batch when it is not.
    mixed.should_not contain("All 5")
  end

  it "runs the write on accept and nothing but the restore on decline" do
    # The card is the gate: `on_commit` is what the Runner hangs the rest of the freeze chain
    # off, and a cancel must reach `on_close` without it having run.
    ov = Runner.drift_confirm(1, 1)
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
    h.closes.should eq(1) # the picker/drill-in restore runs from here

    ov2 = Runner.drift_confirm(1, 1)
    h2 = OverlayHarness.new(ov2)
    h2.press(Termisu::Input::Key::LowerY).should eq(:closed)
    h2.commits.should eq(1)
    h2.closes.should eq(1)
  end

  it "is asked BEFORE the byte cost, on both freeze entry points, and restores on a decline" do
    body = evidence_code
    freeze = body[/private def freeze_into_issue.*?\n  end/m].not_nil!
    # Order matters: "these bytes are not one exchange" has to be answered before "these
    # bytes cost 3 MB", or the operator weighs the size of a copy they would not have taken.
    #
    # Expressed as the SHAPE rather than a textual order: the byte-cost question lives inside
    # the `cost` proc, and `cost` is what the drift gate runs on accept — so drift cannot be
    # second without the gate losing its argument.
    freeze.should contain("gate_request_drift(snaps, cost, after: after)")
    freeze[/cost = -> \{.*?\}/m].not_nil!.should contain("confirm_freeze_cost")
    # The "+ New issue…" arm of the picker goes through the same gate rather than round-tripping
    # the operator's typed title only to refuse afterwards.
    form = body[/private def open_issue_form_for_freeze.*?\n  end/m].not_nil!
    form.should contain("gate_request_drift(snaps, cost, declined: back)")

    gate = body[/private def gate_request_drift.*?\n  end/m].not_nil!
    # A decline restores exactly once, on exactly one path — `declined` then `after`, the
    # same contract `confirm_freeze_cost` keeps.
    gate.should contain("declined.try(&.call)")
    gate.should contain("after.try(&.call)")
    gate.should contain("snaps.count(&.request_drifted?)")
  end
end
