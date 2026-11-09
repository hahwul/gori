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

  # A chip wider than the whole strip is clipped to it, not dropped: the window parks on the
  # active chip, so dropping it left no active chip and nothing to click.
  it "keeps an active chip wider than the strip, clipped to it" do
    rect = Gori::Tui::Rect.new(0, 0, 20, 1)
    segs = Chrome.strip_segments(rect, cjk_labels, 0)
    segs.map(&.[0]).should eq([0])
    segs[0][1].right.should be <= rect.right - 1
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

  # --- multi-select marks (#683) -----------------------------------------------------
  # A mark rides the chip's LEADING PAD column, which every chip has and no ink reaches, so
  # a marked strip must lay out and hit-test exactly like an unmarked one. That is the whole
  # bargain: a glyph that cost a column would move every click on the strip.
  it "paints the mark in the pad column and moves nothing" do
    labels = ["1:alpha", "2:beta", "3:gamma"]
    rect = Rect.new(0, 0, 60, 1)
    plain = Chrome.strip_segments(rect, labels, 0)
    backend = MemoryBackend.new(rect.w, 1)
    Chrome.render_tab_strip(Screen.new(backend), rect, labels, 0, focused: true, marked: Set{0, 2})
    # Geometry is computed without ever seeing the marks, and the renderer shares it.
    Chrome.strip_segments(rect, labels, 0).should eq(plain)
    row = backend.row(0)
    active, second, third = plain.map(&.[1])
    row[active.x].should eq(Chrome::MARK) # marked AND active: the bar rides the gold pill
    backend.bg_at(active.x, 0).should eq(Theme.focus_gold)
    row[active.x + 1].should eq('1')     # the label still starts one column in
    row[second.x].should eq(' ')         # unmarked: the pad stays a pad
    row[third.x].should eq(Chrome::MARK) # marked, inactive: the bar plus a selection band
    backend.bg_at(third.x, 0).should eq(Theme.selection_dim)
    backend.bg_at(third.x + 1, 0).should eq(Theme.selection_dim)  # the band survives the label paint
    (second.right...third.x).each { |cx| row[cx].should eq(' ') } # the gap is still empty
  end

  it "reads a CJK chip's mark at the same column its click resolves to" do
    backend = MemoryBackend.new(CJK_RECT.w, 1)
    Chrome.render_tab_strip(Screen.new(backend), CJK_RECT, cjk_labels, 1, focused: false, marked: Set{0})
    seg = Chrome.strip_segments(CJK_RECT, cjk_labels, 1)[0][1]
    backend.row(0)[seg.x].should eq(Chrome::MARK)
    backend.row(0)[seg.x + 1].should eq(CJK_LABEL[0])
  end

  # `bg:` is the surface the strip sits on. Inside a card (the Preferences modal) the canvas
  # default painted each inactive label on its own black band, flush to the text, while the
  # pad and gap columns kept the card's colour — so every cell the strip paints outside a
  # pill must take the surface, and the receded gold must be blended over it.
  it "paints every non-pill cell on the surface it is handed" do
    Theme.panel.should_not eq(Theme.bg) # else this example proves nothing
    labels = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
    rect = Rect.new(0, 0, 24, 1) # narrow: the active chip scrolls the window, so both markers show
    backend = MemoryBackend.new(rect.w, 1)
    Screen.new(backend).fill(rect, Theme.panel)
    start = Chrome.render_tab_strip(Screen.new(backend), rect, labels, 3, focused: false, bg: Theme.panel)
    start.should be > 0
    backend.row(0)[0].should eq('‹')
    backend.row(0)[rect.right - 1].should eq('›')
    pill = Chrome.strip_segments(rect, labels, 3, start).find! { |(i, _)| i == 3 }[1]
    dim = Theme.blend(Theme.focus_gold, Theme.panel, Chrome::SUBTAB_DIM_GOLD)
    rect.w.times do |x|
      backend.bg_at(x, 0).should eq(pill.contains?(x, 0) ? dim : Theme.panel)
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
    segs = Chrome.menu_geometry(CJK_RECT, :cjk, tabs: tabs).segments
    segs[0][1].w.should eq(Screen.display_width(CJK_LABEL) + 2)
    segs[1][1].x.should be >= segs[0][1].right
  end
