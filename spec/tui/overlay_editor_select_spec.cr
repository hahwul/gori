require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# Three modals embed a real multi-line `TextArea`: the Rewriter STUB RESPONSE, the Discover
# CUSTOM HEADERS list, and the Fuzzer SET card's value list. All three were text boxes an
# operator could type a wordlist or an HTTP response into and could not select out of.
#
# TWO holes, one per input device.
#
# KEYBOARD. Each hand-rolled its own `case key.left? then @editor.move(0, -1)` ladder and
# passed no `selecting:` anywhere — so ⇧arrows moved the caret like bare arrows, and there
# was no PageUp/PageDown, no ⇧Home/⇧End, no ⌥←/→ by word, no ⌥⌫. #583 gave eight surfaces one
# answer (`TextArea#handle_motion_key`) and these three were not among them.
#
# POINTER. The shell dragged nothing over a modal at all: `Runner#dispatch_drag` reached only
# the active tab, and the predicate behind it said so out loud ("nothing else … overlays …
# drags"). So `Overlay` grew the same three-method contract `TabController` has —
# `supports_drag?` / `handle_drag` / `handle_double_click` — and the Runner grew an overlay
# tier ahead of its tab tier. `OverlayHarness#drag` / `#double_click` replay that tier,
# including its opt-in gate.

# Where each card puts its buffer, as an offset from the box top-left. Both single-editor
# cards inset by 2 columns and start one row under the border; the SET card's value list sits
# three rows down, under the name + type rows.
private EDITOR_DX = 2
private EDITOR_DY = 1
private VALUES_DY = 3

private def stub_overlay(text : String) : OverlayHarness
  OverlayHarness.new(RewriterStubOverlay.new(text), commit: true)
end

# A SET card seeded with a LIST payload and its row cursor moved onto the value buffer.
# `for_list` opens on row 0 (the Type selector), so the ↓ here is the operator's own first
# keystroke, not a test-only seam — `handle_values` is reachable no other way.
private def list_overlay(values : String) : OverlayHarness
  ov = FuzzSetOverlay.editing(SetSpec.new(:list, values), 0)
  h = OverlayHarness.new(ov, commit: true)
  h.press(Termisu::Input::Key::Down)
  ov.@sel.should eq(1) # rows = [:type, :values]
  h
end

private def headers_overlay(text : String) : OverlayHarness
  ov = DiscoverHeadersOverlay.new(text.split('\n').compact_map { |l|
    name, _, value = l.partition(':')
    l.includes?(':') ? {name, value.strip} : nil
  })
  OverlayHarness.new(ov, commit: true)
end

