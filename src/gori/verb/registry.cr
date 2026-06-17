module Gori
  module Verb
    # Holds all verb definitions; the single source the keymap and palette both
    # read from (P1). Registration order is preserved for stable palette listing.
    class Registry
      include Enumerable(Definition)

      def initialize
        @by_id = {} of String => Definition
        @order = [] of String
      end

      def register(verb : Definition) : Nil
        raise Gori::Error.new("duplicate verb id: #{verb.id}") if @by_id.has_key?(verb.id)
        @by_id[verb.id] = verb
        @order << verb.id
      end

      def []?(id : String) : Definition?
        @by_id[id]?
      end

      def [](id : String) : Definition
        @by_id[id]? || raise Gori::Error.new("unknown verb id: #{id}")
      end

      def each(& : Definition ->)
        @order.each { |id| yield @by_id[id] }
      end

      def size : Int32
        @order.size
      end

      # Palette search: non-hidden, context-available verbs matching `query` by
      # fuzzy subsequence, ranked best-first. An empty query lists everything
      # (in registration order) so the palette is browsable.
      def search(query : String, ctx : ExecContext) : Array(Definition)
        candidates = self.select { |v| !v.hidden? && v.available?(ctx) }
        return candidates if query.empty?

        scored = candidates.compact_map do |v|
          if score = fuzzy_score(query.downcase, "#{v.title} #{v.id}".downcase)
            {v, score}
          end
        end
        scored.sort_by! { |(_, score)| -score }.map { |(v, _)| v }
      end

      # Subsequence match: every query char appears in order. Score rewards
      # contiguous runs and earlier matches. Returns nil if not a subsequence.
      private def fuzzy_score(query : String, text : String) : Int32?
        score = 0
        ti = 0
        run = 0
        query.each_char do |qc|
          found = false
          while ti < text.size
            tc = text[ti]
            ti += 1
            if tc == qc
              run += 1
              score += 10 + run * 5 - ti # contiguity bonus, earlier-is-better
              found = true
              break
            else
              run = 0
            end
          end
          return nil unless found
        end
        score
      end
    end
  end
end
