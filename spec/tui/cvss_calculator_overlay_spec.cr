require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def calc_harness(initial : String = "", area : Rect = Rect.new(0, 0, 80, 24))
  OverlayHarness.new(CvssCalculatorOverlay.new(initial), area: area)
end

# Rows 0 and 1 are the vector field and the version cycler, so this is how many ↓ presses
# reach metric `i` (0-based).
private def to_metric(h : OverlayHarness, i : Int32)
  (i + 2).times { h.press(Termisu::Input::Key::Down) }
end

private def clear_field(h : OverlayHarness)
  70.times { h.press(Termisu::Input::Key::Backspace) }
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

  # A v4.0 vector opens the v4 table — that is what the version row is for.
  it "adopts a v4.0 vector into the v4 rows and moves the version row with it" do
    calc = CvssCalculatorOverlay.new("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
    calc.value.should eq("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N")
    calc.current_score.should eq(9.3)
    calc.spec.label.should eq("4.0")
    calc.selections["VC"].should eq(2) # high
    calc.selections["SC"].should eq(0) # none
    calc.selections["AT"].should eq(0) # none
  end

  # v3.0 shares v3.1's eight metrics exactly, so it builds here — and re-emits as 3.1 once a
  # metric is touched, which is the honest reading of "you edited it with the 3.1 table".
  it "builds a pasted v3.0 vector on the 3.1 table" do
    calc = CvssCalculatorOverlay.new("CVSS:3.0/AV:L/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
    calc.spec.label.should eq("3.1")
    calc.selections["AV"].should eq(2) # local
    calc.selections["C"].should eq(2)  # high
  end

  # A v2 vector names metrics NEITHER table can spell (`Au`, and no Scope). Half-adopting it
  # would leave the rows spelling a DIFFERENT vector than the field holds.
  it "keeps a v2 vector verbatim without half-adopting it into any row" do
    calc = CvssCalculatorOverlay.new("AV:N/AC:L/Au:N/C:C/I:C/A:C")
    calc.value.should eq("AV:N/AC:L/Au:N/C:C/I:C/A:C")
    calc.current_score.should eq(10.0)
    calc.spec.label.should eq("3.1")  # the row did not move
    calc.selections["C"].should eq(0) # untouched
  end

  it "builds a v4.0 vector the scorer agrees with" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    h.press(Termisu::Input::Key::Down) # version row
    h.press(Termisu::Input::Key::Right)
    calc.spec.label.should eq("4.0")
    # An untouched v4 card scores 0.0 for the same reason the v3.1 one does: no impact.
    calc.value.should eq("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:N/SC:N/SI:N/SA:N")
    calc.current_score.should eq(0.0)

    CvssCalculatorOverlay::V40.metrics.map(&.code).each { |c| calc.selections[c].should eq(0) }
    # The cursor is on the version row; VC is the sixth metric, so six rows down.
    6.times { h.press(Termisu::Input::Key::Down) }
    h.press(Termisu::Input::Key::Right)
    h.press(Termisu::Input::Key::Right)
    calc.selections["VC"].should eq(2) # high
    calc.current_score.should be > 0.0
    Gori::Cvss.resolve(calc.value).should_not be_nil
  end

  # The two versions ask different questions (v4 adds AT and splits the impact into
  # Vulnerable/Subsequent), and FIRST's guidance is that they are not convertible. So each
  # keeps its OWN selections: toggling back restores exactly what was there, and toggling
  # away invents nothing.
  it "remembers each version's own selections across a toggle" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    to_metric(h, 0) # attack vector, in 3.1
    h.press(Termisu::Input::Key::Right)
    h.press(Termisu::Input::Key::Right)
    calc.selections["AV"].should eq(2) # local
    v31 = calc.value

    h.press(Termisu::Input::Key::Up) # back to the version row
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VERSION)
    h.press(Termisu::Input::Key::Right)
    calc.spec.label.should eq("4.0")
    calc.selections["AV"].should eq(0) # v4 has its own map, untouched

    h.press(Termisu::Input::Key::Left)
    calc.spec.label.should eq("3.1")
    calc.selections["AV"].should eq(2) # …and 3.1 kept what it had
    calc.value.should eq(v31)
  end

  it "takes a bare numeric score" do
    calc = CvssCalculatorOverlay.new("8.8")
    calc.value.should eq("8.8")
    calc.current_severity.should eq(Gori::Store::Severity::High)
    calc.invalid?.should be_false
  end

  it "moves the row cursor over the vector field, the version row, the metrics and save" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)

    h.press(Termisu::Input::Key::Down)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VERSION)

    h.press(Termisu::Input::Key::Up)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)

    # Clamped at both ends — no wrap, matching every other rule form.
    h.press(Termisu::Input::Key::Up)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_VECTOR)
    30.times { h.press(Termisu::Input::Key::Down) }
    calc.sel.should eq(calc.row_save)
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
    clear_field(h)
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
    clear_field(h)
    calc.value.should eq("")
    calc.invalid?.should be_false
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  # ↵ on something unreadable keeps the card up rather than dropping the typed text with it.
  it "refuses to commit a value that scores as nothing" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    clear_field(h)
    h.type("not a vector")
    calc.invalid?.should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
  end

  it "picks a row and an option pill by click" do
    calc = CvssCalculatorOverlay.new
    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!
    # Rows start at box.y + 2; row 0 is the vector field and row 1 the version cycler.
    av_row = box.y + 2 + CvssCalculatorOverlay::ROW_FIRST_M

    # `network` is the first pill on the strip — one cell in from where it starts.
    x = box.x + 3 + calc.spec.indent
    calc.handle_click(area, x + 1, av_row).should eq(:stay)
    calc.sel.should eq(CvssCalculatorOverlay::ROW_FIRST_M)
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
    save_y = box.y + 2 + calc.row_save
    calc.handle_click(area, box.x + 4, save_y).should eq(:commit)
  end

  # Looking at a row is not an edit. Opening on a bare score and stepping onto the version row
  # to see what is there used to replace the value with an all-least-severe vector.
  it "does not destroy a value the rows do not describe when the version is cycled" do
    h = calc_harness("8.8")
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.current_severity.should eq(Gori::Store::Severity::High)

    h.press(Termisu::Input::Key::Down) # version row
    h.press(Termisu::Input::Key::Right)
    calc.spec.label.should eq("4.0")
    calc.value.should eq("8.8") # untouched
    calc.current_score.should eq(8.8)

    # …and the first metric edit still takes the vector back, which is the deliberate act.
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Right)
    calc.value.should start_with("CVSS:4.0/")
  end

  it "leaves a v2 vector alone across a version cycle" do
    h = calc_harness("AV:N/AC:L/Au:N/C:C/I:C/A:C")
    calc = h.overlay.as(CvssCalculatorOverlay)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Right)
    calc.value.should eq("AV:N/AC:L/Au:N/C:C/I:C/A:C")
  end

  # ← and → mean opposite things on every other cycler in gori; with two versions they happen
  # to coincide, so nothing but this pins the direction before a third one is added.
  it "steps the version backwards on ← and forwards on →" do
    calc = CvssCalculatorOverlay.new
    calc.cycle_version(1)
    calc.version_idx.should eq(1)
    calc.cycle_version(-1)
    calc.version_idx.should eq(0)
    calc.cycle_version(-1) # wraps
    calc.version_idx.should eq(CvssCalculatorOverlay::VERSIONS.size - 1)
  end

  # `Rect#contains?` counts the borders and the blank interior lines as inside the card, so a
  # click on chrome resolved to a real row index — up to and including the commit row, which
  # made clicking empty padding SAVE.
  it "ignores clicks on the card's own chrome" do
    calc = CvssCalculatorOverlay.new
    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!
    calc.row_at(box, box.x + 4, box.y).should be_nil          # top border
    calc.row_at(box, box.x + 4, box.y + 1).should be_nil      # blank above the rows
    calc.row_at(box, box.x + 4, box.bottom - 1).should be_nil # bottom border
    calc.row_at(box, box.x + 4, box.bottom - 2).should be_nil # blank below the rows
    calc.handle_click(area, box.x + 4, box.bottom - 2).should eq(:stay)
  end

  it "does not commit from a click on the padding of a scrolled card" do
    area = Rect.new(0, 0, 80, 16)
    calc = CvssCalculatorOverlay.new
    calc.cycle_version(1) # v4.0: fourteen rows, more than this card can draw
    h = OverlayHarness.new(calc, area: area)
    h.render
    box = calc.overlay_box(area).not_nil!
    calc.handle_click(area, box.x + 4, box.bottom - 2).should eq(:stay)
    h.open?.should be_true
  end

  # `Frame.option_cycle` reserves four extra columns for the ` ‹/›` cue on the FOCUSED row and
  # falls back to the lit value alone when the strip no longer fits. A hit-test that forgets
  # the cue answers with pills the card never drew.
  it "reports no option pill on a focused row too narrow to draw the strip" do
    CvssCalculatorOverlay::VERSIONS.each do |version|
      (40..80).each do |w|
        area = Rect.new(0, 0, w, 30)
        calc = CvssCalculatorOverlay.new
        calc.cycle_version(1) if version.label == "4.0"
        box = calc.overlay_box(area)
        next unless box
        av_row = box.y + 2 + CvssCalculatorOverlay::ROW_FIRST_M
        calc.set_selected(CvssCalculatorOverlay::ROW_FIRST_M) # focused: the cue is drawn
        before = calc.selections["AV"]
        mb = OverlayHarness.new(calc, area: area).render
        drew_strip = mb.row(av_row).includes?("physical")
        calc.handle_click(area, box.x + 3 + calc.spec.indent + 1, av_row)
        if drew_strip
          calc.selections["AV"].should eq(0) # the first pill really is `network`
        else
          calc.selections["AV"].should eq(before) # nothing was drawn there to hit
        end
      end
    end
  end

  it "picks the clicked version pill instead of stepping past it" do
    calc = CvssCalculatorOverlay.new
    area = Rect.new(0, 0, 80, 24)
    box = calc.overlay_box(area).not_nil!
    ver_row = box.y + 2 + CvssCalculatorOverlay::ROW_VERSION
    x = box.x + 3 + calc.spec.indent
    calc.set_selected(CvssCalculatorOverlay::ROW_VERSION)
    # Clicking the pill already lit must be a no-op, not a step to the other one.
    calc.handle_click(area, x + 1, ver_row).should eq(:stay)
    calc.version_idx.should eq(0)
    calc.handle_click(area, x + " 3.1 ".size + 1, ver_row).should eq(:stay)
    calc.version_idx.should eq(1)
  end

  # A composition belongs to the row that was taking keys; left standing it keeps being
  # spliced into what the vector row DISPLAYS while ←/→ edit metrics, so the card shows
  # something other than what `value` commits.
  it "drops an in-flight composition when the row cursor leaves the vector field" do
    h = calc_harness
    calc = h.overlay.as(CvssCalculatorOverlay)
    calc.set_preedit("가")
    calc.text_fields.first.preedit.should eq("가")
    h.press(Termisu::Input::Key::Down)
    calc.text_fields.first.preedit.should eq("")
  end

  # A v4.0 base vector is wider than the field it is generated into, so the row needs the
  # TextField's own horizontal window — `draw_field` has none, and past its edge it draws
  # neither the tail nor the caret.
  it "windows the vector field so the caret stays on screen for a long vector" do
    area = Rect.new(0, 0, 80, 30)
    calc = CvssCalculatorOverlay.new
    calc.cycle_version(1)
    calc.value.size.should be > 60
    h = OverlayHarness.new(calc, area: area)
    box = calc.overlay_box(area).not_nil!
    mb = h.render
    row = mb.row(box.y + 2)
    row.should contain("SA:N") # the TAIL, which an unwindowed field clipped away
    # …and the window scrolled rather than overflowing: nothing past the card's right border.
    row[box.right..].strip.should be_empty
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
    h.rendered?("version:").should be_true
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
    clear_field(h)
    h.render
    h.rendered?("[ clear cvss ]").should be_true
    calc.value.should eq("")
  end

  # The whole reason this modal was rewritten onto the shared rule-form geometry: at 76
  # columns the hand-rolled card drew its option pills, its buttons and a second copy of the
  # key hint straight through its own border, and Screen#text clips to the SCREEN, not the box.
  # v4.0 is fourteen rows — a natural card height of 18 against the 16 a classic 80x24
  # terminal leaves. Without a window the bottom rows, the commit row among them, would
  # simply not be drawn, and ↑/↓ would walk the cursor off the visible card.
  it "scrolls the rows so the focused one stays on the card when the card is too short" do
    area = Rect.new(0, 0, 80, 16) # a card shorter than v4.0's fourteen rows need
    calc = CvssCalculatorOverlay.new
    calc.cycle_version(1)
    calc.spec.label.should eq("4.0")
    h = OverlayHarness.new(calc, area: area)
    box = calc.overlay_box(area).not_nil!
    box.h.should be < calc.row_count + 4 # the card really is clamped

    # Walk to the commit row and it is on screen, at the bottom of the window.
    (calc.row_count - 1).times { h.press(Termisu::Input::Key::Down) }
    calc.sel.should eq(calc.row_save)
    mb = h.render
    rows = (box.y...box.bottom).map { |y| mb.row(y) }
    rows.any?(&.includes?("[ use ")).should be_true

    # …and the click hit-test inverts the SAME window: the last drawn row is the save row.
    save_y = box.y + 2 + (box.h - 4) - 1
    calc.row_at(box, box.x + 4, save_y).should eq(calc.row_save)

    # Back at the top, the vector field is on screen again and the save row has scrolled off.
    (calc.row_count - 1).times { h.press(Termisu::Input::Key::Up) }
    mb2 = h.render
    rows2 = (box.y...box.bottom).map { |y| mb2.row(y) }
    rows2.any?(&.includes?("vector:")).should be_true
    rows2.any?(&.includes?("[ use ")).should be_false
    # The score readout rides the card's TOP BORDER for exactly this reason — it is the one
    # fact you must see before ↵, and the commit row is not always drawn.
    calc.set_selected(CvssCalculatorOverlay::ROW_FIRST_M + 5)
    calc.adjust(2) # vulnerable C → high
    mb3 = h.render
    mb3.row(box.y).should contain("high")
  end

  it "keeps every cell inside the card at a narrow terminal width" do
    seeds = ["CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H",
             "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N"]
    [76, 60, 46].each do |w|
      seeds.each do |seed|
        area = Rect.new(0, 0, w, 30)
        calc = CvssCalculatorOverlay.new(seed)
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
end
