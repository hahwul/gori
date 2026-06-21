require "../fuzzy"

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
        rank(self.select { |v| !v.hidden? && v.available?(ctx) }, query)
      end

      # Like #search, but narrowed to the verbs that can fire in `scope` — plus
      # Global, which fires everywhere. Backs the ":" context command line so it
      # only offers actions relevant to the focused area. (Body covers the History
      # list etc.; the per-verb available? gates further narrow it to the active
      # tab — e.g. history.copy only when current_tab == :history.)
      def for_scope(scope : Scope, ctx : ExecContext, query : String = "") : Array(Definition)
        candidates = self.select { |v| !v.hidden? && (v.scope == scope || v.scope.global?) && v.available?(ctx) }
        return rank(candidates, query) unless query.empty?
        # Empty query: the focus area's OWN actions first, the always-available
        # Global commands after (partition is stable → registration order within each).
        local, global = candidates.partition { |v| !v.scope.global? }
        local + global
      end

      # Shared filter→rank tail: an empty query keeps registration order (browsable);
      # otherwise fuzzy-score "title id" and sort best-first.
      private def rank(candidates : Array(Definition), query : String) : Array(Definition)
        return candidates if query.empty?

        scored = candidates.compact_map do |v|
          if score = Gori::Fuzzy.score(query.downcase, "#{v.title} #{v.id}".downcase)
            {v, score}
          end
        end
        scored.sort_by! { |(_, score)| -score }.map { |(v, _)| v }
      end
    end
  end
end
