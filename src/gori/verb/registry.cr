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

      # Find across ALL scopes: non-hidden, context-available verbs matching `query`
      # by fuzzy subsequence, ranked best-first. The general primitive (used in tests
      # and future surfaces); the two TUI surfaces use the scoped #for_scope below.
      def search(query : String, ctx : ExecContext) : Array(Definition)
        rank(self.select { |v| !v.hidden? && v.available?(ctx) }, query)
      end

      # Verbs that fire in EXACTLY `scope` (no Global fallback). This backs the two
      # deliberately-distinct command surfaces:
      #   • Ctrl-P palette → for_scope(Global)  — gori-wide app control (settings,
      #     capture, scope/rules, tab nav, quit …).
      #   • ":" command line → for_scope(current_scope) — only the FOCUSED area's
      #     own actions (Body: replay/copy/open …, Replay: send/new, …).
      # Keeping them disjoint is the whole point: app control never clutters ":",
      # and area actions never clutter the palette. Per-verb available? still gates
      # (e.g. history.copy only when current_tab == :history).
      def for_scope(scope : Scope, ctx : ExecContext, query : String = "") : Array(Definition)
        rank(self.select { |v| !v.hidden? && v.scope == scope && v.available?(ctx) }, query)
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
