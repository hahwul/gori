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
          chars = js.chars
          n = chars.size
          String.build(js.bytesize) do |io|
            i = 0
            while i < n
              c = chars[i]
              i = if c == '/' && i + 1 < n && chars[i + 1] == '/'
                    blank_line_comment(chars, i, n, io)
                  elsif c == '/' && i + 1 < n && chars[i + 1] == '*'
                    blank_block_comment(chars, i, n, io)
                  elsif c == '\'' || c == '"' || c == '`'
                    blank_string(chars, i, n, io)
                  else
                    io << c
                    i + 1
                  end
            end
          end
        end

        # Blank a // comment through end-of-line (the terminating newline is left to the caller).
        private def self.blank_line_comment(chars : Array(Char), i : Int32, n : Int32, io : IO) : Int32
          io << "  "
          i += 2
          while i < n && chars[i] != '\n'
            io << ' '
            i += 1
          end
          i
        end

        # Blank a /* … */ comment, delimiters included.
        private def self.blank_block_comment(chars : Array(Char), i : Int32, n : Int32, io : IO) : Int32
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
        private def self.blank_string(chars : Array(Char), i : Int32, n : Int32, io : IO) : Int32
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
            io << ' ' # content blanked (incl. newlines inside a template)
            i += 1
          end
          i
        end

        # DOM-XSS suspects in one STRIPPED script: {source label, sink label} for every sink
        # occurrence that has a taint source in the same statement (bounded by ;{} / newline
        # within WINDOW chars each side). Empty when no sink co-occurs with a source.
        def self.source_sink_pairs(code : String) : Array({String, String})
          pairs = [] of {String, String}
          SINKS.each do |(sink_re, sink_label)|
            pos = 0
            while m = sink_re.match(code, pos)
              b = m.begin(0)
              e = m.end(0)
              if src = source_in_window(code, b, e)
                pairs << {src, sink_label}
              end
              pos = e > pos ? e : pos + 1
            end
          end
          pairs
        end

        # The first taint source inside the statement window around [from, to), or nil.
        private def self.source_in_window(code : String, from : Int32, to : Int32) : String?
          floor = from - WINDOW
          floor = 0 if floor < 0
          ceil = to + WINDOW
          ceil = code.size if ceil > code.size
          pre = code[floor...from]
          lo = (rel = pre.rindex(/[;{}\n]/)) ? floor + rel + 1 : floor
          post = code[to...ceil]
          hi = (rel2 = post.index(/[;{}\n]/)) ? to + rel2 : ceil
          seg = code[lo...hi]
          SOURCES.each { |(re, label)| return label if re.matches?(seg) }
          nil
        end
      end
    end
  end
end
