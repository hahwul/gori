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
# The O(1) accessors the Pet polls every tick. It must never call `all`, which
# materialises a reversed copy of the whole ring 20x/second.
describe Gori::Tui::Notifications do
  it "reports 0 for latest_id on an empty buffer" do
    Notifications.new.latest_id.should eq(0)
    Notifications.new.latest.should be_nil
  end

  it "points latest at the most recent push" do
    s = Notifications.new
    s.push(:info, "a")
    last = s.push(:info, "b")
    s.latest_id.should eq(last.id)
    s.latest.should be(last) # same object, not a copy
  end

  it "still points at the newest after a retention trim" do
    prev = Gori::Settings.notify_retention
    begin
      Gori::Settings.notify_retention = 2
      s = Notifications.new
      last = nil.as(Notifications::Note?)
      5.times { |i| last = s.push(:info, "n#{i}") }
      # push trims with shift, so the newest is always the tail.
      s.latest_id.should eq(last.not_nil!.id)
      s.latest.not_nil!.message.should eq("n4")
    ensure
      Gori::Settings.notify_retention = prev
    end
  end

  it "drops latest_id back to 0 after clear" do
    s = Notifications.new
    s.push(:info, "a")
    s.clear
    s.latest_id.should eq(0)
    s.latest.should be_nil
  end
end

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

  it "keeps the cursor on the note being read when a drain pushes a new one" do
    # THE LOST UPDATE. This overlay holds no snapshot — `notes` re-derives `@store.all`
    # (newest-first) on every call — while the cursor was a bare Int32. Any background
    # completion that reaches a controller drain (a Probe issue, an OAST callback, a
    # fuzz/miner/discover Done) becomes index 0 and shifts everything by +1, so the ↵ the
    # operator presses against the frame they were reading jumps to the NEIGHBOUR.
    # OastController#drain_events guards the identical shape by capturing {session_id, uid}
    # and re-anchoring @cb_sel; a Note's `id` is that stable key here (never recycled —
    # `clear` does not reset @next_id).
    s = store("a", "b", "c") # newest-first: c, b, a
    ov = NotificationsOverlay.new(s)
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down).should eq(:open)
    ov.selected_note.not_nil!.message.should eq("b")

    s.push(:success, "Probe: issue on GET /x") # a drain lands mid-read
    ov.selected_note.not_nil!.message.should eq("b")

    # The highlight has to move with it, or the frame disagrees with what ↵ will do.
    box = h.box.not_nil!
    h.render.row(box.y + 2 + 2).should contain("▎") # list is now [Probe…, c, b, a]
    h.render.row(box.y + 2 + 2).should contain("b")

    jumped = [] of String
    h.on_commit do
      jumped << ov.selected_note.not_nil!.message
      true
    end
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    jumped.should eq(["b"])
  end

  it "anchors from the moment it opens, before the operator has moved at all" do
    # The unmoved-cursor case is the same bug: the center opens on the newest note, a drain
    # prepends, and ↵ opens something the operator never saw. The Runner builds a fresh
    # overlay per open (Runner#open_notifications), so `initialize` IS the open.
    s = store("a")
    ov = NotificationsOverlay.new(s)
    s.push(:warn, "OAST: callback for s1")
    ov.selected_note.not_nil!.message.should eq("a")
  end

  it "falls back to the clamped index when the anchored note is gone" do
    # `clear` and the retention trim can retire the anchor. OastController's re-anchor is a
    # no-op when the key no longer resolves; the same choice here keeps the cursor roughly
    # where it was rather than snapping to the top of a list the operator did not touch.
    s = store("a", "b", "c")
    ov = NotificationsOverlay.new(s)
    ov.move(2) # → "a", the oldest
    ov.selected_note.not_nil!.message.should eq("a")
    s.clear
    s.push(:info, "fresh")
    ov.selected_note.not_nil!.message.should eq("fresh") # clamped, never an index error
  end

  it "clamps the selection on an empty store instead of raising" do
    h = OverlayHarness.new(NotificationsOverlay.new(Notifications.new))
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.overlay.as(NotificationsOverlay).selected_note.should be_nil
    h.rendered?("(no notifications yet)").should be_true
  end
end

# `c` clears the whole store, so it must not fire on a modified chord. This is not
# hypothetical tidiness: `Event::Key#char` is `@char || key.to_char`, so ^C reports 'c', and
# the branch was reachable-by-accident-only — the shell used to claim ^C for the quit-arm
# before any overlay saw a key. Once the quit-arm learned to yield while a modal is up (so ^D
# could reach the Fuzzer payload-set editor), ^C started reaching this overlay, where it
# erased every notification instead of arming quit. Pinned so the guard cannot be dropped as
# redundant on the strength of a Runner invariant that already changed once.
describe "NotificationsOverlay clear guard" do
  it "clears on a bare c but never on ^C or ⌥C" do
    store = Gori::Tui::Notifications.new
    store.push(:info, "first")
    store.push(:info, "second")

    ov = Gori::Tui::NotificationsOverlay.new(store)
    ctrl_c = Termisu::Event::Key.new(Termisu::Input::Key::LowerC, Termisu::Input::Modifier::Ctrl)
    alt_c = Termisu::Event::Key.new(Termisu::Input::Key::LowerC, Termisu::Input::Modifier::Alt)

    # The chord an operator presses to leave must not destroy their evidence.
    ov.handle_key(ctrl_c).should eq(:stay)
    store.all.size.should eq(2)
    ov.handle_key(alt_c).should eq(:stay)
    store.all.size.should eq(2)

    # The advertised mnemonic still works — the hint says "c clear".
    ov.hint.should contain("c clear")
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerC)).should eq(:stay)
    store.all.size.should eq(0)
  end
end
