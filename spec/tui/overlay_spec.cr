require "../spec_helper"
require "../support/overlay_harness"

include Gori::Tui

private def esc_key : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Escape)
end

# Each rule form, opened, and a change made the way the operator makes it: a typed field, a
# cycled option, or (Rewriter) a stub written in its own sub-editor.
private def discard_cases : Array({String, Proc(FormOverlay), Proc(FormOverlay, Nil)})
  type_x = ->(ov : FormOverlay) { ov.set_selected(0); ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x')); nil }
  [
    {"colormarker typed", -> { ColormarkerRuleOverlay.adding.as(FormOverlay) }, type_x},
    {"colormarker colour", -> { ColormarkerRuleOverlay.adding.as(FormOverlay) },
     ->(ov : FormOverlay) { ov.set_selected(ColormarkerRuleOverlay::ROW_COLOR); ov.as(ColormarkerRuleOverlay).adjust(1); nil }},
    {"custom severity", -> { CustomRuleOverlay.adding.as(FormOverlay) },
     ->(ov : FormOverlay) { ov.set_selected(CustomRuleOverlay::ROW_SEV); ov.as(CustomRuleOverlay).adjust(1); nil }},
    {"extract typed", -> { ExtractRuleOverlay.adding.as(FormOverlay) }, type_x},
    {"extract kind", -> { ExtractRuleOverlay.adding.as(FormOverlay) },
     ->(ov : FormOverlay) { ov.set_selected(ExtractRuleOverlay::ROW_KIND); ov.as(ExtractRuleOverlay).adjust(1); nil }},
    {"scope kind", -> { ScopeRuleOverlay.adding.as(FormOverlay) },
     ->(ov : FormOverlay) { ov.set_selected(0); ov.as(ScopeRuleOverlay).adjust(1); nil }},
    {"rewriter typed", -> { RewriterRuleOverlay.adding.as(FormOverlay) }, type_x},
    {"rewriter op", -> { RewriterRuleOverlay.adding.as(FormOverlay) },
     ->(ov : FormOverlay) { ov.set_selected(RewriterRuleOverlay::ROW_OP); ov.as(RewriterRuleOverlay).adjust(1); nil }},
    {"rewriter stub", -> { RewriterRuleOverlay.new(op: "short_circuit").as(FormOverlay) },
     ->(ov : FormOverlay) { ov.as(RewriterRuleOverlay).stub = "HTTP/1.1 200 OK\n\nhi"; nil }},
  ]
end

# One esc on a form with unsaved edits closed it with nothing kept. It now asks once, as the
# hotkey editor does; an untouched form still closes on the first esc.
describe Gori::Tui::DiscardGuard do
  it "closes an untouched form on one esc" do
    discard_cases.each do |(name, open, _)|
      OverlayHarness.new(open.call).press(Termisu::Input::Key::Escape).should eq(:closed), name
    end
    # An edit undone is no edit.
    ov = ColormarkerRuleOverlay.adding
    ov.set_selected(ColormarkerRuleOverlay::ROW_COLOR)
    ov.adjust(1)
    ov.adjust(-1)
    ov.handle_key(esc_key).should eq(:cancel)
  end

  it "asks once before esc discards an edit; a second esc discards, any other key disarms" do
    discard_cases.each do |(name, open, change)|
      ov = open.call
      change.call(ov)
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::Escape).should eq(:open), name
      ov.discard_armed?.should be_true
      h.press(Termisu::Input::Key::Down).should eq(:open)
      ov.discard_armed?.should be_false
      h.press(Termisu::Input::Key::Escape).should eq(:open), name
      h.press(Termisu::Input::Key::Escape).should eq(:closed), name
      h.commits.should eq(0)
    end
  end

  # A click outside the card threw a dirty form away without a word; it now asks as esc does,
  # also when the card cannot be drawn, and a press inside disarms like any key.
  it "asks once before a click outside discards an edit" do
    discard_cases.each do |(name, open, change)|
      ov = open.call
      change.call(ov)
      h = OverlayHarness.new(ov)
      h.click(0, 0).should eq(:open), name
      ov.discard_armed?.should be_true
      h.click(0, 0).should eq(:closed), name
      h.commits.should eq(0)
    end
    ov = RewriterRuleOverlay.adding
    ov.set_selected(0)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x'))
    ov.handle_click(Rect.new(0, 0, 80, 24), 0, 0).should eq(:stay)
    box = ov.overlay_box(Rect.new(0, 0, 80, 24)).not_nil!
    ov.handle_click(Rect.new(0, 0, 80, 24), box.x + 2, box.y + 1) # inside: disarms
    ov.discard_armed?.should be_false
    tiny = Rect.new(0, 0, 20, 4)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 1, 1).should eq(:stay)
    ov.handle_click(tiny, 1, 1).should eq(:cancel)
  end

  # The second press of a double click falls back to an ordinary click when no field takes it,
  # which answered the question the first press had just asked, before a frame could show it.
  it "does not let a double click outside both ask and answer" do
    ov = ScopeRuleOverlay.adding
    ov.set_selected(2)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x'))
    area = Rect.new(0, 0, 80, 24)
    ov.handle_click(area, 0, 0).should eq(:stay)
    ov.handle_double_click(area, 0, 0).should eq(:stay)
    ov.discard_armed?.should be_true
    ov.handle_click(area, 0, 0).should eq(:cancel) # a deliberate second click still discards
  end

  it "closes a form that never opted in on one click outside, typed or not" do
    ov = CustomColorOverlay.adding
    ov.set_selected(0)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x'))
    ov.handle_click(Rect.new(0, 0, 80, 24), 0, 0).should eq(:cancel)
  end

  it "keeps a pasted esc from arming or answering the question" do
    ov = ScopeRuleOverlay.adding
    ov.takes_pasted?(esc_key).should be_false
    ov.takes_pasted?(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: 'a')).should be_true
    IssueForm.new.takes_pasted?(esc_key).should be_false
  end
end
