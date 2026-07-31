require "../verb"

module Gori
  module Verbs
    def self.register_sitemap(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "sitemap.down", "Select next node", "Move down the tree", Verb::Scope::Sitemap,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.sitemap_move(1); nil }

      r.register Verb::Definition.new(
        "sitemap.up", "Select previous node", "Move up the tree", Verb::Scope::Sitemap,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.sitemap_move(-1); nil }

      # `enter` toggles; `space` is intentionally free so it opens the Sitemap action
      # menu (the helix leader) — the redundant expand binding was dropped.
      r.register Verb::Definition.new(
        "sitemap.toggle", "Expand/collapse", "Toggle the selected node", Verb::Scope::Sitemap,
        [Verb::Chord.new("enter")], hidden: true) { |ctx| ctx.sitemap_toggle; nil }

      r.register Verb::Definition.new(
        "sitemap.expand", "Expand node", "Expand the selected node", Verb::Scope::Sitemap,
        [Verb::Chord.new("right"), Verb::Chord.new("l")], hidden: true) { |ctx| ctx.sitemap_expand; nil }

      r.register Verb::Definition.new(
        "sitemap.collapse", "Collapse node", "Collapse the selected node (esc goes back to the menu)", Verb::Scope::Sitemap,
        [Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.sitemap_collapse; nil }

      r.register Verb::Definition.new(
        "sitemap.query", "Filter (QL)", "Filter the tree with a query (host: path: method: status: tag: …)",
        Verb::Scope::Sitemap, [Verb::Chord.new("/")]) { |ctx| ctx.sitemap_query; nil }

      # --- multi-select marks (mirrors History #442) ---
      # Marks make the EXISTING action menu act on N paths — the batch verbs below read the
      # view's target set ("the marks if any, else the cursor row"), so there are no
      # `sitemap.batch-*` twins and no second menu: one declaration, one call path.
      #
      # `t` marks here as it does in History (mutt's tag key, and the same many-times-per-minute
      # triage gesture that earns it an L1 bare key there). Tagging moves up to ⇧T, so the two
      # lists finally agree on what `t` means. NOTE the deliberate divergence from History's ⇧T
      # (mark-all): a tree has no useful "mark every row" — it would sweep hosts and folders
      # into the same batch as the endpoints under them.
      r.register Verb::Definition.new(
        "sitemap.mark-toggle", "Mark path", "Mark/unmark this path and step down — the action menu then acts on every marked path",
        Verb::Scope::Sitemap, [Verb::Chord.new("t")]) { |ctx| ctx.sitemap_mark_toggle; nil }

      # ⇧↑/⇧↓ extend a contiguous range from the anchor — the keyboard form of a GUI
      # shift+click. Free in this scope: Keymap#lookup matches a Chord record EXACTLY, so
      # Chord("up", shift: true) never collided with sitemap.up's Chord("up") — it simply fell
      # through to a no-op. Hidden like the other nav primitives (sitemap.up/down).
      r.register Verb::Definition.new(
        "sitemap.mark-extend-down", "Extend marks down", "Extend the marked range one row down",
        Verb::Scope::Sitemap, [Verb::Chord.new("down", shift: true)],
        hidden: true) { |ctx| ctx.sitemap_mark_extend(1); nil }

      r.register Verb::Definition.new(
        "sitemap.mark-extend-up", "Extend marks up", "Extend the marked range one row up",
        Verb::Scope::Sitemap, [Verb::Chord.new("up", shift: true)],
        hidden: true) { |ctx| ctx.sitemap_mark_extend(-1); nil }

      # esc clears too (SitemapController#handle_body_key shadows sitemap.to-menu only while
      # marks are set) — that's the reflex; this is the discoverable form. Menu-only: 'N' is
      # free in this scope, and clearing is not worth a chord of its own.
      r.register Verb::Definition.new(
        "sitemap.mark-clear", "Clear marks", "Drop every mark (esc does the same)",
        Verb::Scope::Sitemap,
        available: ->(ctx : Verb::ExecContext) { ctx.sitemap_marked_count > 0 },
        mnemonic: 'N') { |ctx| ctx.sitemap_mark_clear; nil }

      # ⇧T — tag the selected path (or every marked path) with a free-text memo; a group fold
      # node toasts. The chord is Chord.new("t", shift: true), NOT Chord.new("T") —
      # Keybind.from_event normalises a typed capital to shift+lowercase, so a "T" chord would
      # never fire; menu_key skips shift chords, hence the explicit mnemonic.
      r.register Verb::Definition.new(
        "sitemap.tag", "Tag path", "Pin a free-text memo to the selected — or every marked — path (filter with tag:)",
        Verb::Scope::Sitemap, [Verb::Chord.new("t", shift: true)],
        mnemonic: 'T') { |ctx| ctx.sitemap_tag; nil }

      # `g` — fold/unfold path-param ids (/users/<uuid> → {uuid}, /users/1,2,3… → [1, 2, 3 … +N]).
      r.register Verb::Definition.new(
        "sitemap.toggle-grouping", "Fold ids", "Fold path-param ids into {uuid}/{hex}/{date} and [1, 2, 3 …] groups",
        Verb::Scope::Sitemap, [Verb::Chord.new("g")]) { |ctx| ctx.sitemap_toggle_grouping; nil }

      # Toggle the scope lens from the Sitemap too (History has its own ⇧S binding).
      # scope_toggle_lens reloads the active sitemap, and the bar shows the ⇧S chip —
      # so the toggle is reachable where its effect is visible. Mnemonic 's' for the
      # action menu (its only chord is ⇧S, which yields no menu key).
      r.register Verb::Definition.new(
        "sitemap.scope-toggle", "Toggle scope lens", "Filter the tree to in-scope endpoints on/off",
        Verb::Scope::Sitemap, [Verb::Chord.new("s", shift: true)], mnemonic: 's') { |ctx| ctx.scope_toggle_lens; nil }

      # `d` — spider + brute-force the selected host/path (opens the Discover config popup).
      r.register Verb::Definition.new(
        "sitemap.discover", "Discover here", "Spider + brute-force the selected host or path subtree",
        Verb::Scope::Sitemap, [Verb::Chord.new("d")], mnemonic: 'd') { |ctx| ctx.sitemap_discover; nil }

      # `o` — read the bytes behind the selected endpoint: resolve its representative captured
      # flow and open History's detail on it. Same chord and same shape as the Issues tab's
      # `issue.open-flow` (verbs/issues.cr) and Probe's `probe.open-flow` — "o opens the
      # evidence" is now one gesture everywhere a list row stands in for a flow.
      #
      # Cursor-only even with marks set (SITEMAP_CURSOR_ONLY in runner.cr): a detail overlay
      # shows one flow, so there is nothing for a batch to mean here.
      r.register Verb::Definition.new(
        "sitemap.open-flow", "Open flow", "Open the selected endpoint's captured request/response in History",
        Verb::Scope::Sitemap, [Verb::Chord.new("o")], mnemonic: 'o') { |ctx| ctx.sitemap_open_flow; nil }

      # `r` — send the selected endpoint (or every marked one) to Repeater, resolving a
      # representative captured flow per path.
      r.register Verb::Definition.new(
        "sitemap.repeater", "Send to Repeater", "Open the selected — or every marked — endpoint's captured request in Repeater",
        Verb::Scope::Sitemap, [Verb::Chord.new("r")], mnemonic: 'r') { |ctx| ctx.sitemap_repeater; nil }

      r.register Verb::Definition.new(
        "sitemap.to-menu", "Back to sub-tabs", "Move focus up to the Sitemap/Discover strip", Verb::Scope::Sitemap,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:subtabs); nil }
    end
  end
end
