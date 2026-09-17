require "../spec_helper"

include Gori::Tui

# `OffscreenTerminal` is the half of the `TerminalPort` seam with no device behind it: a size,
# no input, and a backend whose grid IS the frame. These pin the three properties the headless
# renderer depends on — the dims it was asked for, a readable snapshot, and a poll that always
# says "nothing", which is what makes `Runner#drain_burst`'s inner loop terminate.

describe OffscreenTerminal do
  it "sizes its backend to the dims it was constructed with" do
    port = OffscreenTerminal.new(24, 4)
    port.size.should eq({24, 4})
    port.make_backend.size.should eq({24, 4})
  end

  it "keeps the drawn frame where snapshot can read it" do
    backend = OffscreenTerminal.new(24, 3).make_backend
    screen = Screen.new(backend)
    screen.text(0, 0, "GET /api", Theme.text)
    screen.text(2, 1, "hello", Theme.text)
    backend.flush

    frame = backend.snapshot.not_nil!
    frame.cols.should eq(24)
    frame.rows.should eq(3)
    frame.row_text(0).rstrip.should eq("GET /api")
    frame.row_text(1).rstrip.should eq("  hello")
    frame.row_text(2).strip.should be_empty
  end

  # A wide glyph occupies two columns but contributes one grapheme; `row_text` has to skip the
  # continuation or every CJK row would read doubled.
  it "reads a wide glyph once, from its lead column" do
    backend = OffscreenTerminal.new(12, 1).make_backend
    screen = Screen.new(backend)
    screen.text(0, 0, "안녕 ok", Theme.text)
    backend.flush
    backend.snapshot.not_nil!.row_text(0).rstrip.should eq("안녕 ok")
  end

  it "never reports an event, so a drain loop ends" do
    port = OffscreenTerminal.new(80, 24)
    port.poll_event(0).should be_nil
    port.poll_event(50).should be_nil
  end

  # Everything else a surface asks a terminal for is state with nowhere to go. Called rather
  # than merely declared: a port that raised on one of these would take the render down on a
  # frame that happened to position a caret.
  it "accepts the terminal-state calls a surface makes, and does nothing" do
    port = OffscreenTerminal.new(80, 24)
    port.title = "gori"
    port.set_cursor(3, 4, visible: true)
    port.hide_cursor
    port.enable_mouse
    port.disable_mouse
    port.enable_enhanced_keyboard
    port.enable_bracketed_paste
    port.leave_paste!
    ran = false
    port.suspend { ran = true }
    ran.should be_true
    port.close
  end
end
