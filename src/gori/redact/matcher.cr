require "json"
require "uri"
require "../media_type"

module Gori
  module Redact
    # A `Profile` compiled once into the form the walk actually needs — downcased name sets,
    # parsed JSON Pointers, compiled regexes — plus the body engine that uses them.
    #
    # Compiled rather than re-derived per body because an export runs this over both sides of
    # every flow in a HAR, and because a regex an operator typed can be INVALID: compiling up
    # front turns that into one reported sentence (`pattern_errors`) instead of an exception
    # from the middle of a document, or worse, a silently skipped rule.
    class Matcher
      # A region of a string this matcher would replace: the CHARACTER range (exclusive end,
      # so it slices straight back out with `text[range]`), the placeholder that would have
      # gone there, and the rule that claimed it. See `Matcher#spans`.
      #
      # `placeholder` is EMPTY when the correlation tag could not be minted — no salt is
      # armed (`Redact::SaltMissing`). The range is still right, and a consumer must still
      # cover it: "redacted without a tag" is a bad outcome, "left on the screen" is the
      # one this exists to prevent. A tag is a correlation aid; the range is the redaction.
      record Span, range : Range(Int32, Int32), placeholder : String, rule : String

      getter profile : Profile

      # Regex sources in the profile that would not compile, as `"<source>: <reason>"`. A
      # surface reports these beside the export rather than aborting it: the rest of the
      # profile is still doing its job, and an operator who mistyped one pattern should get
      # the other four applied and be told which one is dead.
      getter pattern_errors : Array(String)

      # Field/key names, downcased for case-insensitive matching. A JSON member name is
      # case-SENSITIVE in the format and a form key is case-sensitive on the wire, but the
      # question this profile asks ("is this the password field?") is not: an API that spells
      # it `Password` is the same disclosure as one that spells it `password`, and an operator
      # writing a profile should not have to guess which the target chose.
      @fields : Hash(String, String)
      @form : Hash(String, String)

      # Each pointer as its RFC 6901 tokens, unescaped. See `Profile` for the `-` token.
      @pointers : Array({Array(String), String})

      # `{regex, rule label}` — the profile's own patterns, then the built-ins.
      @patterns : Array({Regex, String})

      def initialize(@profile : Profile)
        @pattern_errors = [] of String
        @fields = {} of String => String
        @profile.json_fields.each { |f| @fields[f.strip.downcase] = f unless f.strip.empty? }
        @form = {} of String => String
        @profile.form_keys.each { |f| @form[f.strip.downcase] = f unless f.strip.empty? }
        @pointers = [] of {Array(String), String}
        @profile.json_pointers.each do |p|
          next if p.strip.empty?
          @pointers << {Matcher.pointer_tokens(p.strip), p.strip}
        end
        @patterns = [] of {Regex, String}
        @profile.patterns.each do |src|
          next if src.strip.empty?
          begin
            @patterns << {Regex.new(src, Regex::Options::IGNORE_CASE), "pattern #{src}"}
          rescue ex
            @pattern_errors << "#{src}: #{ex.message}"
          end
        end
        BUILTIN_PATTERNS.each { |(rx, label)| @patterns << {rx, label} }
        @text_rules = build_text_rules
      end

      # The derived name=value / "name": "value" regexes — how a profile's FIELD NAMES keep
      # working over a body that could not be parsed. Built here so the fallback pass is one
      # `gsub` per shape rather than one per configured name.
      @text_rules : Array({Regex, String})

      # --- the engine --------------------------------------------------------

      # Sanitize one entity body. `content_type` is the message's Content-Type value (nil when
      # the head carried none, which is normal for a hand-authored Repeater request).
      #
      # Never raises on the body's account: an unparseable document falls back, an
      # unsanitizable one is withheld whole, and either way the caller gets a `Result` it can
      # print. The one exception it CAN propagate is `Redact::SaltMissing`, which is a
      # configuration fault, not a property of these bytes.
      #
      # The UTF-8 gate below is load-bearing, not tidiness: PCRE2 RAISES on the first illegal
      # byte rather than declining to match, and that exception out of a copy action or an
      # export is the exact crash shape this tree keeps finding.
      def body(bytes : Bytes?, content_type : String? = nil) : Result
        return Result.new(text: "", hits: [] of Hit, shape: Shape::Empty) if bytes.nil? || bytes.empty?
        if MediaType.multipart?(content_type)
          return withheld(bytes.size, Shape::Multipart,
            "a multipart body is withheld whole: gori does not split its parts yet, " \
            "so it cannot tell an uploaded file from a form field")
        end
        text = String.new(bytes)
        unless text.valid_encoding?
          # Worded for a WebSocket frame payload as much as for an entity body: `value` is this
          # same gate (see below), so one sentence has to cover both.
          return withheld(bytes.size, Shape::Binary,
            "not valid UTF-8, so it is withheld whole: there is no text to inspect, and " \
            "nothing here can say what it holds")
        end
        if json_shaped?(text, content_type)
          json(text)
        elsif MediaType.form_urlencoded?(content_type)
          form(text)
        else
          plain(text)
        end
      end

      # The same engine over a string that is not an entity body — a WebSocket frame payload, a
      # rendered transcript, a note.
      #
      # Deliberately `body` and not a second gate of its own: with no Content-Type there is no
      # multipart and no form to detect, so "sanitize this string" and "sanitize this body
      # whose type nothing declared" are the same question — and two entry points that answer
      # it separately is how `Wire.ws_messages` and the Repeater's copy menu ended up
      # sanitizing the identical kind of payload down two paths. A size cap or a new sniff
      # added to the gate now applies to both by construction.
      def value(text : String) : Result
        body(text.to_slice, nil)
      end

      # --- shapes ------------------------------------------------------------

      # Is this worth handing to the JSON parser? The Content-Type when there is one, and the
      # first non-space byte when there is not — a stored flow, an imported request or a
      # hand-authored Repeater body frequently declares nothing, and refusing to sniff would
      # drop those bodies to the text pass, which cannot see structure.
      private def json_shaped?(text : String, content_type : String?) : Bool
        return true if MediaType.json?(content_type)
        # A DECLARED type that is not JSON is believed: sniffing past it would hand the JSON
        # parser a `text/html` page that happens to open with `{`.
        return false if MediaType.essence(content_type)
        c = text.each_char.find { |ch| !ch.whitespace? }
        c == '{' || c == '['
      end

      private def json(text : String) : Result
        parsed = begin
          JSON.parse(text)
        rescue JSON::ParseException
          # The body SAYS it is JSON (or looks it) and is not — truncated at the capture cap,
          # JSONP-wrapped, an error page served with the wrong type. Structure is exactly what
          # is unavailable, so this is the case the conservative text pass exists for.
          return plain(text, fell_back: true)
        end
        hits = [] of Hit
        clean = JSON.build do |j|
          walk(j, parsed, [] of {String, Bool}, nil, hits)
        end
        Result.new(text: clean, hits: hits, shape: Shape::Json)
      end

      private def form(text : String) : Result
        hits = [] of Hit
        clean = text.split('&').map { |pair| redact_form_pair(pair, hits) }.join('&')
        Result.new(text: clean, hits: hits, shape: Shape::Form)
      end

      # The conservative pass: the profile's own patterns, the built-in credential shapes, and
      # the profile's FIELD NAMES re-expressed as `"name": "value"` / `name=value` text rules
      # so a profile keeps meaning something over a body whose structure is gone.
      private def plain(text : String, fell_back : Bool = false) : Result
        hits = [] of Hit
        clean = apply_text_rules(text, "body", hits)
        Result.new(text: clean, hits: hits, shape: Shape::Text, fell_back: fell_back)
      end

      private def withheld(size : Int32, shape : Shape, why : String) : Result
        note = "[REDACTED: #{size} byte#{size == 1 ? "" : "s"} withheld — #{why}]"
        # One hit, because the count a surface reports is "how many values did not travel" and
        # a withheld body is the whole of them. `path` is the body itself; there is no finer
        # location to give, which is the point.
        Result.new(text: note, hits: [Hit.new("body", "withheld", note)], shape: shape)
      end

      # --- the JSON walk -----------------------------------------------------

      # Rebuild the document, replacing what matches. `tokens` is the RFC 6901 path to the
      # value being written, each with whether it indexes an ARRAY (the `-` wildcard's test);
      # `name` is the object member name when this value is one, and nil for an array element
      # or the root.
      #
      # Rebuilt rather than patched in place, so the output is always well-formed JSON — which
      # also means a sanitized JSON body carries gori's whitespace and key order, not the
      # origin's. That is a real difference from the captured bytes and it is stated in the
      # docs; a body whose EXACT framing matters is what `--no-redact` and the untouched store
      # are for.
      private def walk(j : JSON::Builder, any : JSON::Any, tokens : Array({String, Bool}),
                       name : String?, hits : Array(Hit)) : Nil
        if rule = match(tokens, name)
          literal = literal_of(any)
          ph = Redact.placeholder(literal)
          hits << Hit.new(Matcher.pointer_string(tokens), rule, ph)
          j.string ph
          return
        end
        case raw = any.raw
        when Hash(String, JSON::Any)
          j.object do
            raw.each do |k, v|
              j.field(k) do
                tokens << {k, false}
                walk(j, v, tokens, k, hits)
                tokens.pop
              end
            end
          end
        when Array(JSON::Any)
          j.array do
            raw.each_with_index do |v, i|
              tokens << {i.to_s, true}
              walk(j, v, tokens, nil, hits)
              tokens.pop
            end
          end
        when String
          # A string LEAF is where a pattern can still find something the names missed — a JWT
          # under a member nobody thought to list is the motivating case.
          j.string apply_text_rules(raw, Matcher.pointer_string(tokens), hits, values_only: true)
        when Nil
          j.null
        when Bool
          j.bool raw
        when Int64
          j.number raw
        when Float64
          j.number raw
        else
          # JSON::Any carries nothing else; emit it as text rather than dropping it.
          j.string raw.to_s
        end
      end

      # Which profile entry, if any, claims the value at `tokens`. Field names are checked
      # first because they are the common case and cheaper.
      private def match(tokens : Array({String, Bool}), name : String?) : String?
        if name && (cfg = @fields[name.downcase]?)
          return "json_field #{cfg}"
        end
        @pointers.each do |(want, src)|
          return "json_pointer #{src}" if pointer_match?(want, tokens)
        end
        nil
      end

      private def pointer_match?(want : Array(String), tokens : Array({String, Bool})) : Bool
        return false unless want.size == tokens.size
        want.each_with_index do |tok, i|
          got, array = tokens[i]
          next if tok == "-" && array # the array wildcard; see `Profile`
          return false unless tok == got
        end
        true
      end

      # The string a matched value's tag is derived from. A container hashes its COMPACT JSON,
      # so two identical sub-objects correlate the way two identical strings do.
      private def literal_of(any : JSON::Any) : String
        case raw = any.raw
        when String then raw
        when Nil    then ""
        else             any.to_json
        end
      end

      # --- forms -------------------------------------------------------------

      # One `k=v` segment. Everything that is not a matched value survives byte-for-byte,
      # including a segment with no `=` at all and the empty segments a `&&` leaves behind.
      #
      # The placeholder is percent-encoded on the way back in, so a sanitized form body is
      # still a valid form body (it decodes to the canonical `[REDACTED:…]`).
      private def redact_form_pair(pair : String, hits : Array(Hit)) : String
        eq = pair.index('=')
        return pair unless eq
        key_raw = pair[0...eq]
        val_raw = pair[(eq + 1)..]
        key = Matcher.form_decode(key_raw)
        value = Matcher.form_decode(val_raw)
        if cfg = @form[key.downcase]?
          ph = Redact.placeholder(value)
          hits << Hit.new(key, "form_key #{cfg}", ph)
          return "#{key_raw}=#{URI.encode_www_form(ph)}"
        end
        cleaned = apply_text_rules(value, key, hits, values_only: true)
        cleaned == value ? pair : "#{key_raw}=#{URI.encode_www_form(cleaned)}"
      end

      # A form value that is not valid percent-encoding is taken literally rather than dropped:
      # the point is to recognise a key, and a malformed body is exactly when redaction matters.
      def self.form_decode(s : String) : String
        URI.decode_www_form(s)
      rescue
        s
      end

      # --- text rules --------------------------------------------------------

      # `values_only` runs only the rules that target a VALUE (the profile's patterns and the
      # built-in shapes), skipping the derived `name: value` rules — inside a JSON string leaf
      # or a decoded form value there is no `name:` pair left to find, and running them there
      # would match a quoted fragment of prose.
      private def apply_text_rules(text : String, path : String, hits : Array(Hit),
                                   values_only : Bool = false) : String
        # The last line of defence for the regex engine. Every ENTRY point already gates on
        # UTF-8, but a value two steps in does not: percent-decoding a form field can turn a
        # valid body into an invalid string (`%FF`), and PCRE2 RAISES on the first illegal byte
        # rather than declining to match. A value gori cannot scan is left exactly as it is —
        # no rule named it, so this changes nothing about what a profile covers.
        return text unless text.valid_encoding?
        clean = text
        rules = values_only ? @patterns : (@text_rules + @patterns)
        rules.each { |(rx, rule)| clean = replace_all(clean, rx, rule, path, hits) }
        clean
      end

      # Walk every match of `rx` over `text`, yielding `{group start, group end, whole match
      # end}` in order, with the cursor advanced the way a replacement pass needs it.
      #
      # Hand-rolled rather than `gsub`, because a block-form gsub only hands back the matched
      # TEXT and rebuilding "the match with its group replaced" from that re-finds the group by
      # value — which picks the wrong occurrence whenever the context around it repeats the
      # secret. Offsets cannot be wrong that way.
      #
      # Extracted from `replace_all` so `spans` can ask the SAME question ("where are the
      # matches") without the answer being routed through a rebuilt string: the screenshot
      # redactor needs coordinates, not replaced text, and a second cursor loop written next
      # to it would be a second set of these two edge cases to get wrong.
      private def each_match(text : String, rx : Regex, & : Int32, Int32, Int32 ->) : Nil
        md = rx.match(text)
        pos = 0
        while md
          # `md.begin(1)` RAISES for a group that did not participate, so the group is chosen
          # by asking whether it captured anything at all, never by the pattern's shape.
          group = md[1]?.nil? ? 0 : 1
          start = md.begin(group)
          stop = md.end(group)
          whole_end = md.end(0)
          yield start, stop, whole_end
          if whole_end > pos
            pos = whole_end
          else
            # A zero-width WHOLE match (`x*` against `y`) leaves the cursor where it was, so the
            # same empty match would be found forever. Step one character.
            pos += 1
          end
          break if pos > text.size
          md = rx.match(text, pos)
        end
      end

      # Replace every match of `rx`, taking capture group 1 when the pattern has one and the
      # whole match when it does not (see `Profile#patterns`).
      private def replace_all(text : String, rx : Regex, rule : String, path : String,
                              hits : Array(Hit)) : String
        clean = nil.as(String::Builder?)
        pos = 0
        each_match(text, rx) do |start, stop, whole_end|
          builder = clean ||= String::Builder.new
          before = pos
          value = text[start...stop]
          if value.empty?
            # A zero-width GROUP has nothing to replace; copy the match through rather than
            # minting a placeholder for the empty string.
            builder << text[before...whole_end]
          else
            builder << text[before...start]
            ph = Redact.placeholder(value)
            hits << Hit.new(path, rule, ph)
            builder << ph
            builder << text[stop...whole_end] if whole_end > stop
          end
          if whole_end > before
            pos = whole_end
          else
            # The zero-width-whole-match step, and the copy `each_match` cannot do for us:
            # skipping without copying silently deletes a byte of the operator's evidence at
            # every such position.
            builder << text[before, 1] if before < text.size
            pos = before + 1
          end
        end
        return text unless builder = clean
        builder << text[pos..] if pos <= text.size
        builder.to_s
      end

      # WHERE this matcher would redact in `text`, as character ranges into the text AS GIVEN.
      #
      # `value` answers "what does the sanitized text say", which is all a body needs. A
      # SCREENSHOT needs coordinates: the cells to paint over sit at columns derived from
      # offsets, and `value` has already rewritten the string those offsets would index.
      #
      # Deliberately NOT the same set of matches as `value`, and the difference is worth
      # stating plainly. `value` applies its rules in sequence, each over the output of the
      # last, so a rule can only match what the previous rules left behind. This runs every
      # rule over the ORIGINAL text and merges the results, which makes it a SUPERSET: two
      # rules that would each have claimed the same secret both report it here, and the merge
      # folds them into one span. So a span COUNT can differ from a `Result#hits` count by
      # one on an overlap, and the masked region is the union. For "paint over everything a
      # profile would have hidden" that is the right direction to err in.
      #
      # `values_only` skips the derived `name: value` rules, matching `apply_text_rules`.
      def spans(text : String, *, values_only : Bool = false) : Array(Span)
        # PCRE2 RAISES on the first illegal byte rather than declining to match, so a frame
        # holding undecodable bytes is reported as "nothing found" instead of crashing the
        # screenshot. Same gate, same reason, as `body` and `apply_text_rules`.
        return [] of Span unless text.valid_encoding?
        found = [] of Span
        rules = values_only ? @patterns : (@text_rules + @patterns)
        rules.each do |(rx, rule)|
          each_match(text, rx) do |start, stop, _|
            next if stop <= start
            found << Span.new(start...stop, tag_for(text[start...stop]), rule)
          end
        end
        merge(found)
      end

      # See `Span#placeholder`: no salt is a configuration fault, and reporting it from here
      # would cost the caller the RANGE as well as the tag.
      private def tag_for(value : String) : String
        Redact.placeholder(value)
      rescue SaltMissing
        ""
      end

      # Overlapping spans folded into one. The placeholder and rule kept are the FIRST span's
      # — the leftmost match, and the rule `value` would have applied first.
      #
      # OVERLAPPING, not merely adjacent: two secrets that happen to sit side by side are two
      # findings and are counted as two. They still cover a contiguous region either way.
      private def merge(found : Array(Span)) : Array(Span)
        return found if found.size < 2
        found.sort_by! { |s| {s.range.begin, s.range.end} }
        merged = [found[0]]
        found.skip(1).each do |span|
          last = merged[-1]
          if span.range.begin < last.range.end
            next if span.range.end <= last.range.end
            merged[-1] = Span.new(last.range.begin...span.range.end, last.placeholder, last.rule)
          else
            merged << span
          end
        end
        merged
      end

      # The profile's field/key names, re-expressed as text rules for the fallback pass. One
      # alternation per shape rather than one regex per name: a broad profile carries ~50
      # names, and 100 passes over a multi-MiB body is the difference between an export and a
      # hang.
      private def build_text_rules : Array({Regex, String})
        rules = [] of {Regex, String}
        unless @fields.empty?
          alt = @fields.keys.map { |k| Regex.escape(k) }.join('|')
          # `"name" : "value"`, with backslash escapes inside the value kept whole — and the
          # closing quote OPTIONAL at end of subject. That last part is not a nicety: this rule
          # runs over bodies that are truncated (a capture cut at the cap, an MCP projection cut
          # at its 64 KB display cap), and requiring the close meant a secret cut mid-value was
          # the one thing the fallback could not see.
          rules << {Regex.new("\"(?:#{alt})\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)(?:\"|\\z)",
            Regex::Options::IGNORE_CASE), "json_field (text fallback)"}
        end
        unless @form.empty?
          alt = @form.keys.map { |k| Regex.escape(k) }.join('|')
          # `name=value` as it appears in a query string, a form body or a cookie run.
          rules << {Regex.new("(?:\\A|[&?;\\s])(?:#{alt})=([^&;\\s\"']*)",
            Regex::Options::IGNORE_CASE), "form_key (text fallback)"}
        end
        rules
      end

      # --- RFC 6901 ----------------------------------------------------------

      # `/a/b~1c` → `["a", "b/c"]`. A pointer that does not start with `/` is taken as if it
      # did, because that is what an operator means by `data/token` and refusing it would be a
      # silent no-op rule.
      #
      # `""` is the whole document (RFC 6901 §5) and `"/"` is the member whose key is the empty
      # string — NOT the document. Both spellings reach here only from a hand-written profile,
      # and reading the second as the first would replace an entire body for a rule that names
      # one oddly-keyed field.
      def self.pointer_tokens(pointer : String) : Array(String)
        return [] of String if pointer.empty?
        s = pointer.starts_with?('/') ? pointer[1..] : pointer
        s.split('/').map(&.gsub("~1", "/").gsub("~0", "~"))
      end

      def self.pointer_string(tokens : Array({String, Bool})) : String
        return "" if tokens.empty?
        String.build do |io|
          tokens.each do |(t, _)|
            io << '/' << t.gsub("~", "~0").gsub("/", "~1")
          end
        end
      end
    end
  end
end