describe "the multi-line overlay editors" do
  describe "RewriterStubOverlay — the keyboard half" do
    it "⇧→ selects, and an unmodified → collapses it" do
      h = stub_overlay("200 OK\r\nContent-Type: text/plain\r\n\r\nhi")
      ed = h.overlay.as(RewriterStubOverlay).@editor
      ed.selection?.should be_false
      h.press(Termisu::Input::Key::Right, shift: true)
      ed.selection_text.should eq("2")
      h.press(Termisu::Input::Key::Right)
      ed.selection?.should be_false
    end

    it "⇧End selects to the end of the status line" do
      h = stub_overlay("200 OK\r\nX: y")
      h.press(Termisu::Input::Key::End, shift: true)
      h.overlay.as(RewriterStubOverlay).@editor.selection_text.should eq("200 OK")
    end

    it "⇧↓ selects across the line break" do
      h = stub_overlay("200 OK\r\nX: y")
      h.press(Termisu::Input::Key::Down, shift: true)
      sel = h.overlay.as(RewriterStubOverlay).@editor.selection_text
      sel.should_not be_nil
      sel.not_nil!.should contain("200 OK")
    end

    it "⌥⌫ deletes a word rather than one character" do
      h = stub_overlay("200 OK")
      h.press(Termisu::Input::Key::End)
      h.press(Termisu::Input::Key::Backspace, alt: true)
      h.overlay.as(RewriterStubOverlay).text.should eq("200 ")
    end

    it "PageDown is no longer typed into the buffer as a stray character" do
      h = stub_overlay("200 OK")
      before = h.overlay.as(RewriterStubOverlay).text
      h.press(Termisu::Input::Key::PageDown)
      h.overlay.as(RewriterStubOverlay).text.should eq(before)
    end
  end

  describe "RewriterStubOverlay — the pointer half" do
    it "opts into dragging" do
      stub_overlay("200 OK").overlay.supports_drag?.should be_true
    end

    it "a press inside the card places the caret instead of doing nothing" do
      h = stub_overlay("200 OK\r\nContent-Type: text/plain")
      h.click_in_box(EDITOR_DX + 4, EDITOR_DY).should eq(:open)
      h.overlay.as(RewriterStubOverlay).@editor.cursor_offset.should eq(4)
    end

    it "a drag from the press extends a selection" do
      h = stub_overlay("200 OK\r\nContent-Type: text/plain")
      h.click_in_box(EDITOR_DX, EDITOR_DY)
      h.drag_in_box(EDITOR_DX + 3, EDITOR_DY)
      h.overlay.as(RewriterStubOverlay).@editor.selection_text.should eq("200")
    end

    it "a double-click takes the word under the pointer" do
      h = stub_overlay("200 OK\r\nContent-Type: text/plain")
      h.click_in_box(EDITOR_DX + 4, EDITOR_DY)
      h.double_click_in_box(EDITOR_DX + 4, EDITOR_DY).should be_true
      h.overlay.as(RewriterStubOverlay).@editor.selection_text.should eq("OK")
    end

    it "a click OUTSIDE the card still saves and closes — the drag arm did not eat it" do
      h = stub_overlay("200 OK")
      h.click(0, 0).should eq(:closed)
      h.commits.should eq(1)
    end
  end

  describe "DiscoverHeadersOverlay" do
    it "⇧End selects the whole header line" do
      h = headers_overlay("Authorization: Bearer t")
      h.press(Termisu::Input::Key::End, shift: true)
      h.overlay.as(DiscoverHeadersOverlay).@editor.selection_text.should eq("Authorization: Bearer t")
    end

    it "⌥→ steps by word instead of one character" do
      h = headers_overlay("Authorization: Bearer t")
      h.press(Termisu::Input::Key::Right, alt: true)
      h.overlay.as(DiscoverHeadersOverlay).@editor.cursor_offset.should eq("Authorization".size)
    end

    it "opts into dragging, and a drag extends from the press" do
      h = headers_overlay("Authorization: Bearer t")
      h.overlay.supports_drag?.should be_true
      h.click_in_box(EDITOR_DX, EDITOR_DY)
      h.drag_in_box(EDITOR_DX + 13, EDITOR_DY)
      h.overlay.as(DiscoverHeadersOverlay).@editor.selection_text.should eq("Authorization")
    end

    it "a double-click takes the header NAME whole — `-` is a word char" do
      h = headers_overlay("X-Custom-Header: v")
      h.click_in_box(EDITOR_DX + 3, EDITOR_DY)
      h.double_click_in_box(EDITOR_DX + 3, EDITOR_DY).should be_true
      h.overlay.as(DiscoverHeadersOverlay).@editor.selection_text.should eq("X-Custom-Header")
    end

    it "a click outside still commits — an editable card must stay dismissible" do
      h = headers_overlay("A: b")
      h.click(0, 0).should eq(:closed)
    end
  end

  describe "FuzzSetOverlay value list" do
    it "⇧→ selects inside a value" do
      h = list_overlay("alpha,beta")
      h.press(Termisu::Input::Key::Right, shift: true)
      h.overlay.as(FuzzSetOverlay).@values.selection_text.should eq("a")
    end

    it "⇧End selects the whole value line" do
      h = list_overlay("alpha,beta")
      h.press(Termisu::Input::Key::End, shift: true)
      h.overlay.as(FuzzSetOverlay).@values.selection_text.should eq("alpha")
    end

    it "⇧↑ on the FIRST line stays in the buffer instead of leaving for the row above" do
      h = list_overlay("alpha,beta")
      h.press(Termisu::Input::Key::Up, shift: true)
      h.overlay.as(FuzzSetOverlay).@sel.should eq(1) # still the value row
    end

    it "a BARE ↑ on the first line still leaves for the row above" do
      h = list_overlay("alpha,beta")
      h.press(Termisu::Input::Key::Up)
      h.overlay.as(FuzzSetOverlay).@sel.should eq(0) # back on the Type row
    end

    it "opts into dragging, and a drag extends from the press" do
      h = list_overlay("alpha,beta")
      h.overlay.supports_drag?.should be_true
      h.click_in_box(EDITOR_DX, VALUES_DY)
      h.drag_in_box(EDITOR_DX + 5, VALUES_DY)
      h.overlay.as(FuzzSetOverlay).@values.selection_text.should eq("alpha")
    end

    it "a double-click takes the value under the pointer" do
      h = list_overlay("alpha,beta")
      h.click_in_box(EDITOR_DX + 2, VALUES_DY)
      h.double_click_in_box(EDITOR_DX + 2, VALUES_DY).should be_true
      h.overlay.as(FuzzSetOverlay).@values.selection_text.should eq("alpha")
    end
  end
end
