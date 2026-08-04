require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# The extract-rule form (#501) — the READ half of a session binding, one sub-tab over from
# the Match & Replace form it deliberately copies. Store-free like its sibling: the
# duplicate-name refusal is INJECTED (`on_validate`), because "is `$SESSION` already
# written by another rule" is a question only the live binding table can answer.
describe Gori::Tui::ExtractRuleOverlay do
  it "defaults to a cookie descriptor with nothing filled in" do
    ov = ExtractRuleOverlay.adding
    ov.editing?.should be_false
    ov.kind.should eq(Gori::ExtractKind::Cookie)
    ov.name.should eq("")
    ov.match_filter.should eq("")
    ov.invalid_reason.should eq("enter a binding name")
  end

  it "strips a leading $ so the operator can type the token as they read it" do
    ov = ExtractRuleOverlay.adding
    "$SESSION".each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
    ov.name.should eq("SESSION")
  end

  it "cycles the descriptor kind with ←/→" do
    ov = ExtractRuleOverlay.adding
    ov.set_selected(ExtractRuleOverlay::ROW_KIND)
    ov.adjust(1)
    ov.kind.should eq(Gori::ExtractKind::Header)
    ov.adjust(-1)
    ov.kind.should eq(Gori::ExtractKind::Cookie)
  end

  it "asks for a selector for every kind except position, which asks for a range" do
    ov = ExtractRuleOverlay.adding
    "SESSION".each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
    ov.invalid_reason.should eq("enter a cookie selector")
    ov.set_selected(ExtractRuleOverlay::ROW_KIND)
    3.times { ov.adjust(1) } # cookie → header → regex → position
    ov.kind.should eq(Gori::ExtractKind::Position)
    ov.invalid_reason.should eq("enter a byte range like 0:32")
  end

  it "skips the row the current kind has no meaning for" do
    ov = ExtractRuleOverlay.adding
    # Cookie: the range row is dead, so ↓ from the selector row lands on Save.
    ov.set_selected(ExtractRuleOverlay::ROW_SELECTOR)
    ov.move(1)
    ov.on_save_row?.should be_true
    # Position: the selector row is dead instead.
    ov2 = ExtractRuleOverlay.new(kind: Gori::ExtractKind::Position)
    ov2.set_selected(ExtractRuleOverlay::ROW_KIND)
    ov2.move(1)
    ov2.on_save_row?.should be_false # landed on ROW_RANGE, not past it
  end

  it "parses a range as start:end" do
    ov = ExtractRuleOverlay.new(kind: Gori::ExtractKind::Position, pos_start: 4, pos_end: 36)
    ov.pos_start.should eq(4)
    ov.pos_end.should eq(36)
  end

  it "round-trips an existing rule" do
    rule = Gori::Store::ExtractRule.new(7_i64, true, "SESSION", "path:/login",
      Gori::ExtractKind::Regex, "token=(\\w+)", 0, 0, "*.acme.test")
    ov = ExtractRuleOverlay.editing(rule)
    ov.editing?.should be_true
    ov.edit_id.should eq(7_i64)
    ov.name.should eq("SESSION")
    ov.match_filter.should eq("path:/login")
    ov.host.should eq("*.acme.test")
    ov.kind.should eq(Gori::ExtractKind::Regex)
    ov.selector.should eq("token=(\\w+)")
  end

  it "reports the INJECTED refusal on the Save row rather than deciding for itself" do
    ov = ExtractRuleOverlay.adding
    "SESSION".each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
    ov.set_selected(ExtractRuleOverlay::ROW_SELECTOR)
    "sid".each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
    ov.invalid_reason.should be_nil # shape is fine on its own
    refuse = ->(_f : ExtractRuleOverlay) { "$SESSION is already written by another extract rule — one name, one writer".as(String?) }
    ov.on_validate = refuse
    ov.invalid_reason.not_nil!.should contain("one name, one writer")
    ov.valid?.should be_false
  end
end

