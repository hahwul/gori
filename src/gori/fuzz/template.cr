module Gori::Fuzz
  # A base request with marked payload positions. The marked TEXT is the single
  # source of truth (re-parsed each run), so it stays robust to edits — gori's
  # TextArea has no selection model. Markers are Burp/ffuf-style `§…§`; `§§` is a
  # literal `§`; an unbalanced trailing `§` is treated as literal text. The text
  # between a marker pair is that position's DEFAULT (used for inactive positions in
  # Sniper, and as the seed the user edits over).
  #
  # The template keeps wire-form CRLF line endings so `render` produces a sendable
  # request byte-for-byte (only the payload spans differ between variations). Binary
  # request bodies can't be carried as text — the same limit the Replay editor has;
  # the byte-exact path remains `gori run replay` / export.
  struct Template
    MARKER = '§'

    record Position, index : Int32, default : String

    getter segments : Array(String) # literal runs; size == positions.size + 1
    getter positions : Array(Position)
    getter? http2 : Bool

    def initialize(@segments : Array(String), @positions : Array(Position), @http2 : Bool)
    end

    def self.parse(marked : String, http2 : Bool = false) : Template
      segs = [] of String
      defs = [] of String
      lit = IO::Memory.new
      chars = marked.chars
      n = chars.size
      i = 0
      while i < n
        c = chars[i]
        if c == MARKER
          if chars[i + 1]? == MARKER # escaped literal §
            lit << MARKER
            i += 2
            next
          end
          segs << lit.to_s
          lit = IO::Memory.new
          j = i + 1
          val = IO::Memory.new
          closed = false
          while j < n
            cj = chars[j]
            if cj == MARKER
              if chars[j + 1]? == MARKER # §§ inside a marker → literal §
                val << MARKER
                j += 2
                next
              end
              closed = true
              break
            end
            val << cj
            j += 1
          end
          if closed
            defs << val.to_s
            i = j + 1
          else # unbalanced trailing § → literal, no position
            lit << MARKER << val.to_s
            i = n
          end
        else
          lit << c
          i += 1
        end
      end
      segs << lit.to_s
      positions = defs.map_with_index { |d, k| Position.new(k, d) }
      new(segs, positions, http2)
    end

    def position_count : Int32
      @positions.size
    end

    def default_payloads : Array(String)
      @positions.map(&.default)
    end

    # Splice payloads into the marked positions. `payloads.size` must equal
    # `position_count`. Bytes are returned BEFORE any Content-Length sync.
    def render(payloads : Array(String)) : Bytes
      io = IO::Memory.new
      io << @segments[0]
      payloads.each_with_index do |p, k|
        io << p
        io << @segments[k + 1]?
      end
      io.to_slice
    end

    # ── Marking helpers (shared by the TUI editor and the CLI) ────────────────────

    # Wrap every query / cookie / urlencoded-or-JSON body VALUE in `§…§`. A no-op if
    # the text already contains any marker (don't double-mark).
    def self.auto_mark(text : String) : String
      return text if text.includes?(MARKER)
      eol = eol_of(text)
      sep = eol + eol
      if bidx = text.index(sep)
        head = text[0, bidx]
        body = text[(bidx + sep.size)..]
      else
        head = text
        body = nil
      end
      hlines = head.split(eol).map_with_index do |line, idx|
        if idx == 0
          mark_query(line)
        elsif header?(line, "cookie")
          mark_cookie(line)
        else
          line
        end
      end
      out = hlines.join(eol)
      out = "#{out}#{sep}#{body && !body.empty? ? mark_body(head, body) : body}" if bidx
      out
    end

    # Toggle a `§…§` marker around the token at char index `cursor`. Inside an
    # existing pair → strip it; on a word → wrap it; on a delimiter/space → insert an
    # empty `§§` so a position can be placed anywhere.
    def self.mark_word(text : String, cursor : Int32) : String
      chars = text.chars
      n = chars.size
      cur = cursor.clamp(0, n)
      if span = enclosing_marker(chars, cur)
        a, b = span
        return String.build { |io| chars.each_with_index { |c, i| io << c unless i == a || i == b } }
      end
      lo = cur
      while lo > 0 && word_char?(chars[lo - 1])
        lo -= 1
      end
      hi = cur
      while hi < n && word_char?(chars[hi])
        hi += 1
      end
      if lo == hi
        "#{chars[0, cur].join}#{MARKER}#{MARKER}#{chars[cur, n - cur].join}"
      else
        "#{chars[0, lo].join}#{MARKER}#{chars[lo, hi - lo].join}#{MARKER}#{chars[hi, n - hi].join}"
      end
    end

    # Strip every marker, leaving the defaults inline (back to the base request).
    def self.clear_markers(text : String) : String
      parse(text).render(parse(text).default_payloads).then { |b| String.new(b) }
    end

    private def self.eol_of(text : String) : String
      text.includes?("\r\n") ? "\r\n" : "\n"
    end

    private def self.header?(line : String, name : String) : Bool
      (colon = line.index(':')) && colon > 0 && line[0...colon].strip.downcase == name ? true : false
    end

    private def self.header_value(head : String, name : String) : String?
      head.each_line do |raw|
        line = raw.chomp
        break if line.empty?
        next unless (colon = line.index(':')) && colon > 0
        return line[(colon + 1)..].strip if line[0...colon].strip.downcase == name
      end
      nil
    end

    # "GET /p?a=1&b=2 HTTP/1.1" → wrap the query values.
    private def self.mark_query(line : String) : String
      parts = line.split(' ')
      return line unless parts.size >= 2
      target = parts[1]
      qidx = target.index('?')
      return line unless qidx
      parts[1] = "#{target[0..qidx]}#{mark_pairs(target[(qidx + 1)..], '&')}"
      parts.join(' ')
    end

    # "Cookie: a=1; b=2" → wrap each cookie value.
    private def self.mark_cookie(line : String) : String
      colon = line.index(':')
      return line unless colon
      "#{line[0..colon]}#{mark_pairs(line[(colon + 1)..], ';')}"
    end

    # Wrap the value after `=` in each `sep`-separated pair (leading space preserved).
    private def self.mark_pairs(s : String, sep : Char) : String
      s.split(sep).map do |pair|
        (eq = pair.index('=')) ? "#{pair[0..eq]}#{MARKER}#{pair[(eq + 1)..]}#{MARKER}" : pair
      end.join(sep)
    end

    private def self.mark_body(head : String, body : String) : String
      ct = (header_value(head, "content-type") || "").downcase
      trimmed = body.strip
      if ct.includes?("urlencoded") || (looks_urlencoded?(body) && !ct.includes?("json"))
        mark_pairs(body, '&')
      elsif ct.includes?("json") || trimmed.starts_with?('{') || trimmed.starts_with?('[')
        mark_json(body)
      else
        body
      end
    end

    private def self.looks_urlencoded?(body : String) : Bool
      body.includes?('=') && !body.includes?('\n') && !body.lstrip.starts_with?('{')
    end

    # Wrap JSON string and number values (best-effort; keys are left alone).
    private def self.mark_json(body : String) : String
      out = body.gsub(/("(?:[^"\\]|\\.)*"\s*:\s*")((?:[^"\\]|\\.)*)(")/) { "#{$1}#{MARKER}#{$2}#{MARKER}#{$3}" }
      out.gsub(/("(?:[^"\\]|\\.)*"\s*:\s*)(-?\d+(?:\.\d+)?)/) { "#{$1}#{MARKER}#{$2}#{MARKER}" }
    end

    private def self.word_char?(c : Char) : Bool
      !c.whitespace? && !"&=?;:/\"'{}[](),§".includes?(c)
    end

    # The {open, close} char indices of the marker pair enclosing `cursor`, else nil.
    # Ignores `§§` subtleties — fine for an interactive toggle.
    private def self.enclosing_marker(chars : Array(Char), cursor : Int32) : {Int32, Int32}?
      marks = [] of Int32
      chars.each_index { |i| marks << i if chars[i] == MARKER }
      k = 0
      while k + 1 < marks.size
        return {marks[k], marks[k + 1]} if marks[k] <= cursor && cursor <= marks[k + 1]
        k += 2
      end
      nil
    end
  end
end
