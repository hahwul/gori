require "../spec_helper"

private alias SS = Gori::Screenshot

private CANVAS = SS::RGB.hex("#0a0a0b")
private INK    = SS::RGB.hex("#c8c8cc")
private GOLD   = SS::RGB.hex("#d9c28b")
private BAND   = SS::RGB.hex("#26262c")

# A 6x3 frame small enough to work the arithmetic out by hand, holding the three things the
# emitters branch on: a WIDE glyph (lead + continuation), a run in a different colour and
# weight, and a background band that does not reach the row's edges.
#
#   row 0   中 中  a   ·   ·   ·      (中 spans columns 0-1; `a` is bold gold)
#   row 1   ·   b   c   ·   ·   ·      (columns 1-3 over a band)
#   row 2   z   &   <   >   ·   ·
private def hand_frame : SS::Frame
  cells = [] of SS::Cell
  cells << SS::Cell.new("中", INK, CANVAS)
  cells << SS::Cell.new("", INK, CANVAS, cont: true)
  cells << SS::Cell.new("a", GOLD, CANVAS, Termisu::Attribute::Bold)
  3.times { cells << SS::Cell.new(" ", INK, CANVAS) }

  cells << SS::Cell.new(" ", INK, CANVAS)
  cells << SS::Cell.new("b", INK, BAND)
  cells << SS::Cell.new("c", INK, BAND)
  cells << SS::Cell.new(" ", INK, BAND)
  2.times { cells << SS::Cell.new(" ", INK, CANVAS) }

  "z&<>".each_char { |ch| cells << SS::Cell.new(ch.to_s, INK, CANVAS) }
  2.times { cells << SS::Cell.new(" ", INK, CANVAS) }

  SS::Frame.new(6, 3, cells, bg: CANVAS, fg: INK, theme: "goridark", title: "6x3")
end

module Gori::Screenshot
  describe Svg do
    # Every number below comes from the formulas, not from a dump of the implementation:
    #   cw = 15 * 0.60 = 9      ch = 15 * 1.20 = 18      baseline = ch * 0.76 = 13.68
    #   W  = 6 * 9 + 2 * 18 = 90            H = 3 * 18 + 2 * 18 + 34 = 124
    #   y0 = pad + titleh = 52              row y = y0 + n * 18
    #   the 中 run spans TWO columns → textLength 18, and `a` therefore starts at 36.
    it "renders the hand-worked frame" do
      Svg.render(hand_frame).should eq(<<-SVG)
        <svg xmlns="http://www.w3.org/2000/svg" width="90" height="124" viewBox="0 0 90.0 124.0" font-family="#{Chrome::BODY_FONTS}" font-size="15.0px" role="img" aria-label="6x3" data-theme="goridark" data-cols="6" data-rows="3">
        <rect x="0.5" y="0.5" width="89.0" height="123.0" rx="10" ry="10" fill="#0a0a0b" stroke="#313132" stroke-width="1"/>
        <rect x="1" y="1" width="88.0" height="34.0" rx="10" ry="10" fill="#19191a"/>
        <rect x="1" y="24.0" width="88.0" height="10" fill="#19191a"/>
        <circle cx="18.0" cy="17.0" r="5.5" fill="#e0645f"/>
        <circle cx="34.0" cy="17.0" r="5.5" fill="#e0b24f"/>
        <circle cx="50.0" cy="17.0" r="5.5" fill="#4fb06a"/>
        <text x="45.0" y="22.0" text-anchor="middle" fill="#919191" font-family="#{Chrome::TITLE_FONTS}" font-size="12.3px">6x3</text>
        <rect x="27.00" y="70.00" width="27.00" height="18.00" fill="#26262c"/>
        <text x="18.00" y="65.68" textLength="18.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">中</text>
        <text x="36.00" y="65.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#d9c28b" font-weight="700" xml:space="preserve">a</text>
        <text x="27.00" y="83.68" textLength="18.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">bc</text>
        <text x="18.00" y="101.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">z&amp;&lt;&gt;</text>
        </svg>
        SVG
    end

    it "walks the aria fallback chain: explicit label, then title, then a generic one" do
      Svg.render(hand_frame, aria: "the history pane").lines.first
        .should contain(%(aria-label="the history pane"))
      Svg.render(hand_frame).lines.first.should contain(%(aria-label="6x3"))
      Svg.render(hand_frame, title: nil).lines.first
        .should contain(%(aria-label="gori terminal screenshot"))
    end

    it "carries the frame's own metadata on the root element" do
      head = Svg.render(hand_frame).lines.first
      head.should contain(%(data-theme="goridark" data-cols="6" data-rows="3"))
      # Absent means NEVER MASKED, which is a different claim from "masked, nothing matched".
      head.should_not contain("data-sanitized")
      Svg.render(hand_frame.with(sanitized: 0)).lines.first
        .should contain(%(data-sanitized="0"))
      Svg.render(hand_frame.with(sanitized: 4)).lines.first
        .should contain(%(data-sanitized="4"))
    end

    it "drops the window chrome for a strip and keeps the cells" do
      dump = Svg.render(hand_frame, tail: 1)
      dump.scan("<circle ").size.should eq(0)
      dump.scan("<rect ").size.should eq(1) # the window only; row 2 has no band
      dump.should contain(">z&amp;&lt;&gt;</text>")
      # One row, no title bar: H = 18 + 36 = 54, and row 0 sits at y0 = pad.
      dump.lines.first.should contain(%(width="90" height="54"))
      dump.lines.first.should contain(%(data-rows="1"))
      dump.should contain(%(<text x="18.00" y="31.68"))
    end

    it "paints a hidden run's background and none of its text" do
      cells = [
        Cell.new("s", INK, BAND, Termisu::Attribute::Hidden),
        Cell.new("h", INK, BAND, Termisu::Attribute::Hidden),
        Cell.new("!", INK, CANVAS),
      ]
      dump = Svg.render(Frame.new(3, 1, cells, bg: CANVAS, fg: INK), title: nil)
      # The shape of the secret survives; the secret does not.
      dump.should contain(%(<rect x="18.00" y="18.00" width="18.00" height="18.00" fill="#26262c"/>))
      dump.should_not contain(">sh<")
      dump.scan("<text ").size.should eq(1)
      dump.should contain(">!</text>")
    end

    it "renders a frame with nothing on it as an empty window" do
      cells = Array.new(4) { Cell.new(" ", INK, CANVAS) }
      dump = Svg.render(Frame.new(2, 2, cells, bg: CANVAS, fg: INK), title: nil)
      dump.scan("<text ").size.should eq(0)
      # No rows: H is the padding alone.
      dump.lines.first.should contain(%(height="36"))
      dump.lines.first.should contain(%(data-rows="0"))
    end

    it "scales every coordinate with the font size and the padding" do
      dump = Svg.render(hand_frame, title: nil, font_size: 10.0, pad: 4.0)
      # cw = 6, ch = 12, W = 6*6 + 8 = 44, H = 3*12 + 8 = 44, baseline = 12 * 0.76 = 9.12
      dump.lines.first.should contain(%(width="44" height="44" viewBox="0 0 44.0 44.0"))
      dump.lines.first.should contain(%(font-size="10.0px"))
      dump.should contain(%(<text x="4.00" y="13.12" textLength="12.00"))
    end
  end
end
