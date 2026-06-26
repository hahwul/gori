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

      r.register Verb::Definition.new(
        "sitemap.toggle", "Expand/collapse", "Toggle the selected node", Verb::Scope::Sitemap,
        [Verb::Chord.new("enter"), Verb::Chord.new("space")], hidden: true) { |ctx| ctx.sitemap_toggle; nil }

      r.register Verb::Definition.new(
        "sitemap.expand", "Expand node", "Expand the selected node", Verb::Scope::Sitemap,
        [Verb::Chord.new("right"), Verb::Chord.new("l")], hidden: true) { |ctx| ctx.sitemap_expand; nil }

      r.register Verb::Definition.new(
        "sitemap.collapse", "Collapse node", "Collapse the selected node (esc goes back to the menu)", Verb::Scope::Sitemap,
        [Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.sitemap_collapse; nil }

      r.register Verb::Definition.new(
        "sitemap.query", "Filter (QL)", "Filter the tree with a query (host: path: method: status: …)",
        Verb::Scope::Sitemap, [Verb::Chord.new("/")]) { |ctx| ctx.sitemap_query; nil }

      # Toggle the scope lens from the Sitemap too (History has its own ⇧S binding).
      # scope_toggle_lens reloads the active sitemap, and the bar shows the ⇧S chip —
      # so the toggle is reachable where its effect is visible.
      r.register Verb::Definition.new(
        "sitemap.scope-toggle", "Toggle scope lens", "Filter the tree to in-scope endpoints on/off",
        Verb::Scope::Sitemap, [Verb::Chord.new("s", shift: true)]) { |ctx| ctx.scope_toggle_lens; nil }

      r.register Verb::Definition.new(
        "sitemap.to-menu", "Back to menu", "Move focus up to the tab menu", Verb::Scope::Sitemap,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }
    end
  end
end
