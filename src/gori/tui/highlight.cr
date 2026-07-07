require "./screen"
require "./theme"
require "../env"
require "termisu"

module Gori::Tui
  # Syntax highlighting for the request/response panes (History detail, Replay,
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
    # History detail and Replay response shapes): styled head, then exactly ONE
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

    # A message split for WINDOWED rendering: the head is small and pre-styled, but
    # the body can be up to the 8 MiB capture cap (100k+ lines), so it's returned as
    # RAW lines + the body `kind`. The caller styles only the visible window via
    # `body_styled` — opening a huge response then never freezes the UI highlighting
    # off-screen lines. `head` includes the blank head/body separator, so the styled
    # output is `head ++ body.map { body_styled }` — identical to `message`.
    record Windowed, head : Array(Line), body : Array(String), kind : Symbol do
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
      Windowed.new(styled, has_body ? to_lines(body) : [] of String, kind)
    end

    # Style a single body line (the public seam for windowed rendering).
    def self.body_styled(raw : String, kind : Symbol) : Line
      body_line(raw, kind)
    end

    # Highlight a message held as one combined text blob (Intercept's byte-exact
    # `raw`, and the Replay/Intercept editors). Splits head from body at the
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
      regions = Env.token_regions(text)
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
        return Windowed.new(head, [] of String, kind)
      end
      head = [] of Line
      all.each_with_index do |raw, i|
        break if i > sep
        head << (i == 0 ? start_line(raw, request) : (i == sep ? blank : header_line(raw)))
      end
      Windowed.new(head, all[(sep + 1)..], kind)
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
      overflow = false
      acc = 0
      line.each do |span|
        span.text.each_grapheme do |g|
          acc += Termisu::UnicodeWidth.grapheme_width(g.to_s)
          if acc > limit
            overflow = true
            break
          end
        end
        break if overflow
      end
      ellipsis = overflow && limit > 1

      visual_col = 0
      line.each do |span|
        break if visual_col >= limit
        span.text.each_grapheme do |g|
          gw = Termisu::UnicodeWidth.grapheme_width(g.to_s)
          room = limit - (ellipsis ? 1 : 0)
          if visual_col + gw > room
            break
          end
          screen.cell(x + visual_col, y, g.to_s, span.fg, bg, span.attr)
          visual_col += gw
        end
        break if visual_col >= limit
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

    # `METHOD target HTTP/x.x` — method coloured by verb, the target bright, the
    # version muted. Spaces are preserved verbatim as their own muted spans so
    # the partition is exact regardless of odd spacing.
    private def self.request_line(raw : String) : Line
      first = raw.index(' ')
      return [Span.new(raw, Theme.method_color(raw), Attribute::Bold)] unless first
      method = raw[0...first]
      spans = [Span.new(method, Theme.method_color(method), Attribute::Bold)]
      last = raw.rindex(' ')
      if last && last > first
        spans << Span.new(raw[first...first + 1], Theme.muted)      # space
        spans << Span.new(raw[first + 1...last], Theme.text_bright) # target
        spans << Span.new(raw[last...last + 1], Theme.muted)        # space
        spans << Span.new(raw[last + 1..], Theme.muted)             # version
      else
        spans << Span.new(raw[first..], Theme.text_bright)
      end
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

    # `Name: value` — field name accented, the colon muted, the value in body
    # text. The first colon is the separator (values may themselves contain ':').
    private def self.header_line(raw : String) : Line
      colon = raw.index(':')
      return plain(raw) unless colon
      spans = [Span.new(raw[0...colon], Theme.syn_header)]
      spans << Span.new(raw[colon...colon + 1], Theme.muted) # ":"
      rest = raw[colon + 1..]
      spans << Span.new(rest, Theme.text) unless rest.empty?
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
      else                  plain(raw)
      end
    end

    # JSON, tokenised per line (valid JSON never splits a string across a raw
    # newline, so a line-local pass is sufficient for both pretty and minified
    # bodies). Object keys (a string immediately followed by ':') are accented
    # distinctly from string values.
    private def self.json_line(raw : String) : Line
      spans = [] of Span
      chars = raw.chars
      n = chars.size
      i = 0
      while i < n
        c = chars[i]
        if c == '"'
          start = i
          i += 1
          while i < n
            if chars[i] == '\\'
              i += 2
            elsif chars[i] == '"'
              i += 1
              break
            else
              i += 1
            end
          end
          str = chars[start...i].join
          k = i
          while k < n && chars[k].ascii_whitespace?
            k += 1
          end
          key = k < n && chars[k] == ':'
          spans << Span.new(str, key ? Theme.syn_header : Theme.syn_string)
        elsif c.ascii_number? || (c == '-' && i + 1 < n && chars[i + 1].ascii_number?)
          start = i
          i += 1
          while i < n && (chars[i].ascii_number? || "+-.eE".includes?(chars[i]))
            i += 1
          end
          spans << Span.new(chars[start...i].join, Theme.syn_number)
        elsif c.ascii_letter?
          start = i
          i += 1
          while i < n && chars[i].ascii_letter?
            i += 1
          end
          word = chars[start...i].join
          spans << Span.new(word, %w(true false null).includes?(word) ? Theme.syn_literal : Theme.text)
        elsif "{}[]:,".includes?(c)
          spans << Span.new(c.to_s, Theme.muted)
          i += 1
        else
          start = i
          i += 1
          while i < n
            d = chars[i]
            break if d == '"' || d.ascii_letter? || d.ascii_number? || "{}[]:,".includes?(d) ||
                     (d == '-' && i + 1 < n && chars[i + 1].ascii_number?)
            i += 1
          end
          spans << Span.new(chars[start...i].join, Theme.text)
        end
      end
      spans
    end

    # `application/x-www-form-urlencoded` — keys accented, `=`/`&` muted, values
    # in body text.
    private def self.form_line(raw : String) : Line
      spans = [] of Span
      chars = raw.chars
      n = chars.size
      i = 0
      expect_key = true
      while i < n
        c = chars[i]
        if c == '&'
          spans << Span.new("&", Theme.muted)
          i += 1
          expect_key = true
        elsif c == '='
          spans << Span.new("=", Theme.muted)
          i += 1
          expect_key = false
        else
          start = i
          while i < n && chars[i] != '&' && chars[i] != '='
            i += 1
          end
          spans << Span.new(chars[start...i].join, expect_key ? Theme.syn_header : Theme.text)
        end
      end
      spans
    end

    # HTML/XML — tag delimiters muted, tag names accented, attributes/text in
    # body text. Line-local: a tag split across lines simply isn't recognised on
    # the continuation line (cosmetic only; text is never altered).
    private def self.markup_line(raw : String) : Line
      spans = [] of Span
      chars = raw.chars
      n = chars.size
      i = 0
      while i < n
        if chars[i] == '<'
          gt = i + 1
          while gt < n && chars[gt] != '>'
            gt += 1
          end
          closed = gt < n # found a '>'
          j = i + 1
          j += 1 if j < n && chars[j] == '/'                # closing tag
          spans << Span.new(chars[i...j].join, Theme.muted) # '<' or '</'
          name = j
          while name < gt && (chars[name].ascii_letter? || chars[name].ascii_number? ||
                chars[name] == '-' || chars[name] == '_' || chars[name] == ':')
            name += 1
          end
          spans << Span.new(chars[j...name].join, Theme.syn_header) if name > j
          spans << Span.new(chars[name...gt].join, Theme.text) if name < gt
          spans << Span.new(">", Theme.muted) if closed
          i = closed ? gt + 1 : gt
        else
          start = i
          i += 1
          while i < n && chars[i] != '<'
            i += 1
          end
          spans << Span.new(chars[start...i].join, Theme.text)
        end
      end
      spans
    end

    # --- helpers -------------------------------------------------------------

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
      # `.scrub` the Fuzzer/Replay/Comparer views already apply on their byte→line seam.
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
