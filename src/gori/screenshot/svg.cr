require "./frame"
require "./chrome"

module Gori::Screenshot
  # The frame as a self-contained SVG: a grid-aligned picture of a real terminal frame, with
  # no external assets and no embedded font.
  #
  # A PORT of `docs/tools/tui-capture/ansi2svg.py`, which rendered every terminal screenshot
  # in gori's docs before this existed, and which the goldens in
  # `spec/support/ansi_fixtures.cr` hold this to byte for byte. The numeric formats below
  # (`%.0f` for the width/height attributes, `%.1f` for the viewBox and the chrome, `%.2f`
  # for cell geometry) are part of that contract, not a style choice: change one and a docs
  # rebuild produces a diff on every screenshot in the tree.
  #
  # Every cell is placed on an exact monospace grid with `textLength` + `lengthAdjust`, so the
  # picture aligns whatever monospace face the reader actually has. That is why a run carries
  # its own width rather than trusting advance widths.
  #
  # FOUR deliberate differences from the reference, each with a spec:
  #
  #   1. A WIDE glyph advances two columns. The python counted characters, so a CJK run's
  #      `textLength` was one cell per character and the run was squeezed to half its width.
  #      Here a continuation column contributes a column to `textLength` and no text.
  #   2. The attribute bits below bold are rendered (`Dim` → opacity, `Cursive` → italic,
  #      `Underline`/`Strikethrough` → `text-decoration`, `Hidden` → the background run
  #      without its text). The python only knew bold. `Blink` is deliberately ignored —
  #      SVG has no honest spelling for it, and it must not split a run either.
  #   3. A row of SPACES over a background band is content, not a blank row to trim (see
  #      `Frame#blank_row?`). The python trimmed on the glyphs alone and would cut a painted
  #      statusline off the bottom of a capture.
  #   4. `"` and `'` are left alone in text CONTENT, where they are legal. The python used
  #      one escaper for content and attributes and so wrote `&quot;` inside a `<text>`
  #      element; JSON on screen is the common case, and both spellings render the same.
  #
  # And one thing this renderer does NOT do that the python did: recompute the column count
  # over a `--tail` slice. A `Frame` carries its column count, and a strip keeps the frame's
  # — so a strip of a half-painted row is padded out to the pane's width rather than cropped
  # to its content. Same reason `Frame#tail` keeps the canvas colour: a strip is part of that
  # screen, not a screen of its own.
  module Svg
    # A cell is 0.60 em wide and 1.20 em tall, and its baseline sits 0.76 of a row down.
    # Not derived from font metrics on purpose: `lengthAdjust="spacingAndGlyphs"` makes the
    # glyphs fit the box, so the box is what has to be stable across readers.
    CELL_W_RATIO   = 0.60
    ROW_H_RATIO    = 1.20
    BASELINE_RATIO = 0.76
    TITLE_BAR_H    = 34.0

    # The attributes that decide whether two neighbouring cells are ONE text run. `Blink` is
    # absent because nothing renders it: including it would split a run into two identical
    # `<text>` elements.
    STYLE_MASK = Termisu::Attribute::Bold | Termisu::Attribute::Dim |
                 Termisu::Attribute::Cursive | Termisu::Attribute::Underline |
                 Termisu::Attribute::Strikethrough | Termisu::Attribute::Hidden

    # The derived measurements of one render, computed once so every emitter agrees.
    record Geometry, cw : Float64, ch : Float64, w : Float64, h : Float64,
      pad : Float64, font_size : Float64, titleh : Float64, nrows : Int32 do
      # The top of row 0 — below the padding, and below the title bar when there is one.
      def y0 : Float64
        pad + titleh
      end
    end

    extend self

    # `frame` as an SVG document.
    #
    # `tail` renders only the last N rows WITH NO WINDOW CHROME — a strip of the screen, for
    # a statusline or a single row. The trailing blank rows are trimmed before the slice is
    # taken (see `Frame#tail`), because a pane is captured at its full height and slicing
    # first would hand back N rows of padding.
    #
    # `aria` is the SPOKEN label. It is separate from `title` because a decorative title says
    # nothing to a screen reader: gori's own wordmark is Mathematical Bold Script, which a
    # reader spells out one codepoint at a time.
    def render(frame : Frame, *, title : String? = frame.title, aria : String? = nil,
               font_size : Float64 = 15.0, pad : Float64 = 18.0, tail : Int32? = nil) : String
      f = tail ? frame.tail(tail) : frame
      bar = tail ? nil : title
      nrows = f.last_content_row + 1
      titleh = bar ? TITLE_BAR_H : 0.0
      cw = font_size * CELL_W_RATIO
      ch = font_size * ROW_H_RATIO
      geo = Geometry.new(cw: cw, ch: ch,
        w: f.cols * cw + pad * 2, h: nrows * ch + pad * 2 + titleh,
        pad: pad, font_size: font_size, titleh: titleh, nrows: nrows)

      String.build do |io|
        emit_root(io, f, geo, aria || title)
        emit_outer(io, f, geo)
        emit_chrome(io, f, geo, bar) if bar
        # Every background rect BEFORE every text run, across ALL rows: SVG paints in
        # document order, so a rect emitted after a run would cover the text of the row above.
        emit_bg_runs(io, f, geo)
        emit_text_runs(io, f, geo)
        io << "</svg>"
      end
    end

    # The root element, its metadata, and the body font stack every text run inherits.
    #
    # `data-theme` / `data-cols` / `data-rows` are gori's own, past the reference renderer's
    # output: a docs build (or a bug report) can then tell which theme and what geometry a
    # picture was taken at without parsing the grid back out. `data-rows` counts the rows
    # DRAWN, after the trim and any tail slice. `data-sanitized` appears only when the frame
    # went through `Screenshot::Mask` — its absence means "never masked", which is a
    # different claim from `data-sanitized="0"` ("masked, and nothing matched").
    #
    # `data-unmaskable` is the rest of that sentence, and appears only when there is one to
    # tell: rules the profile carries that no frame can be asked for (its JSON pointers — see
    # `Screenshot::Mask`). Absent is the ordinary case, "every rule reached this picture".
    private def emit_root(io : IO, f : Frame, geo : Geometry, aria : String?) : Nil
      spoken = quote(aria || "gori terminal screenshot")
      io << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{f0(geo.w)}") \
            %( height="#{f0(geo.h)}" viewBox="0 0 #{f1(geo.w)} #{f1(geo.h)}") \
            %( font-family="#{Chrome::BODY_FONTS}" font-size="#{f1(geo.font_size)}px") \
            %( role="img" aria-label="#{spoken}") \
            %( data-theme="#{quote(f.theme)}" data-cols="#{f.cols}" data-rows="#{geo.nrows}")
      io << %( data-sanitized="#{f.sanitized}") if f.sanitized
      io << %( data-unmaskable="#{f.unmaskable}") if f.unmaskable > 0
      io << ">\n"
    end

    # The rounded window itself: the canvas, hairlined. Inset by half a pixel so the 1px
    # stroke lands ON the pixel grid instead of straddling it.
    private def emit_outer(io : IO, f : Frame, geo : Geometry) : Nil
      io << %(<rect x="0.5" y="0.5" width="#{f1(geo.w - 1)}" height="#{f1(geo.h - 1)}") \
            %( rx="10" ry="10" fill="#{f.bg.to_hex}") \
            %( stroke="#{Chrome.border(f.bg).to_hex}" stroke-width="1"/>\n)
    end

    # The slim window chrome: the title bar, the three lights, the title.
    #
    # TWO rects, not one: the bar is drawn with the window's own corner radius so its top
    # corners round, and the second rect squares the bottom 10px back off — otherwise the
    # bar's lower corners curve away from the body it sits on.
    private def emit_chrome(io : IO, f : Frame, geo : Geometry, title : String) : Nil
      bar = Chrome.chrome_bg(f.bg).to_hex
      io << %(<rect x="1" y="1" width="#{f1(geo.w - 2)}" height="#{f1(geo.titleh)}") \
            %( rx="10" ry="10" fill="#{bar}"/>\n) \
            %(<rect x="1" y="#{f1(geo.titleh - 10)}" width="#{f1(geo.w - 2)}") \
            %( height="10" fill="#{bar}"/>\n)
      Chrome::LIGHTS.each_with_index do |color, k|
        io << %(<circle cx="#{f1(geo.pad + k * 16)}" cy="#{f1(geo.titleh / 2)}") \
              %( r="5.5" fill="#{color}"/>\n)
      end
      io << %(<text x="#{f1(geo.w / 2)}" y="#{f1(geo.titleh / 2 + 5)}") \
            %( text-anchor="middle" fill="#{Chrome.label(f.bg).to_hex}") \
            %( font-family="#{Chrome::TITLE_FONTS}") \
            %( font-size="#{f1(geo.font_size * 0.82)}px">#{escape(title)}</text>\n)
    end

    # One rect per maximal run of cells sharing a background that is NOT the canvas. The
    # canvas is already painted by the outer rect, so emitting runs of it would add several
    # thousand redundant rects to a full-screen capture.
    private def emit_bg_runs(io : IO, f : Frame, geo : Geometry) : Nil
      geo.nrows.times do |y|
        yb = geo.y0 + y * geo.ch
        x = 0
        while x < f.cols
          bg = f.at(x, y).bg
          if bg == f.bg
            x += 1
            next
          end
          stop = x + 1
          while stop < f.cols && f.at(stop, y).bg == bg
            stop += 1
          end
          io << %(<rect x="#{f2(geo.pad + x * geo.cw)}" y="#{f2(yb)}") \
                %( width="#{f2((stop - x) * geo.cw)}" height="#{f2(geo.ch)}") \
                %( fill="#{bg.to_hex}"/>\n)
          x = stop
        end
      end
    end

    private def emit_text_runs(io : IO, f : Frame, geo : Geometry) : Nil
      geo.nrows.times do |y|
        ytext = geo.y0 + y * geo.ch + geo.ch * BASELINE_RATIO
        x = 0
        while x < f.cols
          head = f.at(x, y)
          if head.blank?
            x += 1
            next
          end
          stop, text = run_at(f, x, y, head)
          # Hidden keeps its background run and loses its text — the shape of the secret is
          # still on the screenshot, the secret is not.
          emit_run(io, geo, head, text, x, stop, ytext) unless head.attr.hidden?
          x = stop
        end
      end
    end

    # The maximal run starting at (x, y): its end COLUMN and the text it draws.
    #
    # A continuation column neither breaks the run nor contributes text — it contributes the
    # second column of the wide glyph whose lead is already in the text, which is what makes
    # `textLength` the run's true width. A space ends a run (the background rects carry the
    # gap), as does a change of colour or of any rendered style bit.
    private def run_at(f : Frame, x : Int32, y : Int32, head : Cell) : {Int32, String}
      style = head.attr & STYLE_MASK
      stop = x
      text = String.build do |buf|
        while stop < f.cols
          c = f.at(stop, y)
          if c.cont?
            stop += 1
            next
          end
          break if c.blank? || c.fg != head.fg || (c.attr & STYLE_MASK) != style
          buf << c.grapheme
          stop += 1
        end
      end
      {stop, text}
    end

    private def emit_run(io : IO, geo : Geometry, head : Cell, text : String,
                         x : Int32, stop : Int32, ytext : Float64) : Nil
      io << %(<text x="#{f2(geo.pad + x * geo.cw)}" y="#{f2(ytext)}") \
            %( textLength="#{f2((stop - x) * geo.cw)}") \
            %( lengthAdjust="spacingAndGlyphs" fill="#{head.fg.to_hex}")
      emit_style(io, head.attr)
      io << %( xml:space="preserve">#{escape(text)}</text>\n)
    end

    # The style attributes for one run, in the reference renderer's order (`font-weight`
    # directly after `fill`, which is where the goldens have it).
    private def emit_style(io : IO, attr : Termisu::Attribute) : Nil
      io << %( font-weight="700") if attr.bold?
      io << %( opacity="0.6") if attr.dim?
      io << %( font-style="italic") if attr.cursive?
      # ONE `text-decoration`, because repeating an attribute name is not valid XML and a
      # reader keeps whichever it parsed last — a struck-through underlined run would lose
      # one of the two, and which one would be the reader's choice.
      deco = [] of String
      deco << "underline" if attr.underline?
      deco << "line-through" if attr.strikethrough?
      io << %( text-decoration="#{deco.join(' ')}") unless deco.empty?
    end

    # XML text CONTENT. See difference 4 in the module comment for the quotes.
    private def escape(s : String) : String
      s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    # An attribute VALUE, where the quotes do have to go.
    private def quote(s : String) : String
      escape(s).gsub('"', "&quot;").gsub('\'', "&#x27;")
    end

    private def f0(v : Float64) : String
      sprintf("%.0f", v)
    end

    private def f1(v : Float64) : String
      sprintf("%.1f", v)
    end

    private def f2(v : Float64) : String
      sprintf("%.2f", v)
    end
  end
end
