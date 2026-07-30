module Gori
  module Probe
    module Passive
      # Lightweight, structure-aware JavaScript scanning shared by the client-side rules
      # (DOM XSS, DOM clobbering, prototype pollution, postMessage). There is no JS parser in
      # the tree and a per-flow passive scan can't afford one, so this is deliberately a
      # heuristic — NOT a real AST taint analysis. Two services:
      #
      #   * `scripts` extracts the executable JS out of a response: each inline <script> body
      #     from an HTML page, or the whole body of a JS response. Externals (`src=`) and
      #     non-JS <script type> blocks (json/template/importmap) are skipped.
      #   * `strip` blanks out comments and string/template literals, replacing their CONTENTS
      #     with spaces (offsets preserved). What remains is *code*: a sink/source keyword that
      #     lived inside a string or comment ("use innerHTML safely", // TODO location.hash)
      #     can no longer produce a false match, and a rule can still measure source<->sink
      #     proximity on the cleaned text because character indices line up with the original.
      #
      # DOM XSS runs over the STRIPPED code (Context#client_code) so string/comment noise is
      # gone; the string-literal-driven rules (postMessage "message"/"*", prototype-pollution
      # "__proto__" keys) run over the RAW fragments (Context#client_scripts).
      module JsScan
        # Inline <script>…</script>; group 1 = attributes, group 2 = body. `[\s\S]` matches
        # across newlines without depending on the DOTALL flag; non-greedy stops at the first
        # closing tag.
        SCRIPT_BLOCK = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/i
        # A src= attribute (external script — its inline body is empty) or a non-executable
        # <script type> (data/template island, not JS).
        HAS_SRC     = /\bsrc\s*=/i
        NON_JS_TYPE = /\btype\s*=\s*["']?\s*(?:application\/(?:json|ld\+json)|text\/(?:template|html|x-template|x-handlebars-template)|importmap|speculationrules)/i

        # Character window (each side) used to bound a DOM-XSS source<->sink correlation to the
        # same statement. Large enough for a real one-liner, small enough to stay cheap and to
        # not bridge unrelated minified statements.
        WINDOW = 250

        # DOM taint sources. Case-sensitive (JS identifiers are), each a fixed label used only
        # for a safe evidence string (never the tainted value itself).
        SOURCES = [
          {/\blocation\.hash\b/, "location.hash"},
          {/\blocation\.search\b/, "location.search"},
          {/\blocation\.(?:href|pathname)\b/, "location.href"},
          {/\bdocument\.URL\b/, "document.URL"},
          {/\bdocument\.documentURI\b/, "document.documentURI"},
          {/\bdocument\.baseURI\b/, "document.baseURI"},
          {/\bdocument\.referrer\b/, "document.referrer"},
          {/\bdocument\.cookie\b/, "document.cookie"},
          {/\bdocument\.location\b/, "document.location"},
          {/\bwindow\.name\b/, "window.name"},
          {/\bhistory\.state\b/, "history.state"},
          {/\b(?:e|ev|evt|event|msg|message)\.data\b/, "postMessage data"},
          {/\b(?:localStorage|sessionStorage)\.getItem\b/, "web storage"},
          {/\bURLSearchParams\b/, "URLSearchParams"},
        ] of {Regex, String}

        # HTML/JS execution sinks. Each keys on a distinctive identifier so PCRE's first-byte
        # optimisation skips clean code fast (like body_leaks' per-pattern loop). Sinks whose
        # payload is normally a string (setTimeout/eval) still work post-strip: a `foo+source`
        # concatenation leaves `source` as code even after the string half is blanked.
        SINKS = [
          {/\.(?:inner|outer)HTML\s*\+?=(?!=)/, "innerHTML"},
          {/\.insertAdjacentHTML\s*\(/, "insertAdjacentHTML"},
          {/\bdocument\.write(?:ln)?\s*\(/, "document.write"},
          {/\.srcdoc\s*=(?!=)/, "iframe.srcdoc"},
          {/\beval\s*\(/, "eval"},
          {/\bnew\s+Function\s*\(/, "Function"},
          {/\bset(?:Timeout|Interval)\s*\(/, "setTimeout/setInterval"},
          {/\bdangerouslySetInnerHTML\b/, "dangerouslySetInnerHTML"},
          {/\.html\s*\(/, "jQuery.html()"},
        ] of {Regex, String}

        # A random-access `Char` view over ASCII bytes, used instead of `String#chars` on the
        # (overwhelmingly common) all-ASCII script. `chars` builds an `Array(Char)` sized to the
        # script — for a 256 KiB minified bundle that is a ~1 MiB heap allocation, and both strip
        # and strip_comments used to build their own, on every HTML/JS flow, on the fiber the
        # passive scan shares with the proxy.
        #
        # This is a struct wrapping a borrowed slice, so it allocates nothing. For ASCII the two
        # are isomorphic: byte index == char index and `unsafe_chr` on a byte < 0x80 is exactly
        # the Char `chars` would have held, so the lexers below produce byte-identical output.
        # A script with any non-ASCII byte still takes the `chars` path, which keeps this file's
        # char-offset-preserving invariant exactly as documented (blanking a multi-byte char to a
        # single space) rather than trading it for a byte-offset one.
        private struct AsciiChars
          def initialize(@bytes : Bytes)
          end

          def size : Int32
            @bytes.size
          end

          def [](index : Int32) : Char
            @bytes[index].unsafe_chr
          end
        end

        # Executable JS fragments in a response body, RAW (not yet stripped). `html`/`js` come
        # from the Context content-type gates.
        def self.scripts(text : String?, html : Bool, js : Bool) : Array(String)
          return [] of String if text.nil? || text.empty?
          out = [] of String
          if js
            out << text
          elsif html
            text.scan(SCRIPT_BLOCK) do |m|
              attrs = m[1]
              body = m[2]
              next if body.empty?
              next if HAS_SRC.matches?(attrs)     # external script; body is decorative
              next if NON_JS_TYPE.matches?(attrs) # data/template island, not code
              out << body
            end
          end
          out
        end

        # Blank // line comments, /* */ block comments, and '…' / "…" / `…` string literals,
        # replacing their CONTENTS with spaces so byte/char offsets are preserved. A single
        # conservative left-to-right pass. Regex literals are intentionally left intact:
        # telling `/` division from a regex needs a parser, and regex bodies rarely carry our
        # tokens. Every consumed char emits exactly one char, so indices stay aligned.
        def self.strip(js : String) : String
          return js if js.empty?
          scan_source(js) do |chars, n|
            String.build(js.bytesize) do |io|
              i = 0
              while i < n
                if j = blank_token_at(chars, i, n, io, 0)
                  i = j
                else
                  io << chars[i]
                  i += 1
                end
              end
            end
          end
        end

        # Yields the random-access char source for `js` plus its length: a zero-allocation
        # AsciiChars view when the script is all-ASCII, else the `Array(Char)` the lexers have
        # always used. Both satisfy the same `size`/`[]` shape, so the lexers below are compiled
        # for each and neither is special-cased. `ascii_only?` is a single byte pass, far cheaper
        # than the array it avoids.
        private def self.scan_source(js : String, &)
          if js.ascii_only?
            view = AsciiChars.new(js.to_slice)
            yield view, view.size
          else
            chars = js.chars
            yield chars, chars.size
          end
        end

        # Template-literal nesting recurses one frame per level (blank_string →
        # emit_interpolation → blank_token_at → …, and the copy_* mirror of it), and the depth is
        # ATTACKER-CONTROLLED: it is just response-body text. The recursion happens on the way IN,
        # so no closing delimiters are needed — an unterminated "`${" costs 3 bytes per level, and
        # CLIENT_BODY_CAP / 3 = 87381 levels lands past the ~87k frames an 8 MiB fiber stack holds.
        # A Crystal stack overflow is a FATAL SIGNAL, not a rescuable exception, so Analyzer's
        # per-flow `rescue` cannot contain it: one 256 KiB response body took the whole process
        # down (proxy capture, TUI, CLI and MCP alike). The body cap is not a defense here — it
        # sits on the wrong side of the limit — so the lexers cap the nesting themselves.
        #
        # 64 is far past anything real: minifiers do not add template nesting and hand-written
        # code does not go beyond a handful of levels. Past it we blank the rest of the FRAGMENT
        # (see blank_rest) rather than stop descending in place — declining to recurse would let a
        # nested backtick close the enclosing template early and re-lex the remainder, the exact
        # desync copy_string exists to prevent. Blanking is offset-preserving and cannot desync;
        # the cost is that content past 64 levels of nesting is not analyzed, which is the safe
        # direction (a missed lead, never a false one).
        MAX_INTERP_DEPTH = 64

        # Blank every remaining char of the fragment (one space each, offsets preserved) and
        # return the end index, so the caller's `while i < n` loop terminates immediately.
        private def self.blank_rest(chars, i : Int32, n : Int32, io : IO) : Int32
          while i < n
            io << ' '
            i += 1
          end
          n
        end

        # If chars[i] starts a // or /* */ comment, blank it (→ spaces, offsets preserved) and
        # return the index just past it; else nil. Shared by the string- and comment-strip lexers.
        # No `depth`: a comment never recurses.
        private def self.blank_comment_at(chars, i : Int32, n : Int32, io : IO) : Int32?
          c = chars[i]
          if c == '/' && i + 1 < n && chars[i + 1] == '/'
            blank_line_comment(chars, i, n, io)
          elsif c == '/' && i + 1 < n && chars[i + 1] == '*'
            blank_block_comment(chars, i, n, io)
          end
        end

        # If chars[i] starts a // comment, /* */ comment, or a '…'/"…"/`…` string, blank it
        # (contents → spaces, offsets preserved) and return the index just past it; else nil.
        # Shared by strip and emit_interpolation so the token lexing lives in one place.
        # `depth` is the template-interpolation nesting level (see MAX_INTERP_DEPTH).
        private def self.blank_token_at(chars, i : Int32, n : Int32, io : IO, depth : Int32) : Int32?
          if j = blank_comment_at(chars, i, n, io)
            j
          else
            c = chars[i]
            (c == '\'' || c == '"' || c == '`') ? blank_string(chars, i, n, io, depth) : nil
          end
        end

        # Blank ONLY // and /* */ comments, keeping string/template CONTENTS intact (offsets
        # preserved). For the string-literal-keyed rules (postMessage "message"/"*", prototype
        # pollution "__proto__") that need those literals visible but must NOT match keywords
        # inside commented-out example/debug code. Strings are copied verbatim so an embedded
        # `//` or `/*` (e.g. in a URL literal) is not mistaken for a comment.
        def self.strip_comments(js : String) : String
          return js if js.empty?
          scan_source(js) do |chars, n|
            String.build(js.bytesize) do |io|
              i = 0
              while i < n
                c = chars[i]
                i = if c == '/' && i + 1 < n && chars[i + 1] == '/'
                      blank_line_comment(chars, i, n, io)
                    elsif c == '/' && i + 1 < n && chars[i + 1] == '*'
                      blank_block_comment(chars, i, n, io)
                    elsif c == '\'' || c == '"' || c == '`'
                      copy_string(chars, i, n, io, 0)
                    else
                      io << c
                      i + 1
                    end
              end
            end
          end
        end

        # Copy a '…'/"…"/`…` literal verbatim (contents kept), consuming it so an embedded
        # // or /* inside the string is not treated as a comment. Honors \\ escapes. For a
        # template literal, a ${…} interpolation is CODE, not string content — it is consumed
        # via copy_interpolation so a NESTED template's backtick inside ${…} is not mistaken
        # for this template's closing delimiter (which would terminate early and re-lex the
        # real remainder, blanking a URL's // as a comment).
        private def self.copy_string(chars, i : Int32, n : Int32, io : IO, depth : Int32) : Int32
          quote = chars[i]
          io << quote
          i += 1
          while i < n
            ch = chars[i]
            if ch == '\\' && i + 1 < n
              io << ch << chars[i + 1]
              i += 2
              next
            end
            if quote == '`' && ch == '$' && i + 1 < n && chars[i + 1] == '{'
              i = copy_interpolation(chars, i, n, io, depth)
              next
            end
            io << ch
            i += 1
            break if ch == quote
          end
          i
        end

        # Consume a template ${…} interpolation for the comment-only strip: blank real code
        # comments inside it, but COPY string literals verbatim (so their contents stay for the
        # string-key rules), tracking brace depth to find the matching `}`. Recurses through
        # copy_string for nested strings/templates. `i` points at `$`. Offset-preserving.
        private def self.copy_interpolation(chars, i : Int32, n : Int32, io : IO, depth : Int32) : Int32
          return blank_rest(chars, i, n, io) if depth >= MAX_INTERP_DEPTH
          io << '$' << '{'
          i += 2
          braces = 1
          while i < n && braces > 0
            ch = chars[i]
            if ch == '{' || ch == '}'
              braces += ch == '{' ? 1 : -1
              io << ch
              i += 1
            elsif j = blank_comment_at(chars, i, n, io) # real code comment inside ${…} → blank
              i = j
            elsif ch == '\'' || ch == '"' || ch == '`'
              i = copy_string(chars, i, n, io, depth + 1) # string content kept
            else
              io << ch
              i += 1
            end
          end
          i
        end

        # Blank a // comment through end-of-line (the terminating newline is left to the caller).
        private def self.blank_line_comment(chars, i : Int32, n : Int32, io : IO) : Int32
          io << "  "
          i += 2
          while i < n && chars[i] != '\n'
            io << ' '
            i += 1
          end
          i
        end

        # Blank a /* … */ comment, delimiters included.
        private def self.blank_block_comment(chars, i : Int32, n : Int32, io : IO) : Int32
          io << "  "
          i += 2
          while i < n && !(chars[i] == '*' && i + 1 < n && chars[i + 1] == '/')
            io << ' '
            i += 1
          end
          if i < n
            io << "  "
            i += 2
          end
          i
        end

        # Blank a '…' / "…" / `…` literal's CONTENTS (delimiters kept), honoring \\ escapes.
        # For a template literal a `${…}` interpolation is CODE, not string content, so its
        # expression is emitted (via emit_interpolation) instead of blanked — otherwise the
        # common template-literal sink shape (innerHTML = `${location.hash}`) would lose its
        # source and DOM-XSS would miss it.
        private def self.blank_string(chars, i : Int32, n : Int32, io : IO, depth : Int32) : Int32
          quote = chars[i]
          io << quote # opening delimiter kept
          i += 1
          while i < n
            ch = chars[i]
            if ch == '\\' && i + 1 < n
              io << "  " # escaped pair, length preserved
              i += 2
              next
            end
            if ch == quote
              io << ch # closing delimiter kept
              i += 1
              break
            end
            if quote == '`' && ch == '$' && i + 1 < n && chars[i + 1] == '{'
              i = emit_interpolation(chars, i, n, io, depth) # ${…} expression kept as code
              next
            end
            io << ' ' # content blanked (incl. newlines inside a template)
            i += 1
          end
          i
        end

        # Emit a template-literal `${…}` interpolation as CODE: keep the expression visible so
        # source/sink keywords inside it survive, but blank nested strings/comments (so their
        # CONTENTS can't false-match) and track brace depth to find the matching `}`. Every
        # consumed char emits exactly one char, so offsets stay aligned. `i` points at `$`.
        private def self.emit_interpolation(chars, i : Int32, n : Int32, io : IO, depth : Int32) : Int32
          return blank_rest(chars, i, n, io) if depth >= MAX_INTERP_DEPTH
          io << "  " # blank the '${' delimiter (2 spaces, offset-preserved): keeps the inner
          #            expression as code but removes the '{' so source_in_window's /[;{}\n]/
          #            statement-boundary scan doesn't truncate the window at the interpolation
          #            (else `innerHTML = `${location.hash}`` loses its source and DOM-XSS misses it)
          i += 2
          braces = 1
          while i < n && braces > 0
            ch = chars[i]
            if ch == '{' || ch == '}'
              braces += ch == '{' ? 1 : -1
              io << (ch == '}' && braces == 0 ? ' ' : ch) # blank the OUTER closing '}'; keep inner braces
              i += 1
            elsif j = blank_token_at(chars, i, n, io, depth + 1) # nested string/comment (recurses for a nested template)
              i = j
            else
              io << ch
              i += 1
            end
          end
          i
        end

        # DOM-XSS suspects in one STRIPPED script: {source label, sink label} for every sink
        # occurrence that has a taint source in the same statement (bounded by ;{} / newline
        # within WINDOW chars each side). Empty when no sink co-occurs with a source.
        def self.source_sink_pairs(code : String) : Array({String, String})
          pairs = [] of {String, String}
          # Whole-script source prefilter. A sink can only pair with a source that exists SOMEWHERE
          # in the script, so a bundle with no source at all cannot produce a pair no matter how
          # many sinks it carries — and a minified SPA/jQuery bundle carries thousands (`.html(`,
          # `.innerHTML=`, `setTimeout(`). Without this, that bundle paid the full sink walk to
          # return []: measured 230ms per flow, on the fiber the passive scan shares with the proxy.
          # 14 whole-body `matches?` passes instead ⇒ 1.0ms (228× — bench/probe_passive_bench).
          return pairs unless SOURCES.any? { |(re, _)| re.matches?(code) }
          SINKS.each do |(sink_re, sink_label)|
            # `scan`, NOT a `while m = sink_re.match(code, pos)` loop: re-entering `match` with a
            # start offset is ~515× slower than one `scan` walk for the SAME matches and the SAME
            # allocation (74.00ms vs 143.64µs over 2448 hits in a 256 KiB body — pure CPU inside
            # the match call; `match_at_byte_index` is just as slow, so it is not char↔byte
            # conversion). `scan` yields the same MatchData, so begin/end are unchanged.
            code.scan(sink_re) do |m|
              if src = source_in_window(code, m.byte_begin(0), m.byte_end(0))
                pairs << {src, sink_label}
              end
            end
          end
          pairs
        end

        # The bytes that end a statement, hence bound a source↔sink window: ';' '{' '}' '\n'.
        # Held as BYTES, and the window walk below is a direct byte scan outward from the sink —
        # NOT `String#rindex`/`index` over a substring. Two reasons: `String#rindex(Regex)` walks
        # the whole subject FORWARD keeping the last match and allocates a MatchData per boundary,
        # and taking the `pre`/`post` substrings at all is what made this quadratic on a non-ASCII
        # script. The scan stops at the first boundary in each direction, so it touches at most
        # WINDOW bytes per side and allocates nothing — and this runs once per sink occurrence.
        BOUNDS = {0x3Bu8, 0x7Bu8, 0x7Du8, 0x0Au8}

        # The first taint source inside the statement window around [from, to), or nil.
        # Offsets are BYTE offsets. Char-index slicing (`code[floor...from]`) is O(1) only while
        # the script is all-ASCII; one non-ASCII byte anywhere makes every `String#[]` walk from
        # the start, and this runs per sink occurrence — thousands of times in a minified bundle.
        # A single accented char in a regex literal (kept intact by `strip`, by design) is enough:
        # measured 9ms → 1765ms per flow, on the fiber the passive scan shares with the proxy.
        private def self.source_in_window(code : String, from : Int32, to : Int32) : String?
          bytes = code.to_slice
          floor = from - WINDOW
          floor = 0 if floor < 0
          ceil = to + WINDOW
          ceil = bytes.size if ceil > bytes.size
          # Statement start: the LAST boundary before the sink (else the window floor). Scanned as
          # raw bytes: every BOUNDS byte is ASCII, and a UTF-8 continuation byte is always >= 0x80,
          # so a byte scan can never match inside a multi-byte char.
          lo = floor
          i = from - 1
          while i >= floor
            if BOUNDS.includes?(bytes[i])
              lo = i + 1
              break
            end
            i -= 1
          end
          # Statement end: the FIRST boundary after the sink (else the window ceiling).
          hi = ceil
          j = to
          while j < ceil
            if BOUNDS.includes?(bytes[j])
              hi = j
              break
            end
            j += 1
          end
          # A window edge can land mid-char, so scrub before handing the slice to PCRE (invalid
          # UTF-8 makes the match raise). Bounded to ~2*WINDOW bytes, so this costs nothing.
          seg = String.new(bytes[lo, hi - lo]).scrub
          SOURCES.each { |(re, label)| return label if re.matches?(seg) }
          nil
        end
      end
    end
  end
end
