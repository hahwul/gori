require "../tab_controller"
require "../sitemap_view"

module Gori::Tui
  # The Sitemap tab: a host/path tree derived from captured flows. Near
  # pure-delegation to SitemapView — owns the view, frames the body, and routes the
  # sitemap verbs. `reload` is public so the cross-tab scope lens (which filters the
  # tree) can refresh it.
  class SitemapController < TabController
    QUERY_DEBOUNCE = 110.milliseconds

    def initialize(host : Host)
      super(host)
      @sitemap = SitemapView.new
      @sitemap.set_scope(@host.session.scope) # honour the lens + show its chip on the bar
      @query_reload_at = nil.as(Time::Instant?)
    end

    def view : SitemapView
      @sitemap
    end

    def tab : Symbol
      :sitemap
    end

    def command_scope : Verb::Scope
      Verb::Scope::Sitemap
    end

    def body_badge : Symbol # the QL filter bar / tag editor capture text; else the navigable tree
      @sitemap.querying? || @sitemap.tagging? ? :editor : :body
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      proxy = @host.session.proxy
      BodyChrome.framed(screen, rect, focused) do |inner|
        @sitemap.render(screen, inner, focused: focused,
          listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
      end
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
      return "type a tag · ↵ save · esc cancel" if @sitemap.tagging?
      @sitemap.querying? ? "type query · ↹ complete · ↵ apply · esc clear" \
                         : "↑/↓ move · / filter · t tag · g group · ↵/→ expand · ← collapse · esc tabs"
    end

    # Live IME composition flows to whichever text field is open (the QL filter bar or
    # the tag editor) — so Hangul composes live in both.
    def set_preedit(text : String) : Bool
      if @sitemap.tagging?
        @sitemap.set_tag_preedit(text)
        return true
      end
      return false unless @sitemap.querying?
      @sitemap.set_preedit(text)
      true
    end

    def on_enter : Nil
      reload
    end

    def on_external_change : Nil
      reload
    end

    # Re-derive the tree from the store under the current scope filter + `/` query
    # (both held by the view). Public so the scope-lens toggle (a cross-tab action
    # mediated by the shell) can refresh it.
    def reload : Nil
      @sitemap.reload(@host.session.store)
    end

    # --- QL filter bar (a text sub-mode; the shell claims it before the focus ring) ---
    # Returns true (swallows). Mirrors HistoryController#handle_query_key.
    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      store = @host.session.store
      case
      when key.enter?     then flush_query_reload; @sitemap.stop_query
      when key.escape?    then @query_reload_at = nil; @sitemap.cancel_query; @sitemap.reload(store)
      when key.tab?       then (@sitemap.query_complete; schedule_query_reload)
      when key.backspace? then @sitemap.query_backspace; schedule_query_reload
      when key.left?      then @sitemap.query_move(-1)
      when key.right?     then @sitemap.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @sitemap.query_insert(c)
          schedule_query_reload
          @sitemap.set_preedit("") # clear preedit on committed char
        end
      end
      true
    end

    # Called each run-loop tick: run the debounced filter reload if the deadline
    # passed. Returns true when it flushed (→ the shell marks the frame dirty).
    def flush_query_reload_if_due(now : Time::Instant) : Bool
      if (deadline = @query_reload_at) && now >= deadline
        flush_query_reload
        return true
      end
      false
    end

    # Defer the (potentially 10k-node) tree rebuild until typing pauses.
    private def schedule_query_reload : Nil
      @query_reload_at = Time.instant + QUERY_DEBOUNCE
    end

    private def flush_query_reload : Nil
      return unless @query_reload_at
      @query_reload_at = nil
      @sitemap.reload(@host.session.store)
    end

    # `/` — focus the QL filter bar (verb-dispatched).
    def sitemap_query : Nil
      @sitemap.start_query
      @host.status("filter: type a query · ↹ complete · ↵ apply · esc clear")
    end

    # --- tag editor (a text sub-mode; the shell routes its keys via handle_tag_key) ---
    # `t` — open the tag editor for the selected node. A synthetic group fold node has
    # no real path, so it can't be tagged — toast instead of opening an empty editor.
    def sitemap_tag : Nil
      if @sitemap.start_tag
        @host.status("tag: type a memo · ↵ save · esc cancel")
      else
        @host.status("can't tag a [grouped] sequence — expand it and tag a value")
      end
    end

    # Commits/cancels the tag editor. Enter persists the buffer to the (host, path) the
    # editor targets, then reloads so the tag stamps onto the tree (and tag: filters see
    # it). Esc discards. Returns true (swallows) while the editor is open.
    def handle_tag_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?  then commit_tag
      when key.escape? then @sitemap.cancel_tag
      when key.left?   then @sitemap.tag_move(-1)
      when key.right?  then @sitemap.tag_move(1)
      when key.backspace? then @sitemap.tag_backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          @sitemap.tag_insert(c)
          @sitemap.set_tag_preedit("") # clear preedit on committed char
        end
      end
      true
    end

    private def commit_tag : Nil
      if target = @sitemap.tag_target
        host, path = target
        text = @sitemap.tag_buffer
        @host.session.store.set_sitemap_tag(host, path, text)
        @sitemap.apply_tag(text) # stamp in place — keeps the selection, no re-derive
        # A `tag:` filter must re-evaluate against the changed tag (the in-place stamp
        # doesn't re-filter), else the just-tagged node stays hidden / a cleared tag shown.
        reload if @sitemap.filtering?
        @host.status(text.empty? ? "tag cleared" : "tagged: #{text}")
      else
        @sitemap.cancel_tag
      end
    end

    # `g` — fold/unfold numeric path-param sequences, then rebuild the tree.
    def sitemap_toggle_grouping : Nil
      @sitemap.toggle_grouping
      reload
      @host.status(@sitemap.grouping? ? "grouping sequences on" : "grouping sequences off")
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
