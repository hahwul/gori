require "./screen"
require "./theme"

module Gori::Tui
  # Miss Ring's art: a 3-row x 9-column gilded hoop with a lashed cartoon face in it.
  # Motif is Loki's Miss Minutes (huge eyes, stubby arms) crossed with Claude's mascot
  # (soft rounded forms, minimal face); the SHAPE is the gori mark itself — a ring —
  # painted in the live palette's brand gold.
  #
  # Pure and stateless: art tables, an ink (role) layer, a palette resolver and a draw
  # loop. Everything about WHEN she moves lives in Pet; everything about HOW she looks
  # lives here.
  #
  # WHY THE SILHOUETTE READS ROUND. A cell is 1 unit wide and 2 units tall, so a half
  # block is a square pixel and the hoop is drawn in half-pixels rather than characters:
  #
  #       col: 0    1     2 3 4 5 6     7    8
  #   row 0:   ' '  ▗     ▀ ▀ ▀ ▀ ▀     ▖   badge
  #   row 1:   ╺    █     <- face 5 ->  █    ╸
  #   row 2:   ' '  ▝     ▄ ▄ ▄ ▄ ▄     ▘   ' '
  #
  # Going up the left side the ink starts at x=1 (the full-block wall), then 1.5 (the ▗
  # quadrant), then 2 (the ▀ top edge) — a three-step arc, mirrored at every corner. The
  # hoop spans x∈[1,8] (7 cells) and y∈[0,3] (3 rows ≈ 6 cell-widths), i.e. a near-square
  # bounding box, and the wall (1 cell) and the top/bottom stroke (half a row ≈ 1 cell
  # width) are the same weight. That is what makes it a ring and not a rounded rectangle.
  #
  # The walls MUST be full blocks. With half-block walls (▐ / ▌) the ink stops at x=1.5
  # and the ╺ arm ends at x=1.0, leaving a half-cell gap that reads as a detached dash.
  module Mascot
    W = 9
    H = 3

    # Cols 1..7 of the top and bottom rows. Col 0 is the left arm slot, col 8 the right
    # arm (row 1) / mood badge (row 0).
    #
    # Char tuples, not Strings: she is drawn on EVERY frame the Runner paints, and
    # String#[](Int) walks the codepoints on non-ASCII text — indexing these per cell
    # would make the hot path scale with the art's byte length for no reason.
    RING_TOP = {'▗', '▀', '▀', '▀', '▀', '▀', '▖'}
    RING_BOT = {'▝', '▄', '▄', '▄', '▄', '▄', '▘'}
    WALL     = '█'

    # She is a MISS, so she has lashes. These are thin strokes, not blocks, and both sit
    # at cap height while the pupil sits mid-cell — so they read as lashes floating at the
    # outer-upper corner of each eye. The slants are outward: ` is a \ (top end to the
    # left) beside the left eye, ´ is a / (top end to the right) beside the right eye.
    # Quadrant blocks (▘ ▝) would land in the same place but butt against the █ wall and
    # read as the wall thickening.
    LASH_L = '`' # U+0060
    LASH_R = '´' # U+00B4 ACUTE ACCENT

    # Every pose. FIVE, deliberately — expression variety comes from the independent
    # wink/arms/badge/glint axes below, not from growing this table. :error reuses the
    # :alert face and is told apart by its badge, its red-shifted gold and a shake.
    POSES = {:idle, :blink, :happy, :alert, :doze}
    WINKS = {:none, :left, :right}

    # Ink roles, one char per art cell, parallel to the assembled art rows:
    #   H hoop highlight (lit, upper-left)   R hoop base (brand gold)
    #   S hoop shadow (turned away)          A arm
    #   f face field (pupils)                L lash (mascara — warmer than the pupil)
    #   X mood badge                         . plate (background only)
    #
    # ONE grid for every pose: poses only ever change cells inside the face, and the face
    # is uniformly typed, so adding an expression never means restating the hoop's shading.
    # The light source is fixed upper-left — hence HHH then RRRR across the top, H on the
    # left wall, S on the right wall, and a single R of bounce light at the bottom-left.
    INK = {
      ".HHHRRRRX",
      "AHLfffLSA",
      ".RSSSSSS.",
    }

    # Where the specular walks during a glint sweep — up the left wall and across the
    # top. Indices into this are what Frame#glint holds; -1 is "no specular".
    GLINT_PATH = { {1, 1}, {1, 0}, {2, 0}, {3, 0}, {4, 0} }

    # EVERYTHING drawn on one frame — the sprite and the speech bubble both, so Pet#tick
    # can answer "did the drawn thing change" with a single field-wise compare instead of
    # re-deriving anything. Mascot.draw consumes the sprite fields; Pet.draw adds the
    # bubble and the shake offset around it.
    record Frame,
      pose : Symbol = :idle,
      wink : Symbol = :none,
      arms : Symbol = :rest, # :rest | :wave_a | :wave_b | :down
      badge : Char? = nil,
      glint : Int32 = -1, # index into GLINT_PATH; -1 = no specular this frame
      mood : Symbol = :info,
      bubble : String? = nil,
      shake : Int32 = 0 # -1 | 0 | 1 column offset (the :error reaction)

    # Every colour the mascot can wear, resolved once per draw from the live theme and
    # the current mood.
    record Palette,
      ring : Color, hi : Color, lo : Color, glint : Color,
      face : Color, ink : Color, lash : Color, arm : Color,
      badge : Color, plate : Color

    def self.eyes(pose : Symbol) : {Char, Char}
      case pose
      when :blink then {'─', '─'}
      when :happy then {'^', '^'}
      when :alert then {'O', 'O'}
      when :doze  then {'~', '~'}
      else             {'●', '●'} # :idle
      end
    end

    # Cols 2..6: lash, left eye, gap, right eye, lash.
    #
    # A wink only applies to the open-eyed idle face — a winking :alert or :doze would
    # read as a rendering glitch rather than a gesture.
    def self.face(pose : Symbol, wink : Symbol) : {Char, Char, Char, Char, Char}
      l, r = eyes(pose)
      if pose == :idle
        l = '─' if wink == :left
        r = '─' if wink == :right
      end
      {LASH_L, l, ' ', r, LASH_R}
    end

    # ASCII / and \ rather than the box-drawing ╱ ╲: at this size they read identically
    # and they are the only glyphs in the sheet that would have thin font coverage.
    def self.arms(kind : Symbol) : {Char, Char}
      case kind
      when :down   then {' ', ' '} # asleep — the arms hang
      when :wave_a then {'╺', '/'}
      when :wave_b then {'╺', '\\'}
      else              {'╺', '╸'}
      end
    end

    # The glyph at (col, row) of the 9x3 grid. Allocation-free — this is what the draw
    # loop reads, so a frame costs no String building at all.
    def self.glyph(frame : Frame, col : Int32, row : Int32) : Char
      case row
      when 0
        return frame.badge || ' ' if col == 8
        col == 0 ? ' ' : RING_TOP[col - 1]
      when 2
        col == 0 || col == 8 ? ' ' : RING_BOT[col - 1]
      else
        al, ar = arms(frame.arms)
        case col
        when 0    then al
        when 1, 7 then WALL
        when 8    then ar
        else           face(frame.pose, frame.wink)[col - 2]
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
    # seven blends, each converting colours to RGB components — per frame was pure waste.
    # Theme.revision is the same invalidation signal the other colour-baking caches use, so
    # a theme swap re-derives on the next access.
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
      # Cartoon-eye rule: the face plate always sits on the light pole so the pupils read
      # dark-on-light; ink_on then guarantees contrast even on a custom focus_gold.
      face = Theme.blend(gold, paper, 0.38)
      ink = Theme.ink_on(face)
      Palette.new(
        ring: gold,
        hi: Theme.blend(gold, paper, 0.60),
        lo: Theme.blend(gold, soot, 0.62),
        glint: Theme.blend(gold, paper, 0.18),
        face: face,
        ink: ink,
        lash: Theme.blend(gold, ink, 0.25), # mostly ink, warmed toward the gold
        arm: Theme.blend(gold, soot, 0.72),
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

    private def self.role_style(role : Char, pal : Palette) : {Color, Color, Attribute}
      case role
      when 'H' then {pal.hi, pal.plate, Attribute::Bold}
      when 'R' then {pal.ring, pal.plate, Attribute::Bold}
      when 'S' then {pal.lo, pal.plate, Attribute::Bold}
      when 'A' then {pal.arm, pal.plate, Attribute::Bold}
      when 'X' then {pal.badge, pal.plate, Attribute::Bold}
      when 'L' then {pal.lash, pal.face, Attribute::Bold}
      when 'f' then {pal.ink, pal.face, Attribute::Bold}
      else          {pal.plate, pal.plate, Attribute::None}
      end
    end

    # Paint the sprite with col 0 at `x`.
    #
    # The '.' plate role still writes an opaque background space: the pet OCCLUDES body
    # content, so the whole box must be claimed or the tab's text bleeds through the
    # hoop's corners. On a still beat the diff renderer forwards none of it.
    #
    # `arms: false` is the narrow-terminal fallback — it drops cols 0 and 8, which also
    # drops the mood badge; mood is then carried by the gold's hue shift and the pose
    # alone. The caller positions x for the full 9-column grid either way.
    def self.draw(screen : Screen, x : Int32, y : Int32, frame : Frame, pal : Palette,
                  *, arms : Bool = true) : Nil
      lo = arms ? 0 : 1
      hi = arms ? W - 1 : W - 2
      gx, gy = frame.glint >= 0 ? (GLINT_PATH[frame.glint]? || {-1, -1}) : {-1, -1}
      H.times do |ry|
        ink = INK[ry]
        (lo..hi).each do |col|
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
