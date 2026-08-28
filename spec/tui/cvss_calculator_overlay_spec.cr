require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

describe Gori::Tui::CvssCalculatorOverlay do
  it "initializes with default metrics producing 9.8 Critical" do
    calc = CvssCalculatorOverlay.new
    calc.vector_string.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    calc.current_score.should eq(9.8)
    calc.current_severity.should eq(Gori::Store::Severity::Critical)
  end

  it "parses initial vector into matching metric selections" do
    calc = CvssCalculatorOverlay.new("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:C/C:L/I:L/A:L")
    calc.vector_string.should eq("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:C/C:L/I:L/A:L")
    calc.current_score.should be < 5.0
    calc.selections["AV"].should eq(2) # Local
    calc.selections["AC"].should eq(1) # High
    calc.selections["PR"].should eq(2) # High
    calc.selections["UI"].should eq(1) # Required
    calc.selections["S"].should eq(1)  # Changed
  end

  it "navigates metrics with up/down and j/k keys" do
    h = OverlayHarness.new(CvssCalculatorOverlay.new)
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.selected_metric.should eq(0)

    h.press(Termisu::Input::Key::Down)
    calc.selected_metric.should eq(1)

    h.type("j")
    calc.selected_metric.should eq(2)

    h.press(Termisu::Input::Key::Up)
    calc.selected_metric.should eq(1)

    h.type("k")
    calc.selected_metric.should eq(0)

    # Wrap around
    h.press(Termisu::Input::Key::Up)
    calc.selected_metric.should eq(CvssCalculatorOverlay::METRICS.size - 1)
  end

  it "cycles options with left/right and space keys" do
    h = OverlayHarness.new(CvssCalculatorOverlay.new)
    calc = h.overlay.as(CvssCalculatorOverlay)
    # selected_metric is 0 (AV: Network [0], Adjacent [1], Local [2], Physical [3])
    calc.selections["AV"].should eq(0)

    h.press(Termisu::Input::Key::Right)
    calc.selections["AV"].should eq(1) # Adjacent

    h.press(Termisu::Input::Key::Space)
    calc.selections["AV"].should eq(2) # Local

    h.press(Termisu::Input::Key::Left)
    calc.selections["AV"].should eq(1) # Adjacent
  end

  it "selects options directly using number keys 1..4" do
    h = OverlayHarness.new(CvssCalculatorOverlay.new)
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.selected_metric.should eq(0) # AV

    h.type("4")
    calc.selections["AV"].should eq(3) # Physical

    h.type("1")
    calc.selections["AV"].should eq(0) # Network
  end

  it "commits with enter and invokes on_apply callback" do
    applied = nil
    calc = CvssCalculatorOverlay.new
    calc.on_apply = ->(vec : String) { applied = vec }

    h = OverlayHarness.new(calc)
    outcome = h.press(Termisu::Input::Key::Enter)
    outcome.should eq(:closed)
    h.commits.should eq(1)
    applied.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
  end

  it "cancels with escape without invoking on_apply" do
    applied = nil
    calc = CvssCalculatorOverlay.new
    calc.on_apply = ->(vec : String) { applied = vec }

    h = OverlayHarness.new(calc)
    outcome = h.press(Termisu::Input::Key::Escape)
    outcome.should eq(:closed)
    h.commits.should eq(0)
    applied.should be_nil
  end

  it "handles mouse clicks on option pills and buttons" do
    calc = CvssCalculatorOverlay.new
    applied = nil
    calc.on_apply = ->(vec : String) { applied = vec }

    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!

    # Row 1 is AV (y = box.y + 1). Options start at box.x + 28.
    # Click Network option
    calc.handle_click(area, box.x + 30, box.y + 1).should eq(:stay)
    calc.selected_metric.should eq(0)
    calc.selections["AV"].should eq(0)

    # Click Apply button at row 11
    calc.handle_click(area, box.x + 4, box.y + 11).should eq(:commit)
    applied.should_not be_nil

    # Click Cancel button at row 11
    calc.handle_click(area, box.x + 20, box.y + 11).should eq(:cancel)
  end

  it "renders calculator card with metrics and score" do
    h = OverlayHarness.new(CvssCalculatorOverlay.new, area: Rect.new(0, 0, 80, 24))
    h.render
    h.rendered?("CVSS v3.1 CALCULATOR").should be_true
    h.rendered?("Attack Vector (AV)").should be_true
    h.rendered?("[Network]").should be_true
    h.rendered?("Score:").should be_true
    h.rendered?("9.8 CRITICAL").should be_true
    h.rendered?("[ Apply (↵) ]").should be_true
  end
end
