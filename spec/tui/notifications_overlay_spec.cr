require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def store(*messages : String) : Notifications
  s = Notifications.new
  messages.each_with_index { |m, i| s.push(:info, m, Jobs::Goto.new(:history, i.to_i64)) }
  s
end

# The notification center is the one LIST modal in this batch: no form, no commit
# closure of its own state — ↵ hands the selected note to the shell's jump, and `c`
# empties the store it was handed. Driven through OverlayHarness, which replays the
# Runner's generic dispatch (see spec/support/overlay_harness.cr).
describe Gori::Tui::NotificationsOverlay do
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(NotificationsOverlay.new(store("a"))).assert_chrome(OverlayKind::Notifications, "NOTIFICATIONS")
  end

  it "↵ commits the SELECTED note, not just the first" do
    # Notes render newest-first, so pushing a,b,c lists them c,b,a — ↓ once lands on b.
    ov = NotificationsOverlay.new(store("a", "b", "c"))
    jumped = [] of String
    h = OverlayHarness.new(ov)
    h.on_commit do
      jumped << ov.selected_note.not_nil!.message
      true
    end

    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    jumped.should eq(["b"])
  end

  it "esc closes without running the jump" do
    h = OverlayHarness.new(NotificationsOverlay.new(store("a")))
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "c empties the shared store in place and stays open" do
    s = store("a", "b")
    h = OverlayHarness.new(NotificationsOverlay.new(s))
    h.press(Termisu::Input::Key::LowerC, 'c').should eq(:open)
    s.all.should be_empty
    h.commits.should eq(0)
  end

  it "^P runs the injected palette hop instead of committing or cancelling" do
    ov = NotificationsOverlay.new(store("a"))
    hops = 0
    ov.on_palette = -> { hops += 1; nil }
    h = OverlayHarness.new(ov)
    # :stay, because the closure itself closes this modal and raises the palette — the
    # shell must not run a second dismissal on top of what the closure just opened.
    h.press(Termisu::Input::Key::LowerP, ctrl: true).should eq(:open)
    hops.should eq(1)
    h.commits.should eq(0)
  end

  it "a click on a row selects AND opens it; inside-but-not-a-row stays; outside dismisses" do
    ov = NotificationsOverlay.new(store("a", "b", "c"))
    picked = [] of String
    h = OverlayHarness.new(ov)
    h.on_commit do
      picked << ov.selected_note.not_nil!.message
      true
    end
    # Rows start at box.y + 2; the third row is the oldest note ("a").
    h.click_in_box(3, 4).should eq(:closed)
    picked.should eq(["a"])

    # The card's title row holds no note — a click there must not commit or close.
    inside = OverlayHarness.new(NotificationsOverlay.new(store("a")))
    inside.click_in_box(3, 0).should eq(:open)
    inside.commits.should eq(0)

    away = OverlayHarness.new(NotificationsOverlay.new(store("a")))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "the wheel moves the selection (base handle_wheel delegates to move)" do
    ov = NotificationsOverlay.new(store("a", "b", "c"))
    OverlayHarness.new(ov).wheel(2)
    ov.selected_note.not_nil!.message.should eq("a") # newest-first: c, b, a
  end

  it "dismisses (never opens) a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. The
    # pre-seam shell closed the center here (`return @overlay = None if box.nil?`), so the
    # override must report :cancel, NOT the :commit that would fire a jump with no card.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = NotificationsOverlay.new(store("a"))
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:cancel)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(0)
    h.rendered?("notifications need").should be_true
  end

  it "still hit-tests rows in the rect the shell actually passes (layout.body)" do
    # Production hands an overlay `layout.body` — 6 rows shorter and offset from the screen.
    body = Gori::Tui::Rect.new(2, 4, 76, 18)
    ov = NotificationsOverlay.new(store("a", "b", "c"))
    picked = [] of String
    h = OverlayHarness.new(ov, area: body)
    h.on_commit do
      picked << ov.selected_note.not_nil!.message
      true
    end
    # Row 2, NOT row 0: the overlay opens on row 0, so clicking it would assert an end state
    # identical to the no-op path and would still pass with set_selected deleted.
    h.click_in_box(3, 4).should eq(:closed)
    picked.should eq(["a"]) # newest-first (c, b, a), so row 2 is the oldest note
  end

  it "clamps the selection on an empty store instead of raising" do
    h = OverlayHarness.new(NotificationsOverlay.new(Notifications.new))
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.overlay.as(NotificationsOverlay).selected_note.should be_nil
    h.rendered?("(no notifications yet)").should be_true
  end
end
