require "./screen"
require "./theme"
require "../env"
require "termisu"

module Gori::Tui
  # Syntax highlighting for the request/response panes (History detail, Repeater,
  # Intercept). Turns raw HTTP message text into styled spans so every view
  # colours the request line, status line, header names, and structured bodies
  # (JSON / form-encoded / markup) the same way instead of re-implementing it.
  #
  # The cardinal rule: the styled output is always 1:1 in line count with the
  # plain `split('\n')` the views used before, and the concatenation of a line's
  # span texts equals the original line. That keeps scroll bounds and the editor
  # cursor aligned and guarantees no character is ever dropped or duplicated —
  # highlighting is purely a colour overlay on top of the exact same glyphs.
  module Highlight
    # A run of same-styled text within one rendered line.
    record Span, text : String, fg : Color, attr : Attribute = Attribute::None

    # One rendered line: an ordered partition of the source line into spans.
    alias Line = Array(Span)

    # --- public entry points -------------------------------------------------

    # Highlight a full HTTP message held as separate head/body byte slices (the
    # History detail and Repeater response shapes): styled head, then exactly ONE
    # blank line, then the styled body.
    def self.message(head : Bytes?, body : Bytes?, request : Bool) : Array(Line)
      head_lines = to_lines(head)
      # Drop the trailing "" entries the CRLFCRLF head terminator leaves behind
      # (see `message_windowed`) so the head ends on its last header, not on 1–2
      # blank lines.
      while head_lines.size > 1 && head_lines[-1].empty?
        head_lines.pop
      end
      has_body = !(body.nil? || body.empty?)
      body_lines = has_body ? to_lines(body) : [] of String
      kind = body_kind(content_type_in(head_lines))

      out = [] of Line
      in_headers = true
      head_lines.each_with_index do |raw, i|
        if i == 0
          out << start_line(raw, request)
        elsif raw.empty?
          in_headers = false
          out << blank
        elsif in_headers
          out << header_line(raw)
        else
          out << plain(raw)
        end
      end
      if has_body
        out << blank
        body_lines.each { |bl| out << body_line(bl, kind) }
      end
      out
    end

    # Lazy line store for a (possibly multi-MiB) body. Scans once for LF offsets so
    # open/scroll can index by line number without allocating N String objects up
    # front; individual lines are materialised (scrub + rstrip CR) only when read.
    # Matches `String#split('\n').map(&.rstrip('\r'))` semantics of `to_lines`.
    struct BodyLines
      # Shared empty instance — body-less windowed messages.
      EMPTY = BodyLines.new(Bytes.empty, [] of Int32, nil)

      def self.empty : BodyLines
        EMPTY
      end

      # Build from wire/display bytes without splitting into strings.
      def self.from_bytes(bytes : Bytes) : BodyLines
        return empty if bytes.empty?
        starts = Array(Int32).new
        starts << 0
        bytes.each_with_index do |b, i|
          starts << (i + 1) if b == 0x0A_u8
        end
        new(bytes, starts, nil)
      end

      # Wrap an already-split body (Intercept `from_lines_windowed` path).
      def self.from_array(lines : Array(String)) : BodyLines
        return empty if lines.empty?
        new(Bytes.empty, [] of Int32, lines)
      end

      def initialize(@bytes : Bytes, @starts : Array(Int32), @lines : Array(String)?)
      end

      def size : Int32
        if lines = @lines
          lines.size
        else
          @starts.size
        end
      end

      def empty? : Bool
        size == 0
      end

      # Materialise line `i` (0-based). Same scrub/rstrip rules as `to_lines`.
      def [](i : Int32) : String
        if lines = @lines
          return lines[i]
        end
        start = @starts[i]
        finish = (i + 1 < @starts.size) ? (@starts[i + 1] - 1) : @bytes.size
        len = finish - start
        return "" if len <= 0
        String.new(@bytes[start, len]).scrub.rstrip('\r')
      end
    end

    # A message split for WINDOWED rendering: the head is small and pre-styled, but
    # the body can be up to the capture cap (many 10k–100k+ lines), so it's returned as
    # lazy `BodyLines` + the body `kind`. The caller styles only the visible window via
    # `body_styled` — opening a huge response never freezes the UI highlighting
    # off-screen lines, and never allocates a String per off-screen line on open.
    # `head` includes the blank head/body separator, so the styled output is
    # `head ++ body.map { body_styled }` — identical to `message`.
    record Windowed, head : Array(Line), body : BodyLines, kind : Symbol do
      def total : Int32
        head.size + body.size
      end

      # The styled line at absolute index `i` (head pre-styled, body styled lazily).
      def line_at(i : Int32) : Line
        i < head.size ? head[i] : Highlight.body_styled(body[i - head.size], kind)
      end
    end

    # `kind` overrides the content-type-derived styling (used by Pretty when its
    # output is no longer the content-type's language, e.g. GraphQL/JWT → :text).
    def self.message_windowed(head : Bytes?, body : Bytes?, request : Bool, kind : Symbol? = nil) : Windowed
      head_lines = to_lines(head)
      # A captured head ends with the CRLFCRLF terminator, which `to_lines` turns
      # into trailing "" entries ("…\r\n\r\n" → […, "", ""]). Drop them so the
      # single separator appended below renders as exactly ONE blank line between
      # the head and the body, not the 2–3 the terminator would otherwise leave.
      while head_lines.size > 1 && head_lines[-1].empty?
        head_lines.pop
      end
      has_body = !(body.nil? || body.empty?)
      kind = kind || body_kind(content_type_in(head_lines))
      styled = [] of Line
      in_headers = true
      head_lines.each_with_index do |raw, i|
        if i == 0
          styled << start_line(raw, request)
        elsif raw.empty?
          in_headers = false
          styled << blank
        elsif in_headers
          styled << header_line(raw)
        else
          styled << plain(raw)
        end
      end
      styled << blank if has_body # the head/body separator
      Windowed.new(styled, has_body ? BodyLines.from_bytes(body.not_nil!) : BodyLines.empty, kind)
    end

    # Style a single body line (the public seam for windowed rendering).
    def self.body_styled(raw : String, kind : Symbol) : Line
      body_line(raw, kind)
    end

    # Highlight a message held as one combined text blob (Intercept's byte-exact
    # `raw`, and the Repeater/Intercept editors). Splits head from body at the
    # first blank line and stays strictly 1:1 with `text.split('\n')`, so it can
    # back an editable buffer where each styled line must line up with the
    # cursor's line.
    def self.from_lines(all : Array(String), request : Bool) : Array(Line)
      sep = all.index("")
      kind = body_kind(content_type_in(all))
      lines = all.map_with_index do |raw, i|
        if i == 0
          start_line(raw, request)
        elsif sep.nil?
          header_line(raw) # no blank line yet → everything after the start line is a header
        elsif i < sep
          header_line(raw)
        elsif i == sep
          blank # the head/body separator
        else
          body_line(raw, kind)
        end
      end
      request ? lines.map { |line| with_env_tokens(line) } : lines
    end

    # Per-character colours for a filter/QL query, so its boolean structure reads apart
    # from the values being matched — `(host:a OR host:b) -method:GET` should show at a
    # glance which words are operators and where the group closes.
    #
    # Classification comes from FilterAst's own lexer, so the colour is a truthful
    # preview of how the query will be PARSED: a lowercase `or`, a quoted "AND", and a
    # `(` sitting inside a value all stay plain, because none of them group anything.
    # Characters no span covers (the whitespace between terms) keep `base`.
    def self.filter_query(query : String, base : Color = Theme.text) : Array(Color)
      colors = Array(Color).new(query.size, base)
      FilterAst.spans(query).each do |span|
        fg = case span.kind
             in .operator? then Theme.syn_keyword
             in .paren?    then Theme.syn_keyword
             in .field?    then Theme.syn_header
             in .value?    then Theme.text_bright
             in .quote?    then Theme.syn_string
             in .plain?    then base
             end
        (span.start...(span.start + span.size)).each { |i| colors[i] = fg if i < colors.size }
      end
      colors
    end

    # Single-line env overlay (TARGET fields, ENV pane values).
    def self.env_line(raw : String, base_fg : Color = Theme.text, attr : Attribute = Attribute::None) : Line
      with_env_tokens([Span.new(raw, base_fg, attr)])
    end

    def self.with_env_tokens(line : Line) : Line
      out = [] of Span
      line.each { |span| env_spans_in(span.text, span.fg, span.attr).each { |s| out << s } }
      out
    end

    private def self.env_spans_in(text : String, base_fg : Color, attr : Attribute = Attribute::None) : Line
      # Fast path: no prefix configured, or the line has no prefix char at all (most
      # URLs/values carry no $TOKEN). token_regions returns [] in that case anyway, but
      # its default `vars = Env.effective_vars` rebuilds a merged Hash on EVERY call
      # first — wasted per-frame allocation on the TARGET rows that redraw each frame.
      prefix = Settings.env_prefix
      return [Span.new(text, base_fg, attr)] if prefix.empty? || !text.includes?(prefix)
      regions = Env.token_regions(text, prefix)
      return [Span.new(text, base_fg, attr)] if regions.empty?
      spans = [] of Span
      pos = 0
      regions.each do |(a, b, known)|
        spans << Span.new(text[pos...a], base_fg, attr) if a > pos
        spans << Span.new(text[a...b], known ? Theme.env_known : Theme.env_unknown, known ? attr : (attr | Attribute::Italic))
        pos = b
      end
      spans << Span.new(text[pos..], base_fg, attr) if pos < text.size
      spans
    end

    # Windowed variant of `from_lines` for a combined-text message (Intercept's
    # held bytes): the head (start line + headers + the blank separator) is styled
    # eagerly, the body kept RAW + styled per visible line — so a multi-MiB held
    # body doesn't freeze the UI on selection.
    def self.from_lines_windowed(all : Array(String), request : Bool) : Windowed
      sep = all.index("")
      kind = body_kind(content_type_in(all))
      if sep.nil?
        head = all.map_with_index { |raw, i| i == 0 ? start_line(raw, request) : header_line(raw) }
        return Windowed.new(head, BodyLines.empty, kind)
      end
      head = [] of Line
      all.each_with_index do |raw, i|
        break if i > sep
        head << (i == 0 ? start_line(raw, request) : (i == sep ? blank : header_line(raw)))
      end
      Windowed.new(head, BodyLines.from_array(all[(sep + 1)..]), kind)
    end

    # --- Markdown (Notes / Project description) ------------------------------
    # Colour-overlay highlighting for prose notes. The markdown SYNTAX stays
    # visible (markers are coloured, not hidden/rendered) and the output is strictly
    # 1:1 with the input lines + span texts, so the editable buffer's cursor stays
    # aligned. Fenced code blocks (``` / ~~~) are tracked across lines.
    def self.markdown(all : Array(String)) : Array(Line)
      out = [] of Line
      fence = false
      all.each do |raw|
        if md_fence?(raw)
          out << (raw.empty? ? Line.new : [Span.new(raw, Theme.syn_number)])
          fence = !fence
        elsif fence
          out << (raw.empty? ? Line.new : [Span.new(raw, Theme.syn_string)])
        else
          out << md_line(raw)
        end
      end
      out
    end

    private def self.md_fence?(raw : String) : Bool
      t = raw.lstrip
      t.starts_with?("```") || t.starts_with?("~~~")
    end

    # One non-fence markdown line → styled spans (block-level dispatch, then inline).
    private def self.md_line(raw : String) : Line
      return Line.new if raw.empty?
      t = raw.lstrip
      indent = raw.size - t.size
      return [Span.new(raw, Theme.text_bright, Attribute::Bold)] if md_heading?(t)  # # .. ######
      return [Span.new(raw, Theme.muted, Attribute::Italic)] if t.starts_with?('>') # blockquote
      return [Span.new(raw, Theme.muted)] if md_hr?(t)                              # --- *** ___
      if (m = md_list_marker(t)) > 0
        cut = indent + m
        return [Span.new(raw[0, cut], Theme.accent)] + md_inline(raw[cut..], Theme.text)
      end
      md_inline(raw, Theme.text)
    end

    private def self.md_heading?(t : String) : Bool
      h = 0
      while h < t.size && t[h] == '#'
        h += 1
      end
      h >= 1 && h <= 6 && (h == t.size || t[h] == ' ')
    end

    # Leading list marker length within `t` (lstripped), incl. the trailing space:
    # "- "/"* "/"+ " → 2, "12. " → 4. 0 when the line isn't a list item.
    private def self.md_list_marker(t : String) : Int32
      return 2 if t.size >= 2 && (t[0] == '-' || t[0] == '*' || t[0] == '+') && t[1] == ' '
      d = 0
      while d < t.size && t[d].ascii_number?
        d += 1
      end
      return d + 2 if d > 0 && d + 1 < t.size && t[d] == '.' && t[d + 1] == ' '
      0
    end

    private def self.md_hr?(t : String) : Bool
      s = t.rstrip
      return false if s.size < 3
      {'-', '*', '_'}.each do |ch|
        return true if s.count(ch) >= 3 && s.each_char.all? { |c| c == ch || c == ' ' }
      end
      false
    end

    # Inline spans for one line's text: bold **, italic *, code `, strike ~~, links
    # [t](u). Index-based so every char is emitted exactly once (1:1). Markers kept
    # visible (coloured), not stripped. `_` is intentionally NOT emphasis (avoids
    # snake_case false positives).
    private def self.md_inline(text : String, base : Color) : Line
      spans = Line.new
      n = text.size
      run = 0
      i = 0
      while i < n
        c = text[i]
        e = -1
        col = base
        at = Attribute::None
        case c
        when '`'
          if (j = text.index('`', i + 1))
            e = j + 1
            col = Theme.syn_string
          end
        when '*'
          if i + 1 < n && text[i + 1] == '*'
            if (k = text.index("**", i + 2))
              e = k + 2
              at = Attribute::Bold
            end
          elsif i + 1 < n && text[i + 1] != ' ' && (k = text.index('*', i + 1))
            e = k + 1
            at = Attribute::Italic
          end
        when '~'
          if i + 1 < n && text[i + 1] == '~' && (k = text.index("~~", i + 2))
            e = k + 2
            col = Theme.muted
            at = Attribute::Strikethrough
          end
        when '['
          if (rb = text.index(']', i + 1)) && rb + 1 < n && text[rb + 1] == '(' && (rp = text.index(')', rb + 2))
            e = rp + 1
            col = Theme.syn_header
            at = Attribute::Underline
          end
        end
        if e > i
          spans << Span.new(text[run, i - run], base) if i > run
          spans << Span.new(text[i, e - i], col, at)
          run = i = e
        else
          i += 1
        end
      end
      spans << Span.new(text[run, n - run], base) if n > run
      spans
    end

    # Draw a styled line at (x, y), clipped to `width` columns (default: to the
    # right edge). Truncation matches `Screen#fit` glyph-for-glyph and in the
    # returned x, so toggling highlighting never shifts a cell: wider-than-1
    # overflow keeps `limit - 1` glyphs plus a trailing ellipsis, while a 1-wide
    # slot shows the first glyph alone (an ellipsis there would hide all real
    # content — exactly Screen#fit's `w == 1` special case). Returns the x just
    # past the drawn text.
    def self.draw(screen : Screen, x : Int32, y : Int32, line : Line,
                  bg : Color = Theme.bg, width : Int32? = nil) : Int32
      limit = width || (screen.width - x)
      return x if limit <= 0

      # Special case for width=1: always show the first glyph (even if it is
      # wide, e.g. Hangul), never ellipsis. Matches Screen#fit policy.
      if limit == 1
        if line.any? && !line[0].text.empty?
          first = line[0].text.each_grapheme.first.to_s
          screen.cell(x, y, first, line[0].fg, bg, line[0].attr)
          return x + Screen.display_width(first)
        end
        return x
      end

      # Does the line exceed `limit`? Stop measuring as soon as it does — never walk a
      # huge (e.g. minified-JSON, multi-KB header) line in full just to set a boolean.
      # A printable-ASCII span (the common case — HTTP heads/bodies) is all width-1
      # glyphs, so its width is its char count: skip the grapheme walk (and its per-glyph
      # `g.to_s` String) entirely, mirroring Screen#text's ASCII fast path. Mixed lines
      # stay correct — width accumulates across spans regardless of which branch each takes.
      overflow = false
      acc = 0
      line.each do |span|
        t = span.text
        if printable_ascii?(t)
          if acc + t.size > limit
            overflow = true
            break
          end
          acc += t.size
        else
          t.each_grapheme do |g|
            acc += Termisu::UnicodeWidth.grapheme_width(g.to_s)
            if acc > limit
              overflow = true
              break
            end
          end
          break if overflow
        end
      end
      ellipsis = overflow && limit > 1

      visual_col = 0
      room = limit - (ellipsis ? 1 : 0)
      done = false
      line.each do |span|
        break if done
        t = span.text
        if printable_ascii?(t)
          # Each printable-ASCII char is one width-1 cell; pass the Char to `cell` (interned
          # via Screen::ASCII_CELL — zero allocation) instead of a fresh `g.to_s` String.
          t.each_char do |ch|
            if visual_col + 1 > room
              done = true
              break
            end
            screen.cell(x + visual_col, y, ch, span.fg, bg, span.attr)
            visual_col += 1
          end
        else
          t.each_grapheme do |g|
            gw = Termisu::UnicodeWidth.grapheme_width(g.to_s)
            # The FIRST grapheme that doesn't fit terminates ALL rendering — a single
            # continuous walk, so a later span can't resume into the leftover room and draw
            # a narrower glyph in place of the skipped wide one (Screen#fit glyph parity).
            if visual_col + gw > room
              done = true
              break
            end
            screen.cell(x + visual_col, y, g.to_s, span.fg, bg, span.attr)
            visual_col += gw
          end
        end
        break if done || visual_col >= limit
      end

      if ellipsis && visual_col < limit
        screen.cell(x + visual_col, y, '…', Theme.muted, bg)
        visual_col += 1
      end
      x + visual_col
    end

    # Drop the first `start_col` display columns of a styled line, mirroring the
    # TextArea string slicer: whole spans before the cut are skipped, the span the
    # cut lands in is trimmed (a straddling wide glyph → leading spaces), and every
    # following span is kept verbatim. Used by horizontally-scrolled editors so the
    # styled overlay lines up with the cells actually drawn. Identity when col <= 0.
    def self.slice_left(line : Line, start_col : Int32) : Line
      return line if start_col <= 0
      out = Line.new
      acc = 0
      cutting = true
      line.each do |span|
        unless cutting
          out << span
          next
        end
        sw = Screen.display_width(span.text)
        if acc + sw <= start_col # whole span is left of the cut
          acc += sw
          next
        end
        kept = String.build do |io|
          span.text.each_char do |ch|
            if cutting
              w = Screen.display_width(ch.to_s)
              if acc + w <= start_col
                acc += w
                next
              end
              io << " " * (acc + w - start_col) if acc < start_col # straddling glyph → visible cells as spaces
              io << ch if acc >= start_col                         # clean boundary keeps the glyph
              acc += w
              cutting = false
            else
              io << ch
            end
          end
        end
        out << Span.new(kept, span.fg, span.attr) unless kept.empty?
      end
      out
    end

    # The plain-string counterpart of `slice_left` — same straddling-glyph handling,
    # for the read-only panes that draw raw `String` lines (no syntax overlay) rather
    # than a styled `Line`. Identity when start_col <= 0.
    def self.slice_left_text(s : String, start_col : Int32) : String
      return s if start_col <= 0
      acc = 0
      cutting = true
      String.build do |io|
        s.each_char do |ch|
          if cutting
            w = Screen.display_width(ch.to_s)
            if acc + w <= start_col
              acc += w
              next
            end
            io << " " * (acc + w - start_col) if acc < start_col # straddling glyph → visible cells as spaces
            io << ch if acc >= start_col                         # clean boundary keeps the glyph
            acc += w
            cutting = false
          else
            io << ch
          end
        end
      end
    end

    # Delete the character ranges `ranges` (line-LOCAL char offsets, each `[a, b)`
    # within `[0, line-char-count]`, sorted ascending and non-overlapping) from a
    # styled line, keeping every surviving character's exact styling. The result's
    # span texts concatenate to the source line with those ranges removed — the
    # concealment counterpart to the module's 1:1 invariant. Used by TextArea to hide
    # the `¦chain` segment of a §…§ marker inline while the chain stays in the editable
    # buffer. Identity when `ranges` is empty (the hot path for every other line).
    def self.conceal(line : Line, ranges : Array({Int32, Int32})) : Line
      return line if ranges.empty?
      out = Line.new
      off = 0 # char offset of the current span's first char within the whole line
      line.each do |span|
        t = span.text
        len = t.size
        pos = 0 # local index of the next unemitted char in `t`
        ranges.each do |(a, b)|
          la = a - off
          lb = b - off
          next if lb <= pos || la >= len # range fully behind the cursor / after this span
          la = {la, pos}.max
          lb = {lb, len}.min
          next if la >= lb
          out << Span.new(t[pos...la], span.fg, span.attr) if la > pos
          pos = lb
        end
        out << Span.new(t[pos...len], span.fg, span.attr) if pos < len
        off += len
      end
      out
    end

    # Total display width of a styled line (sum of its spans) — used to clamp a
    # horizontal scroll offset against the widest currently-visible row.
    def self.line_width(line : Line) : Int32
      line.sum { |span| Screen.display_width(span.text) }
    end

    # As `line_width`, but stops summing once the running width reaches `limit` — and
    # caps WITHIN a span too (a huge minified body is one plain span > MAX_HL_LINE), so
    # the per-frame h-scroll clamp never fully measures a multi-MB line. See
    # Screen.display_width_upto. Exact for lines narrower than limit.
    def self.line_width_upto(line : Line, limit : Int32) : Int32
      w = 0
      line.each do |span|
        break if w >= limit
        w += Screen.display_width_upto(span.text, limit - w)
      end
      w
    end

    # --- line builders -------------------------------------------------------

    private def self.start_line(raw : String, request : Bool) : Line
      request ? request_line(raw) : status_line(raw)
    end

    # `METHOD target HTTP/x.x` — method coloured by verb, the target broken into
    # path + query (see `target_spans`), the version muted. Spaces are preserved
    # verbatim as their own muted spans so the partition is exact regardless of odd
    # spacing.
    private def self.request_line(raw : String) : Line
      first = raw.index(' ')
      return [Span.new(raw, Theme.method_color(raw), Attribute::Bold)] unless first
      method = raw[0...first]
      spans = [Span.new(method, Theme.method_color(method), Attribute::Bold)]
      last = raw.rindex(' ')
      if last && last > first
        spans << Span.new(raw[first...first + 1], Theme.muted) # space
        target_spans(raw[first + 1...last]).each { |s| spans << s }
        spans << Span.new(raw[last...last + 1], Theme.muted) # space
        spans << Span.new(raw[last + 1..], Theme.muted)      # version
      else
        spans << Span.new(raw[first...first + 1], Theme.muted) # space
        target_spans(raw[first + 1..]).each { |s| spans << s }
      end
      spans
    end

    # Break a request target into `path[?query][#fragment]`: the path (incl. any
    # absolute-form `scheme://host`) stays bright; `?`/`#` and the query's `&`/`=`
    # mute; query keys accent (syn_header), values body text — reusing `form_line`.
    # Byte/index-based so the spans still concatenate to the exact target. Identity
    # (one bright span) when there's no query string — the common case.
    private def self.target_spans(t : String) : Line
      qi = t.index('?')
      return [Span.new(t, Theme.text_bright)] unless qi
      spans = [] of Span
      spans << Span.new(t[0...qi], Theme.text_bright) if qi > 0 # path
      spans << Span.new("?", Theme.muted)
      fi = t.index('#', qi + 1)
      query = fi ? t[(qi + 1)...fi] : t[(qi + 1)..]
      form_line(query).each { |s| spans << s } unless query.empty?
      spans << Span.new(t[fi..], Theme.muted) if fi # '#fragment'
      spans
    end

    # `HTTP/x.x CODE reason` — version muted, code coloured by status class,
    # reason in body text.
    private def self.status_line(raw : String) : Line
      first = raw.index(' ')
      return [Span.new(raw, Theme.muted)] unless first
      spans = [Span.new(raw[0...first], Theme.muted)]
      spans << Span.new(raw[first...first + 1], Theme.muted) # space
      second = raw.index(' ', first + 1)
      if second
        code = raw[first + 1...second]
        spans << Span.new(code, Theme.status_color(code.to_i?), Attribute::Bold)
        spans << Span.new(raw[second...second + 1], Theme.muted) # space
        spans << Span.new(raw[second + 1..], Theme.text)         # reason
      else
        code = raw[first + 1..]
        spans << Span.new(code, Theme.status_color(code.to_i?), Attribute::Bold)
      end
      spans
    end

    # `Name: value` — field name accented, the colon muted, the value tokenised by
    # `header_value_spans`. The first colon is the separator (values may themselves
    # contain ':').
    private def self.header_line(raw : String) : Line
      colon = raw.index(':')
      return plain(raw) unless colon
      spans = [Span.new(raw[0...colon], Theme.syn_header)]
      spans << Span.new(raw[colon...colon + 1], Theme.muted) # ":"
      rest = raw[colon + 1..]
      unless rest.empty?
        header_value_spans(raw[0...colon].downcase, rest).each { |s| spans << s }
      end
      spans
    end

    # Well-known Set-Cookie attribute names (lowercased) — coloured as keywords so the
    # cookie's own name/value pairs stand out from the flags that follow.
    COOKIE_ATTRS = %w(path domain expires max-age samesite secure httponly partitioned priority)

    # Colour a header value by header name: cookies and auth get dedicated tokenisers,
    # everything else a light param lexer. `v` keeps the leading space after the colon
    # so the spans concatenate back to the exact value. Guarded against a pathological
    # multi-KB header the same way body lines are.
    private def self.header_value_spans(name_lc : String, v : String) : Line
      return [Span.new(v, Theme.text)] if v.bytesize > MAX_HL_LINE
      case name_lc
      when "cookie", "set-cookie"                 then cookie_value_spans(v)
      when "authorization", "proxy-authorization" then auth_value_spans(v)
      else                                             generic_value_spans(v)
      end
    end

    # `scheme credential` (Bearer …, Basic …, Digest …): the scheme keyword-coloured,
    # the credential as a string. Leading whitespace kept as its own muted span.
    private def self.auth_value_spans(v : String) : Line
      n = v.size
      i = 0
      while i < n && v[i] == ' '
        i += 1
      end
      return [Span.new(v, Theme.text)] if i >= n
      s0 = i
      while i < n && v[i] != ' '
        i += 1
      end
      spans = [] of Span
      spans << Span.new(v[0...s0], Theme.muted) if s0 > 0  # leading space(s)
      spans << Span.new(v[s0...i], Theme.syn_keyword)      # scheme
      spans << Span.new(v[i..], Theme.syn_string) if i < n # space + credential
      spans
    end

    # `name=value; name=value; Attr` (Cookie / Set-Cookie): names accented, values
    # body text, `=`/`;` muted, known Set-Cookie attributes keyword-coloured.
    private def self.cookie_value_spans(v : String) : Line
      spans = [] of Span
      b = v.to_slice
      n = b.size
      i = 0
      expect_name = true
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x3b_u8 # ';'
          spans << Span.new(v.byte_slice(i, 1), Theme.muted)
          i += 1
          expect_name = true
        elsif c == 0x3d_u8 # '='
          spans << Span.new(v.byte_slice(i, 1), Theme.muted)
          i += 1
          expect_name = false
        else
          start = i
          while i < n && b.unsafe_fetch(i) != 0x3b_u8 && b.unsafe_fetch(i) != 0x3d_u8
            i += 1
          end
          tok = v.byte_slice(start, i - start)
          color = if expect_name
                    COOKIE_ATTRS.includes?(tok.strip.downcase) ? Theme.syn_keyword : Theme.syn_header
                  else
                    Theme.text
                  end
          spans << Span.new(tok, color)
        end
      end
      spans
    end

    # Generic header value: a single plain span when there's no structure (Host, Date,
    # User-Agent, …), else a light param lexer — quoted strings syn_string, param keys
    # (a token immediately before '=') syn_header, `=`/`;`/`,` muted, the rest body text.
    # Bare numbers/dates are intentionally NOT highlighted (too noisy across headers).
    private def self.generic_value_spans(v : String) : Line
      return [Span.new(v, Theme.text)] unless v.includes?('=') || v.includes?('"')
      spans = [] of Span
      b = v.to_slice
      n = b.size
      i = 0
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x22_u8 # '"' — quoted string (to the next quote or EOL)
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            i += 1
            break if d == 0x22_u8
          end
          spans << Span.new(v.byte_slice(start, {i, n}.min - start), Theme.syn_string)
        elsif c == 0x3d_u8 || c == 0x3b_u8 || c == 0x2c_u8 # '=' ';' ','
          spans << Span.new(v.byte_slice(i, 1), Theme.muted)
          i += 1
        else
          start = i
          while i < n
            d = b.unsafe_fetch(i)
            break if d == 0x22_u8 || d == 0x3d_u8 || d == 0x3b_u8 || d == 0x2c_u8
            i += 1
          end
          key = i < n && b.unsafe_fetch(i) == 0x3d_u8 # a token right before '=' is a param key
          spans << Span.new(v.byte_slice(start, i - start), key ? Theme.syn_header : Theme.text)
        end
      end
      spans
    end

    # --- body dispatch -------------------------------------------------------

    # Per-line ceiling for structured highlighting. The json/form/markup
    # tokenizers do `raw.chars` (materializing the whole line as an Array(Char)),
    # so a single very long line — e.g. a minified multi-MB JSON/HTML body that
    # decodes to ONE line — would freeze the UI fiber for seconds and spike memory.
    # Above this, fall back to a single plain span (line count is unchanged, so the
    # styled/plain 1:1 invariant the views rely on still holds).
    MAX_HL_LINE = 64 * 1024

    private def self.body_line(raw : String, kind : Symbol) : Line
      return blank if raw.empty?
      return plain(raw) if raw.bytesize > MAX_HL_LINE
      case kind
      when :json       then json_line(raw)
      when :form       then form_line(raw)
      when :xml, :html then markup_line(raw)
      when :graphql    then graphql_line(raw)
      else                  plain(raw)
      end
    end

    # JSON, tokenised per line (valid JSON never splits a string across a raw
    # newline, so a line-local pass is sufficient for both pretty and minified
    # bodies). Object keys (a string immediately followed by ':') are accented
    # distinctly from string values.
    # Byte-scanned (not `raw.chars`): all token boundaries are ASCII bytes, and every UTF-8
    # multibyte byte is ≥0x80 (never a boundary byte), so it falls into the text/value/else
    # runs exactly as a non-ASCII Char did — output is byte-identical, spans still concat to
    # the exact line (a cut only ever lands on an ASCII byte = a char boundary, so byte_slice
    # never splits a codepoint). Removes the per-line Array(Char) + the per-span sub-array+join.
    private def self.json_line(raw : String) : Line
      spans = [] of Span
      b = raw.to_slice # view over the UTF-8 bytes, no copy
      n = b.size
      # JSONC line comment: a line whose first non-space bytes are `//` is a comment
      # (the JWT decoder emits `// header` / `// payload` markers around JSON segments).
      # Real JSON never starts a line with `//`, so this is safe for genuine bodies.
      ws = 0
      while ws < n && ascii_ws?(b.unsafe_fetch(ws))
        ws += 1
      end
      if ws + 1 < n && b.unsafe_fetch(ws) == 0x2f_u8 && b.unsafe_fetch(ws + 1) == 0x2f_u8
        return [Span.new(raw, Theme.syn_comment)]
      end
      i = 0
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x22_u8 # '"'
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            if d == 0x5c_u8 # backslash: skip the escaped byte
              i += 2
            elsif d == 0x22_u8
              i += 1
              break
            else
              i += 1
            end
          end
          str = raw.byte_slice(start, {i, n}.min - start) # i may overshoot on a trailing '\'
          k = i
          while k < n && ascii_ws?(b.unsafe_fetch(k))
            k += 1
          end
          key = k < n && b.unsafe_fetch(k) == 0x3a_u8 # ':'
          spans << Span.new(str, key ? Theme.syn_header : Theme.syn_string)
        elsif ascii_digit?(c) || (c == 0x2d_u8 && i + 1 < n && ascii_digit?(b.unsafe_fetch(i + 1)))
          start = i
          i += 1
          while i < n && (ascii_digit?(b.unsafe_fetch(i)) || num_cont?(b.unsafe_fetch(i)))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.syn_number)
        elsif ascii_letter?(c)
          start = i
          i += 1
          while i < n && ascii_letter?(b.unsafe_fetch(i))
            i += 1
          end
          word = raw.byte_slice(start, i - start)
          spans << Span.new(word, %w(true false null).includes?(word) ? Theme.syn_literal : Theme.text)
        elsif json_struct?(c)
          spans << Span.new(raw.byte_slice(i, 1), Theme.muted)
          i += 1
        else
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            break if d == 0x22_u8 || ascii_letter?(d) || ascii_digit?(d) || json_struct?(d) ||
                     (d == 0x2d_u8 && i + 1 < n && ascii_digit?(b.unsafe_fetch(i + 1)))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.text)
        end
      end
      spans
    end

    # ASCII byte classifiers (mirror the Char#ascii_* predicates the tokenizers used).
    private def self.ascii_digit?(x : UInt8) : Bool
      x >= 0x30_u8 && x <= 0x39_u8
    end

    private def self.ascii_letter?(x : UInt8) : Bool
      (x >= 0x41_u8 && x <= 0x5a_u8) || (x >= 0x61_u8 && x <= 0x7a_u8)
    end

    # Char#ascii_whitespace?: space or 0x09..0x0d.
    private def self.ascii_ws?(x : UInt8) : Bool
      x == 0x20_u8 || (x >= 0x09_u8 && x <= 0x0d_u8)
    end

    # JSON number continuation: one of `+ - . e E`.
    private def self.num_cont?(x : UInt8) : Bool
      x == 0x2b_u8 || x == 0x2d_u8 || x == 0x2e_u8 || x == 0x65_u8 || x == 0x45_u8
    end

    # JSON structural punctuation: one of `{ } [ ] : ,`.
    private def self.json_struct?(x : UInt8) : Bool
      x == 0x7b_u8 || x == 0x7d_u8 || x == 0x5b_u8 || x == 0x5d_u8 || x == 0x3a_u8 || x == 0x2c_u8
    end

    # GraphQL operation keywords (styled distinctly from `true`/`false`/`null` literals).
    GRAPHQL_KEYWORDS = %w(query mutation subscription fragment on)

    # GraphQL query language (the Pretty/decoded display form): `#` comments, operation
    # keywords, `$variables`, `@directives`, strings, numbers, and field/type names (an
    # identifier immediately before `:` / `(` / `{`). Byte-scanned and line-local like
    # the other body tokenizers, so the spans concatenate back to the exact line.
    private def self.graphql_line(raw : String) : Line
      spans = [] of Span
      b = raw.to_slice
      n = b.size
      i = 0
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x23_u8 # '#' — comment to end of line
          spans << Span.new(raw.byte_slice(i, n - i), Theme.syn_comment)
          i = n
        elsif c == 0x22_u8 # '"' — string (to the next unescaped quote or EOL)
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            if d == 0x5c_u8
              i += 2
            elsif d == 0x22_u8
              i += 1
              break
            else
              i += 1
            end
          end
          spans << Span.new(raw.byte_slice(start, {i, n}.min - start), Theme.syn_string)
        elsif c == 0x24_u8 # '$' — variable
          start = i
          i += 1
          while i < n && gql_name?(b.unsafe_fetch(i))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.syn_literal)
        elsif c == 0x40_u8 # '@' — directive
          start = i
          i += 1
          while i < n && gql_name?(b.unsafe_fetch(i))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.syn_keyword)
        elsif ascii_digit?(c) || (c == 0x2d_u8 && i + 1 < n && ascii_digit?(b.unsafe_fetch(i + 1)))
          start = i
          i += 1
          while i < n && (ascii_digit?(b.unsafe_fetch(i)) || num_cont?(b.unsafe_fetch(i)))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.syn_number)
        elsif gql_name_start?(c)
          start = i
          i += 1
          while i < n && gql_name?(b.unsafe_fetch(i))
            i += 1
          end
          word = raw.byte_slice(start, i - start)
          k = i
          while k < n && ascii_ws?(b.unsafe_fetch(k))
            k += 1
          end
          nxt = k < n ? b.unsafe_fetch(k) : 0_u8
          color = if GRAPHQL_KEYWORDS.includes?(word)
                    Theme.syn_keyword
                  elsif word == "true" || word == "false" || word == "null"
                    Theme.syn_literal
                  elsif nxt == 0x3a_u8 || nxt == 0x28_u8 || nxt == 0x7b_u8 # ':' '(' '{' → field/arg/type
                    Theme.syn_header
                  else
                    Theme.text
                  end
          spans << Span.new(word, color)
        elsif gql_punct?(c)
          spans << Span.new(raw.byte_slice(i, 1), Theme.muted)
          i += 1
        else
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            break if d == 0x23_u8 || d == 0x22_u8 || d == 0x24_u8 || d == 0x40_u8 ||
                     gql_name_start?(d) || ascii_digit?(d) || gql_punct?(d) ||
                     (d == 0x2d_u8 && i + 1 < n && ascii_digit?(b.unsafe_fetch(i + 1)))
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.text)
        end
      end
      spans
    end

    # GraphQL name start byte: ASCII letter or `_`.
    private def self.gql_name_start?(x : UInt8) : Bool
      ascii_letter?(x) || x == 0x5f_u8
    end

    # GraphQL name continuation byte: letter, digit, or `_`.
    private def self.gql_name?(x : UInt8) : Bool
      ascii_letter?(x) || ascii_digit?(x) || x == 0x5f_u8
    end

    # GraphQL punctuation: one of `{ } ( ) [ ] : ! = , |`.
    private def self.gql_punct?(x : UInt8) : Bool
      x == 0x7b_u8 || x == 0x7d_u8 || x == 0x28_u8 || x == 0x29_u8 ||
        x == 0x5b_u8 || x == 0x5d_u8 || x == 0x3a_u8 || x == 0x21_u8 ||
        x == 0x3d_u8 || x == 0x2c_u8 || x == 0x7c_u8
    end

    # `application/x-www-form-urlencoded` — keys accented, `=`/`&` muted, values
    # in body text.
    private def self.form_line(raw : String) : Line
      spans = [] of Span
      b = raw.to_slice
      n = b.size
      i = 0
      expect_key = true
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x26_u8 # '&'
          spans << Span.new(raw.byte_slice(i, 1), Theme.muted)
          i += 1
          expect_key = true
        elsif c == 0x3d_u8 # '='
          spans << Span.new(raw.byte_slice(i, 1), Theme.muted)
          i += 1
          expect_key = false
        else
          start = i
          while i < n && b.unsafe_fetch(i) != 0x26_u8 && b.unsafe_fetch(i) != 0x3d_u8
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), expect_key ? Theme.syn_header : Theme.text)
        end
      end
      spans
    end

    # HTML/XML — tag delimiters muted, tag names accented, attributes tokenised (see
    # `attr_spans`), text in body colour. `<!-- -->` comments and `<!DOCTYPE>`/`<?xml?>`
    # declarations get their own colours. Line-local: a tag (or comment) split across
    # lines simply isn't recognised on the continuation line (cosmetic only; text is
    # never altered).
    private def self.markup_line(raw : String) : Line
      spans = [] of Span
      b = raw.to_slice
      n = b.size
      i = 0
      while i < n
        if b.unsafe_fetch(i) == 0x3c_u8 # '<'
          # Comment: '<!-- … -->' (line-local — an unterminated comment runs to EOL).
          if i + 3 < n && b.unsafe_fetch(i + 1) == 0x21_u8 && b.unsafe_fetch(i + 2) == 0x2d_u8 && b.unsafe_fetch(i + 3) == 0x2d_u8
            close = find_seq(b, i + 4, n)
            stop = close ? close + 3 : n
            spans << Span.new(raw.byte_slice(i, stop - i), Theme.syn_comment)
            i = stop
            next
          end
          gt = i + 1
          while gt < n && b.unsafe_fetch(gt) != 0x3e_u8 # '>'
            gt += 1
          end
          closed = gt < n # found a '>'
          j = i + 1
          # A declaration ('<!DOCTYPE …') or processing instruction ('<?xml …?>'): the
          # name reads as a keyword; a closing tag keeps the '/' in the delimiter.
          decl = false
          if j < n && (b.unsafe_fetch(j) == 0x21_u8 || b.unsafe_fetch(j) == 0x3f_u8) # '!' or '?'
            decl = true
            j += 1
          elsif j < n && b.unsafe_fetch(j) == 0x2f_u8 # '/' closing tag
            j += 1
          end
          spans << Span.new(raw.byte_slice(i, j - i), Theme.muted) # '<' / '</' / '<!' / '<?'
          name = j
          while name < gt && tag_name?(b.unsafe_fetch(name))
            name += 1
          end
          spans << Span.new(raw.byte_slice(j, name - j), decl ? Theme.syn_keyword : Theme.syn_header) if name > j
          if name < gt
            if decl
              spans << Span.new(raw.byte_slice(name, gt - name), Theme.text)
            else
              attr_spans(raw.byte_slice(name, gt - name)).each { |s| spans << s }
            end
          end
          spans << Span.new(raw.byte_slice(gt, 1), Theme.muted) if closed # '>'
          i = closed ? gt + 1 : gt
        else
          start = i
          i += 1
          while i < n && b.unsafe_fetch(i) != 0x3c_u8
            i += 1
          end
          spans << Span.new(raw.byte_slice(start, i - start), Theme.text)
        end
      end
      spans
    end

    # Byte offset of the first `-->` at or after `from` (comment terminator), or nil.
    private def self.find_seq(b : Bytes, from : Int32, n : Int32) : Int32?
      k = from
      while k + 2 < n
        return k if b.unsafe_fetch(k) == 0x2d_u8 && b.unsafe_fetch(k + 1) == 0x2d_u8 && b.unsafe_fetch(k + 2) == 0x3e_u8
        k += 1
      end
      nil
    end

    # The attribute region between a tag name and '>': attribute names → syn_number (the
    # palette's reserved "tag attribute names" slot), '=' muted, quoted values ("…"/'…')
    # → syn_string, '/' (self-close) muted, whitespace/other → body text. `after_eq`
    # keeps an UNQUOTED value (e.g. `type=text`) body-coloured rather than as a name.
    private def self.attr_spans(seg : String) : Line
      spans = [] of Span
      b = seg.to_slice
      n = b.size
      i = 0
      after_eq = false
      while i < n
        c = b.unsafe_fetch(i)
        if c == 0x22_u8 || c == 0x27_u8 # '"' / '\'' quoted value (to the matching quote or EOL)
          quote = c
          start = i
          i += 1
          while i < n && b.unsafe_fetch(i) != quote
            i += 1
          end
          i += 1 if i < n # include the closing quote
          spans << Span.new(seg.byte_slice(start, {i, n}.min - start), Theme.syn_string)
          after_eq = false
        elsif c == 0x3d_u8 # '='
          spans << Span.new(seg.byte_slice(i, 1), Theme.muted)
          i += 1
          after_eq = true
        elsif c == 0x2f_u8 # '/' self-closing
          spans << Span.new(seg.byte_slice(i, 1), Theme.muted)
          i += 1
        elsif tag_name?(c)
          start = i
          i += 1
          while i < n && tag_name?(b.unsafe_fetch(i))
            i += 1
          end
          spans << Span.new(seg.byte_slice(start, i - start), after_eq ? Theme.text : Theme.syn_number)
          after_eq = false
        else
          start = i
          i += 1
          while i < n
            d = b.unsafe_fetch(i)
            break if d == 0x22_u8 || d == 0x27_u8 || d == 0x3d_u8 || d == 0x2f_u8 || tag_name?(d)
            i += 1
          end
          spans << Span.new(seg.byte_slice(start, i - start), Theme.text)
          after_eq = false
        end
      end
      spans
    end

    # A tag-name byte: ASCII letter/digit or one of `- _ :`.
    private def self.tag_name?(x : UInt8) : Bool
      ascii_letter?(x) || ascii_digit?(x) || x == 0x2d_u8 || x == 0x5f_u8 || x == 0x3a_u8
    end

    # --- helpers -------------------------------------------------------------

    # Whether every byte is printable ASCII (0x20..0x7e), so the string is all width-1
    # glyphs with one byte per displayed cell. Lets `draw` skip grapheme clustering +
    # `grapheme_width` + per-glyph `g.to_s` on the common HTTP-text span. A control byte
    # (< 0x20 / 0x7f) or any byte >= 0x80 (a multibyte lead/continuation, or a codepoint
    # whose display width may be 0/2) falls through to the exact grapheme-walk path. Empty
    # string is trivially true (the fast path then draws nothing, matching each_grapheme).
    private def self.printable_ascii?(s : String) : Bool
      s.to_slice.all? { |b| b >= 0x20_u8 && b <= 0x7e_u8 }
    end

    private def self.plain(raw : String) : Line
      [Span.new(raw, Theme.text)]
    end

    private def self.blank : Line
      Array(Span).new
    end

    private def self.to_lines(bytes : Bytes?) : Array(String)
      return [] of String unless bytes
      # `.scrub` maps invalid UTF-8 to U+FFFD (width-1, printable) so a body with stray
      # bytes never feeds raw invalid sequences into width/search math — mirrors the
      # `.scrub` the Fuzzer/Repeater/Comparer views already apply on their byte→line seam.
      String.new(bytes).scrub.split('\n').map(&.rstrip('\r'))
    end

    # The media type from the first `Content-Type` header, lowercased and
    # stripped of parameters. Scans only the header block (stops at the first
    # blank line) so a body that happens to contain the word never matches.
    private def self.content_type_in(lines : Array(String)) : String?
      lines.each do |line|
        break if line.empty?
        colon = line.index(':')
        next unless colon
        next unless line[0...colon].downcase == "content-type"
        value = line[colon + 1..].strip.downcase
        semi = value.index(';')
        return semi ? value[0...semi].strip : value
      end
      nil
    end

    private def self.body_kind(content_type : String?) : Symbol
      return :text unless ct = content_type
      return :json if ct.includes?("json")
      return :form if ct.includes?("x-www-form-urlencoded")
      return :xml if ct.includes?("xml")
      return :html if ct.includes?("html")
      :text
    end
  end
end
