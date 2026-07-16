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

      # `t` — tag the selected path with a free-text memo (a group fold node toasts).
      r.register Verb::Definition.new(
        "sitemap.tag", "Tag path", "Pin a free-text memo to the selected path (filter with tag:)",
        Verb::Scope::Sitemap, [Verb::Chord.new("t")]) { |ctx| ctx.sitemap_tag; nil }

      # `g` — fold/unfold numeric path-param sequences (/users/1,2,3… → [1, 2, 3 … +N]).
      r.register Verb::Definition.new(
        "sitemap.toggle-grouping", "Group sequences", "Fold numeric path-param sequences into [1, 2, 3 …] groups",
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

      # `r` — send the selected endpoint to Repeater (resolves a representative captured flow).
      r.register Verb::Definition.new(
        "sitemap.repeater", "Send to Repeater", "Open the selected endpoint's captured request in Repeater",
        Verb::Scope::Sitemap, [Verb::Chord.new("r")], mnemonic: 'r') { |ctx| ctx.sitemap_repeater; nil }

      r.register Verb::Definition.new(
        "sitemap.to-menu", "Back to menu", "Move focus up to the tab menu", Verb::Scope::Sitemap,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }
    end
  end
end
