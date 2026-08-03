require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Sub-tab chips are laid out in DISPLAY COLUMNS, because that is the unit the painter
# advances in. Measuring a label with `String#size` instead makes every wide-glyph chip
# narrower than the cells it paints: render and the click hit-test both read `strip_layout`
# so they agree with EACH OTHER, and both disagree with the screen — clicking the visible
# tail of a chip switches to its neighbour, and the active chip's gold band runs past its
# own pill. Reachable from a Repeater session name or CJK path, a Notes first line, and the
# Fuzzer / Comparer / Decoder strips.
#
# 14 characters, 25 columns — the gap the whole file is about.
private CJK_LABEL = "회원가입 결제 플로우 점검"
private CJK_RECT  = Gori::Tui::Rect.new(0, 0, 60, 1)

private def cjk_labels : Array(String)
  [CJK_LABEL, "beta"]
end

describe "Chrome sub-tab strip — chip geometry in display columns" do
  it "is measuring a label whose column count really does differ from its size" do
    # Guards the rest of the file: an ASCII label would make every example below vacuous.
    Screen.display_width(CJK_LABEL).should eq(25)
    CJK_LABEL.size.should eq(14)
  end

  it "sizes a chip by the columns it paints, not by its character count" do
    seg = Chrome.strip_segments(CJK_RECT, cjk_labels, 0)[0][1]
    seg.w.should eq(Screen.display_width(CJK_LABEL) + 2) # " label " — one pad each side
  end

  it "hit-tests every column the painter writes back to the chip that wrote it" do
    # The actual user-visible defect: render_tab_strip starts a chip's text at seg.x + 1 and
    # advances by DISPLAY width, so any column in that run must resolve to the same chip the
    # glyphs came from. Asserted over the whole run rather than one sampled column, since
    # which column first crosses over depends on the label.
    segs = Chrome.strip_segments(CJK_RECT, cjk_labels, 0)
    first = segs[0][1]
    ((first.x + 1)...(first.x + 1 + Screen.display_width(CJK_LABEL))).each do |cx|
      hit = segs.find { |(_, r)| r.contains?(cx, CJK_RECT.y) }
      next unless hit
      hit[0].should eq(0),
        "column #{cx} is under chip 0's glyphs but hit-tests to chip #{hit[0]}"
    end
  end

  it "leaves the breathing room between chips actually empty" do
    # The rendered counterpart: the two-column gap strip_layout reserves has to hold nothing.
    # A chip measured in characters drags its tail glyphs (and, when it is the active pill,
    # its gold band) straight through that gap and into the next chip.
    backend = MemoryBackend.new(CJK_RECT.w, 1)
    Chrome.render_tab_strip(Screen.new(backend), CJK_RECT, cjk_labels, 0, focused: true)
    segs = Chrome.strip_segments(CJK_RECT, cjk_labels, 0)
    first, second = segs[0][1], segs[1][1]
    backend.bg_at(first.right - 1, 0).should eq(Theme.focus_gold) # the pill is really filled
    (first.right...second.x).each do |cx|
      backend.row(0)[cx].should eq(' '),
        "column #{cx} sits in the gap between chips but holds #{backend.row(0)[cx].inspect}"
    end
  end

  it "keeps the ASCII strip byte-for-byte where it was" do
    # display_width takes its printable-ASCII fast path here, so the common strip must not
    # have moved a single column.
    labels = ["1:alpha", "2:beta", "3:gamma"]
    Chrome.strip_segments(Rect.new(0, 0, 60, 1), labels, 0).map { |(i, r)| {i, r.x, r.w} }
      .should eq([{0, 1, 9}, {1, 12, 8}, {2, 22, 9}])
  end
end

describe "Chrome tab menu — chip geometry in display columns" do
  it "sizes a menu segment by its columns too, for whatever labels it is handed" do
    # The catalog TABS are fixed ASCII, so this is consistency rather than a live defect —
    # but menu_layout takes `tabs:` from the caller and shares scroll_start with the sub-tab
    # strip, and the two must not measure a label differently.
    tabs = [{:cjk, CJK_LABEL}, {:beta, "beta"}]
    segs = Chrome.menu_segments(CJK_RECT, :cjk, tabs: tabs)
    segs[0][1].w.should eq(Screen.display_width(CJK_LABEL) + 2)
    segs[1][1].x.should be >= segs[0][1].right
  end
end
