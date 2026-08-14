require "./screen"
require "./theme"

module Gori::Tui
  # The figures that ride above a `TrafficEmptyState` card — one per variant, each saying
  # what the tab DOES in a shape rather than in another sentence. Deliberately separate
  # from `Brand`: that module is the gori mark (project-picker hero + Help → About), and a
  # tab's figure has nothing to do with the product's logo. Editing `Brand::ART` to suit a
  # tab would silently redraw both of those surfaces.
  #
  # SIZE IS THE WHOLE DESIGN CONSTRAINT. `Layout.compute` gives a body of 18 rows on an
  # 80x24, the body frame takes 2 and a sub-tab strip 2 more, so a renderer has 14..16 rows
  # to spend. A card runs 6..15 of them. That leaves 3 rows for a figure if it is to appear
  # at all on the terminal most people run — which is why every block here is 3 rows except
  # the two CENTERED variants (`:notes`, `:project_desc`), whose cards are the shortest and
  # which spend no row on a headline, so they can afford 4 and 5. `Brand::ART` is 11 rows
  # and needed ~20: it was gated out of every realistic pane, which is what made the art on
  # the Project tab read as missing rather than as opportunistic.
  #
  # Width is capped by the card, not by the pane: a card is 42..50 columns, so a figure
  # wider than ~34 stops reading as belonging to the card below it.
  #
  # Every glyph must measure exactly ONE cell (see spec/tui/empty_art_spec.cr). `draw`
  # places glyph N of a line at column N, so a width-2 glyph shears its row and pulls the
  # figure apart. That bans the geometric shapes (`◆ ► ●`) and `⏸` the cards use in their
  # TEXT lines — there `Screen.display_width` measures them, here nothing does. The safe
  # families are ASCII, Box Drawing (U+2500..257F) and Block Elements (U+2580..259F).
  module EmptyArt
    extend self

    # A figure plus the metrics every caller needs. All DERIVED from the literal, because
    # these get redrawn and a hardcoded row or column count stops matching without saying so
    # (the lesson `Brand`'s own constants record).
    struct Block
      getter lines : Array(String)
      getter h : Int32
      # Leftmost inked column, and the inked width from there. Centering uses these rather
      # than raw line lengths, so the VISIBLE shape is what centres over the card instead of
      # the figure's leading indentation.
      getter left : Int32
      getter ink_w : Int32
      # Narrowest pane width that still seats the figure: below it `origin_x` clamps to 0 and
      # the block's right edge runs off the pane.
      getter min_w : Int32

      def initialize(@lines : Array(String))
        @h = @lines.size
        @left = @lines.min_of { |line| line.size - line.lstrip.size }
        @ink_w = @lines.max_of(&.rstrip.size) - @left
        @min_w = @ink_w + 2 * @left
      end
    end

    # The three ink tiers, keyed by HOW MUCH OF THE CELL the glyph fills — so a figure reads
    # as subject-over-scaffolding rather than as one flat blob, and so a variant's author
    # picks a tier by drawing rather than by passing a colour.
    #
    #   █  the subject       — the proxy, the payload that landed, the token bit that moved
    #   ▓  secondary mass    — the traffic around it, the candidates that did not hit
    #   ▄▀ etc.              — detail strokes; always secondary
    #   ─│┌ and ASCII        — scaffolding: frames, wires, tree joints
    #
    # All three are the SAME hue sunk to different depths toward the canvas, so a figure reads
    # as one object rather than as blocks in one colour wired together in another — and, more
    # importantly, so the ordering holds BY CONSTRUCTION in every palette.
    #
    # Both alternatives for the scaffolding tier are wrong, each in its own theme:
    #   * `Theme.border` (rgb 42 on a rgb 10 canvas) is nearly invisible on the default dark
    #     theme — the frames dropped out and the figure read as blocks floating in space. A
    #     card's border can afford to be that quiet because it is a big rectangle; three cells
    #     of wire cannot.
    #   * `Theme.muted` is readable everywhere, but it is a palette slot with no relationship to
    #     this ramp: on `goriday` it carries MORE contrast than the mass above it, so the wires
    #     came out stronger than the subject they frame. spec/tui/empty_art_spec.cr sweeps every
    #     built-in theme, which is what caught that.
    #
    # `Theme.blend(hue, base, t)` returns `base + t * (hue - base)`, so contrast against the
    # canvas is proportional to `t` — a smaller value sinks the tier further into the
    # background, in any palette, light or dark.
    #
    # `▓` is REPAINTED as a full block in the dim colour rather than drawn literally, for the
    # same reason `Brand::FAR_RING` is: on a stroke one or two cells thick a dither pattern
    # reads as texture instead of as distance, and the pattern is font-dependent where a
    # blend of the palette's own colours is not.
    SOLID = '█'
    DIM   = '▓'
    # Mass, then scaffolding. Kept apart by enough that the two tiers never read as one; the
    # floor on the lower one is what keeps the wires visible at all.
    DIM_MIX      = 0.55
    SCAFFOLD_MIX = 0.34

    # Whether `ch` is a Block Elements glyph — the "ink" families, as opposed to the Box
    # Drawing and ASCII scaffolding.
    private def block?(ch : Char) : Bool
      ch.ord >= 0x2580 && ch.ord <= 0x259F
    end

    # What one art cell paints. Bold on the ink so it holds its weight against the frame;
    # the scaffolding stays plain, which is most of what separates the two by eye.
    def ink(ch : Char) : {Char, Color, Attribute}
      return {SOLID, dim_ink, Attribute::Bold} if ch == DIM
      return {ch, Theme.accent, Attribute::Bold} if ch == SOLID
      return {ch, dim_ink, Attribute::Bold} if block?(ch)
      {ch, scaffold_ink, Attribute::None}
    end

    def dim_ink : Color
      Theme.blend(Theme.accent, Theme.bg, DIM_MIX)
    end

    def scaffold_ink : Color
      Theme.blend(Theme.accent, Theme.bg, SCAFFOLD_MIX)
    end

    # ---------------------------------------------------------------------------
    # The catalog. One entry per TrafficEmptyState variant; a variant with no entry
    # simply gets no figure (`for` returns nil and the card renders as it always did).
    # ---------------------------------------------------------------------------

    # Client, proxy, origin — with the proxy lit, because the card's whole job is to hand
    # over the address of that middle box.
    HISTORY = Block.new([
      "┌────┐   ┌────┐   ┌────┐",
      "│ ▓▓ │══>│ ██ │══>│ ▓▓ │",
      "└────┘   └────┘   └────┘",
    ])

    # A host that branches into paths — the host → path tree the card describes, as the
    # shape it actually takes in the pane.
    SITEMAP = Block.new([
      "┌──────┐",
      "│ ████ ├──┬── ▓▓▓▓▓▓▓",
      "└──────┘  └── ▓▓▓▓",
    ])

    # Two messages stopped at a closed barrier, with nothing past it: the queue is the
    # point, and the dashes beyond the gate are the traffic that is NOT flowing.
    INTERCEPT = Block.new([
      "┌────┐ ┌────┐ ║",
      "│ ▓▓ │ │ ██ │ ║ ─ ─ ─",
      "└────┘ └────┘ ║",
    ])

    # Out and back: one request sent, one response to compare it against.
    REPEATER = Block.new([
      "┌────┐ ══>  ┌────┐",
      "│ ██ │      │ ▓▓ │",
      "└────┘ <══  └────┘",
    ])

    # A template whose two marked positions drop payloads out through the bottom edge —
    # the §marker§ substitution the card explains, drawn.
    FUZZER = Block.new([
      "┌────────────────┐",
      "│ ▓▓▓ ██ ▓▓ ██ ▓ │",
      "└─────██────██───┘",
    ])

    # A response-length histogram with the outlier lit: what a finished run looks like, and
    # what the operator is actually scanning for in it.
    FUZZER_RESULTS = Block.new([
      "▓▓▓  ██████████",
      "▓▓▓  ██████████████████",
      "███  ████████████████████████",
    ])

    # A window sliding along a stream — passive scanning reads what passes, it does not
    # send. The caught span is the lit one.
    PROBE = Block.new([
      "      ┌────┐",
      "▓▓▓▓▓▓│ ██ │▓▓▓▓▓▓",
      "      └────┘",
    ])

    # One triaged record with its severity bar — the unit of work on this tab.
    ISSUES = Block.new([
      "┌─┬──────────────────┐",
      "│█│ ▓▓▓▓▓▓▓▓▓▓▓▓     │",
      "└─┴──────────────────┘",
    ])

    # A torn-off sheet: a scratchpad, not a document. The tear is what tells it apart from
    # the Project dossier below, which is the same framed page with a title.
    NOTES = Block.new([
      "┌───────────────┐",
      "│ ▄▄▄▄▄  ▄▄▄▄   │",
      "│ ▄▄▄▄▄▄▄▄▄▄    │",
      "└╲╱╲╱╲╱╲╱╲╱╲╱╲╱╲┘",
    ])

    # The Project mark: a dossier with a title and a written body. NOT the gori logo — this
    # pane is "what is this engagement", and the brand mark answered a different question
    # (and at 11 rows never fit). The title line is the lit one because that is the thing
    # the empty pane is asking the operator to write first.
    PROJECT_DESC = Block.new([
      "┌───────────────┐",
      "│ ██████        │",
      "│ ▄▄▄▄▄  ▄▄▄▄▄  │",
      "│ ▄▄▄▄▄▄▄▄▄     │",
      "└───────────────┘",
    ])

    # A root fanning out into the endpoints a crawl turns up.
    DISCOVER = Block.new([
      "      ┌── ▓▓▓▓",
      "██ ───┼── ▓▓▓",
      "      └── ▓▓▓▓▓▓",
    ])

    # Two columns with one span differing — the answer this tab exists to give, so the
    # figure shows a diff rather than two identical halves.
    COMPARER = Block.new([
      "┌──────┬──────┐",
      "│ ▄▄▄▄ │ ██▄▄ │",
      "└──────┴──────┘",
    ])

    # A wordlist over a sieve, with the two names that got through lit below it. The slots
    # sit under the gaps on purpose: that alignment is what makes it read as filtering.
    MINER = Block.new([
      "▓▓ ▓▓ ▓▓ ▓▓ ▓▓ ▓▓",
      "──┬──┬──┬──┬──┬──",
      "   ██       ██",
    ])

    # One token split into cells, with the positions that vary between samples lit — which
    # is exactly what the analysis pane reports.
    SEQUENCER = Block.new([
      "┌──┬──┬──┬──┬──┬──┐",
      "│▓▓│██│▓▓│██│▓▓│▓▓│",
      "└──┴──┴──┴──┴──┴──┘",
    ])

    CATALOG = {
      :history        => HISTORY,
      :sitemap        => SITEMAP,
      :intercept      => INTERCEPT,
      :repeater       => REPEATER,
      :fuzzer         => FUZZER,
      :fuzzer_results => FUZZER_RESULTS,
      :probe          => PROBE,
      :issues         => ISSUES,
      :notes          => NOTES,
      :project_desc   => PROJECT_DESC,
      :discover       => DISCOVER,
      :comparer       => COMPARER,
      :miner          => MINER,
      :sequencer      => SEQUENCER,
    }

    # The figure for a variant, or nil when it has none — an unknown variant is not an
    # error, it just renders the card on its own.
    def for(variant : Symbol) : Block?
      CATALOG[variant]?
    end

    # Absolute column for glyph col 0 of each line (leading spaces included), so the INKED
    # figure centres within `width` starting at `x0`.
    def origin_x(block : Block, x0 : Int32, width : Int32) : Int32
      x0 + {(width - block.ink_w) // 2 - block.left, 0}.max
    end

    def draw(screen : Screen, block : Block, origin_x : Int32, y : Int32) : Nil
      block.lines.each_with_index do |line, i|
        line.each_char_with_index do |ch, col|
          next if ch == ' '
          glyph, colour, attr = ink(ch)
          screen.cell(origin_x + col, y + i, glyph, colour, Theme.bg, attr: attr)
        end
      end
    end
  end
end
