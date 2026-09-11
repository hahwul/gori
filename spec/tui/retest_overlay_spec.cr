require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "../../src/gori/tui/retest_overlay"

include Gori::Tui

# The RETEST card (#1036). What these pin is the card's own contract — which keys arm which
# hand-off, what the two halves show, and the guard that keeps an edit out of a run in
# flight. The domain edges are injected at the open-site (`Runner#open_retest_overlay`), so
# nothing here touches a Store.

private def retest_step(id : Int64, role : Gori::Store::RetestRole, assertion : String = "",
                        position : Int32 = id.to_i) : Gori::Store::RetestStep
  Gori::Store::RetestStep.new(id, 1_i64, position, role, Gori::Store::LinkRefKind::Repeater,
    id, assertion, 0_i64, 0_i64)
end

private def retest_planned(id : Int64, role : Gori::Store::RetestRole, assertion : String = "",
                           method : String = "GET", label : String = "session #{id}",
                           missing : String? = nil) : Gori::Retest::Planned
  Gori::Retest::Planned.new(retest_step(id, role, assertion), method,
    "https://acme.test/#{id}", label, missing)
end

private def retest_row(position : Int32, role : Gori::Store::RetestRole,
                       outcome : Gori::Store::RetestOutcome, assertion : String = "status:403",
                       detail : String = "status 200, expected 403",
                       flow_id : Int64? = 9_i64) : Gori::Store::RetestRunStep
  Gori::Store::RetestRunStep.new(position.to_i64, 1_i64, position, role,
    Gori::Store::LinkRefKind::Repeater, 4_i64, "victim order", "GET",
    "https://acme.test/orders/7", assertion, outcome, detail, 200, 900_i64, 120_i64, flow_id)
end

private def retest_run(verdict : Gori::Store::RetestVerdict) : Gori::Store::RetestRun
  Gori::Store::RetestRun.new(3_i64, 1_i64, 1_700_000_000_000_000_i64, 1_700_000_001_000_000_i64,
    "tui", verdict, 2, 1, 1, 0, 0, 0, 0)
end

private def retest_card(steps : Array(Gori::Retest::Planned),
                        run : Gori::Store::RetestRun? = nil,
                        rows : Array(Gori::Store::RetestRunStep) = [] of Gori::Store::RetestRunStep) : RetestOverlay
  ov = RetestOverlay.new(1_i64, "broken access control")
  ov.load(steps, run, rows)
  ov
end

private def retest_render(ov : RetestOverlay, width = 110, height = 20) : String
  backend = MemoryBackend.new(width, height)
  ov.render(Screen.new(backend), Rect.new(0, 0, width, height))
  (0...height).map { |y| backend.row(y) }.join('\n')
end

