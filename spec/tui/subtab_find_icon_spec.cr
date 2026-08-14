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
    icon, chips = BodyChrome.find_icon_split(row, labels, nil, count: 3)
    icon = icon.not_nil!
    icon.x.should eq(row.x)
    icon.w.should eq(BodyChrome::ICON_W)
    chips.x.should eq(icon.right) # no gap, no overlap
    chips.right.should eq(row.right)
    chips.w.should eq(row.w - BodyChrome::ICON_W)
  end

  it "gives the chips every column back when there is no affordance" do
    # A fixed (Help/Probe/Target/OAST) or self-drawn (Project) strip passes count: nil, and
    # must lay out byte-for-byte as it did before the affordance existed. This example is
    # the no-regression gate for those five strips.
    icon, chips = BodyChrome.find_icon_split(row, labels, nil, count: nil)
    icon.should be_nil
    chips.should eq(row)
  end

  it "keeps the pill the same width as the count grows" do
    # `Chrome.scroll_start` only ever ADVANCES its window, so a pill that widened at the
    # 10th session would shove the strip right and never give the column back. Collapsing
    # past 99 is what keeps the label inside the fixed box.
    widths = [1, 9, 10, 99, 100, 4000].map do |n|
      BodyChrome.find_icon_split(row, labels, nil, count: n)[0].not_nil!.w
    end
    widths.uniq.should eq([BodyChrome::ICON_W])
    Screen.display_width(BodyChrome.icon_label(4000)).should be <= BodyChrome::ICON_W - 2
  end

  it "drops the pill rather than leaving the strip with no room for a chip" do
    # An affordance for FINDING sub-tabs must never be the reason none is on screen.
    # Swept rather than sampled: the crossover column depends on the label's width.
    (8..40).each do |w|
      icon, chips = BodyChrome.find_icon_split(row(w), [CJK_LABEL, "beta"], nil, count: 2)
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
    BodyChrome.find_icon_split(row(w), wide, hidden, count: 2)[0].should_not be_nil
    BodyChrome.find_icon_split(row(w), wide, nil, count: 2)[0].should be_nil
  end

  it "has no affordance to place when every chip is filtered away" do
    BodyChrome.find_icon_split(row, labels, Set{0, 1, 2}, count: 3)[0].should be_nil
    BodyChrome.find_icon_split(row, [] of String, nil, count: 0)[0].should be_nil
  end
end

describe "BodyChrome ⌕ find affordance — what is drawn is what is hit" do
  it "paints no chip ink inside the pill's columns" do
    backend = MemoryBackend.new(60, 2)
    BodyChrome.render_subtab_strip(Screen.new(backend), Rect.new(0, 0, 60, 2),
      labels, 0, focused: true, find: 3)
    icon, chips = BodyChrome.find_icon_split(BodyChrome.tab_row(Rect.new(0, 0, 60, 2)),
      labels, nil, count: 3)
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

  it "leaves the pill's trailing pad clear of the ‹ overflow marker" do
    # `Chrome` always writes `‹` at ITS rect's x (chrome.cr:507). Without the narrowed rect
    # the marker lands on the glyph; without the pad it lands flush against it.
    backend = MemoryBackend.new(24, 1)
    many = (1..9).map { |i| "#{i}:session#{i}" }
    BodyChrome.render_subtab_strip(Screen.new(backend), Rect.new(0, 0, 24, 1),
      many, 8, focused: false, find: 9)
    icon = BodyChrome.find_icon_split(Rect.new(0, 0, 24, 1), many, nil, count: 9)[0].not_nil!
    backend.row(0).should contain("‹")            # the window really did scroll
    backend.row(0)[0, icon.w].should contain("⌕") # …and the pill survived it
    backend.row(0)[icon.right - 1].should eq(' ') # the pad, kept clear
  end

  it "lights exactly one pill on the row" do
    # The affordance and the active chip share the strip's focus colour, so only one of
    # them may wear it. `focused && !lit` on the chips is what enforces that.
    lit = MemoryBackend.new(60, 1)
    BodyChrome.render_subtab_strip(Screen.new(lit), Rect.new(0, 0, 60, 1),
      labels, 0, focused: true, find: 3, find_lit: true)
    icon = BodyChrome.find_icon_split(Rect.new(0, 0, 60, 1), labels, nil, count: 3)[0].not_nil!
    chip = Chrome.strip_segments(
      BodyChrome.find_icon_split(Rect.new(0, 0, 60, 1), labels, nil, count: 3)[1], labels, 0)[0][1]
    lit.bg_at(icon.x + 1, 0).should eq(Theme.focus_gold)
    lit.bg_at(chip.x + 1, 0).should eq(Theme.blend(Theme.focus_gold, Theme.bg, Chrome::SUBTAB_DIM_GOLD))

    off = MemoryBackend.new(60, 1)
    BodyChrome.render_subtab_strip(Screen.new(off), Rect.new(0, 0, 60, 1),
      labels, 0, focused: true, find: 3, find_lit: false)
    off.bg_at(icon.x + 1, 0).should_not eq(Theme.focus_gold)
    off.bg_at(chip.x + 1, 0).should eq(Theme.focus_gold) # focus stays on the active chip
  end

  it "leaves the bright pill on the active chip when the affordance did not fit" do
    # A narrow terminal must not produce a row where nothing is lit — the operator would be
    # typing at a strip that looks unfocused. Width 12 is deliberately a size where a chip
    # still fits (so the row is not the pre-existing zero-chip case) but the pill does not.
    narrow = Rect.new(0, 0, 12, 1)
    short = ["beta", "gamma"]
    BodyChrome.find_icon_split(narrow, short, nil, count: 2)[0].should be_nil
    Chrome.strip_segments(narrow, short, 0).size.should be >= 1

    backend = MemoryBackend.new(narrow.w, 1)
    BodyChrome.render_subtab_strip(Screen.new(backend), narrow,
      short, 0, focused: true, find: 2, find_lit: true)
    backend.bg_at(1, 0).should eq(Theme.focus_gold)
  end
end
