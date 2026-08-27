require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# The History column form (#819) — the same interaction model as `ExtractRuleOverlay`, one row
# richer: a column names a SIDE and a WIDTH, which a binding has no use for.
describe Gori::Tui::ColumnOverlay do
  it "defaults to a response header with nothing filled in" do
    ov = ColumnOverlay.adding
    ov.editing?.should be_false
    ov.kind.should eq(Gori::ExtractKind::Header)
    ov.side.should eq(Gori::MessageSide::Response)
    ov.invalid_reason.should eq("enter a column label")
  end

  it "cycles the side and the kind with ←/→" do
    ov = ColumnOverlay.adding
    ov.set_selected(ColumnOverlay::ROW_SIDE)
    ov.adjust(1)
    ov.side.should eq(Gori::MessageSide::Request)
    ov.set_selected(ColumnOverlay::ROW_KIND)
    ov.adjust(1)
    ov.kind.should eq(Gori::ExtractKind::Regex)
  end

  it "skips the row the current kind has no meaning for" do
    ov = ColumnOverlay.adding
    ov.set_selected(ColumnOverlay::ROW_KIND)
    2.times { ov.adjust(1) } # header → regex → position
    ov.kind.should eq(Gori::ExtractKind::Position)
    # `position` reads a RANGE, so the selector row is dead and refuses the caret.
    ov.set_selected(ColumnOverlay::ROW_SELECTOR)
    ov.@sel.should_not eq(ColumnOverlay::ROW_SELECTOR)

    ov.set_selected(ColumnOverlay::ROW_KIND)
    ov.adjust(1) # position → jsonpath: now the RANGE row is the dead one
    ov.kind.should eq(Gori::ExtractKind::JsonPath)
    ov.set_selected(ColumnOverlay::ROW_RANGE)
    ov.@sel.should_not eq(ColumnOverlay::ROW_RANGE)
  end

  # A display preference with an obvious nearest legal answer, unlike a selector — where
  # guessing would change which value the column shows.
  it "clamps a width instead of refusing it, and reads a blank one as auto" do
    ov = ColumnOverlay.new(label: "X", selector: "x", width: 999)
    ov.width.should eq(Gori::DisplayColumns::MAX_WIDTH)
    ColumnOverlay.new(label: "X", selector: "x").width.should eq(0)
  end

  it "drives fields → ↵ on the width row → on_commit → close" do
    ov = ColumnOverlay.adding
    h = OverlayHarness.new(ov)
    saved = [] of {String, String, String}
    h.on_commit do
      saved << {ov.label, ov.side.label, ov.selector}
      true
    end

    h.type("RID")
    h.press(Termisu::Input::Key::Down) # label → side
    ov.adjust(1)                       # → request
    2.times { h.press(Termisu::Input::Key::Down) }
    h.type("x-request-id")
    h.press(Termisu::Input::Key::Down) # selector → width
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    saved.should eq([{"RID", "request", "x-request-id"}])
  end

  # THE reason `Runner#save_history_column` carries an `invalid_reason` guard. `↵` on the last
  # text row commits without consulting the form, exactly as `ExtractRuleOverlay` does — so a
  # column the Save row is currently rendering a refusal for still reaches the commit site, and
  # a commit site that does not check would persist a blank-headed column that takes cells from
  # HOST and PATH for the rest of the engagement. (`apply_extract_rule` carries the same guard,
  # for the same reason, one sub-tab over.)
  it "reaches the commit site while the form is still invalid" do
    ov = ColumnOverlay.adding
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(ColumnOverlay::ROW_WIDTH)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1)
    ov.valid?.should be_false
    ov.invalid_reason.should eq("enter a column label")
  end

  it "refuses a regex that will not compile, naming it" do
    ov = ColumnOverlay.new(label: "T", kind: Gori::ExtractKind::Regex, selector: "([unclosed")
    ov.valid?.should be_false
    ov.invalid_reason.not_nil!.should contain("does not compile")
  end

  # The preview is the point of the band, so it must follow the characters being typed into the
  # selector; only the label and the width — which move no value — are gated out.
  it "re-runs the preview as the selector is typed, but not as the label is" do
    ov = ColumnOverlay.new(label: "X", selector: "a")
    runs = 0
    ov.on_preview = ->(_f : ColumnOverlay) {
      runs += 1
      "v".as(String?)
    }

    ov.set_selected(ColumnOverlay::ROW_SELECTOR)
    ov.handle_key(skey(Termisu::Input::Key::LowerA, 'b'))
    ov.handle_key(skey(Termisu::Input::Key::LowerA, 'c'))
    runs.should eq(2)

    before = runs
    ov.set_selected(ColumnOverlay::ROW_LABEL)
    3.times { ov.handle_key(skey(Termisu::Input::Key::LowerA, 'z')) }
    runs.should eq(before)
  end
end
