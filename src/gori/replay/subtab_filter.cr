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
