require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The ⌕ affordance at the left edge of a sub-tab strip. Every example here is geometry or
# pixels — `BodyChrome` is a state-free module, so none of this needs a Runner, and each
# one fails when the rule it names is removed (control-run, not a source grep: this repo
# has been fooled three times by a spec matching the PROSE that explained the rule).
#
# The invariant the whole file defends: the pill and the chips PARTITION the row. Render
# and both mouse hit-tests read `find_icon_split`, so a click can only land on what was
# drawn there — the "what gori draws vs what it hit-tests" split has produced six real
# defects in this codebase already.

# 25 columns from 14 characters — the wide-glyph case chip widths have to survive.
private CJK_LABEL = "회원가입 결제 플로우 점검"

private def labels : Array(String)
  ["1:login", "2:search api", "3:checkout"]
end

private def row(w : Int32 = 60) : Rect
  Rect.new(0, 0, w, 1)
end

describe "BodyChrome ⌕ find affordance — geometry" do
  it "partitions the row: the pill takes the left edge, the chips take the rest" do
    icon, chips = BodyChrome.find_icon_split(row, labels, nil, show: true)
    icon = icon.not_nil!
    icon.x.should eq(row.x)
    icon.w.should eq(BodyChrome::ICON_W)
    chips.x.should eq(icon.right) # no gap, no overlap
    chips.right.should eq(row.right)
    chips.w.should eq(row.w - BodyChrome::ICON_W)
  end

  it "gives the chips every column back when there is no affordance" do
    # A fixed (Help/Probe/Target/OAST) or self-drawn (Project) strip passes show: false, and
    # must lay out byte-for-byte as it did before the affordance existed. This example is
    # the no-regression gate for those five strips.
    icon, chips = BodyChrome.find_icon_split(row, labels, nil, show: false)
    icon.should be_nil
    chips.should eq(row)
  end

  it "spends no column on breathing room, but never lets the glyph end on the chips" do
    # cursor | glyph | spare — three columns, and the spare is the whole safety margin.
    # `Chrome` writes `‹` at the chips rect's x when the strip scrolls, and a glyph ending
    # on that column would be blanked by it (a terminal clears a wide glyph's lead when
    # something lands on its continuation cell). Everything else that used to pad this pill
    # was defending against ambiguous-width terminals, which gori's own box-drawing borders
    # do not survive either — so it was bought at the price of looking like an empty chip.
    BodyChrome::ICON_W.should eq(3)
    Screen.display_width(BodyChrome::MARKER.to_s).should eq(1)
    # The glyph starts one column in, and must fit inside the pill even measured double.
    (1 + Screen.display_width(BodyChrome::ICON)).should be <= BodyChrome::ICON_W
  end

  it "drops the pill rather than leaving the strip with no room for a chip" do
    # An affordance for FINDING sub-tabs must never be the reason none is on screen.
    # Swept rather than sampled: the crossover column depends on the label's width.
    (8..40).each do |w|
      icon, chips = BodyChrome.find_icon_split(row(w), [CJK_LABEL, "beta"], nil, show: true)
      next unless icon
      Chrome.strip_segments(chips, [CJK_LABEL, "beta"], 0).size.should be >= 1,
        "at width #{w} the pill is drawn but no chip fits beside it"
    end
  end

  it "measures the first VISIBLE chip, not chip 0, when the filter hides it" do
    # The `/` sub-tab filter can hide chip 0 entirely (subtab_hidden). Sizing against a
    # hidden chip would drop the pill on the width of a chip nobody can see.
    hidden = Set{0}
    wide = [CJK_LABEL, "b"]
    w = BodyChrome::ICON_W + Screen.display_width("b") + 2 + 2
    BodyChrome.find_icon_split(row(w), wide, hidden, show: true)[0].should_not be_nil
    BodyChrome.find_icon_split(row(w), wide, nil, show: true)[0].should be_nil
  end

  it "has no affordance to place when every chip is filtered away" do
    BodyChrome.find_icon_split(row, labels, Set{0, 1, 2}, show: true)[0].should be_nil
    BodyChrome.find_icon_split(row, [] of String, nil, show: true)[0].should be_nil
  end
end

