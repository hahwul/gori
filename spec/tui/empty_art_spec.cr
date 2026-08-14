require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The figures that ride above the empty-state cards. `EmptyArt.draw` paints glyph N of a line
# at column N, and `left`/`ink_w` measure the figure in CHARACTERS — so every invariant here
# exists because a violation shears a row or silently hides the whole figure rather than
# failing loudly. Mirrors spec/tui/brand_art_spec.cr, which guards the same rules for the
# gori mark.

# What a source line actually paints, resolved through the ink tiers (`▓` is repainted as a
# solid block, so the source text is NOT what lands on screen).
private def painted(line : String) : String
  line.chars.map { |ch| ch == ' ' ? ' ' : EmptyArt.ink(ch)[0] }.join
end

# Every variant that has a figure. Spelled out rather than derived from CATALOG.keys, because
# the failure this catches is a MISKEYED entry: `:fuzzer_result` would leave that variant with
# no art forever and nothing else would ever mention it.
EXPECTED_ART = [
  :history, :sitemap, :intercept, :repeater, :fuzzer, :fuzzer_results, :probe, :issues,
  :notes, :project_desc, :discover, :comparer, :miner, :miner_results, :sequencer,
  :sequencer_samples, :oast,
]

describe Gori::Tui::EmptyArt do
  it "has a figure for every empty-state variant, and none for anything else" do
    EmptyArt::CATALOG.keys.to_a.sort_by(&.to_s).should eq(EXPECTED_ART.sort_by(&.to_s))
    EXPECTED_ART.each { |v| EmptyArt.for(v).should_not be_nil }
    EmptyArt.for(:not_a_variant).should be_nil
  end

  it "is drawn entirely in single-cell glyphs" do
    EmptyArt::CATALOG.each do |variant, block|
      block.lines.each_with_index do |line, row|
        line.each_char_with_index do |ch, col|
          glyph = EmptyArt.ink(ch)[0]
          Screen.draw_width(glyph.to_s).should eq(1),
            "#{variant} row #{row} col #{col}: #{glyph.inspect} is not one cell"
        end
      end
    end
  end

  # ASCII, Box Drawing and Block Elements are the families whose width is unambiguous in every
  # terminal. The geometric shapes and `⏸` the cards use in their TEXT lines are East-Asian
  # Ambiguous: fine where `Screen.display_width` measures them, fatal here where nothing does.
  it "stays inside the three width-safe glyph families" do
    EmptyArt::CATALOG.each do |variant, block|
      block.lines.each_with_index do |line, row|
        line.each_char do |ch|
          o = ch.ord
          ok = (o >= 0x20 && o <= 0x7e) || (o >= 0x2500 && o <= 0x257F) || (o >= 0x2580 && o <= 0x259F)
          ok.should be_true, "#{variant} row #{row}: #{ch.inspect} (#{"0x%04x" % o}) is outside ASCII / Box Drawing / Block Elements"
        end
      end
    end
  end

  it "reports each figure's own geometry" do
    EmptyArt::CATALOG.each do |variant, block|
      block.h.should eq(block.lines.size), variant.to_s
      block.left.should eq(block.lines.min_of { |l| l.size - l.lstrip.size }), variant.to_s
      block.ink_w.should eq(block.lines.max_of(&.rstrip.size) - block.left), variant.to_s
      block.min_w.should eq(block.ink_w + 2 * block.left), variant.to_s
      block.ink_w.should be > 0, variant.to_s
    end
  end

  it "keeps every line inside the measured ink extent" do
    EmptyArt::CATALOG.each do |variant, block|
      block.lines.each_with_index do |line, row|
        line.rstrip.size.should be <= block.left + block.ink_w, "#{variant} row #{row}"
        line.should eq(line.rstrip), "#{variant} row #{row} has trailing padding" # rstrip drives the extent
      end
    end
  end

  # THE budget, and the reason it is a spec rather than a comment. A body is 14..16 rows on an
  # 80x24 and a card eats 6..15 of them, so a figure has 3 rows to spend — 4 only for the
  # CENTERED variants, whose cards are the shortest and which draw no headline. `Brand::ART` is
  # 11 rows and needed ~20: it was gated out of every realistic pane, which is exactly how art
  # ends up looking absent instead of opportunistic. Growing a figure past this budget fails
  # here instead of silently disappearing on the terminal most people run.
  #
  # The CENTERED cap is 4 rather than 5 because `:project_desc` shipped at 5 and proved the
  # point one size down: its pane is the shortest full-card host in the app (the overview card
  # takes the top of the Project tab), so 5 + gap + card needed 14 rows against the 13 a 100x30
  # leaves — the figure only ever appeared at 120x40. `paints every figure at a realistic body
  # size` below cannot catch that on its own; it renders into a rect no real pane is that tall.
  it "keeps every figure inside the row budget its tier can pay for" do
    EmptyArt::CATALOG.each do |variant, block|
      cap = TrafficEmptyState::CENTERED.includes?(variant) ? 4 : 3
      block.h.should be <= cap, "#{variant} is #{block.h} rows, over the #{cap}-row budget"
      # Wider than this and the figure stops reading as belonging to the 42..50 column card.
      block.ink_w.should be <= 34, "#{variant} is #{block.ink_w} columns wide"
    end
  end

  # The Project dossier's own arithmetic, pinned at the size that caught it. 13 rows is what a
  # 100x30 leaves the DESCRIPTION pane once the overview card above it has taken its share, and
  # `place_art_and_card` admits a figure only when `art.h + ART_GAP + card_h` fits — so this
  # fails the moment the figure grows a row back or the card does.
  it "paints the project dossier in the pane a 100x30 actually leaves it" do
    b = MemoryBackend.new(100, 13)
    TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, 13), variant: :project_desc)
    b.contains?("PROJECT").should be_true
    b.contains?(painted(EmptyArt::PROJECT_DESC.lines[1]).strip).should be_true
  end

  # The tiers are what stop a figure reading as one flat blob. Assert the SEPARATION and the
  # ORDER, not the constants: a DIM_MIX edited to 0 would flatten every figure, and no other
  # spec would notice.
  # Measured as CONTRAST AGAINST THE CANVAS, not raw luma, so the claim holds on light palettes
  # too — there "nearer" means darker. The sweep is the point: an earlier version took the
  # scaffolding from `Theme.muted`, which reads fine on the default dark theme and carries MORE
  # contrast than the mass above it on `goriday`. One-theme assertions cannot see that.
  it "separates subject, secondary mass and scaffolding in every built-in theme" do
    before = Theme.active_name
    begin
      Theme.available.each do |name|
        Theme.apply(name)
        solid_glyph, solid, solid_attr = EmptyArt.ink(EmptyArt::SOLID)
        dim_glyph, dim, _ = EmptyArt.ink(EmptyArt::DIM)
        _, scaffold, scaffold_attr = EmptyArt.ink('─')

        solid_glyph.should eq(EmptyArt::SOLID)
        dim_glyph.should eq(EmptyArt::SOLID) # never a literal dither — see EmptyArt

        canvas = Theme.luma(Theme.bg)
        ramp = [solid, dim, scaffold].map { |c| (Theme.luma(c) - canvas).abs }
        # Falling off in order: subject, then mass, then scaffolding. This is what stops the
        # subject ending up the faintest part of its own figure.
        ramp.each_cons(2) do |(a, b)|
          (a - b).should be > 0.03, "#{name}: tiers collapsed or inverted (#{ramp})"
        end
        # …and the quietest tier still has to be visible at all. `Theme.border` fails this on the
        # default dark theme (rgb 42 on a rgb 10 canvas), which is why the scaffolding is a blend
        # of the accent rather than that slot.
        ramp.last.should be > 0.15, "#{name}: scaffolding is invisible on the canvas"
        # Ink is bold, scaffolding is not: most of what separates the two by eye at a glance.
        solid_attr.should eq(Attribute::Bold)
        scaffold_attr.should eq(Attribute::None)
      end
    ensure
      Theme.apply(before)
    end
  end

  it "centres the inked figure, not its leading indentation" do
    EmptyArt::CATALOG.each do |variant, block|
      x = EmptyArt.origin_x(block, 0, 100)
      # The ink spans [x + left, x + left + ink_w); that span is what must be centred in 100.
      lead = x + block.left
      trail = 100 - (lead + block.ink_w)
      (lead - trail).abs.should be <= 1, "#{variant} ink is off-centre (#{lead} vs #{trail})"
    end
  end

  # A figure that never paints is the failure mode this whole change exists to avoid, so pin it
  # END TO END at the size the app really hands a renderer: 16 rows is an 80x24's framed body
  # with no sub-tab strip.
  it "paints every figure above its card at a realistic body size" do
    EXPECTED_ART.each do |variant|
      block = EmptyArt.for(variant).not_nil!
      b = MemoryBackend.new(100, 16)
      TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, 16),
        variant: variant, listen: {"127.0.0.1", 8080})
      widest = block.lines.max_by(&.rstrip.size)
      b.contains?(painted(widest).strip).should be_true,
        "#{variant}: the figure did not paint at 100x16"
    end
  end

  # The other half: the figure is the FIRST thing dropped on a short pane and the card the last,
  # because the card is the part that says how to start. Without this assertion a gate that never
  # admits art — or one that always does and overflows — passes the example above either way.
  it "drops the figure before the card on a pane too short for both" do
    b = MemoryBackend.new(100, 12)
    TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, 12),
      variant: :history, listen: {"127.0.0.1", 8080})
    b.contains?("FLOW LOG").should be_true                                 # the card is still there…
    b.contains?(painted(EmptyArt::HISTORY.lines[1]).strip).should be_false # …the figure is not
  end
end
