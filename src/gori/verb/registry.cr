require "../fuzzy"

module Gori
  module Verb
    # Holds all verb definitions; the single source the keymap and palette both
    # read from (P1). Space-menu empty lists keep registration order; the Ctrl-P
    # palette (Global, empty query) uses a curated browse order instead.
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

      # True when scope has at least one non-hidden, MENU-KEYED verb tagged with
      # `section` — lets the tab-bar space menu (@focus == :menu) decide whether a
      # scope has its OWN :tab actions or should fall back to :common instead. Must
      # match what open() actually renders (SpaceMenu#open only shows verbs carrying
      # a menu_key), else this could report a section that would render empty.
      def has_section?(scope : Scope, section : Symbol) : Bool
        any? { |v| !v.hidden? && v.scope == scope && v.section == section && v.menu_key }
      end

      # Fail fast on a space-menu key collision WITHIN a displayable view. A view is
      # COMMON ∪ one context section — that's everything the space menu can show at
      # once (COMMON always renders; at most one section joins it, per #open in
      # SpaceMenu). Two non-hidden verbs deriving the same menu_key (an explicit
      # mnemonic, else the first plain single-char chord) that could appear in the
      # SAME view means the later one is silently unreachable by that key —
      # SpaceMenu#verb_for is a first-match find, so the collision has no other
      # symptom. Two DIFFERENT sections may reuse a key freely (e.g. Replay's request
      # `i` and response `i`) since they never render together. Cross-scope reuse is
      # likewise fine (the space menu is scoped), mirroring Conflicts' same-scope
      # rule. space_menu_spec asserts the same invariant; calling this at build time
      # makes it a boot-time guarantee, like the duplicate verb-id raise in #register.
      def validate_menu_keys! : Nil
        by_scope = Hash(Scope, Array(Definition)).new { |h, k| h[k] = [] of Definition }
        each { |v| by_scope[v.scope] << v unless v.hidden? }

        by_scope.each do |scope, verbs|
          common = verbs.select { |v| v.section == :common }
          check_menu_keys!(scope, :common, common)
          sections = verbs.map(&.section).uniq.reject { |s| s == :common }
          sections.each do |section|
            view = common + verbs.select { |v| v.section == section }
            check_menu_keys!(scope, section, view)
          end
        end
      end

      # Raise on the first key collision among `verbs` (one displayable view's worth).
      private def check_menu_keys!(scope : Scope, section : Symbol, verbs : Array(Definition)) : Nil
        seen = {} of Char => String
        verbs.each do |v|
          next unless key = v.menu_key
          if prior = seen[key]?
            raise Gori::Error.new(
              "space-menu key collision: '#{key}' claimed by both #{prior} and #{v.id} in #{scope}/#{section}")
          end
          seen[key] = v.id
        end
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
      #   • space menu → for_scope(current_scope) — only the FOCUSED area's own
      #     actions (Body: replay/copy/open …, Replay: send/new, …).
      # Keeping them disjoint is the whole point: app control never clutters the
      # space menu, and area actions never clutter the palette. Per-verb available? gates
      # (e.g. history.copy only when current_tab == :history).
      def for_scope(scope : Scope, ctx : ExecContext, query : String = "") : Array(Definition)
        candidates = self.select { |v| !v.hidden? && v.scope == scope && v.available?(ctx) }
        # Empty Global browse: curated palette order (Settings → Go to → rest → exit).
        # Other scopes keep registration order; fuzzy queries always rank by score.
        return browse_palette(candidates) if query.empty? && scope == Scope::Global
        rank(candidates, query)
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

      # Ctrl-P empty-query order (stable within each group via registration index):
      #   1. Settings
      #   2. Go to … tab jumps, then other Navigation
      #   3. Everything else (Action / System / …)
      #   4. Back to projects, then Quit gori (exit paths always last)
      private def browse_palette(candidates : Array(Definition)) : Array(Definition)
        candidates.each_with_index.to_a.sort_by { |(v, i)| {palette_group(v), i} }.map { |(v, _)| v }
      end

      private def palette_group(v : Definition) : Int32
        return 90 if v.id == "app.back"
        return 99 if v.id == "app.quit"
        case v.category
        in Category::Settings   then 0
        in Category::Navigation then v.id.starts_with?("tab.") ? 1 : 2
        in Category::Action     then 10
        in Category::System     then 10
        end
      end
    end
  end
end
