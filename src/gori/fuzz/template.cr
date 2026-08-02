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
  # request byte-for-byte (only the payload spans differ between variations).
  #
  # `parse` and `render` are BYTE-oriented, so a request body that is not valid UTF-8
  # survives them intact. They used to iterate `marked.chars`, and Crystal's char iteration
  # substitutes U+FFFD for every invalid byte — so a captured body carrying a raw 0x80-0xFF
  # run (a protobuf/gRPC frame, a gzip'd or otherwise binary POST, a latin-1 form field) came
  # out of `render` with each of those bytes replaced by a THREE-byte replacement character.
  # Every request the sweep sent was a different length from the one the operator seeded it
  # with, under a Content-Length recomputed to match the corruption, and nothing said so.
  # Scrubbing at load time only moves that corruption earlier; this is where it has to stop.
  struct Template
    MARKER = '§'
    # Value|chain delimiter inside a marker: `§value¦chain§`. NOT '|' — the Decoder
    # chain syntax already uses '|'/','/'>'  as step separators, so the boundary must
    # be a char the chain never contains. `¦¦` escapes a literal `¦`, mirroring `§§`.
    CHAIN_SEP = '¦'

    # UTF-8 encodings of the two delimiters, for the byte scan. Matching these two-byte
    # sequences is exactly as precise as matching the chars was: UTF-8 is self-synchronizing
    # and 0xC2 is a LEAD byte, never a continuation (continuations are 0x80..0xBF), so
    # `C2 A7` inside well-formed text can only ever be `§`.
    MARKER_BYTES    = Bytes[0xC2_u8, 0xA7_u8]
    CHAIN_SEP_BYTES = Bytes[0xC2_u8, 0xA6_u8]

    record Position, index : Int32, default : String, chain : String = ""

    getter segments : Array(String) # literal runs; size == positions.size + 1
    getter positions : Array(Position)
    getter? http2 : Bool

    def initialize(@segments : Array(String), @positions : Array(Position), @http2 : Bool)
    end

    # The result of scanning one marker's interior (see scan_interior): the decoded
    # {default, chain}, whether a chain part was opened (a bare `¦` seen — needed to
    # rebuild an unbalanced marker faithfully), whether the closing § was found, and the
    # BYTE index just past the closing § (or n when unbalanced).
    private record InteriorScan, default : String, chain : String,
      chained : Bool, closed : Bool, next_i : Int32

    # Branch-for-branch the scan it has always been — escaped `§§`, the `¦` value|chain
    # split, the unbalanced-trailing-`§` tail-fold — over BYTES rather than chars, so a
    # non-UTF-8 body passes through untouched. Every offset here is a byte offset; the
    # CHARACTER offsets the TUI highlight needs stay in `marked_spans`, which reads the
    # editor's (already well-formed) text.
    def self.parse(marked : String, http2 : Bool = false) : Template
      segs = [] of String
      defs = [] of {String, String} # {default, chain}
      lit = IO::Memory.new
      bytes = marked.to_slice
      n = bytes.size
      i = 0
      while i < n
        if !marker_at?(bytes, i)
          lit.write_byte(bytes[i])
          i += 1
        elsif marker_at?(bytes, i + 2) # escaped literal §
          lit.write(MARKER_BYTES)
          i += 4
        else
          s = scan_interior(bytes, i, n)
          if s.closed
            segs << String.new(lit.to_slice)
            lit = IO::Memory.new
            defs << {s.default, s.chain}
          else # unbalanced trailing § → literal text, opens no position (no truncation:
            # the § + interior fold into `lit` so render's positions.size+1 segments keep it)
            lit.write(MARKER_BYTES)
            lit << s.default
            if s.chained
              lit.write(CHAIN_SEP_BYTES)
              lit << s.chain
            end
          end
          i = s.next_i
        end
      end
      segs << String.new(lit.to_slice)
      positions = defs.map_with_index { |(d, ch), k| Position.new(k, d, ch) }
      new(segs, positions, http2)
    end

    # Is the two-byte `§` encoding at byte offset `i`? Bounds-checked, so it answers false
    # rather than raising at the end of the slice (the `chars[i + 1]?` this replaced).
    private def self.marker_at?(bytes : Bytes, i : Int32) : Bool
      i >= 0 && i + 1 < bytes.size && bytes[i] == 0xC2_u8 && bytes[i + 1] == 0xA7_u8
    end

    private def self.chain_sep_at?(bytes : Bytes, i : Int32) : Bool
      i >= 0 && i + 1 < bytes.size && bytes[i] == 0xC2_u8 && bytes[i + 1] == 0xA6_u8
    end

    # Scan from the opening § at byte offset `open` to the matching close, decoding `§§`→§
    # and `¦¦`→¦; the first bare `¦` splits the interior into value|chain. Returns the decoded
    # parts even when unbalanced (closed: false), so parse can fold them back as literal.
    private def self.scan_interior(bytes : Bytes, open : Int32, n : Int32) : InteriorScan
      j = open + 2
      val = IO::Memory.new
      chn = IO::Memory.new
      in_chain = false
      while j < n
        if marker_at?(bytes, j)
          if marker_at?(bytes, j + 2) # §§ inside a marker → literal §
            (in_chain ? chn : val).write(MARKER_BYTES)
            j += 4
            next
          end
          return InteriorScan.new(String.new(val.to_slice), String.new(chn.to_slice), in_chain, true, j + 2)
        elsif chain_sep_at?(bytes, j)
          if chain_sep_at?(bytes, j + 2) # ¦¦ inside a marker → literal ¦
            (in_chain ? chn : val).write(CHAIN_SEP_BYTES)
            j += 4
            next
          end
          in_chain ? chn.write(CHAIN_SEP_BYTES) : (in_chain = true) # 1st bare ¦ splits value|chain; a 2nd is literal
          j += 2
          next
        end
        (in_chain ? chn : val).write_byte(bytes[j])
        j += 1
      end
      InteriorScan.new(String.new(val.to_slice), String.new(chn.to_slice), in_chain, false, n)
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
      render_spans(payloads)[0]
    end

    # `render`, plus the byte span `[start, end)` each payload occupies in the result.
    #
    # The spans exist so a send seam can tell TEMPLATE bytes from PAYLOAD bytes. Everything
    # downstream of here sees one flat request, which is how `$TOKEN` as a payload came to be
    # replaced by the live session token: `Env.expand_bindings` scans the whole message by
    # design, and nothing between the splice and the socket knew which bytes the operator had
    # nominated as the thing under test. Computed here rather than re-derived later because
    # this is the only place that knows — a payload can contain any bytes, including the
    # segment text around it.
    def render_spans(payloads : Array(String)) : {Bytes, Array({Int32, Int32})}
      # Pre-size to the exact output length (segments + payloads, both written once) so a
      # KB-scale request doesn't regrow the default 64B buffer 64→128→…→N every emit on the
      # fuzz build path. bytesize is O(1) and both arrays are tiny (position_count+1); on the
      # parse contract (segments.size == positions.size + 1) the sum is exact, and off-contract
      # it can only OVER-estimate (fewer segments written) — never under, so never a truncation.
      io = IO::Memory.new(@segments.sum(&.bytesize) + payloads.sum(&.bytesize))
      spans = Array({Int32, Int32}).new(payloads.size)
      io << @segments[0]?
      payloads.each_with_index do |p, k|
        start = io.pos.to_i32
        io << p
        # An EMPTY payload gets an empty span rather than none: the list stays 1:1 with
        # `payloads` (a consumer indexes it), and a zero-width range matches nothing.
        spans << {start, io.pos.to_i32}
        io << @segments[k + 1]?
      end
      {io.to_slice, spans}
    end

    # Map each payload through its position's Decoder chain (empty chain = identity),
    # returning a new payload array to feed `render`. A chain that fails on THIS payload — a
    # step that raised on these bytes, or output over MAX_OUT — leaves that value
    # UNTRANSFORMED (Decoder.run never raises). This is the VALUES-only view, for callers that
    # do not report a per-row chain failure — the baseline/calibration seeds and the Repeater
    # preview, which shows the same rendered bytes it sends. A REPORTED fuzz request uses
    # `apply_chains_reported`, which also returns the named reason so the row can carry it
    # rather than passing a wrong-on-the-wire request off as clean.
    #
    # What this must NOT be reached with is a chain that could never run at all — an unknown
    # token, or a saved chain the library registered as unusable (recursive, past MAX_TOKENS).
    # Those are a property of the TEMPLATE, not of a payload, so they are refused once at
    # `Fuzz::Plan.build` (`refuse_unusable_chains`) before the first dial. What is left is
    # genuinely per-payload — `base64-decode` over a payload that isn't base64, `shell-escape`
    # over a non-UTF-8 payload — where the next payload may well succeed and there is nothing
    # to refuse up front. Decoder works on Bytes but the template splices Strings, so the
    # transformed bytes are rewrapped with String.new — encoders (base64/url/hex/hash/escape)
    # stay ASCII; a decoder that produces raw bytes may lose fidelity, the same limit binary
    # bodies already have.
    def apply_chains(payloads : Array(String), registry : Decoder::Registry) : Array(String)
      apply_chains_reported(payloads, registry).map(&.[0])
    end

    # Like `apply_chains`, but returns `{value, chain_error}` per payload: the transformed
    # value AND — when the chain FAILED on THIS payload — the named reason it did not run
    # (nil when it ran, or when there was no chain). The value in the failing case is the
    # payload UNTRANSFORMED, a different request than the operator declared, so the reason
    # rides out with it: a per-request `Fuzz::Result` already carries `error`/`retried`, so
    # `chain_error` lands beside them and is counted in the run's error tally rather than
    # swallowed under `0 errors` (#567/H3 Finding 1). Kept separate from `apply_chains` so the
    # Repeater preview and baseline seeds — which have no per-row surface — need no change.
    def apply_chains_reported(payloads : Array(String), registry : Decoder::Registry) : Array({String, String?})
      payloads.map_with_index do |p, k|
        spec = @positions[k]?.try(&.chain)
        next {p, nil} if spec.nil? || spec.empty?
        res = Decoder.run(registry, p.to_slice, spec)
        if res.ok? && (o = res.output)
          {String.new(o), nil}
        else
          {p, chain_failure_reason(spec, res)}
        end
      end
    end

    # A named, operator-facing reason a chain did not run on a payload, in the shape
    # `gori run decoder` already prints one screen away — "chain '<spec>' step '<name>'
    # failed: <message>" — so the row says WHY the payload went out raw, not merely that it
    # did. Read-only over Decoder's public `ChainResult` (the codec package owns that struct).
    private def chain_failure_reason(spec : String, res : Decoder::ChainResult) : String
      if (i = res.failed_at) && (step = res.steps[i]?)
        detail = step.error || (step.state.unknown? ? "unknown converter" : "failed")
        "chain '#{spec}' step '#{step.name}' failed: #{detail}"
      else
        "chain '#{spec}' produced no output"
      end
    end

    # ── Marking helpers (shared by the TUI editor and the CLI) ────────────────────

    # PROVENANCE, for a SEED path: neutralise every `§` in bytes that arrived off the WIRE,
    # by doubling it into the `§§` escape `parse` already folds back to a single literal `§`.
    #
    # `§` is U+00A7 — ordinary text, ubiquitous in German and legal bodies — so a capture
    # carries it for reasons that have nothing to do with gori. Dropped into a template
    # buffer raw, a captured `§…§` pair IS the injection-position syntax: the site's own
    # text becomes a position nobody marked, and a run replaces it with every payload in the
    # set. Escaping keeps the bytes (`render` puts the single `§` back on the wire) and
    # leaves the buffer honest — the operator can still delete a `§` to mark it deliberately.
    #
    # Returns `raw` ITSELF when there is no `§` in it, so the overwhelmingly common seed is
    # byte-identical and allocation-free.
    def self.escape_literal_markers(raw : Bytes) : Bytes
      return raw unless marker_bytes_in?(raw)
      io = IO::Memory.new(raw.size + 8)
      i = 0
      while i < raw.size
        if raw[i] == MARKER_BYTES[0] && i + 1 < raw.size && raw[i + 1] == MARKER_BYTES[1]
          io.write(MARKER_BYTES) # §§ — one literal § again after `parse`
          io.write(MARKER_BYTES)
          i += 2
        else
          io.write_byte(raw[i])
          i += 1
        end
      end
      io.to_slice
    end

    # True when `raw` holds the two-byte UTF-8 encoding of `§`. A BYTE scan, so a buffer
    # carrying invalid UTF-8 is never walked as chars (`String#includes?('§')` would be, and
    # this is asked about captured request bytes). As precise as the char test: UTF-8 is
    # self-synchronizing and 0xC2 is a lead byte, never a continuation.
    def self.marker_bytes_in?(raw : Bytes) : Bool
      i = 0
      while i < raw.size - 1
        return true if raw[i] == MARKER_BYTES[0] && raw[i + 1] == MARKER_BYTES[1]
        i += 1
      end
      false
    end

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
    #
    # `chars` decides WHERE the marker goes; the returned text is spliced out of `text`
    # itself. See the BYTE-SAFETY note under `split_raw_interior` for why the two are not
    # the same thing.
    def self.mark_word(text : String, cursor : Int32) : String
      chars = text.chars
      n = chars.size
      cur = cursor.clamp(0, n)
      if span = enclosing_marker(chars, cur)
        a, b = span
        # Drop the whole marker: both `§` AND any `¦chain` (keep only the raw value),
        # else unmarking `§v¦b64§` would leave a stray `v¦b64`.
        value, _ = split_raw_interior(chars[(a + 1)...b])
        return "#{text[0, a]}#{text[a + 1, value.size]}#{text[(b + 1)..]}"
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
        text # on a delimiter/space: no token to wrap (a bare §§ would parse as an escaped literal §, not a position)
      else
        "#{text[0, lo]}#{MARKER}#{text[lo, hi - lo]}#{MARKER}#{text[hi..]}"
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
      # The value is spliced out of `text`, never rebuilt from its chars — see the
      # BYTE-SAFETY note under `split_raw_interior`. (`escape_chain` runs on the CHAIN,
      # which is a converter spec the operator typed, not captured bytes.)
      raw_value = text[a + 1, value.size]
      interior = clean.empty? ? raw_value : "#{raw_value}#{CHAIN_SEP}#{escape_chain(clean)}"
      "#{text[0, a + 1]}#{interior}#{text[close..]}"
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
      # Spliced out of `text` — see the BYTE-SAFETY note under `split_raw_interior`.
      new_text = "#{text[0, a]}#{text[a + 1, value.size]}#{text[b..]}"
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
    #
    # BYTE SAFETY — read before touching a marking helper. Its callers use only the
    # `.size` of what comes back, never the chars themselves, and that is the rule the
    # whole marking layer follows: a `text.chars` array may decide WHERE a boundary is,
    # but the text handed back must be spliced out of the ORIGINAL String (`text[a, n]`,
    # which copies bytes), never rebuilt with `.join` — and never passed through
    # `String#gsub`, which walks chars just the same. Crystal's char iteration substitutes
    # U+FFFD for every byte that is not valid UTF-8, so a `chars.join` rebuild turns each
    # such byte into the THREE bytes of the replacement character. `parse`/`render` were
    # made byte-oriented for exactly this reason (see the header); `mark_word`,
    # `strip_marker` and `set_chain` were not, and ^K on a token in a captured binary
    # request rewrote the rest of that request — measured, on `x=1 bin=<ff fe 01 02>`:
    # `ff fe` came back as `ef bf bd ef bf bd`, +4 bytes under a Content-Length that then
    # resynced to the corruption. `auto_mark` below was always safe and is the model:
    # it slices the String, it does not walk it.
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
