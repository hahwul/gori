require "uri"
require "../filter_ast"
require "../store"
require "../proxy/codec/http1"

module Gori
  module Repeater
    # Normalize the flat tag set a Repeater session carries. Tags are whitespace-free
    # tokens ("idor", "auth-bypass"); the editor accepts them space/comma separated
    # and may prefix them with `#`. Stored as one space-joined column (V31); the
    # multi-label set lives in memory as an Array.
    module Tags
      # Parse a raw editor string / stored column into a deduped token list. Splits on
      # whitespace and commas, strips a leading `#`, drops blanks, and de-duplicates
      # case-insensitively (keeping the first-seen casing).
      def self.parse(raw : String?) : Array(String)
        return [] of String unless raw
        seen = Set(String).new
        out = [] of String
        raw.split(/[\s,]+/).each do |tok|
          t = tok.strip.lstrip('#')
          next if t.empty?
          key = t.downcase
          next if seen.includes?(key)
          seen << key
          out << t
        end
        out
      end

      # Space-joined column value for the store; nil when there are no tags (so an
      # empty set clears the column, like a blank name).
      def self.serialize(tags : Array(String)) : String?
        tags.empty? ? nil : tags.join(' ')
      end
    end

    # An in-memory predicate over Repeater sub-tabs, parsed from a History-like filter
    # string. Repeater sessions live wholly in memory, so — unlike History's QL→SQL —
    # this matches Crystal-side (the same shape as Issues::Filter). Terms are
    # whitespace-separated and AND-joined; a leading `-` negates a field term; an
    # unrecognised or bare token is free text over name + summary + target + tags.
    #
    #   idor                    → free text "idor" (name/summary/target/tag)
    #   tag:idor method:post    → tagged "idor" AND a POST request
    #   -tag:done host:api      → not tagged "done" AND target contains "api"
    class SubtabFilter
      # Completable field names (canonical forms shown in the filter guidance row).
      # Aliases host/target and method/verb share value pools below.
      FIELDS = %w[tag name host target method verb status]

      # The non-numeric `status:` values, so the completion pool can offer them beside the
      # codes actually present. Words, never digits, so neither can shadow a real code.
      STATUS_WORDS = %w[error unsent]

      # Common HTTP methods suggested even when no open session uses them yet.
      METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE]

      # The searchable projection of one Repeater session. Kept free of TUI types so the
      # matcher is pure + unit-testable; the controller builds these from its views.
      # `status` is the last send's outcome as ONE lowercase token: the status code
      # ("404"), `error` when the send itself failed, or `unsent` when this session has
      # never been sent. A String rather than an `Int32?` because those are three answers to
      # one question the operator asks in one field — `status:4` for every 4xx, and matching
      # by PREFIX (below) is what makes that spelling work. A nil would have needed its own
      # word anyway, and the two words cannot collide with a code.
      record Subject,
        name : String?,
        summary : String,
        target : String,
        method : String,
        tags : Array(String),
        status : String = "" do
        # The projection of a PERSISTED row, for the headless surfaces (MCP `get_repeater_context`).
        #
        # The TUI builds its subjects from the live `RepeaterView` instead, because a dirty
        # editor's bytes are not the row's — but both must reach the SAME shape or the
        # operator's `/` filter and an agent's `filter` argument would answer differently
        # about one session. Everything here is derived exactly as `RepeaterView` derives it:
        # `summary`/`request_method` off the first non-blank request line, `tags` through
        # `Tags.parse`, `status` off the stored response head.
        def self.from_row(r : Store::RepeaterRecord) : Subject
          request = String.new(r.request)
          new(name: r.name, summary: summary_of(request), target: r.target,
            method: method_of(request), tags: Tags.parse(r.tags),
            status: Subject.row_status(r))
        end

        # "METHOD /path" off the first non-blank request line — the label `RepeaterView#summary`
        # derives for a tab with no stored name, and therefore the label the strip paints.
        # Public because a caller holding request BYTES and no row yet needs the same answer
        # (`create_repeaters` naming a session it is about to insert); a second derivation
        # there would be a second answer to "what is this tab called".
        def self.summary_of(request : String) : String
          line = first_nonblank_line(request)
          parts = line.split(' ')
          s = "#{parts[0]?} #{parts[1]?}".strip
          s.empty? ? line : s
        end

        # The leading METHOD token, for `method:`.
        def self.method_of(request : String) : String
          first_nonblank_line(request).split(' ').first? || ""
        end

        # `scrub`, because a repeater request is seeded from a capture without one and
        # `split`/`downcase` on invalid UTF-8 raises — which would fail the WHOLE listing
        # over one bad row. Lossless for a filter match.
        def self.first_nonblank_line(request : String) : String
          request.scrub.each_line.find { |l| !l.strip.empty? }.try(&.strip) || ""
        end

        # The ONE spelling of the `status:` token, from the two facts every surface has: the
        # send's error (if any) and the response HEAD bytes.
        #
        # The head, and not a parsed status object, is what both callers can actually supply.
        # `RepeaterView#restore` rebuilds its `Repeater::Result` with `response: nil` on
        # purpose — the parsed `RawResponse` is not persisted — so a live view asked for
        # `result.response.try(&.status)` answers `unsent` for a session that plainly shows a
        # 403 in its response pane. Reading the head is the one question both a reopened tab
        # and a stored row can answer, so it is the only one this asks.
        #
        # `error` beats a head: a session that answered 200 and was then re-sent into a
        # connection refusal keeps the old head (`update_repeater_response` writes both), and
        # the news is the failure.
        def self.status_token(error : String?, head : Bytes?) : String
          return "error" if error && !error.empty?
          return "unsent" if head.nil? || head.empty?
          begin
            Proxy::Codec::Http1.parse_response_head(head).status.to_s
          rescue
            # Bytes we hold and cannot read. NOT "unsent" — something answered — and not a
            # code, because there is none to name.
            "error"
          end
        end

        protected def self.row_status(r : Store::RepeaterRecord) : String
          status_token(r.response_error, r.response_head)
        end
      end

      private record Term, kind : Symbol, text : String, negate : Bool

      def self.parse(query : String) : SubtabFilter
        new(FilterAst.build(FilterAst.parse(query)) { |t| build_term(t) })
      end

      def initialize(@tree : FilterAst::Tree(Term)?)
      end

      def empty? : Bool
        @tree.nil?
      end

      # An empty filter passes all; order is preserved.
      def apply(subjects : Array(Subject)) : Array(Subject)
        return subjects if @tree.nil?
        subjects.select { |s| matches?(s) }
      end

      def matches?(s : Subject) : Bool
        tree = @tree
        return true unless tree
        eval(tree, s)
      end

      private def eval(tree : FilterAst::Tree(Term), s : Subject) : Bool
        case tree.op
        in .leaf? then match_term(tree.leaf, s)
        in .not?  then !eval(tree.children.first, s)
        in .and?  then tree.children.all? { |c| eval(c, s) }
        in .or?   then tree.children.any? { |c| eval(c, s) }
        end
      end

      # --- Tab-complete suggestions (History-style; in-memory over open sessions) ---
      # Returns complete tokens for the whitespace-bounded token under `cx`. Empty
      # when the caret sits on blank space or nothing matches. Value pools for
      # tag/name/host/method come from `subjects` (cardinality is small — open tabs).
      # `fields` limits which field NAMES a tab completes (a text tab passes %w(name) so
      # it never suggests host:/method:); defaults to the full canonical set (Repeater).
      def self.suggestions(query : String, cx : Int32, subjects : Array(Subject),
                           fields : Array(String) = FIELDS) : Array(String)
        cur = FilterAst.token_at(query, cx)
        return [] of String if cur.core.empty?
        if colon = cur.core.index(':')
          field_raw = cur.core[0...colon]
          field = field_raw.downcase
          prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..])
          # Strip a typed `#` on tags so `tag:#id` still suggests `tag:idor`.
          val_prefix = field == "tag" ? prefix.lstrip('#') : prefix
          suggest_values(field, val_prefix, subjects)
            .map { |v| "#{cur.prefix}#{field_raw}:#{FilterAst.quote(v)}" }
        else
          fields.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}:" }
        end
      end

      # Host portion of a target URL for `host:` suggestions (falls back to the
      # authority-ish first path segment when URI.parse fails).
      def self.host_of(target : String) : String?
        # scrub: target derives from a captured request; URI.parse returns an EMPTY host for an
        # invalid-UTF-8 authority (falling through past the guard below), so the bare-host sub
        # would then raise. Scrub once here — host_of only produces a display/suggestion string.
        t = target.scrub.strip
        return nil if t.empty?
        begin
          if h = URI.parse(t).host
            return h unless h.empty?
          end
        rescue
        end
        bare = t.sub(%r{^[a-z][a-z0-9+.-]*://}i, "")
        host = bare.split('/').first?.try(&.split('?').first).try(&.split('#').first)
        return nil unless host
        host = host.split('@').last? || host # user:pass@host
        host = host.split(']').last? || host # strip [ipv6]:port clumsily
        host = host.lstrip('[')
        host = host.split(':').first? || host # drop :port for hostname
        host.empty? ? nil : host
      end

      # --- parsing -------------------------------------------------------------

      # Never drops a term: an empty value (mid-typing `tag:`) stays and is handled by
      # match_term, so the sub-tab strip doesn't blank out between keystrokes.
      private def self.build_term(t : FilterAst::Term) : Term
        tok = t.text
        negate = t.negate?
        if colon = tok.index(':')
          field = tok[0...colon].downcase
          value = tok[(colon + 1)..].downcase
          case field
          when "tag"            then return Term.new(:tag, value.lstrip('#'), negate)
          when "name"           then return Term.new(:name, value, negate)
          when "host", "target" then return Term.new(:target, value, negate)
          when "method", "verb" then return Term.new(:method, value, negate)
          when "status"         then return Term.new(:status, value, negate)
          end
        end
        # Unrecognised prefix or bare token → free text (name/summary/target/tags).
        Term.new(:text, tok.downcase, negate)
      end

      private def self.suggest_values(field : String, prefix : String, subjects : Array(Subject)) : Array(String)
        p = prefix.downcase
        case field
        when "tag"
          collect_prefix(p, subjects.flat_map(&.tags))
        when "name"
          collect_prefix(p, subjects.compact_map(&.name))
        when "host"
          collect_prefix(p, subjects.compact_map { |s| host_of(s.target) })
        when "target"
          collect_prefix(p, subjects.map(&.target).reject(&.empty?))
        when "method", "verb"
          # Session methods first (preserve casing), then the static set for gaps.
          from_sess = collect_prefix(p, subjects.map(&.method).reject(&.empty?))
          seen = Set(String).new(from_sess.map(&.downcase))
          static = METHODS.select { |m| m.downcase.starts_with?(p) && !seen.includes?(m.downcase) }
          from_sess + static
        when "status"
          # Codes actually present first, then the two words for gaps — the same
          # observed-then-static shape `method` uses.
          from_sess = collect_prefix(p, subjects.map(&.status).reject(&.empty?))
          seen = Set(String).new(from_sess)
          from_sess + STATUS_WORDS.select { |w| w.starts_with?(p) && !seen.includes?(w) }
        else
          [] of String
        end
      end

      # De-duplicate case-insensitively (keep first-seen casing); prefix-filter.
      private def self.collect_prefix(prefix : String, values : Array(String)) : Array(String)
        seen = Set(String).new
        out = [] of String
        values.each do |raw|
          key = raw.downcase
          next if key.empty? || !key.starts_with?(prefix) || seen.includes?(key)
          seen << key
          out << raw
        end
        out
      end

      # --- matching ------------------------------------------------------------

      private def match_term(t : Term, s : Subject) : Bool
        # An empty value (mid-type "tag:" / "method:") matches all, so the strip
        # doesn't blank out until a value is typed — uniform across every field kind.
        # Negation is honoured: `tag:` matches all, so `-tag:` matches none.
        return !t.negate if t.text.empty?
        hit = case t.kind
              when :tag    then s.tags.any?(&.downcase.includes?(t.text))
              when :name   then (s.name || "").downcase.includes?(t.text)
              when :target then s.target.downcase.includes?(t.text)
              when :method then s.method.downcase.includes?(t.text)
                # PREFIX, not substring: `status:4` has to mean "every 4xx", and `includes?`
                # would also hand it 204 and 400-through-a-404. The one field here whose
                # values have positional meaning.
              when :status then s.status.starts_with?(t.text)
              else              free_text(t.text, s)
              end
        t.negate ? !hit : hit
      end

      private def free_text(text : String, s : Subject) : Bool
        return true if text.empty?
        (s.name || "").downcase.includes?(text) ||
          s.summary.downcase.includes?(text) ||
          s.target.downcase.includes?(text) ||
          s.tags.any?(&.downcase.includes?(text))
      end
    end
  end
end
