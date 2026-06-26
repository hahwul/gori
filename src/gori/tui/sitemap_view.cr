require "uri"
require "./screen"
require "./theme"
require "../store"
require "../ql"
require "../scope"

module Gori::Tui
  # The Sitemap tab: a literal host → path tree built from captured flows (no ID
  # templating — every distinct segment is its own node, P3/DESIGN.md §3). Helps
  # answer "what does this app do". Navigate with ↑/↓, expand/collapse with
  # →/←/Enter.
  class SitemapView
    # One tree node: a host (depth 0) or a path segment.
    class Node
      getter label : String
      getter children : Array(Node)
      property methods : Array(String)
      property expanded : Bool

      def initialize(@label : String)
        @children = [] of Node
        @methods = [] of String
        @expanded = true
      end

      def child(label : String) : Node
        @children.find { |c| c.label == label } || begin
          node = Node.new(label)
          @children << node
          node
        end
      end

      def leaf? : Bool
        @children.empty?
      end
    end

    # The QL fields meaningful for the endpoint tree (no `flag` — tags aren't
    # produced yet). Mirrors History's set so the same `/` query language applies.
    QL_FIELDS = %w(host path method status scheme body)

    def initialize
      @hosts = [] of Node
      @selected = 0
      @scroll = 0
      @loaded = false
      # Flattened (node, depth) rows, rebuilt only when the tree or its expand
      # state changes — not re-walked on every render frame.
      @visible_cache = nil.as(Array({Node, Int32})?)
      # QL filter bar (mirrors HistoryView): the Scope lens + a `/` query are AND-ed
      # into the one filter that builds the tree.
      @scope = nil.as(Scope?)
      @query = ""
      @querying = false
      @qcx = 0      # caret position within @query
      @preedit = "" # IME composition, drawn at the caret
    end

    # Inject the Scope lens so the tree honours it AND the bar can show its state
    # (the scope chip). Mirrors HistoryController wiring the same Scope into its view.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    def reload(store : Store) : Nil
      combined = QL.and(@scope.try(&.filter) || QL::EMPTY, QL.parse(@query))
      @hosts = [] of Node
      store.sitemap_entries(combined).each do |(host, method, target)|
        add(host, normalize_path(target), method)
      end
      @selected = 0
      @scroll = 0
      @visible_cache = nil
      @loaded = true
    end

    def move(delta : Int32) : Nil
      rows = visible_rows
      return if rows.empty?
      @selected = (@selected + delta).clamp(0, rows.size - 1)
    end

    # At the first (top) node — lets the Runner pop focus to the tab bar on ↑.
    def at_top? : Bool
      @selected == 0
    end

    def toggle : Nil
      node = selected_node
      return unless node && !node.leaf?
      node.expanded = !node.expanded
      @visible_cache = nil # expand state changed → re-flatten next render
    end

    def expand : Nil
      node = selected_node
      return unless node && !node.leaf?
      node.expanded = true
      @visible_cache = nil
    end

    # Collapses the selected node; returns false if there was nothing to collapse
    # (so the caller can move focus out to the sidebar).
    def collapse : Bool
      node = selected_node
      if node && !node.leaf? && node.expanded
        node.expanded = false
        @visible_cache = nil
        true
      else
        false
      end
    end

    # --- QL filter bar (mirrors HistoryView) ---------------------------------

    def querying? : Bool
      @querying
    end

    # True when the tree is a filtered subset (a `/` query or the Scope lens is on).
    def filtering? : Bool
      !@query.blank? || (@scope.try(&.active?) == true)
    end

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil # Enter: keep the filter, leave edit mode
      @querying = false
    end

    def cancel_query : Nil # Esc: clear the filter, leave edit mode
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Tab-complete the current token to the first field-name suggestion.
    def query_complete : Bool
      sugg = query_suggestions
      return false if sugg.empty?
      s, e = current_token_bounds
      @query = "#{@query[0, s]}#{sugg.first}#{@query[e..]}"
      @qcx = s + sugg.first.size
      true
    end

    # Field-name suggestions for the token under the cursor (values aren't suggested
    # — the tree's useful axes are host/path/method, which are open-ended).
    def query_suggestions : Array(String)
      token = current_token
      return [] of String if token.empty? || token.includes?(':')
      QL_FIELDS.select(&.starts_with?(token.downcase)).map { |f| "#{f}:" }
    end

    private def current_token : String
      s, e = current_token_bounds
      @query[s...e]
    end

    private def current_token_bounds : {Int32, Int32}
      s = @qcx
      while s > 0 && @query[s - 1] != ' '
        s -= 1
      end
      e = @qcx
      while e < @query.size && @query[e] != ' '
        e += 1
      end
      {s, e}
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      render_ql_bar(screen, rect)
      # The bar takes the top row; while querying a suggestion row sits below it.
      offset = bar_rows
      tree = Rect.new(rect.x, rect.y + offset, rect.w, {rect.h - offset, 0}.max)
      return if tree.h <= 0

      unless @loaded && !@hosts.empty?
        msg = filtering? ? "no endpoints match" : "no traffic captured yet"
        screen.text(tree.x + 1, tree.y, msg, Theme.muted)
        screen.text(tree.x + 1, tree.y + 2, "browse through the proxy, then return here", Theme.muted) unless filtering?
        return
      end

      rect = tree
      rows = visible_rows
      ensure_visible(rows.size, rect.h)
      (0...rect.h).each do |i|
        ri = @scroll + i
        break if ri >= rows.size
        node, depth = rows[ri]
        y = rect.y + i
        selected = ri == @selected
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme.accent, bg)
        end

        marker = node.leaf? ? " " : (node.expanded ? "▾" : "▸")
        x = rect.x + 1 + depth * 2
        screen.cell(x, y, marker[0], Theme.muted, bg)
        fg = depth == 0 ? Theme.text_bright : Theme.text
        x = screen.text(x + 2, y, node.label, fg, bg)
        unless node.methods.empty?
          tag = node.methods.join(" ")
          screen.text({rect.right - tag.size - 1, x + 1}.max, y, tag, Theme.muted, bg)
        end
      end
    end

    # Rows the QL bar occupies at the top of the body: 1 (the bar) + 1 suggestion
    # row while querying. The tree renders below it; clicks subtract the same offset.
    private def bar_rows : Int32
      @querying ? 2 : 1
    end

    private def render_ql_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "query › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright, width: rect.w - prefix.size - 2)
        render_suggestions(screen, rect, rect.y + 1)
        return
      end

      # Right cluster: the scope-lens chip (always shown so the ⇧S toggle is
      # discoverable — the Scope lens filters the tree too) and, when filtering, the
      # matching host count.
      scope_on = @scope.try(&.active?) == true
      chip, chip_color = scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted}
      rx = rect.right - 1
      if filtering?
        count = "#{@hosts.size}h"
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end
      screen.text({rx - chip.size, rect.x}.max, rect.y, chip, chip_color)

      left_w = {(rx - chip.size) - (rect.x + 1) - 1, 0}.max
      if filtering?
        label = @query.blank? ? "(in-scope only)" : ": #{@query}"
        screen.text(rect.x + 1, rect.y, label, Theme.text, width: left_w)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  host:  method:  path:  status:>=500", Theme.muted, width: left_w)
      end
    end

    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      sugg = query_suggestions
      return if sugg.empty?
      screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme.muted, width: rect.w - 2)
    end

    # Inverts render's tree placement (offset below the QL bar) to find which
    # visible_rows index a click lands on; nil past the last populated row.
    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if mx < rect.x || mx >= rect.right # reject the frame border columns (mirror the other list helpers)
      i = my - (rect.y + bar_rows)
      return nil if i < 0 || i >= {rect.h - bar_rows, 0}.max
      idx = @scroll + i
      idx < visible_rows.size ? idx : nil
    end

    # Inverts render's marker column `rect.x + 1 + depth*2` for visible_rows[ri].
    def marker_hit?(rect : Rect, mx : Int32, ri : Int32) : Bool
      row = visible_rows[ri]?
      return false unless row
      mx == rect.x + 1 + row[1] * 2
    end

    # Mirrors `move`: set @selected clamped to the populated rows.
    def select_index(idx : Int32) : Nil
      rows = visible_rows
      return if rows.empty?
      @selected = idx.clamp(0, rows.size - 1)
    end

    # Single-click design: select the row, then expand/collapse it via `toggle`.
    def toggle_at(idx : Int32) : Nil
      select_index(idx)
      toggle
    end

    private def selected_node : Node?
      rows = visible_rows
      rows[@selected]?.try(&.[0])
    end

    private def visible_rows : Array({Node, Int32})
      @visible_cache ||= begin
        rows = [] of {Node, Int32}
        @hosts.each { |host| collect(host, 0, rows) }
        rows
      end
    end

    private def collect(node : Node, depth : Int32, rows : Array({Node, Int32})) : Nil
      rows << {node, depth}
      return unless node.expanded
      node.children.each { |child| collect(child, depth + 1, rows) }
    end

    private def add(host : String, path : String, method : String) : Nil
      host_node = @hosts.find { |h| h.label == host } || begin
        node = Node.new(host)
        @hosts << node
        node
      end
      segments = path.split('/').reject(&.empty?)
      node = segments.empty? ? host_node.child("/") : segments.reduce(host_node) { |n, seg| n.child(seg) }
      node.methods << method unless node.methods.includes?(method)
    end

    private def normalize_path(target : String) : String
      return target unless target.starts_with?("http://") || target.starts_with?("https://")
      uri = URI.parse(target)
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    rescue
      target
    end

    private def ensure_visible(total : Int32, h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