describe "Gori::Tui::ExtractRuleOverlay — Overlay seam" do
  it "exposes the chrome the generic Runner dispatch renders" do
    OverlayHarness.new(ExtractRuleOverlay.adding).assert_chrome(OverlayKind::ExtractRule, "EXTRACT RULE")
  end

  it "drives fields → ↵ on the selector → on_commit → close" do
    ov = ExtractRuleOverlay.adding
    h = OverlayHarness.new(ov)
    saved = [] of {String, String, String}
    h.on_commit do
      saved << {ov.name, ov.match_filter, ov.selector}
      true
    end

    h.type("SESSION")
    h.press(Termisu::Input::Key::Down) # name → when
    h.type("path:/login")
    3.times { h.press(Termisu::Input::Key::Down) } # when → host → kind → selector
    h.type("sid")
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    saved.should eq([{"SESSION", "path:/login", "sid"}])
  end

  it "keeps the form open when the binding table refuses it" do
    ov = ExtractRuleOverlay.adding
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(ExtractRuleOverlay::ROW_SAVE)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # apply_extract_rule DID run — it just returned false
  end
end

describe Gori::Tui::RewriterView do
  # The sub-tab strip. `[`/`]` and NOT ⇥: the shell owns Tab for its focus cycle
  # (`runner.cr` says so at the gate), so a body binding for it never fires — which is
  # something only driving the built TUI showed.
  it "reserves one row for the strip and hands the rest to the sub-tab body" do
    v = RewriterView.new
    rect = Rect.new(0, 0, 80, 24)
    strip, body = v.sub_layout(rect)
    strip.h.should eq(1)
    strip.y.should eq(0)
    body.y.should eq(1)
    body.h.should eq(23)
  end

  it "gives the whole rect to the body when there is no room for a strip" do
    v = RewriterView.new
    _, body = v.sub_layout(Rect.new(0, 0, 80, 1))
    body.h.should eq(1)
  end

  it "hit-tests each strip label back to its sub-tab" do
    v = RewriterView.new
    rect = Rect.new(0, 0, 80, 24)
    # " rules " starts at x+1 and is label.size + 2 wide, then " extract ", then " bindings ".
    v.sub_at(rect, 2, 0).should eq(:rules)
    v.sub_at(rect, 10, 0).should eq(:extract)
    v.sub_at(rect, 20, 0).should eq(:bindings)
    v.sub_at(rect, 70, 0).should be_nil # past the last label
    v.sub_at(rect, 2, 5).should be_nil  # not on the strip row
  end

  it "keeps the rule list and preview pair below the strip" do
    v = RewriterView.new
    rect = Rect.new(0, 0, 80, 24)
    list, pin, _ = v.layout(rect)
    list.y.should eq(1)
    (pin.y > list.y).should be_true
  end

  # PREVIEW OUTPUT is a `ReadPane` now, not a windowed draw over a bare String: it is the one
  # place the post-rewrite bytes exist, and it had no caret, no selection and no `y`. The view
  # half is what a spec can reach (the controller needs a Host) — that the pane it is handed is
  # the pane it draws, into the rect `preview_output_body` hit-tests.
  it "draws the PREVIEW OUTPUT through the read pane it is handed" do
    v = RewriterView.new
    rect = Rect.new(0, 0, 100, 30)
    pane = ReadPane.new
    pane.source(["OUTMARK one", "OUTMARK two"])
    b = MemoryBackend.new(100, 30)
    v.render(Screen.new(b), rect, [] of Gori::Store::MatchRule, 0, 0, 0,
      :preview_out, true, false, TextArea.new("GET / HTTP/1.1\r\nHost: h\r\n\r\n"), pane)
    b.contains?("PREVIEW OUTPUT").should be_true
    b.contains?("OUTMARK one").should be_true

    # The caret the pane painted sits inside the rect the click hit-test inverts against.
    body = v.preview_output_body(rect)
    body.empty?.should be_false
    pane.click(body, body.x + 4, body.y + 1)
    pane.cursor.cy.should eq(1)
    pane.copy_text.should eq("OUTMARK two")
  end
end
