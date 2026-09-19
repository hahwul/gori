require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The card ↵ opens on a ring row that carries a `detail` (#1090) — the long form the
# 60-column notification row could only clip. Read-only: it never answers :commit, so every
# example here asserts `commits == 0` wherever the card leaves, and what it renders is
# asserted against a MemoryBackend rather than against the overlay's own state — the whole
# point of the card is that the operator can SEE the paragraph.
#
# Driven through OverlayHarness, which replays the Runner's generic dispatch (see
# spec/support/overlay_harness.cr).

private def note(summary : String, detail : String?, level : Symbol = :warn,
                 source : String = "agent:claude-code") : Notifications::Note
  Notifications.new.push(level, summary, nil, source: source, detail: detail)
end

# `line0` … `lineN-1`, one per row once wrapped — a body whose windowing can be read off
# the screen without counting columns.
private def numbered(n : Int32) : String
  (0...n).map { |i| "line#{i}" }.join("\n")
end

describe Gori::Tui::NoteDetailOverlay do
  it "exposes the chrome the shell's collapsed ladders read off an overlay" do
    OverlayHarness.new(NoteDetailOverlay.new(note("summary", "detail")))
      .assert_chrome(OverlayKind::NoteDetail, "NOTE")
  end

  it "draws the summary as the heading, with who/what/when under it" do
    n = note("the login flow still 302s to /sso", "Retried with the captured cookie jar.")
    h = OverlayHarness.new(NoteDetailOverlay.new(n))
    box = h.box.not_nil!
    mb = h.render

    mb.row(box.y + 1).should contain("the login flow still 302s to /sso")
    # The row could not say WHO or at what level without spending the columns the message
    # needs; the card has the room, so it says both, plus the age.
    meta = mb.row(box.y + 2)
    meta.should contain("warn")
    meta.should contain("claude-code") # "agent:claude-code" → the name is the useful half
    mb.row(box.y + 4).should contain("Retried with the captured cookie jar.")
  end

  it "wraps the detail to the card's columns rather than clipping it" do
    # The failure this card exists to fix: everything past the row's width was simply not
    # reachable. Two words each too long to share a line at the card's 68-column body.
    a = "a" * 60
    b = "b" * 60
    h = OverlayHarness.new(NoteDetailOverlay.new(note("summary", "#{a} #{b}")))
    box = h.box.not_nil!
    mb = h.render
    mb.row(box.y + 4).should contain(a)
    mb.row(box.y + 5).should contain(b) # …on the NEXT row, not truncated with an ellipsis
    mb.contains?("…").should be_false
  end

  it "scrolls a detail longer than the card, and ↑/↓ move the window" do
    ov = NoteDetailOverlay.new(note("summary", numbered(30)))
    h = OverlayHarness.new(ov)
    box = h.box.not_nil!
    top = box.y + 4
    h.render.row(top).should contain("line0")

    3.times { h.press(Termisu::Input::Key::Down).should eq(:open) }
    h.render.row(top).should contain("line3")
    h.press(Termisu::Input::Key::Up).should eq(:open)
    h.render.row(top).should contain("line2")

    # …and never past the top, where a bare `@scroll -= 1` would run negative.
    10.times { h.press(Termisu::Input::Key::Up) }
    ov.scroll.should eq(0)
    h.commits.should eq(0)
  end

  it "pages by the rows the last frame drew, and Home/End go to the ends" do
    # `Overlay#page_key`'s list contract: ⇞/⇟ step one DRAWN page — the height a
    # hard-coded number would disagree with the moment the terminal is a different size.
    ov = NoteDetailOverlay.new(note("summary", numbered(60)))
    h = OverlayHarness.new(ov)
    box = h.box.not_nil!
    top = box.y + 4
    page = box.bottom - 1 - top # the body band this card was given
    h.render                    # stamps the page step

    h.press(Termisu::Input::Key::PageDown).should eq(:open)
    h.render.row(top).should contain("line#{page}")
    h.press(Termisu::Input::Key::PageUp).should eq(:open)
    h.render.row(top).should contain("line0")

    h.press(Termisu::Input::Key::End).should eq(:open)
    h.render.row(box.bottom - 2).should contain("line59") # the tail, clamped on the draw path
    ov.scroll.should eq(60 - page)

    h.press(Termisu::Input::Key::Home).should eq(:open)
    h.render.row(top).should contain("line0")
    h.commits.should eq(0)
  end

  it "the wheel scrolls (the base handle_wheel delegates to move)" do
    ov = NoteDetailOverlay.new(note("summary", numbered(30)))
    OverlayHarness.new(ov).wheel(3)
    ov.scroll.should eq(3)
  end

  it "esc closes without committing" do
    h = OverlayHarness.new(NoteDetailOverlay.new(note("summary", "detail")))
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "y copies the summary AND the detail, and says so in the hint" do
    ov = NoteDetailOverlay.new(note("the login flow still 302s", "Retried with the jar.\nNo Set-Cookie."))
    # A copy that dropped the summary would lose the one line naming what the paragraph is
    # about; the ring row shows only that line, so the card owes the operator both.
    ov.copy_text.should eq("the login flow still 302s\n\nRetried with the jar.\nNo Set-Cookie.")

    prev = Gori::Settings.clipboard_osc52?
    begin
      # OFF, so the example writes nothing to the tty Clipboard resolves (`TtyOut`): the
      # verdict is what this asserts, and `Clipboard.copy` reports it either way.
      Gori::Settings.clipboard_osc52 = false
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::LowerY, 'y').should eq(:open)
      ov.hint.should contain("copied")
      h.commits.should eq(0)
      # The flash lasts until the next key, like the notification centre's.
      h.press(Termisu::Input::Key::Down).should eq(:open)
      ov.hint.should_not contain("copied")
    ensure
      Gori::Settings.clipboard_osc52 = prev
    end
  end

  it "never copies on ^Y or ⌥Y — a chord is not a mnemonic" do
    ov = NoteDetailOverlay.new(note("summary", "detail"))
    # `Event::Key#char` is `@char || key.to_char`, so ^Y arrives carrying 'y'.
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerY,
      Termisu::Input::Modifier::Ctrl)).should eq(:stay)
    ov.hint.should_not contain("copied")
  end

  it "falls back to the summary alone when there is no detail to draw" do
    # Not reachable from the ring (that row has no marker and jumps instead), but the card
    # must not draw a blank body or copy an empty string if another open-site ever hands it
    # a bare note.
    ov = NoteDetailOverlay.new(note("summary only", nil))
    ov.copy_text.should eq("summary only")
    OverlayHarness.new(ov).rendered?("(no detail)").should be_true
  end

  it "declines to draw — and dismisses a click — in a window too small for the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # is unreachable through the default; pass an area that forces it. :cancel, never the
    # :commit that would look like the card had acted.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = NoteDetailOverlay.new(note("summary", "detail"))
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:cancel)

    h = OverlayHarness.new(ov, area: tiny)
    h.rendered?("note detail needs").should be_true
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(0)
  end

  it "still draws in the rect the shell actually passes (layout.body)" do
    # Production hands an overlay `layout.body` — 6 rows shorter and offset from the screen.
    body = Gori::Tui::Rect.new(2, 4, 76, 18)
    h = OverlayHarness.new(NoteDetailOverlay.new(note("summary", numbered(30))), area: body)
    box = h.box.not_nil!
    box.y.should be >= body.y
    box.bottom.should be <= body.bottom
    h.render.row(box.y + 4).should contain("line0")
  end
end
