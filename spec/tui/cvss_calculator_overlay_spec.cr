require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def calc_harness(initial : String = "", area : Rect = Rect.new(0, 0, 80, 24))
  OverlayHarness.new(CvssCalculatorOverlay.new(initial), area: area)
end

# The vector row is row 0, so this is how many ↓ presses reach metric `i` (0-based).
private def to_metric(h : OverlayHarness, i : Int32)
  (i + 1).times { h.press(Termisu::Input::Key::Down) }
end

describe Gori::Tui::CvssCalculatorOverlay do
  # An empty start is the LEAST severe vector this card can build, not the worst. It used to
  # default C/I/A to High, so opening the calculator and pressing ↵ filed a 9.8 Critical
  # nobody chose — and that number ends up in someone's report.
  it "starts on the least severe vector, not the worst" do
    calc = CvssCalculatorOverlay.new
    calc.value.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N")
    calc.current_score.should eq(0.0)
    calc.current_severity.should eq(Gori::Store::Severity::Info)
  end

  it "parses an initial v3.1 vector into matching metric selections" do
    calc = CvssCalculatorOverlay.new("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:C/C:L/I:L/A:L")
    calc.value.should eq("CVSS:3.1/AV:L/AC:H/PR:H/UI:R/S:C/C:L/I:L/A:L")
    calc.current_score.should be < 5.0
    calc.selections["AV"].should eq(2) # local
    calc.selections["AC"].should eq(1) # high
    calc.selections["PR"].should eq(2) # high
    calc.selections["UI"].should eq(1) # required
    calc.selections["S"].should eq(1)  # changed
  end

  it "accepts a lowercase vector and keeps it as the canonical value" do
    calc = CvssCalculatorOverlay.new("cvss:3.1/av:n/ac:l/pr:n/ui:n/s:u/c:h/i:h/a:h")
    calc.current_score.should eq(9.8)
    calc.selections["C"].should eq(2)
  end

  # A v2/v4 vector names metrics these eight rows cannot spell (v2 has Au, v4 has AT/VC/VI/VA).
  # Half-adopting it would leave the rows spelling a DIFFERENT vector than the field holds.
  it "keeps a non-v3 vector verbatim without half-adopting it into the rows" do
    calc = CvssCalculatorOverlay.new("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
    calc.value.should eq("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
    calc.current_score.should eq(9.3)
    calc.selections["C"].should eq(0) # untouched
  end

  it "takes a bare numeric score" do
    calc = CvssCalculatorOverlay.new("8.8")
    calc.value.should eq("8.8")
    calc.current_severity.should eq(Gori::Store::Severity::High)
    calc.invalid?.should be_false
  end

  it "moves the row cursor over the vector field, the metrics and the save row" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)

    h.press(Termisu::Input::Key::Down)
    calc.sel.should eq(1)

    h.press(Termisu::Input::Key::Up)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)

    # Clamped at both ends — no wrap, matching every other rule form.
    h.press(Termisu::Input::Key::Up)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)
    20.times { h.press(Termisu::Input::Key::Down) }
    calc.sel.should eq(CvssCalculatorOverlay::ROW_SAVE)
  end

  it "cycles a metric with ←/→ and rewrites the vector field with it" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    to_metric(h, 0) # attack vector
    calc.selections["AV"].should eq(0)

    h.press(Termisu::Input::Key::Right)
    calc.selections["AV"].should eq(1) # adjacent
    calc.value.should start_with("CVSS:3.1/AV:A/")

    h.press(Termisu::Input::Key::Left)
    calc.selections["AV"].should eq(0)
    calc.value.should start_with("CVSS:3.1/AV:N/")
  end

  it "picks an option directly with 1..n" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    to_metric(h, 0)
    h.type("4")
    calc.selections["AV"].should eq(3) # physical
    h.type("1")
    calc.selections["AV"].should eq(0) # network
    h.type("9")                        # past the end of this metric's options — ignored, not a crash
    calc.selections["AV"].should eq(0)
  end

  # The whole point of the field: paste a vector and the builder catches up with it.
  it "adopts a vector typed into the field into the metric rows" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)
    45.times { h.press(Termisu::Input::Key::Backspace) }
    calc.value.should eq("")
    h.type("CVSS:3.1/AV:P/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    calc.selections["AV"].should eq(3) # physical
    calc.selections["C"].should eq(2)  # high
    calc.current_score.should eq(6.8)
    calc.current_severity.should eq(Gori::Store::Severity::Medium)
  end

  it "commits the field's value through on_commit" do
    calc = CvssCalculatorOverlay.new("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    applied = nil.as(String?)
    calc.on_commit = -> { applied = calc.value; true }
    h = OverlayHarness.new(calc)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    applied.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
  end

  it "cancels with escape without committing" do
    h = calc_harness
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  # An empty field is "clear the issue's cvss" — a real intent, and NOT the same thing as a
  # string that scores as nothing.
  it "commits an empty value as a clear" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    45.times { h.press(Termisu::Input::Key::Backspace) }
    calc.value.should eq("")
    calc.invalid?.should be_false
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  # ↵ on something unreadable keeps the card up rather than dropping the typed text with it.
  it "refuses to commit a value that scores as nothing" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    45.times { h.press(Termisu::Input::Key::Backspace) }
    h.type("not a vector")
    calc.invalid?.should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
  end

  it "picks a row and an option pill by click" do
    calc = CvssCalculatorOverlay.new
    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!
    av_row = box.y + 2 + 1 # rows start at box.y + 2; row 0 is the vector field

    # `network` is the first pill on the strip — one cell in from where it starts.
    x = box.x + 3 + CvssCalculatorOverlay::VALUE_INDENT
    calc.handle_click(area, x + 1, av_row).should eq(:stay)
    calc.sel.should eq(1)
    calc.selections["AV"].should eq(0)

    # `adjacent` is the second: past " network ".
    calc.handle_click(area, x + " network ".size + 1, av_row).should eq(:stay)
    calc.selections["AV"].should eq(1)
    calc.value.should start_with("CVSS:3.1/AV:A/")
  end

  it "commits from a click on the save row" do
    calc = CvssCalculatorOverlay.new("9.8")
    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!
    save_y = box.y + 2 + CvssCalculatorOverlay::ROW_SAVE
    calc.handle_click(area, box.x + 4, save_y).should eq(:commit)
  end

  it "cancels on a click outside the card" do
    calc = CvssCalculatorOverlay.new
    area = Rect.new(0, 0, 80, 24)
    calc.handle_click(area, 0, 0).should eq(:cancel)
  end

  it "renders the field, the metric strips and the save row" do
    h = calc_harness("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    h.render
    h.rendered?("CVSS v3.1").should be_true
    h.rendered?("vector:").should be_true
    h.rendered?("attack vector (AV):").should be_true
    h.rendered?("network").should be_true
    h.rendered?("[ use ").should be_true
    h.rendered?("9.8").should be_true
    h.rendered?("critical").should be_true
  end

  it "says what an unreadable value is on the save row" do
    h = calc_harness("nonsense")
    h.render
    h.rendered?("[ not a cvss vector or score ]").should be_true
  end

  it "offers to clear when the field is empty" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    45.times { h.press(Termisu::Input::Key::Backspace) }
    h.render
    h.rendered?("[ clear cvss ]").should be_true
    calc.value.should eq("")
  end

  # The whole reason this modal was rewritten onto the shared rule-form geometry: at 76
  # columns the hand-rolled card drew its option pills, its buttons and a second copy of the
  # key hint straight through its own border, and Screen#text clips to the SCREEN, not the box.
  it "keeps every cell inside the card at a narrow terminal width" do
    [76, 60, 46].each do |w|
      area = Rect.new(0, 0, w, 24)
      calc = CvssCalculatorOverlay.new("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
      box = calc.overlay_box(area)
      next unless box
      mb = OverlayHarness.new(calc, area: area).render
      (box.y...box.bottom).each do |y|
        row = mb.row(y)
        outside = row.each_char.with_index.reject { |(_, x)| x >= box.x && x < box.right }
        outside.each do |(ch, x)|
          fail "row #{y} col #{x} painted #{ch.inspect} outside the card at width #{w}" unless ch == ' '
        end
      end
    end
  end
end
