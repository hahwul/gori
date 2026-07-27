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

    # PageUp/PageDown/Home/End over the sitemap tree (view clamps the selection).
    def body_scroll(delta : Int32) : Bool
      end_range_gesture # a page key is cursor nav, like ↑/↓
      @sitemap.move(delta)
      true
    end

    # esc clears the marks. Runs BEFORE the Sitemap keymap, so this shadows sitemap.to-menu
    # ONLY while marks are set — with none set, esc still pops to the sub-tab strip. (The QL
    # bar and the tag editor claim every key ahead of this while either is up, so their own
    # esc handling is unaffected.)
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      return false unless ev.key.escape? && @sitemap.mark_count > 0
      @sitemap.clear_marks
      @host.status("marks cleared")
      true
    end

    def body_badge : Symbol # the QL filter bar / tag editor capture text; else the navigable tree
      @sitemap.querying? || @sitemap.tagging? ? :editor : :body
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      BodyChrome.framed(screen, rect, focus == :body) { |inner| render_content(screen, inner, focus) }
    end

    # Frameless render into an already-inset content rect — the seam TargetController drives
    # so the Sitemap sub-tab draws under the shared Target frame + sub-tab strip.
    def render_content(screen : Screen, content : Rect, focus : Symbol) : Nil
      focused = focus == :body
      proxy = @host.session.proxy
      @sitemap.render(screen, content, focused: focused,
        listen: {proxy.host, proxy.port}, capturing: @host.session.capturing?)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click_content(rect.inset(1, 1), mx, my)
    end

    # Click hit-test against the content rect directly (TargetController passes the rect
    # below its sub-tab strip; the standalone path insets the frame itself).
    def handle_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      return true unless ri = @sitemap.row_at(content, mx, my)
      # A click that MOVES the cursor collapses the range, same as a plain arrow. A click on
      # the row already under the cursor doesn't: that reads as "expand this node" (the marker
      # hit below), not as a selection gesture — the distinction af7e561 drew for the wheel.
      end_range_gesture unless ri == @sitemap.selected_index
      @sitemap.select_index(ri)
      @sitemap.toggle_at(ri) if @sitemap.marker_hit?(content, mx, ri)
      true
    end

    def handle_wheel(step : Int32) : Bool
      # Deliberately NOT end_range_gesture: a wheel reads as "scroll the viewport", not as a
      # selection gesture, so it must not destroy a mark set the way a cursor key does.
      @sitemap.move(step)
      true
    end

    def body_hint(focus : Symbol) : String
      return "type a tag · ↵ save · esc cancel" if @sitemap.tagging?
      return "type query · ↹ complete · ↵ apply · esc clear" if @sitemap.querying?
      # Marks survive a filter change, so the `/` affordance stays up while they're set.
      return "↑/↓ move · / filter · t mark · ⇧T tag · space cmds · esc clears marks" if @sitemap.mark_count > 0
      "↑/↓ move · / filter · t mark · ⇧T tag · g fold · ↵/→ expand · ← collapse · esc tabs"
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
    # ⇧T — open the tag editor over the target set (the marks if any, else the selected
    # node). A synthetic group fold node has no real path, so it can't be tagged — toast
    # instead of opening an empty editor.
    def sitemap_tag : Nil
      n = @sitemap.mark_count
      if @sitemap.start_tag
        subject = n > 0 ? "tag #{paths(n)}" : "tag"
        @host.status("#{subject}: type a memo · ↵ save · esc cancel")
      else
        @host.status("can't tag a fold — expand it and tag a value")
      end
    end

    # Commits/cancels the tag editor. Enter persists the buffer to the (host, path) the
    # editor targets, then reloads so the tag stamps onto the tree (and tag: filters see
    # it). Esc discards. Returns true (swallows) while the editor is open.
    def handle_tag_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then commit_tag
      when key.escape?    then @sitemap.cancel_tag
      when key.left?      then @sitemap.tag_move(-1)
      when key.right?     then @sitemap.tag_move(1)
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
      targets = @sitemap.tag_targets
      if targets.empty?
        @sitemap.cancel_tag
        return
      end
      text = @sitemap.tag_buffer
      store = @host.session.store
      targets.each { |(host, path)| store.set_sitemap_tag(host, path, text) }
      @sitemap.apply_tag(text) # stamp every target in place — keeps the selection, no re-derive
      # A `tag:` filter must re-evaluate against the changed tags (the in-place stamp
      # doesn't re-filter), else the just-tagged node stays hidden / a cleared tag shown.
      reload if @sitemap.filtering?
      n = targets.size
      @host.status(
        if text.empty?
          n == 1 ? "tag cleared" : "cleared #{n} tags"
        else
          n == 1 ? "tagged: #{text}" : "tagged #{paths(n)}: #{text}"
        end)
    end

    private def paths(n : Int32) : String
      "#{n} path#{n == 1 ? "" : "s"}"
    end

    # `g` — fold/unfold path-param ids (uuid/hex/date + numeric runs), then rebuild.
    def sitemap_toggle_grouping : Nil
      @sitemap.toggle_grouping
      reload
      @host.status(@sitemap.grouping? ? "id folding on" : "id folding off")
    end

    # --- marks (multi-select, mirrors History #442) ---------------------------

    def marked_node_count : Int32
      @sitemap.mark_count
    end

    # `t` — flip the cursor row's mark and step down. A fold carries no path, so it can't be
    # marked (nor tagged, nor resolved to an endpoint) — say so rather than eat the key.
    def sitemap_mark_toggle : Nil
      return @host.status("can't mark a fold — expand it and mark a value") unless @sitemap.toggle_mark
      @host.status(mark_status)
    end

    def sitemap_mark_clear : Nil
      @sitemap.clear_marks
      @host.status("marks cleared")
    end

    def sitemap_mark_extend(delta : Int32) : Nil
      @sitemap.extend_marks(delta)
      @host.status(mark_status)
    end

    # Shared mark toast — says the count AND how much of it is off-screen, matching the bar
    # chip: a set spanning collapsed subtrees or a filtered-out path must never look smaller
    # than it is.
    private def mark_status : String
      n = @sitemap.mark_count
      return "no marks — verbs act on the cursor row" if n == 0
      hidden = @sitemap.marked_hidden_count
      msg = "#{paths(n)} marked"
      msg += " (#{hidden} not visible)" if hidden > 0
      msg
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture and hands its marks back
    # (SitemapView#end_mark_gesture). Says so only when marks actually went away, so arrowing
    # down an unmarked tree stays silent — and names what survived, since `t` marks are
    # deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @sitemap.end_mark_gesture == 0
      n = @sitemap.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # --- verbs (delegated from the Runner's ExecContext) ---
    def sitemap_move(delta : Int32) : Nil
      if delta < 0 && @sitemap.at_top?
        @host.request_focus(:subtabs) # ↑ at the top node pops to Target's Sitemap|Discover strip (downgrades to :menu with no strip)
      else
        end_range_gesture
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
