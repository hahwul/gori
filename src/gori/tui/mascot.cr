require "./screen"
require "./theme"

module Gori::Tui
  # Miss Ring's art: a 3-row x 8-column gilded hoop with a lashed cartoon face in it.
  # Motif is Loki's Miss Minutes (huge eyes, lashes) crossed with Claude's mascot (soft
  # rounded forms, minimal face); the SHAPE is the gori mark itself — a ring — painted in
  # the live palette's brand gold.
  #
  # Pure and stateless: art tables, an ink (role) layer, a palette resolver and a draw
  # loop. Everything about WHEN she moves lives in Companion; everything about HOW she looks
  # lives here.
  #
  # WHY THE SILHOUETTE IS ROUND AND NOT OVAL. A terminal row is about twice as tall as a
  # cell is wide, so three rows buy six units of height — and to read as a circle rather
  # than an oval the equator has to be six CELLS across, not seven. Half-block walls put
  # it exactly there, and the crown then tapers half a cell per step:
  #
  #       col:  0    1   2 3 4   5    6    7
  #   row 0:   ' '   ▄   ▀ ▀ ▀   ▄   ' '  badge
  #   row 1:    ▐   <-- face 5 -->    ▌   ' '
  #   row 2:   ' '   ▀   ▄ ▄ ▄   ▀   ' '  ' '
  #
  #   equator  ▐ x[0.5,1] .. ▌ x[6,6.5]        = 6.0 cells
  #   y 0.5-1  ▄ at col 1 and col 5            = 5.0 cells
  #   y 0-0.5  ▀ at cols 2..4                  = 3.0 cells
  #
  # A circle of diameter six wants 6 / 5.2 / 3.3 at those bands, so the profile lands on
  # it. Every step is half a cell, which is what keeps the arc smooth instead of notched.
  #
  # THE COST IS THE ARMS. A half-block wall starts at x=0.5, but a `╺` stub in the column
  # to its left ends at x=1.0 of that column — half a cell short. Nothing can bridge it
  # without making the wall a full block, which would push the equator back to seven cells
  # and lose the circle. So she has no arms, and the badge column carries mood instead.
  module Mascot
    W = 8
    H = 3

    # Cols 0..6 of the top and bottom rows; col 7 is the mood badge (row 0 only).
    #
    # Char tuples, not Strings: she is drawn on EVERY frame the Runner paints, and
    # String#[](Int) walks the codepoints on non-ASCII text — indexing these per cell
    # would make the hot path scale with the art's byte length for no reason.
    CROWN  = {' ', '▄', '▀', '▀', '▀', '▄', ' '}
    FLOOR  = {' ', '▀', '▄', '▄', '▄', '▀', ' '}
    WALL_L = '▐'
    WALL_R = '▌'

    # She is a MISS, so she has lashes. These are thin strokes, not blocks, and both sit at
    # cap height while the pupil sits mid-cell, so they float at the upper corner of each eye.
    #
    # THE SLANTS POINT INWARD, and that is the whole expression. ´ rises to the right and `
    # rises to the left, so putting ´ on the left and ` on the right raises both brows toward
    # the middle — the soft, open look. Swap them and the high ends point outward instead,
    # which drops the inner brow and reads as stern. Same two glyphs, opposite character.
    LASH_L = '´' # U+00B4 ACUTE ACCENT — rises to the right, so it lifts the inner brow
    LASH_R = '`' # U+0060 GRAVE ACCENT — rises to the left, mirroring it

    # …which makes the PAIRING an expression axis of its own, and the cheapest one she has:
    # four leanings out of two glyphs she already wears, with no new coverage risk and no
    # new cell claimed. The eyes say what she is doing; the brows say how she feels about
    # it, which is why ●_● and ●_● with the brows turned over read as "deadpan" and
    # "unimpressed" rather than as the same face twice.
    #
    # DERIVED FROM THE POSE, never carried on Frame. A brow field would be the third member
    # of the folded-field class the `wink` and `shake` comments describe: Mascot.cavity is
    # the only thing that reads these, so anything it did not honour would be a Frame that
    # compares unequal to its neighbour and paints identical cells. Deriving them here
    # leaves nothing to fold.
    #
    # The ink layer needs no change either — row 1 is "HlemelS.", so both brow cells are
    # already role 'l' whichever way they lean.
    def self.brows(pose : Symbol) : {Char, Char}
      case pose
      when :error, :pout then {LASH_R, LASH_L} # both inner ends DOWN — furrowed
      when :wonder, :hmm then {LASH_L, LASH_L} # ´ on the right drops that brow alone …
      when :wry          then {LASH_R, LASH_R} # … and ` on the left drops the other one
      else                    {LASH_L, LASH_R} # soft and open — the resting pair
      end
    end

    # The centre cell of the cavity: a small mouth between the eyes.
    #
    # EVERY MOUTH HAS TO SIT AT OR BELOW MID-CELL. A combining-style diacritic is drawn at
    # cap height, which is exactly where the lashes are — so ˘ (U+02D8), the obvious cup
    # shape, put the mouth ABOVE the eyes and level with the lashes.
    #
    # ᴗ (U+1D17 BOTTOM HALF O) is the same cup at the right height, and rounder. It was
    # tried and dropped, so: it is NOT a width problem — the terminal owns the grid, a
    # fallback glyph is drawn INTO the cell, and the advance comes from East Asian Width,
    # where ᴗ is Neutral. Measured in a real terminal, ▐´●ᴗ●`▌ is the same 7 cells as the
    # spelling below, and 30 of them fill 30 columns of a 40-column pane without wrapping.
    # It is a COVERAGE problem: most monospace cmaps lack it, so it renders through a
    # proportional fallback face, and an environment with no fallback pool at all draws a
    # box. u is the same cup at the same x-height and is in every monospace font, which is
    # why the mouth is spelled with it and there is no setting to change that.
    #
    # n is the ONE addition to that set and it costs nothing the argument above forbids: it
    # is u turned over, the same letterform in the same x-height band, in the same fonts.
    # The cup opening downward is the frown, and it is the only mouth shape the four
    # existing ones cannot approximate.
    #
    # CAP_HEIGHT_MARKS is what a spec checks the mouth against — it may never be one.
    CAP_HEIGHT_MARKS = {'˘', '¯', '^', '´', '`', '¨', '˙', '˚', '˜', '‾'}
    MOUTHS           = {'u', 'o', '_', '·', 'n'}

    def self.mouth(pose : Symbol) : Char
      case pose
      when :happy  then 'o' # delighted, open — x-height
      when :alert  then '_' # tense, flat — baseline
      when :error  then '_'
      when :doze   then '·' # slack — mid
      when :oh     then 'o' # the yawn winding up, and a small "oh" on its own
      when :yawn   then 'o'
      when :smile  then 'u' # the resting cup, under crinkled-shut eyes
      when :squint then 'u'
      when :flat   then '_' # deadpan: the tense mouth on an unbothered face
      when :wonder then 'o' # the curious "oh?", told apart from :oh by the cocked brow
      when :wry    then 'u' # the resting cup under one crinkled eye — a half-smile
      when :hmm    then '_' # weighing it up
      when :pout   then 'n' # the cup turned over — the sulk
      else              'u' # the resting smile — a cup below the eyes
      end
    end

    # Every pose. Two families, and the split matters: the first six are REACTIONS (what
    # mood she is in, chosen by Companion#pose_for), the rest are IDLE GESTURES she plays
    # unprompted (Companion::GESTURES) — plus the quieter cousins a reaction SETTLES into,
    # which belong to both families at once (:smile, :hmm, :flat).
    #
    # Still a table that has to be earned: a new entry needs a face no other pose already
    # wears, and it is only a face if the three cavity glyphs plus the brows differ, since
    # that is the whole of what a pose can change. A spec sweeps exactly that.
    POSES = {:idle, :blink, :happy, :alert, :error, :doze,
             :oh, :yawn, :smile, :squint, :flat,
             :wonder, :wry, :hmm, :pout}
    WINKS = {:none, :left, :right}

    # Ink roles, one char per art cell, parallel to the assembled art rows:
    #   H hoop highlight (lit, upper-left)   R hoop base (brand gold)
    #   S hoop shadow (turned away)          C corner, dimmed toward the plate
    #   e pupil, in the hole                 l lash, in the hole
    #   m mouth, in the hole                 o the hole itself
    #   X mood badge                         . plate
    #
    # THE INTERIOR IS A HOLE, not a face plate. Filling the five cavity cells with a light
    # colour laid a bright horizontal bar straight through the middle of a three-row
    # sprite, and the eye read that bar before it read the ring — the single thing most
    # responsible for the hoop not looking round. Dropping the interior to the plate lets
    # the terminal show through the way a real ring's hole does, and leaves the silhouette
    # as the only thing to look at.
    #
    # THE CORNERS ARE DIMMED. A terminal cannot anti-alias, but a corner cell held at a
    # mid-tone between the band and the plate reads as a partly-covered pixel, which
    # softens the stair-step where the arc turns.
    #
    # ONE grid for every pose: poses only ever change cells inside the hole, so adding an
    # expression never means restating the hoop's shading. The light source is fixed
    # upper-left — hence H then RR across the crown, H on the left wall, S on the right.
    # The centre cell is 'm', NOT 'o'. It holds the mouth glyph, and the hole role paints
    # plate-on-plate — so typing it as a hole drew the mouth in the background colour and
    # made it invisible. A tmux capture cannot catch that: capture-pane returns the
    # character buffer regardless of what colour it was painted in.
    INK = {
      ".CHRRC.X",
      "HlemelS.",
      ".CSSSC..",
    }

    # Where the specular walks during a glint sweep — up the left wall and across the
    # crown. Indices into this are what Frame#glint holds; -1 is "no specular".
    GLINT_PATH = { {0, 1}, {1, 0}, {2, 0}, {3, 0}, {4, 0} }

    # EVERYTHING drawn on one frame — the sprite and the speech bubble both, so Companion#tick
    # can answer "did the drawn thing change" with a single field-wise compare instead of
    # re-deriving anything. Mascot.draw consumes the sprite fields; Companion.draw adds the
    # bubble and the shake offset around it.
    record Frame,
      pose : Symbol = :idle,
      wink : Symbol = :none,
      badge : Char? = nil,
      glint : Int32 = -1, # index into GLINT_PATH; -1 = no specular this frame
      mood : Symbol = :info,
      bubble : String? = nil,
      shake : Int32 = 0 # -1 | 0 | 1 column offset (the :error reaction)

    # Every colour the mascot can wear, resolved once per draw from the live theme and
    # the current mood.
    record Palette,
      ring : Color, hi : Color, lo : Color, glint : Color,
      corner : Color, eye : Color, lash : Color, mouth : Color,
      badge : Color, plate : Color

    # SPELL OUT EVERY POSE, including the ones that land on the `else` value anyway. A pose
    # missing an arm here falls through to the open idle eyes and — paired with an idle
    # mouth — renders as a pose that never visibly happened, which nothing about the code
    # or a tmux capture flags. Same for .mouth above.
    def self.eyes(pose : Symbol) : {Char, Char}
      case pose
      when :blink  then {'─', '─'}
      when :happy  then {'^', '^'}
      when :alert  then {'O', 'O'}
      when :error  then {'×', '×'} # the ✘_✘ read, with a glyph every face actually has
      when :doze   then {'~', '~'}
      when :yawn   then {'─', '─'} # squeezed shut mid-yawn
      when :smile  then {'^', '^'} # crinkled — :happy's eyes over the resting mouth
      when :squint then {'·', '·'} # pupils down to a dot, peering at something
      when :oh     then {'●', '●'} # open, over an open mouth
      when :flat   then {'●', '●'} # open, over a flat mouth — deadpan
      when :wonder then {'●', '●'} # :oh's eyes; the cocked brow is what makes it a question
      when :wry    then {'^', '●'} # ONE eye crinkled — the asymmetry is the whole joke
      when :hmm    then {'·', '●'} # one pupil narrowed, weighing something up
      when :pout   then {'●', '●'} # open and unimpressed, under furrowed brows
      else              {'●', '●'} # :idle
      end
    end

    # Cols 1..5 of the middle row: lash, left eye, mouth, right eye, lash. Named for the
    # hole it fills, which is what the ink layer calls it too.
    #
    # THE WHOLE OF A POSE IS THESE FIVE CELLS — brows, eyes and mouth — which is also why
    # every idle gesture is expressed here and not in the badge or the glint: `placement =
    # bar` paints this row alone (Mascot.draw_row), so anything said elsewhere is mute for
    # everyone running the chip.
    #
    # A wink only applies to the open-eyed idle pose — a winking :alert or :doze would
    # read as a rendering glitch rather than a gesture.
    def self.cavity(pose : Symbol, wink : Symbol) : {Char, Char, Char, Char, Char}
      l, r = eyes(pose)
      if pose == :idle
        l = '─' if wink == :left
        r = '─' if wink == :right
      end
      bl, br = brows(pose)
      {bl, l, mouth(pose), r, br}
    end

    # The glyph at (col, row) of the 8x3 grid. Allocation-free — this is what the draw
    # loop reads, so a frame costs no String building at all.
    def self.glyph(frame : Frame, col : Int32, row : Int32) : Char
      case row
      when 0 then col == W - 1 ? (frame.badge || ' ') : CROWN[col]
      when 2 then col == W - 1 ? ' ' : FLOOR[col]
      else
        case col
        when 0     then WALL_L
        when 6     then WALL_R
        when W - 1 then ' '
        else            cavity(frame.pose, frame.wink)[col - 1]
        end
      end
    end

    # The three assembled art rows. Each is exactly W single-codepoint, single-column
    # glyphs (spec-guarded over every pose x wink). Convenience for specs and debugging;
    # the draw path uses `glyph` directly and never builds these.
    def self.rows(frame : Frame) : {String, String, String}
      build = ->(row : Int32) {
        String.build { |io| W.times { |col| io << glyph(frame, col, row) } }
      }
      {build.call(0), build.call(1), build.call(2)}
    end

    # Mood only shifts the base gold; the whole ramp — highlight, shadow, specular, face,
    # lash — re-derives from it. One hue swap re-tints the entire sprite and she never
    # stops reading as the brand mark.
    #
    # `plate` is the background she is stamped onto (the tab body's fill).
    #
    # MEMOISED on (theme revision, mood, plate). She is drawn on every frame but her mood
    # changes a few times a minute at most, so resolving the ramp — two luma poles and
    # several blends, each converting colours to RGB components — per frame was pure
    # waste. Theme.revision is the same invalidation signal the other colour-baking caches
    # use, so a theme swap re-derives on the next access.
    @@cache_key : {UInt32, Symbol, Color}? = nil
    @@cached : Palette? = nil

    def self.palette(mood : Symbol, plate : Color) : Palette
      key = {Theme.revision, mood, plate}
      if (hit = @@cached) && @@cache_key == key
        return hit
      end
      pal = build_palette(mood, plate)
      @@cache_key = key
      @@cached = pal
      pal
    end

    private def self.build_palette(mood : Symbol, plate : Color) : Palette
      gold = case mood
             when :happy then Theme.blend(Theme.focus_gold, Theme.green, 0.30)
             when :warn  then Theme.blend(Theme.focus_gold, Theme.yellow, 0.55)
             when :alarm then Theme.blend(Theme.focus_gold, Theme.red, 0.45)
             when :doze  then Theme.blend(Theme.focus_gold, plate, 0.45) # dimmed, asleep
             else             Theme.focus_gold
             end
      # Shade toward soot and light toward paper, NOT toward Theme.bg: "blend toward bg"
      # darkens on GORIDARK and lightens on GORIDAY, so a shadow defined that way inverts
      # on every light palette. See Theme.paper/soot.
      paper, soot = Theme.paper, Theme.soot
      # The pole that CONTRASTS with the plate she is stamped on — paper on a dark palette,
      # soot on a light one. The pupils and lashes sit in the HOLE, directly on that plate,
      # so pushing the gold toward this pole is what keeps them legible on both: "make them
      # brighter" is only the right answer on half the themes.
      pole = Theme.luma(plate) > 0.5 ? soot : paper
      Palette.new(
        ring: gold,
        hi: Theme.blend(gold, paper, 0.60),
        lo: Theme.blend(gold, soot, 0.62),
        glint: Theme.blend(gold, paper, 0.18),
        # Halfway to the plate: a partly-covered pixel, so the arc's stair-step softens.
        corner: Theme.blend(gold, plate, 0.55),
        eye: Theme.blend(gold, pole, 0.45),   # mostly the contrasting pole — reads as a pupil
        mouth: Theme.blend(gold, pole, 0.55), # between the pupil and the lash
        lash: Theme.blend(gold, pole, 0.70),  # closer to the band, so it stays a hint
        badge: badge_color(mood),
        plate: plate,
      )
    end

    private def self.badge_color(mood : Symbol) : Color
      case mood
      when :alarm then Theme.red
      when :warn  then Theme.yellow
      when :happy then Theme.green
      else             Theme.focus_gold
      end
    end

    # Public because the spec asserts the one property this table can silently violate: an
    # inked cell whose fg equals its bg is drawn and invisible.
    def self.role_style(role : Char, pal : Palette) : {Color, Color, Attribute}
      case role
      when 'H' then {pal.hi, pal.plate, Attribute::Bold}
      when 'R' then {pal.ring, pal.plate, Attribute::Bold}
      when 'S' then {pal.lo, pal.plate, Attribute::Bold}
      when 'C' then {pal.corner, pal.plate, Attribute::Bold}
      when 'X' then {pal.badge, pal.plate, Attribute::Bold}
      when 'e' then {pal.eye, pal.plate, Attribute::Bold}
      when 'm' then {pal.mouth, pal.plate, Attribute::Bold}
      when 'l' then {pal.lash, pal.plate, Attribute::Bold}
      else          {pal.plate, pal.plate, Attribute::None} # 'o' hole and '.' plate alike
      end
    end

    # The one-row form, for the status bar: columns 0..6 of the middle row — the hoop's
    # equator with the whole face still in it. Deliberately NOT a second art table; it is a
    # slice of the same sprite, so the two placements cannot drift apart.
    BAR_W = 7

    def self.bar_label(frame : Frame) : String
      String.build { |io| BAR_W.times { |c| io << glyph(frame, c, 1) } }
    end

    def self.draw_row(screen : Screen, x : Int32, y : Int32, frame : Frame, pal : Palette) : Nil
      BAR_W.times do |col|
        fg, bg, attr = role_style(INK[1][col], pal)
        screen.cell(x + col, y, glyph(frame, col, 1), fg, bg, attr)
      end
    end

    # Paint the sprite with col 0 at `x`.
    #
    # The plate and hole roles still write an OPAQUE background space rather than skipping
    # the cell: the companion occludes body content, so the whole box has to be claimed or the
    # tab's text bleeds through the hole and the hoop's corners. The hole reads as a hole
    # because it is painted the plate colour, not because it is left unpainted. On a still
    # beat the diff renderer forwards none of it.
    def self.draw(screen : Screen, x : Int32, y : Int32, frame : Frame, pal : Palette) : Nil
      gx, gy = frame.glint >= 0 ? (GLINT_PATH[frame.glint]? || {-1, -1}) : {-1, -1}
      H.times do |ry|
        ink = INK[ry]
        W.times do |col|
          role = ink[col]
          fg, bg, attr = role_style(role, pal)
          # The specular overrides one hoop cell — polished metal turning under a light.
          fg = pal.glint if col == gx && ry == gy && role.in?('H', 'R', 'S')
          screen.cell(x + col, y + ry, glyph(frame, col, ry), fg, bg, attr)
        end
      end
    end
  end
end