describe "BodyChrome ⌕ find affordance — what is drawn is what is hit" do
  it "draws the glyph alone — the pill carries no session count" do
    # The chips already say how many sessions there are, and the `/` filter bar one row
    # below prints `visible/total`. A number on the pill was the same fact told a third
    # time, in the one spot on the row that has to stay quiet.
    backend = MemoryBackend.new(60, 1)
    many = (1..12).map { |i| "#{i}:session#{i}" }
    BodyChrome.render_subtab_strip(Screen.new(backend), Rect.new(0, 0, 60, 1),
      many, 0, focused: true, find: true)
    pill = backend.row(0)[0, BodyChrome::ICON_W]
    pill.should contain("⌕")
    pill.each_char { |c| c.ascii_number?.should be_false, "the pill drew a count: #{pill.inspect}" }
  end

  it "paints no chip ink inside the pill's columns" do
    backend = MemoryBackend.new(60, 2)
    BodyChrome.render_subtab_strip(Screen.new(backend), Rect.new(0, 0, 60, 2),
      labels, 0, focused: true, find: true)
    icon, chips = BodyChrome.find_icon_split(BodyChrome.tab_row(Rect.new(0, 0, 60, 2)),
      labels, nil, show: true)
    icon = icon.not_nil!
    # Every column the chips claim is outside the pill, and vice versa. Column-by-column
    # rather than a rect comparison, because that is the unit a click arrives in.
    Chrome.strip_segments(chips, labels, 0).each do |(idx, seg)|
      (seg.x...seg.right).each do |cx|
        icon.contains?(cx, 0).should be_false,
          "column #{cx} is inside the ⌕ pill but hit-tests to chip #{idx}"
      end
    end
  end

  it "keeps the glyph off the last column, where the ‹ overflow marker would erase it" do
    # `Chrome` always writes `‹` at ITS rect's x (chrome.cr:507) — the column immediately
    # after the pill. Without the narrowed chips rect that marker lands ON the glyph; with
    # the glyph on the pill's last column it lands on the glyph's continuation cell, and a
    # terminal answers that by blanking the wide glyph that owns it. The spare column is
    # what keeps `⌕` on screen for the one state that reaches this code — a scrolled strip.
    backend = MemoryBackend.new(24, 1)
    many = (1..9).map { |i| "#{i}:session#{i}" }
    BodyChrome.render_subtab_strip(Screen.new(backend), Rect.new(0, 0, 24, 1),
      many, 8, focused: false, find: true)
    icon = BodyChrome.find_icon_split(Rect.new(0, 0, 24, 1), many, nil, show: true)[0].not_nil!
    backend.row(0).should contain("‹")            # the window really did scroll
    backend.row(0)[0, icon.w].should contain("⌕") # …and the pill survived it
    backend.row(0)[icon.right - 1].should eq(' ') # the spare, never inked
  end

  it "marks the focused pill with a cursor and gold ink, never a filled band" do
    # The pill is one glyph, not a labelled chip: it says "the keys are here" with a `▎`
    # that was not there a frame ago plus gold ink, and paints NO background. A filled
    # band reads as a chip that lost its label, and it is the treatment this affordance
    # was deliberately moved off. MemoryBackend records no attributes, so the Bold half
    # of the treatment is not observable here — the colour and the mark are.
    lit = MemoryBackend.new(60, 1)
    BodyChrome.render_subtab_strip(Screen.new(lit), Rect.new(0, 0, 60, 1),
      labels, 0, focused: true, find: true, find_lit: true)
    icon = BodyChrome.find_icon_split(Rect.new(0, 0, 60, 1), labels, nil, show: true)[0].not_nil!
    chip = Chrome.strip_segments(
      BodyChrome.find_icon_split(Rect.new(0, 0, 60, 1), labels, nil, show: true)[1], labels, 0)[0][1]

    lit.row(0)[icon.x].should eq(BodyChrome::MARKER)
    lit.fg_at(icon.x, 0).should eq(Theme.focus_gold)
    lit.fg_at(icon.x + 1, 0).should eq(Theme.focus_gold) # the glyph, same ink as its cursor
    # The two inked cells sit on the plain canvas, and NO column of the pill wears the gold
    # fill — stated over the whole rect because that is the treatment being ruled out, and
    # the gap column between cursor and glyph is never painted at all.
    lit.bg_at(icon.x, 0).should eq(Theme.bg)
    lit.bg_at(icon.x + 1, 0).should eq(Theme.bg)
    (icon.x...icon.right).each do |cx|
      lit.bg_at(cx, 0).should_not eq(Theme.focus_gold),
        "column #{cx} of the pill is filled gold, not inked"
    end
    # The active chip recedes while the pill holds the keys — `focused && !lit` — so the
    # row still names exactly one current stop.
    lit.bg_at(chip.x + 1, 0).should eq(Theme.blend(Theme.focus_gold, Theme.bg, Chrome::SUBTAB_DIM_GOLD))

    off = MemoryBackend.new(60, 1)
    BodyChrome.render_subtab_strip(Screen.new(off), Rect.new(0, 0, 60, 1),
      labels, 0, focused: true, find: true, find_lit: false)
    off.row(0)[icon.x].should eq(' ') # the cursor column is claimed either way
    off.fg_at(icon.x + 1, 0).should eq(Theme.muted)
    off.bg_at(chip.x + 1, 0).should eq(Theme.focus_gold) # focus stays on the active chip
  end

  it "leaves the bright pill on the active chip when the affordance did not fit" do
    # A narrow terminal must not produce a row where nothing is lit — the operator would be
    # typing at a strip that looks unfocused. Width 10 is deliberately a size where a chip
    # still fits (so the row is not the pre-existing zero-chip case) but the pill does not.
    narrow = Rect.new(0, 0, 10, 1)
    short = ["beta", "gamma"]
    BodyChrome.find_icon_split(narrow, short, nil, show: true)[0].should be_nil
    Chrome.strip_segments(narrow, short, 0).size.should be >= 1

    backend = MemoryBackend.new(narrow.w, 1)
    BodyChrome.render_subtab_strip(Screen.new(backend), narrow,
      short, 0, focused: true, find: true, find_lit: true)
    backend.bg_at(1, 0).should eq(Theme.focus_gold)
  end
end
