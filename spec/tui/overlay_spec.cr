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

  it "keeps a pasted esc from arming or answering the question" do
    ov = ScopeRuleOverlay.adding
    ov.takes_pasted?(esc_key).should be_false
    ov.takes_pasted?(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: 'a')).should be_true
    IssueForm.new.takes_pasted?(esc_key).should be_false
  end
end
