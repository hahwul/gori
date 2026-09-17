require "./frame"
require "../redact"

module Gori::Screenshot
  # Painting the project's redaction profile over a captured frame, so a screenshot of a live
  # engagement can be published without the secrets that were on the screen.
  #
  # The same `Redact::Matcher` an export or a copy uses, asked the same question in the shape
  # a grid needs: `Matcher#spans` gives character ranges over the ORIGINAL text, and those map
  # to columns through `Frame#row_columns`. Nothing here re-derives what a secret looks like —
  # a profile an operator edits reaches a screenshot by construction.
  #
  # WHAT IT CAN AND CANNOT SEE. A profile's rules are BODY rules (`src/gori/redact.cr`), so
  # over a rendered screen they behave as the text fallback does: the profile's field names
  # re-expressed as `"name": "value"` / `name=value`, its own patterns, and the two built-in
  # credential shapes (a JWS compact serialization, a PEM private-key block). Headers are not
  # redacted anywhere in gori by design, and this changes nothing about that — a header that
  # happens to spell `token=…` on screen matches the form-key rule like any other text.
  #
  # TWO PASSES, and the second is the whole reason `Frame#continuations` exists. A pane wraps
  # a long line across several screen rows, and neither half of a soft-wrapped JWT matches on
  # its own. Pass 1 is a row at a time. Pass 2 rejoins each wrap group and looks only for
  # matches that CROSS a row boundary; anything inside one row was pass 1's already, and
  # counting it twice would inflate the number a surface reports.
  module Mask
    # `[REDACTED:` + 8 hex + `]`. A region narrower than the tag is filled with blocks
    # instead: half a tag reads as a truncated secret, and the point of the tag is that two
    # screenshots of the same value carry the same one.
    TAG_WIDTH = 19

    # What covers a region too narrow for a tag. A solid block would read as a drawn UI
    # element; a shaded one reads as "something was here".
    FILL = "▒"

    extend self

    # `frame` with every region the profile claims painted over, and a count of the regions.
    #
    # A nil matcher means this project does not redact by default, and the frame comes back
    # UNTOUCHED with `sanitized` still nil — which is a different statement from
    # `sanitized: 0` ("masked, and nothing matched"), and the SVG carries the difference.
    # Build the matcher with `Redact::Policy.ambient(store)`: it already refuses a profile
    # with no rules (a matcher that would sanitize nothing is worse than none, because the
    # picture would then claim to be sanitized) and arms the correlation salt.
    def apply(frame : Frame, matcher : Gori::Redact::Matcher?) : Frame
      return frame unless matcher
      cells = frame.cells.dup
      count = mask_rows(frame, cells, matcher) + mask_wraps(frame, cells, matcher)
      frame.with(cells: cells, sanitized: count)
    end

    # Pass 1: one row at a time, over the row's full width.
    private def mask_rows(frame : Frame, cells : Array(Cell),
                          matcher : Gori::Redact::Matcher) : Int32
      n = 0
      frame.rows.times do |y|
        # `rstrip` because a terminal row is padded to the pane width, and a rule anchored at
        # the end of the subject (the truncated-value fallback) would otherwise never fire.
        # Stripping the TAIL cannot move any index, so the column map still lines up.
        found = matcher.spans(frame.row_text(y).rstrip)
        next if found.empty?
        colmap = frame.row_columns(y)
        found.each do |span|
          c0, c1 = columns(colmap, span.range.begin, span.range.end, frame.cols)
          write(frame, cells, y, c0, c1, span.placeholder)
          n += 1
        end
      end
      n
    end

    # Pass 2: each wrap group rejoined, for the matches that cross a row boundary.
    private def mask_wraps(frame : Frame, cells : Array(Cell),
                           matcher : Gori::Redact::Matcher) : Int32
      n = 0
      wrap_groups(frame).each do |group|
        rows, x0, x1 = group
        # Each row's own slice, right-stripped — and THAT is load-bearing: the padding blanks
        # at a row's end are not part of the logical line, and joining them in would insert
        # spaces into the middle of the very secret this pass exists to find.
        segs = rows.map { |y| frame.row_text(y, x0, x1).rstrip }
        bases = [] of Int32
        acc = 0
        segs.each do |seg|
          bases << acc
          acc += seg.size
        end
        matcher.spans(segs.join).each do |span|
          n += 1 if apply_crossing(frame, cells, group, segs, bases, span)
        end
      end
      n
    end

    # Write one rejoined span, but only if it actually crosses a row boundary. Returns whether
    # it was written, which is also whether it should be counted — a span that sits inside one
    # row was already found and counted by pass 1.
    private def apply_crossing(frame : Frame, cells : Array(Cell),
                               group : {Array(Int32), Int32, Int32}, segs : Array(String),
                               bases : Array(Int32),
                               span : Gori::Redact::Matcher::Span) : Bool
      rows, x0, x1 = group
      parts = [] of {Int32, Int32, Int32} # row, first char, last char (exclusive), per row
      rows.each_with_index do |y, i|
        a = {span.range.begin, bases[i]}.max - bases[i]
        b = {span.range.end, bases[i] + segs[i].size}.min - bases[i]
        parts << {y, a, b} if a < b
      end
      return false if parts.size < 2
      parts.each do |(y, a, b)|
        colmap = frame.row_columns(y, x0, x1)
        c0, c1 = columns(colmap, a, b, x1)
        write(frame, cells, y, c0, c1, span.placeholder)
      end
      true
    end

    # The rows each soft-wrapped logical line occupies, with the window it wraps inside.
    #
    # A `WrapSpan` says "row y continues the row above", so a maximal run of consecutive
    # marked rows sharing a window is one logical line — plus the row BEFORE the run, which
    # started it and carries no mark of its own.
    #
    # That prepend over-joins at a pane top: if the first visible row of a scrolled pane is
    # marked, the row above it belongs to whatever is drawn there (another pane, a border) and
    # gets joined in anyway. The failure that produces is a false MATCH — something masked
    # that did not need to be — and that is the direction to fail in. Reading the mark as
    # "this row alone" would under-mask instead, which is the failure that matters.
    private def wrap_groups(frame : Frame) : Array({Array(Int32), Int32, Int32})
      by_window = {} of {Int32, Int32} => Array(Int32)
      frame.continuations.each do |s|
        (by_window[{s.x0, s.x1}] ||= [] of Int32) << s.y
      end
      groups = [] of {Array(Int32), Int32, Int32}
      by_window.each do |(window, ys)|
        x0, x1 = window
        ys.sort!.uniq!
        run = [] of Int32
        ys.each do |y|
          if !run.empty? && y != run.last + 1
            groups << {with_starter(run), x0, x1}
            run = [] of Int32
          end
          run << y
        end
        groups << {with_starter(run), x0, x1} unless run.empty?
      end
      groups
    end

    private def with_starter(run : Array(Int32)) : Array(Int32)
      first = run.first
      first > 0 ? [first - 1] + run : run.dup
    end

    # Character indices into a row's text → the COLUMNS they name. An index past the end of
    # the map is the row's right edge: the map covers the row as drawn, and a match can run to
    # the end of the (right-stripped) text.
    #
    # Neither edge can land inside a wide glyph — `row_columns` only ever names the column a
    # cell STARTS at — so a mask never leaves half a CJK character showing.
    private def columns(colmap : Array(Int32), a : Int32, b : Int32,
                        edge : Int32) : {Int32, Int32}
      {a < colmap.size ? colmap[a] : edge, b < colmap.size ? colmap[b] : edge}
    end

    # Paint `[c0, c1)` of row `y`.
    #
    # Each cell keeps its OWN background, so a redaction inside a selection band or a coloured
    # header still sits in that band — the picture keeps its layout and loses only the value.
    # The foreground is taken from the region's first cell, so the cover reads in whatever
    # palette that row is drawn in.
    #
    # A region wide enough carries the correlation tag; everything else is filled. An EMPTY
    # placeholder means no salt was armed to mint a tag with (see `Matcher::Span`), and it
    # falls back to the fill: "redacted without a tag" is a bad outcome, "left on the screen"
    # is the one this exists to prevent.
    private def write(frame : Frame, cells : Array(Cell), y : Int32,
                      c0 : Int32, c1 : Int32, placeholder : String) : Nil
      # Clamped to the grid, like every other consumer of a `WrapSpan`: the marks are
      # recorded by a pane and can outlive the geometry that produced them, and this is the
      # one place here that writes rather than reads.
      c0 = {c0, 0}.max
      c1 = {c1, frame.cols}.min
      return if c1 <= c0 || y < 0 || y >= frame.rows
      fg = frame.at(c0, y).fg
      tag = (c1 - c0 >= TAG_WIDTH && !placeholder.empty?) ? placeholder : nil
      (c0...c1).each_with_index do |x, i|
        glyph = if tag
                  i < tag.size ? tag[i].to_s : " "
                else
                  FILL
                end
        cells[y * frame.cols + x] = Cell.new(glyph, fg, frame.at(x, y).bg)
      end
    end
  end
end