describe Gori::Tui::RetestOverlay do
  it "shows the plan with role, method, source and the one expected result" do
    ov = retest_card([retest_planned(1_i64, :baseline, "status:200"),
                      retest_planned(2_i64, :variant, "status:403", method: "POST")])
    text = retest_render(ov)
    text.should contain("RETEST — ISSUE #1")
    text.should contain("broken access control")
    text.should contain("baseline")
    text.should contain("GET session 1")
    text.should contain("expect status:200")
    text.should contain("POST session 2")
    # The confirm's own sentence, shown while the plan is still being built rather than only
    # in the dialog.
    text.should contain("state-changing (POST)")
  end

  it "flags a step whose Repeater session is gone, on the row" do
    ov = retest_card([retest_planned(1_i64, :variant, "status:200",
      missing: "repeater #1 no longer exists")])
    retest_render(ov).should contain("⚠ repeater #1 no longer exists")
  end

  it "says what an empty plan needs rather than drawing a blank card" do
    retest_render(retest_card([] of Gori::Retest::Planned)).should contain("press a to add")
  end

  it "⇥ swaps STEPS and RESULTS, and the verdict rides the footer" do
    ov = retest_card([retest_planned(1_i64, :variant, "status:403")],
      retest_run(Gori::Store::RetestVerdict::Fail),
      [retest_row(1, :variant, Gori::Store::RetestOutcome::Fail)])
    ov.mode.should eq(:steps)
    harness = OverlayHarness.new(ov)
    harness.press(Termisu::Input::Key::Tab).should eq(:open)
    ov.mode.should eq(:results)
    text = retest_render(ov)
    text.should contain("RESULTS")
    text.should contain("FAIL")
    text.should contain("victim order")
    text.should contain("expect status:403")
    text.should contain("→ status 200, expected 403")
  end

  it "arms each edit through on_close rather than opening a modal from a key handler" do
    # The `LinksOverlay#pending_add` seam: every one of these opens ANOTHER modal, which the
    # shell's own close would tear straight back down if it went up from here.
    {'a' => :add, 'e' => :edit, 'd' => :remove, 'r' => :run, 'R' => :run_with_cleanup}.each do |ch, want|
      ov = retest_card([retest_planned(1_i64, :variant, "status:200")])
      OverlayHarness.new(ov).press(Termisu::Input::Key::LowerA, ch).should eq(:closed)
      ov.pending.should eq(want)
    end
  end

  it "arms the cleanup-permitting run on ⇧R in either shifted spelling" do
    # The operator "explicitly permitting" cleanup after a refused send — the one thing the
    # safety rule requires a way to say, and which a two-button confirm cannot ask.
    [{'R', false}, {'r', true}].each do |(ch, shift)|
      ov = retest_card([retest_planned(1_i64, :variant, "status:200")])
      OverlayHarness.new(ov).press(Termisu::Input::Key::LowerR, ch, shift: shift).should eq(:closed)
      ov.pending.should eq(:run_with_cleanup)
    end
  end

  it "leaves `e` and `d` inert with nothing selected, so an empty card does not close itself" do
    ov = retest_card([] of Gori::Retest::Planned)
    harness = OverlayHarness.new(ov)
    harness.press(Termisu::Input::Key::LowerA, 'e').should eq(:open)
    harness.press(Termisu::Input::Key::LowerA, 'd').should eq(:open)
    ov.pending.should be_nil
  end

  it "ignores a ctrl-modified letter — ^D must not arm the remove" do
    ov = retest_card([retest_planned(1_i64, :variant)])
    OverlayHarness.new(ov).press(Termisu::Input::Key::LowerA, 'd', ctrl: true).should eq(:open)
    ov.pending.should be_nil
  end

  it "opens a result row's recorded flow with ↵, and only when one was recorded" do
    with_flow = retest_card([] of Gori::Retest::Planned, retest_run(Gori::Store::RetestVerdict::Fail),
      [retest_row(1, :variant, Gori::Store::RetestOutcome::Fail)])
    h1 = OverlayHarness.new(with_flow)
    h1.press(Termisu::Input::Key::Tab)
    h1.press(Termisu::Input::Key::Enter).should eq(:closed)
    with_flow.pending.should eq(:open_flow)

    without = retest_card([] of Gori::Retest::Planned, retest_run(Gori::Store::RetestVerdict::Fail),
      [retest_row(1, :cleanup, Gori::Store::RetestOutcome::Skipped, flow_id: nil)])
    h2 = OverlayHarness.new(without)
    h2.press(Termisu::Input::Key::Tab)
    h2.press(Termisu::Input::Key::Enter).should eq(:open)
    without.pending.should be_nil
  end

  it "refuses every edit while a run is in flight, but still takes r and s" do
    # An edit mid-run would change a plan the fiber is already partway through sending.
    ov = retest_card([retest_planned(1_i64, :variant, "status:200")])
    ov.set_running(true, "sending step 1 of 3…")
    harness = OverlayHarness.new(ov)
    %w[a e d].each do |ch|
      harness.press(Termisu::Input::Key::LowerA, ch[0]).should eq(:open)
      ov.pending.should be_nil
    end
    retest_render(ov).should contain("sending step 1 of 3…")
    # `r` too: it lives in the always-key half so it works in both modes, which put it ahead
    # of the running guard. Mid-run it dropped the card, was refused, and reopened on STEPS —
    # throwing away the live RESULTS view for a key the running hint never offers.
    harness.press(Termisu::Input::Key::LowerA, 'r').should eq(:open)
    ov.pending.should be_nil
    stopped = 0
    ov.on_stop = -> { stopped += 1; nil }
    harness.press(Termisu::Input::Key::LowerA, 's').should eq(:open)
    stopped.should eq(1)
  end

  it "reorders in place with ⇧J/⇧K — the card stays up for a repeatable edit" do
    ov = retest_card([retest_planned(1_i64, :baseline), retest_planned(2_i64, :variant)])
    moves = [] of Int32
    ov.on_move = ->(d : Int32) { moves << d; nil }
    harness = OverlayHarness.new(ov)
    harness.press(Termisu::Input::Key::LowerJ, 'J', shift: true).should eq(:open)
    harness.press(Termisu::Input::Key::LowerK, 'K', shift: true).should eq(:open)
    moves.should eq([1, -1])
    # The typed capital ALONE, with no shift flag — which is what a terminal whose keyboard
    # protocol folds the modifier into the character actually sends, and what a `key.lower_k?
    # && ev.shift?` arm silently never saw.
    harness.press(Termisu::Input::Key::LowerJ, 'J').should eq(:open)
    harness.press(Termisu::Input::Key::LowerK, 'K').should eq(:open)
    moves.should eq([1, -1, 1, -1])
    # …and the OTHER spelling a terminal may report: shift + the LOWERCASE character. Without
    # a `!ev.shift?` guard on the nav arms this lands as cursor movement and the reorder arm
    # is dead for exactly the protocol its comment names.
    harness.press(Termisu::Input::Key::LowerJ, 'j', shift: true).should eq(:open)
    harness.press(Termisu::Input::Key::LowerK, 'k', shift: true).should eq(:open)
    moves.should eq([1, -1, 1, -1, 1, -1])
    ov.selected.should eq(0)
    # …and no shifted press moves the cursor. It would otherwise chase the row it just
    # moved, so two presses of ⇧J would carry a step three places.
    harness.press(Termisu::Input::Key::LowerJ, 'j').should eq(:open)
    ov.selected.should eq(1)
  end

  it "SELECTS on a row click and never commits — a stray click must not teleport anywhere" do
    ov = retest_card([retest_planned(1_i64, :baseline), retest_planned(2_i64, :variant)])
    harness = OverlayHarness.new(ov)
    # Row 0 sits three rows below the card top (title, hint, divider).
    harness.click_in_box(4, 4).should eq(:open)
    ov.selected.should eq(1)
    ov.pending.should be_nil
    harness.commits.should eq(0)
  end

  it "dismisses on a click outside the card, like every other modal" do
    ov = retest_card([retest_planned(1_i64, :baseline)])
    OverlayHarness.new(ov).click(0, 0).should eq(:closed)
  end

  it "names itself as its own OverlayKind" do
    retest_card([] of Gori::Retest::Planned).key.should eq(OverlayKind::Retest)
  end
end