end

# Names used to be cut to ~16 columns by each tab's label builder, which cannot see the strip,
# so a wide terminal showed `1:Demo engagemen…` beside sixty empty columns. The strip fits
# them now: whole names when there is room, one shared name budget when there is not.
describe "Chrome sub-tab strip — names fit the strip's width" do
  long = ["1:Demo engagement — recon notes", "2:Workbench cross-links", "3:IDOR probe #idor #auth"]

  it "shows whole names when the strip has room" do
    b = MemoryBackend.new(140, 1)
    Chrome.render_tab_strip(Screen.new(b), Rect.new(0, 0, 140, 1), long, 0, false)
    long.each { |l| b.row(0).should contain(l) }
  end

  it "clips every name alike, keeping the index and the tags, when the strip is narrow" do
    b = MemoryBackend.new(80, 1)
    Chrome.render_tab_strip(Screen.new(b), Rect.new(0, 0, 80, 1), long, 0, false)
    row = b.row(0)
    row.should contain("3:IDOR probe #idor #auth") # short enough to stay whole
    row.should contain("1:Demo engagement — r…")
    row.should contain("2:Workbench cross-lin…") # the same name budget as chip 1
    # Render and hit-test read one layout, so every segment still covers its drawn label.
    Chrome.strip_segments(Rect.new(0, 0, 80, 1), long, 0).size.should eq(3)
  end

  it "keeps SUBTAB_NAME_FLOOR columns of a name and scrolls past that" do
    many = (1..12).map { |i| "#{i}:#{"n" * 30}" }
    segs = Chrome.strip_segments(Rect.new(0, 0, 80, 1), many, 0)
    segs.size.should be < many.size # it scrolls rather than clip below the floor
    segs.first[1].w.should eq(2 + Screen.display_width("1:") + Chrome::SUBTAB_NAME_FLOOR)
  end
end

# The top bar used to drop the project name first at 80 columns (`𝓰𝓸𝓻𝓲 ·…`) while ⌘ and ⚙
# — two chords' mouse twins — stayed. The name now keeps its columns and those step aside.
private def top_bar_row(w : Int32, project : String, probe : String = "probe:passive") : String
  b = MemoryBackend.new(w, 1)
  Chrome.render_top_bar(Screen.new(b), Rect.new(0, 0, w, 1), project: project,
    scope: "scope:off(7)", probe: probe, rules: "rules:2", listen: "localhost:18997")
  b.row(0)
end

private def top_bar_hit(w : Int32, x : Int32, project : String) : Symbol?
  Chrome.top_bar_chip_at(Rect.new(0, 0, w, 1), x, 0, project: project,
    scope: "scope:off(7)", probe: "probe:passive", rules: "rules:2", listen: "localhost:18997")
end

describe "Chrome top bar — the project name outlasts the chips" do
  # 76: the bar's rect on an 80-column terminal, inside the frame's two-column margins.
  it "keeps the name at 80 columns by yielding ⌘ first" do
    row = top_bar_row(76, "demo")
    row.should contain("· demo ")
    row.should contain("● localhost:18997")
    row.should_not contain("⌘")
    # The click map follows the chips that are drawn: no ⌘ to press.
    (0...76).none? { |x| top_bar_hit(76, x, "demo") == :palette }.should be_true
  end

  it "keeps every chip on a wide bar" do
    row = top_bar_row(140, "demo")
    row.should contain("· demo")
    row.should contain("⚙")
  end

  it "never drops an active probe chip for the name" do
    top_bar_row(60, "a-long-project-name", "probe:active").should contain("probe:active")
  end
end
