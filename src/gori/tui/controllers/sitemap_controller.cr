require "../tab_controller"
require "../sitemap_view"

module Gori::Tui
  # The Sitemap tab: a host/path tree derived from captured flows. Near
  # pure-delegation to SitemapView — owns the view, frames the body, and routes the
  # sitemap verbs. `reload` is public so the cross-tab scope lens (which filters the
  # tree) can refresh it.
  class SitemapController < TabController
    def initialize(host : Host)
      super(host)
      @sitemap = SitemapView.new
    end

    def tab : Symbol
      :sitemap
    end

    def command_scope : Verb::Scope
      Verb::Scope::Sitemap
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @sitemap.render(screen, inner, focused: focused) }
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = rect.inset(1, 1)
      return true unless ri = @sitemap.row_at(inner, mx, my)
      @sitemap.select_index(ri)
      @sitemap.toggle_at(ri) if @sitemap.marker_hit?(inner, mx, ri)
      true
    end

    def handle_wheel(step : Int32) : Bool
      @sitemap.move(step)
      true
    end

    def body_hint(focus : Symbol) : String
      "↑/↓ move · ↵/→ expand · ← collapse · esc tabs"
    end

    def on_enter : Nil
      reload
    end

    def on_external_change : Nil
      reload
    end

    # Re-derive the tree from the store under the current scope filter. Public so the
    # scope-lens toggle (a cross-tab action mediated by the shell) can refresh it.
    def reload : Nil
      @sitemap.reload(@host.session.store, @host.session.scope.filter)
    end

    # --- verbs (delegated from the Runner's ExecContext) ---
    def sitemap_move(delta : Int32) : Nil
      if delta < 0 && @sitemap.at_top?
        @host.request_focus(:menu) # ↑ at the top node pops up to the tab bar
      else
        @sitemap.move(delta)
      end
    end

    def sitemap_toggle : Nil
      @sitemap.toggle
    end

    def sitemap_expand : Nil
      @sitemap.expand
    end

    def sitemap_collapse : Nil
      @sitemap.collapse # ← collapses the node; at the root it's a no-op (esc goes up, not ←)
    end
  end
end
