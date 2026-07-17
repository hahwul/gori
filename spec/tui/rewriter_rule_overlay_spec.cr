require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def stype(ov : RewriterRuleOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
end

private def down(ov : RewriterRuleOverlay, n : Int32) : Nil
  n.times { ov.handle_key(skey(Termisu::Input::Key::Down)) }
end

describe Gori::Tui::RewriterRuleOverlay do
  it "defaults to a literal request-head replace" do
    ov = RewriterRuleOverlay.adding
    ov.editing?.should be_false
    ov.target.should eq(Gori::Store::RuleTarget::Request)
    ov.op.should eq(Gori::Store::RuleOp::Replace)
    ov.match_kind.should eq(Gori::Store::MatchKind::Literal)
    ov.part.should eq(Gori::Store::RulePart::Head)
    ov.header_op?.should be_false
  end

  it "cycles the op with ←/→ and reports a header op" do
    ov = RewriterRuleOverlay.adding
    down(ov, 2) # name → target → op
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay)
    ov.op.should eq(Gori::Store::RuleOp::AddHeader)
    ov.header_op?.should be_true
  end

  it "forces a header op onto the HEAD even if part is cycled to body" do
    ov = RewriterRuleOverlay.adding
    down(ov, 2) # op row
    ov.handle_key(skey(Termisu::Input::Key::Right)) # replace → add_header
    down(ov, 2) # op → match → part
    ov.handle_key(skey(Termisu::Input::Key::Right)) # part → body
    down(ov, 2) # part → host → header(find)
    stype(ov, "X-Trace")
    rule = ov.candidate_rule
    rule.op.should eq(Gori::Store::RuleOp::AddHeader)
    rule.part.should eq(Gori::Store::RulePart::Head) # normalized, not body
    rule.pattern.should eq("X-Trace")
  end

  it "requires a pattern, and validates a regex replace" do
    ov = RewriterRuleOverlay.adding
    ov.valid?.should be_false # empty pattern
    down(ov, 3) # name → target → op → match
    ov.handle_key(skey(Termisu::Input::Key::Right)) # literal → regex
    ov.match_kind.should eq(Gori::Store::MatchKind::Regex)
    down(ov, 3) # match → part → host → find
    stype(ov, "(")            # an unbalanced group
    ov.valid?.should be_false # bad regex
    ov.handle_key(skey(Termisu::Input::Key::LowerA, ')'))
    ov.valid?.should be_true # "()" compiles
  end

  it "seeds edit mode from an existing rule" do
    rule = Gori::Store::MatchRule.new(7_i64, true, Gori::Store::RuleTarget::Response,
      Gori::Store::RulePart::Body, "old", "new",
      Gori::Store::RuleOp::Replace, Gori::Store::MatchKind::Regex, "my-rule", "*.example.com")
    ov = RewriterRuleOverlay.editing(rule)
    ov.editing?.should be_true
    ov.edit_id.should eq(7_i64)
    ov.target.should eq(Gori::Store::RuleTarget::Response)
    ov.part.should eq(Gori::Store::RulePart::Body)
    ov.match_kind.should eq(Gori::Store::MatchKind::Regex)
    ov.name.should eq("my-rule")
    ov.host.should eq("*.example.com")
    ov.pattern.should eq("old")
    ov.replacement.should eq("new")
  end

  it "commits from the value row and cancels on esc" do
    ov = RewriterRuleOverlay.adding
    down(ov, 6) # → find
    stype(ov, "a")
    down(ov, 1) # find → value
    ov.handle_key(skey(Termisu::Input::Key::Enter)).should eq(:commit)

    ov2 = RewriterRuleOverlay.adding
    ov2.handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "renders without crashing and maps a click to a row" do
    ov = RewriterRuleOverlay.adding
    screen = Screen.new(MemoryBackend.new(90, 30))
    area = Rect.new(0, 0, 90, 30)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 2).should eq(0) # name row
  end
end
