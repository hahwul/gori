require "uri"

module Gori
  module Replay
    # Normalize the flat tag set a Replay session carries. Tags are whitespace-free
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

    # An in-memory predicate over Replay sub-tabs, parsed from a History-like filter
    # string. Replay sessions live wholly in memory, so — unlike History's QL→SQL —
    # this matches Crystal-side (the same shape as Findings::Filter). Terms are
    # whitespace-separated and AND-joined; a leading `-` negates a field term; an
    # unrecognised or bare token is free text over name + summary + target + tags.
    #
    #   idor                    → free text "idor" (name/summary/target/tag)
    #   tag:idor method:post    → tagged "idor" AND a POST request
    #   -tag:done host:api      → not tagged "done" AND target contains "api"
    class SubtabFilter
      # Completable field names (canonical forms shown in the filter guidance row).
      # Aliases host/target and method/verb share value pools below.
      FIELDS = %w(tag name host target method verb)

      # Common HTTP methods suggested even when no open session uses them yet.
      METHODS = %w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE)

      # The searchable projection of one Replay session. Kept free of TUI types so the
      # matcher is pure + unit-testable; the controller builds these from its views.
      record Subject,
        name : String?,
        summary : String,
        target : String,
        method : String,
        tags : Array(String)

      private record Term, kind : Symbol, text : String, negate : Bool

      def self.parse(query : String) : SubtabFilter
        terms = [] of Term
        query.split.each do |raw|
          next if raw.empty?
          negate = false
          tok = raw
          if tok.starts_with?('-') && tok.size > 1
            negate = true
            tok = tok[1..]
          end
          terms << build_term(tok, negate)
        end
        new(terms)
      end

      def initialize(@terms : Array(Term))
      end

      def empty? : Bool
        @terms.empty?
      end

      # Keep input order; every term must match (AND). An empty filter passes all.
      def apply(subjects : Array(Subject)) : Array(Subject)
        return subjects if @terms.empty?
        subjects.select { |s| matches?(s) }
      end

      def matches?(s : Subject) : Bool
        @terms.all? { |t| match_term(t, s) }
      end

      # --- Tab-complete suggestions (History-style; in-memory over open sessions) ---
      # Returns complete tokens for the whitespace-bounded token under `cx`. Empty
      # when the caret sits on blank space or nothing matches. Value pools for
      # tag/name/host/method come from `subjects` (cardinality is small — open tabs).
      def self.suggestions(query : String, cx : Int32, subjects : Array(Subject)) : Array(String)
        token, _, _ = token_at(query, cx)
        return [] of String if token.empty?
        neg = token.starts_with?('-') && token.size > 1
        core = neg ? token[1..] : token
        neg_p = neg ? "-" : ""
        if colon = core.index(':')
          field_raw = core[0...colon]
          field = field_raw.downcase
          prefix = core[(colon + 1)..]
          # Strip a typed `#` on tags so `tag:#id` still suggests `tag:idor`.
          val_prefix = field == "tag" ? prefix.lstrip('#') : prefix
          suggest_values(field, val_prefix, subjects).map { |v| "#{neg_p}#{field_raw}:#{v}" }
        else
          FIELDS.select(&.starts_with?(core.downcase)).map { |f| "#{neg_p}#{f}:" }
        end
      end

      # Bounds of the token under the caret (History's current_token_bounds shape).
      def self.token_at(query : String, cx : Int32) : {String, Int32, Int32}
        cx = cx.clamp(0, query.size)
        s = cx
        while s > 0 && query[s - 1] != ' '
          s -= 1
        end
        e = cx
        while e < query.size && query[e] != ' '
          e += 1
        end
        {query[s...e], s, e}
      end

      # Host portion of a target URL for `host:` suggestions (falls back to the
      # authority-ish first path segment when URI.parse fails).
      def self.host_of(target : String) : String?
        t = target.strip
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

      private def self.build_term(tok : String, negate : Bool) : Term
        if colon = tok.index(':')
          field = tok[0...colon].downcase
          value = tok[(colon + 1)..].downcase
          case field
          when "tag"            then return Term.new(:tag, value.lstrip('#'), negate)
          when "name"           then return Term.new(:name, value, negate)
          when "host", "target" then return Term.new(:target, value, negate)
          when "method", "verb" then return Term.new(:method, value, negate)
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
