require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

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
    down(ov, 2)                                     # op row
    ov.handle_key(skey(Termisu::Input::Key::Right)) # replace → add_header
    down(ov, 2)                                     # op → match → part
    ov.handle_key(skey(Termisu::Input::Key::Right)) # part → body
    down(ov, 2)                                     # part → host → header(find)
    stype(ov, "X-Trace")
    rule = ov.candidate_rule
    rule.op.should eq(Gori::Store::RuleOp::AddHeader)
    rule.part.should eq(Gori::Store::RulePart::Head) # normalized, not body
    rule.pattern.should eq("X-Trace")
  end

  it "requires a pattern, and validates a regex replace" do
    ov = RewriterRuleOverlay.adding
    ov.valid?.should be_false                       # empty pattern
    down(ov, 3)                                     # name → target → op → match
    ov.handle_key(skey(Termisu::Input::Key::Right)) # literal → regex
    ov.match_kind.should eq(Gori::Store::MatchKind::Regex)
    down(ov, 3)               # match → part → host → find
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

# Post-migration surface. This form carries TWO injected couplings, not one: on_commit
# (RewriterController#apply_rewriter_rule) and on_preview (a scan of recent flows). The
# form owns only WHEN to ask for a preview — that gate used to be @rewriter_preview_sig
# on the Runner, and it is what keeps typing from rescanning traffic on every keystroke.
describe "Gori::Tui::RewriterRuleOverlay — Overlay seam" do
  it "exposes the chrome the collapsed Runner ladders used to hard-code" do
    OverlayHarness.new(RewriterRuleOverlay.adding).assert_chrome(OverlayKind::RewriterRule, "REWRITER RULE")
  end

  it "drives fields → ↵ on value → on_commit → close through the generic dispatch" do
    ov = RewriterRuleOverlay.adding
    h = OverlayHarness.new(ov)
    saved = [] of {String, String, String}
    h.on_commit do
      saved << {ov.name, ov.pattern, ov.replacement}
      true
    end

    h.type("strip-csp")
    6.times { h.press(Termisu::Input::Key::Down) } # name → … → find
    h.type("secret")
    h.press(Termisu::Input::Key::Down) # → value
    h.type("REDACTED")
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    saved.should eq([{"strip-csp", "secret", "REDACTED"}])
  end

  it "keeps the form open when the controller rejects it (empty pattern)" do
    ov = RewriterRuleOverlay.adding
    ov.valid?.should be_false
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(8) # Save row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # apply_rewriter_rule DID run — it just returned false
  end

  it "esc cancels and a click-away dismisses — neither persists anything" do
    h = OverlayHarness.new(RewriterRuleOverlay.adding)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(RewriterRuleOverlay.adding)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel) # raw: not a silent save
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "click selects a row, and a click on Save commits" do
    ov = RewriterRuleOverlay.adding
    h = OverlayHarness.new(ov)
    # Rows start at box.y + 2; Save is index 8.
    h.click_in_box(3, 4).should eq(:open) # the op row
    h.click_in_box(3, 10).should eq(:closed)
    h.commits.should eq(1)
  end

  it "asks the injected preview source ONCE per match-relevant change, never for pure nav" do
    ov = RewriterRuleOverlay.adding
    asked = [] of Gori::Store::MatchRule
    ov.on_preview = ->(candidate : Gori::Store::MatchRule) {
      asked << candidate
      "affects 2 of 7 recent flows"
    }
    h = OverlayHarness.new(ov)

    # An empty pattern must never scan (it would match everything); the slot says so.
    h.press(Termisu::Input::Key::Down)
    ov.preview.should eq("enter a pattern to preview")
    asked.should be_empty

    5.times { h.press(Termisu::Input::Key::Down) } # → find
    h.type("secret")
    asked.size.should eq(6) # one scan per character that changed the pattern
    asked.last.pattern.should eq("secret")
    ov.preview.should eq("affects 2 of 7 recent flows")

    # Moving the selection changes no match-relevant field → no rescan, so typing stays
    # responsive no matter how much traffic is in the project.
    before = asked.size
    3.times { h.press(Termisu::Input::Key::Up) }
    h.click_in_box(3, 4)
    h.wheel(3)
    asked.size.should eq(before)
  end

  it "labels the preview slot for a header op (\"header name\", not \"pattern\")" do
    ov = RewriterRuleOverlay.adding
    h = OverlayHarness.new(ov)
    2.times { h.press(Termisu::Input::Key::Down) } # → op
    h.press(Termisu::Input::Key::Right)            # replace → add_header
    ov.header_op?.should be_true
    ov.preview.should eq("enter a header name to preview")
  end

  it "routes IME preedit to the focused text row" do
    h = OverlayHarness.new(RewriterRuleOverlay.adding)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end
end
