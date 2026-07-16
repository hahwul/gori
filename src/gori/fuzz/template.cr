require "../decoder"

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
  # request bodies can't be carried as text — the same limit the Repeater editor has;
  # the byte-exact path remains `gori run repeater` / export.
  struct Template
    MARKER = '§'
    # Value|chain delimiter inside a marker: `§value¦chain§`. NOT '|' — the Decoder
    # chain syntax already uses '|'/','/'>'  as step separators, so the boundary must
    # be a char the chain never contains. `¦¦` escapes a literal `¦`, mirroring `§§`.
    CHAIN_SEP = '¦'

    record Position, index : Int32, default : String, chain : String = ""

    getter segments : Array(String) # literal runs; size == positions.size + 1
    getter positions : Array(Position)
    getter? http2 : Bool

    def initialize(@segments : Array(String), @positions : Array(Position), @http2 : Bool)
    end

    # The result of scanning one marker's interior (see scan_interior): the decoded
    # {default, chain}, whether a chain part was opened (a bare `¦` seen — needed to
    # rebuild an unbalanced marker faithfully), whether the closing § was found, and the
    # index just past the closing § (or n when unbalanced).
    private record InteriorScan, default : String, chain : String,
      chained : Bool, closed : Bool, next_i : Int32

    def self.parse(marked : String, http2 : Bool = false) : Template
      segs = [] of String
      defs = [] of {String, String} # {default, chain}
      lit = IO::Memory.new
      chars = marked.chars
      n = chars.size
      i = 0
      while i < n
        c = chars[i]
        if c != MARKER
          lit << c
          i += 1
        elsif chars[i + 1]? == MARKER # escaped literal §
          lit << MARKER
          i += 2
        else
          s = scan_interior(chars, i, n)
          if s.closed
            segs << lit.to_s
            lit = IO::Memory.new
            defs << {s.default, s.chain}
          else # unbalanced trailing § → literal text, opens no position (no truncation:
            # the § + interior fold into `lit` so render's positions.size+1 segments keep it)
            lit << MARKER << s.default
            lit << CHAIN_SEP << s.chain if s.chained
          end
          i = s.next_i
        end
      end
      segs << lit.to_s
      positions = defs.map_with_index { |(d, ch), k| Position.new(k, d, ch) }
      new(segs, positions, http2)
    end

    # Scan from the opening § at `open` to the matching close, decoding `§§`→§ and
    # `¦¦`→¦; the first bare `¦` splits the interior into value|chain. Returns the decoded
    # parts even when unbalanced (closed: false), so parse can fold them back as literal.
    private def self.scan_interior(chars : Array(Char), open : Int32, n : Int32) : InteriorScan
      j = open + 1
      val = IO::Memory.new
      chn = IO::Memory.new
      in_chain = false
      while j < n
        cj = chars[j]
        if cj == MARKER
          if chars[j + 1]? == MARKER # §§ inside a marker → literal §
            (in_chain ? chn : val) << MARKER
            j += 2
            next
          end
          return InteriorScan.new(val.to_s, chn.to_s, in_chain, true, j + 1)
        elsif cj == CHAIN_SEP
          if chars[j + 1]? == CHAIN_SEP # ¦¦ inside a marker → literal ¦
            (in_chain ? chn : val) << CHAIN_SEP
            j += 2
            next
          end
          in_chain ? (chn << CHAIN_SEP) : (in_chain = true) # 1st bare ¦ splits value|chain; a 2nd is literal
          j += 1
          next
        end
        (in_chain ? chn : val) << cj
        j += 1
      end
      InteriorScan.new(val.to_s, chn.to_s, in_chain, false, n)
    end

    def position_count : Int32
      @positions.size
    end

    # The `[start, end)` CHARACTER offsets (into `text`) of every CLOSED `§…§`
    # region, in marker order, INCLUDING both `§` delimiters. 1:1 with
    # `parse(text).positions` — same `§§`-escape and unbalanced-trailing-§ rules — so
    # a highlight built from these covers exactly the bytes that get fuzzed. An
    # unbalanced trailing `§` yields NO span (parse folds it into literal text).
    # Offsets index `text.chars`; feed the SAME LF-joined string the editor holds
    # (`TextArea#text`), never the CRLF wire form. (Used for the TUI marker tint; the
    # scan is branch-for-branch identical to `parse` above, minus the literal building,
    # so `render`'s byte-exact path stays untouched.)
    def self.marked_spans(text : String) : Array({Int32, Int32})
      spans = [] of {Int32, Int32}
      chars = text.chars
      n = chars.size
      i = 0
      while i < n
        if chars[i] == MARKER
          if chars[i + 1]? == MARKER # escaped literal § — not an opener
            i += 2
            next
          end
          open = i
          j = i + 1
          closed = false
          while j < n
            if chars[j] == MARKER
              if chars[j + 1]? == MARKER # §§ inside a marker → literal §
                j += 2
                next
              end
              closed = true
              break
            end
            j += 1
          end
          if closed
            spans << {open, j + 1} # [§ … §] inclusive of both delimiters
            i = j + 1
          else
            break # unbalanced trailing § opens no position (matches parse's tail-fold)
          end
        else
          i += 1
        end
      end
      spans
    end

    def default_payloads : Array(String)
      @positions.map(&.default)
    end

    # Splice payloads into the marked positions. `payloads.size` must equal
    # `position_count`. Bytes are returned BEFORE any Content-Length sync.
    def render(payloads : Array(String)) : Bytes
      # Pre-size to the exact output length (segments + payloads, both written once) so a
      # KB-scale request doesn't regrow the default 64B buffer 64→128→…→N every emit on the
      # fuzz build path. bytesize is O(1) and both arrays are tiny (position_count+1); on the
      # parse contract (segments.size == positions.size + 1) the sum is exact, and off-contract
      # it can only OVER-estimate (fewer segments written) — never under, so never a truncation.
      io = IO::Memory.new(@segments.sum(&.bytesize) + payloads.sum(&.bytesize))
      io << @segments[0]
      payloads.each_with_index do |p, k|
        io << p
        io << @segments[k + 1]?
      end
      io.to_slice
    end

    # Map each payload through its position's Decoder chain (empty chain = identity),
    # returning a new payload array to feed `render`. A chain that fails — an unknown
    # token, a step that raised, or output over MAX_OUT — leaves that value
    # UNTRANSFORMED: Decoder.run never raises, and a streaming fuzz run has nowhere to
    # surface a per-position error (validate chains in the Decoder tab). Decoder works
    # on Bytes but the template splices Strings, so the transformed bytes are rewrapped
    # with String.new — encoders (base64/url/hex/hash/escape) stay ASCII; a decoder that
    # produces raw bytes may lose fidelity, the same limit binary bodies already have.
    def apply_chains(payloads : Array(String), registry : Decoder::Registry) : Array(String)
      payloads.map_with_index do |p, k|
        spec = @positions[k]?.try(&.chain)
        next p if spec.nil? || spec.empty?
        res = Decoder.run(registry, p.to_slice, spec)
        (res.ok? && (o = res.output)) ? String.new(o) : p
      end
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
    # existing pair → strip it; on a word → wrap it; on a delimiter/space → unchanged
    # (a bare `§§` would parse as an escaped literal §, so empty positions aren't made
    # this way — use auto_mark or type the default between the markers).
    def self.mark_word(text : String, cursor : Int32) : String
      chars = text.chars
      n = chars.size
      cur = cursor.clamp(0, n)
      if span = enclosing_marker(chars, cur)
        a, b = span
        # Drop the whole marker: both `§` AND any `¦chain` (keep only the raw value),
        # else unmarking `§v¦b64§` would leave a stray `v¦b64`.
        value, _ = split_raw_interior(chars[(a + 1)...b])
        return "#{chars[0, a].join}#{value.join}#{chars[(b + 1)..].join}"
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
        chars.join # on a delimiter/space: no token to wrap (a bare §§ would parse as an escaped literal §, not a position)
      else
        "#{chars[0, lo].join}#{MARKER}#{chars[lo, hi - lo].join}#{MARKER}#{chars[hi, n - hi].join}"
      end
    end

    # Strip every marker, leaving the defaults inline (back to the base request).
    # Chains are dropped too — `render(default_payloads)` emits only the defaults.
    def self.clear_markers(text : String) : String
      tmpl = parse(text)
      String.new(tmpl.render(tmpl.default_payloads))
    end

    # The Decoder-chain string of the `§…§` marker enclosing char index `cursor`, or
    # nil when the cursor isn't inside a closed marker. Seeds the chain-edit overlay.
    def self.chain_at(text : String, cursor : Int32) : String?
      idx = marked_spans(text).index { |(a, b)| a <= cursor && cursor <= b }
      return nil unless idx
      parse(text).positions[idx]?.try(&.chain)
    end

    # The DEFAULT value (the `§value§` payload, unescaped) of the marker enclosing char
    # index `cursor`, or nil when the cursor isn't in a closed marker. Feeds the ^Y chain
    # overlay's transform preview (value → chain → output).
    def self.value_at(text : String, cursor : Int32) : String?
      idx = marked_spans(text).index { |(a, b)| a <= cursor && cursor <= b }
      return nil unless idx
      parse(text).positions[idx]?.try(&.default)
    end

    # Char index of the OPEN `§` of the marker enclosing `cursor`, or nil. The value region
    # [open, ¦) is untouched by a chain edit, so this is a stable, edit-safe anchor to
    # restore the caret to after the ^Y overlay rewrites the chain.
    def self.marker_start_at(text : String, cursor : Int32) : Int32?
      marked_spans(text).find { |(a, b)| a <= cursor && cursor <= b }.try(&.[0])
    end

    # Replace/insert/remove the chain of the marker enclosing `cursor`, returning the
    # new text (nil when the cursor isn't inside a marker). An empty `chain` removes
    # the `¦…` entirely. The raw default bytes are kept verbatim; the new chain has any
    # literal `§`/`¦` escaped so it round-trips through `parse`.
    def self.set_chain(text : String, cursor : Int32, chain : String) : String?
      chars = text.chars
      span = marked_spans(text).find { |(a, b)| a <= cursor && cursor <= b }
      return nil unless span
      a, b = span
      close = b - 1 # index of the closing §
      value, _ = split_raw_interior(chars[(a + 1)...close])
      clean = chain.strip
      interior = clean.empty? ? value.join : "#{value.join}#{CHAIN_SEP}#{escape_chain(clean)}"
      "#{chars[0, a + 1].join}#{interior}#{chars[close..].join}"
    end

    # The closed `§…§` span `{a, b}` (b == closing-§ index + 1) whose STRUCTURE the
    # char at char-index `idx` belongs to — an opening/closing `§`, the `¦` value|chain
    # separator, or an escaped `§§`/`¦¦` delimiter half inside — or nil when `idx` isn't
    # such a char. Deleting any of these unbalances the marker (and exposes its concealed
    # `¦chain`), so the TUI editor guards a backspace/forward-delete of them behind a
    # confirm. A normal value byte, or a `§`/`¦` OUTSIDE every closed marker (e.g. an
    # escaped literal that folds to plain text), returns nil. `spans` defaults to a fresh
    # `marked_spans`; pass the view's cached one to skip a re-scan.
    def self.structural_marker_at(text : String, idx : Int32,
                                  spans : Array({Int32, Int32}) = marked_spans(text)) : {Int32, Int32}?
      return nil if idx < 0
      c = text[idx]?
      return nil unless c == MARKER || c == CHAIN_SEP
      spans.find { |(a, b)| a <= idx && idx < b } # b == close + 1, so this covers [a, close]
    end

    # Whether inserting `ch` at char-index `cursor` would drop a NEW `§`/`¦` into (or
    # flush against) an existing closed marker `[a, b]` — i.e. `a <= cursor <= b` — which a
    # plain insert would turn into a "marker in marker" / stray escape and unbalance the
    # structure. The editor escapes such a char (`§§`/`¦¦`) so it survives as a literal in
    # the value instead. Chars that can't be delimiters, and inserts in the open space
    # BETWEEN markers, return false (so typing a fresh `§…§` by hand still works). `spans`
    # defaults to a fresh scan; pass the cached one to skip it.
    def self.insert_breaks_marker?(text : String, cursor : Int32, ch : Char,
                                   spans : Array({Int32, Int32}) = marked_spans(text)) : Bool
      return false unless ch == MARKER || ch == CHAIN_SEP
      spans.any? { |(a, b)| a <= cursor && cursor <= b }
    end

    # Remove the closed marker at `span` (`{a, b}`: a = opening §, b-1 = closing §),
    # leaving ONLY its raw value — both `§` delimiters AND any `¦chain` are dropped
    # (mirrors `mark_word`'s unmark branch). Returns `{new_text, caret}` with the caret at
    # the char offset just past the freed value. Fed by the delimiter-delete confirm.
    def self.strip_marker(text : String, span : {Int32, Int32}) : {String, Int32}
      chars = text.chars
      a, b = span
      close = b - 1
      value, _ = split_raw_interior(chars[(a + 1)...close])
      new_text = "#{chars[0, a].join}#{value.join}#{chars[b..].join}"
      {new_text, a + value.size}
    end

    # Per closed marker: {open, sep, close} char offsets — `open`/`close` index the two
    # `§`, and `sep` is the value|chain boundary `¦` (== `close` when there's no chain).
    # Lets the views tint the value and the (dimmer) chain separately; 1:1 with
    # `positions` / `marked_spans`.
    # `spans` defaults to a fresh `marked_spans(text)`; pass a cached one (views memoize it on
    # the editor revision) so a cache-miss here does ONE `text.chars` instead of two.
    def self.marker_regions(text : String, spans : Array({Int32, Int32}) = marked_spans(text)) : Array({Int32, Int32, Int32})
      chars = text.chars
      spans.map do |(a, b)|
        close = b - 1
        value, chain = split_raw_interior(chars[(a + 1)...close])
        sep = chain.nil? ? close : (a + 1 + value.size)
        {a, sep, close}
      end
    end

    # Split a marker's RAW interior chars at the first UNESCAPED `¦` into
    # {value, chain}. `§§` and `¦¦` are escapes (skip both), so an escaped `¦` isn't a
    # boundary. `chain` is nil when the marker carries no chain.
    private def self.split_raw_interior(interior : Array(Char)) : {Array(Char), Array(Char)?}
      i = 0
      n = interior.size
      while i < n
        c = interior[i]
        if (c == MARKER && interior[i + 1]? == MARKER) || (c == CHAIN_SEP && interior[i + 1]? == CHAIN_SEP)
          i += 2
          next
        elsif c == CHAIN_SEP
          return {interior[0, i], interior[(i + 1)..]}
        end
        i += 1
      end
      {interior, nil}
    end

    private def self.escape_chain(s : String) : String
      s.gsub(MARKER, "#{MARKER}#{MARKER}").gsub(CHAIN_SEP, "#{CHAIN_SEP}#{CHAIN_SEP}")
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
    # An EMPTY value (`a=`) is left unmarked: a bare `§§` parses as an escaped literal
    # § (injecting a stray byte and creating no position), so empty values can't be
    # auto-marked — wrap them by hand with an explicit default if you want to fuzz them.
    private def self.mark_pairs(s : String, sep : Char) : String
      s.split(sep).map do |pair|
        (eq = pair.index('=')) && eq + 1 < pair.size ? "#{pair[0..eq]}#{MARKER}#{pair[(eq + 1)..]}#{MARKER}" : pair
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

    # Wrap JSON string and number values (best-effort; keys are left alone). An
    # EMPTY string value (`"k":""`) is skipped — `§§` would parse as a literal § and
    # inject a stray byte (also producing invalid JSON), so empty values stay inert.
    private def self.mark_json(body : String) : String
      out = body.gsub(/("(?:[^"\\]|\\.)*"\s*:\s*")((?:[^"\\]|\\.)*)(")/) do |m|
        $2.empty? ? m : "#{$1}#{MARKER}#{$2}#{MARKER}#{$3}"
      end
      out = out.gsub(/("(?:[^"\\]|\\.)*"\s*:\s*)(-?\d+(?:\.\d+)?)/) { "#{$1}#{MARKER}#{$2}#{MARKER}" }
      # Also mark boolean/null scalar values so `--auto` exercises flag-style fields
      # (e.g. "admin":true) as documented. (Array-element values are still unmarked.)
      out.gsub(/("(?:[^"\\]|\\.)*"\s*:\s*)(true|false|null)\b/) { "#{$1}#{MARKER}#{$2}#{MARKER}" }
    rescue ArgumentError
      # An invalid-UTF-8 body (e.g. a repeater seeded from a captured non-UTF-8 JSON request) makes
      # the PCRE gsub raise; leave it unmarked rather than crash the TUI auto-mark — and do NOT
      # scrub, because this template is re-sent and its bytes must stay exact (P7).
      body
    end

    private def self.word_char?(c : Char) : Bool
      !c.whitespace? && !"&=?;:/\"'{}[](),§¦".includes?(c)
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
