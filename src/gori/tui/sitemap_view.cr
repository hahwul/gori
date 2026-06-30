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
      # Scope state, meaningful only on host (depth-0) nodes — stamped by `reload` so
      # the render loop doesn't re-evaluate the (mutex-guarded) Scope every frame.
      property in_scope : Bool
      property endpoints : Int32 # # of captured endpoints (nodes with methods) under it
      # Full URL path from the host root ("" on the host node, "/" for the bare root),
      # stamped during `add`. Stable regardless of how grouping later reshapes the tree,
      # so it's the durable key for a path tag.
      property path : String
      # Optional free-text memo pinned to this (host, path), stamped from the store each
      # reload (V17). nil = untagged.
      property tag : String?
      # A synthetic `[1, 2, 3 … +N]` fold node: its children are real numeric siblings
      # collapsed by `group_sequences`. Not a real path — never tagged, never keyed.
      property grouped : Bool

      def initialize(@label : String)
        @children = [] of Node
        @methods = [] of String
        @expanded = true
        @in_scope = false
        @endpoints = 0
        @path = ""
        @tag = nil
        @grouped = false
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

    # A flattened tree row. `guides` is a bitmask: bit L set ⇒ a vertical `│` tree-guide
    # is drawn at ancestor level L (its branch continues below this row). Built once per
    # tree/expand change in `collect`, not re-walked per frame.
    private record VisibleRow, node : Node, depth : Int32, guides : UInt64

    # The QL fields meaningful for the endpoint tree. Mirrors History's set so the same
    # `/` query language applies, plus `tag:` — a Sitemap-local field (handled here, not
    # in the shared QL) that filters the tree by a node's path memo.
    QL_FIELDS = %w(host path method status scheme body header size dur tag)

    # Pure-numeric siblings beyond this count under one parent fold into a single
    # `[1, 2, 3 … +N]` group node (path-param explosion like /users/1,2,3…).
    SEQUENCE_GROUP_THRESHOLD = 10

    def initialize
      @hosts = [] of Node
      @selected = 0
      @scroll = 0
      @loaded = false
      # Flattened rows (node, depth, tree-guide bitmask), rebuilt only when the tree or
      # its expand state changes — not re-walked on every render frame.
      @visible_cache = nil.as(Array(VisibleRow)?)
      # Whether the Scope has any rules — gates the scope markers/dimming on host rows
      # (stamped each reload so render needn't touch the mutex-guarded Scope).
      @scope_configured = false
      # QL filter bar (mirrors HistoryView): the Scope lens + a `/` query are AND-ed
      # into the one filter that builds the tree.
      @scope = nil.as(Scope?)
      @query = ""
      @querying = false
      @qcx = 0      # caret position within @query
      @preedit = "" # IME composition, drawn at the caret
      # Numeric-sequence folding (Feature: path-param explosion). On by default; `g`
      # toggles it for the rare case of wanting every literal id.
      @grouping = true
      # Tag editor — a one-line text sub-mode (mirrors the QL `/` bar) that edits the
      # selected node's path memo. The controller persists @tag_buffer on commit.
      @tagging = false
      @tag_buffer = ""
      @tag_cx = 0
      @tag_preedit = ""
      # The (host, path) the open editor targets, PINNED at start_tag — a mid-edit external
      # reload resets @selected to 0, so a selection-based lookup at commit would tag the
      # wrong (usually top host) node. Pinning keeps the tag landing on the intended node.
      @tag_host = ""
      @tag_path = ""
    end

    # Inject the Scope lens so the tree honours it AND the bar can show its state
    # (the scope chip). Mirrors HistoryController wiring the same Scope into its view.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    def reload(store : Store) : Nil
      # `tag:`/`-tag:` are Sitemap-local (the shared QL has no tag column): split them
      # out, hand the residual to QL.parse, and apply the tag filter to the built tree.
      positives, negatives, residual = split_tag_terms(@query)
      combined = QL.and(@scope.try(&.filter) || QL::EMPTY, QL.parse(residual))
      @hosts = [] of Node
      store.sitemap_entries(combined).each do |(host, method, target)|
        add(host, normalize_path(target), method)
      end
      stamp_tags(store.sitemap_tags)
      filter_by_tags(positives, negatives)
      @hosts.each { |h| group_sequences(h) } if @grouping
      # Stamp host-level scope state + endpoint counts on the FINAL tree, so the render
      # loop is a pure read (no per-frame Scope mutex hits). host_in_scope?/configured?
      # evaluate the rules regardless of the ⇧S enabled flag, so targets are marked even
      # with the lens off (all traffic shown).
      @scope_configured = @scope.try(&.configured?) == true
      @hosts.each do |h|
        h.in_scope = @scope_configured && (@scope.try(&.host_in_scope?(h.label)) == true)
        h.endpoints = endpoint_count(h)
      end
      @selected = 0
      @scroll = 0
      @visible_cache = nil
      @loaded = true
    end

    # --- tags: stamp / filter ------------------------------------------------

    # Pin each node's memo from the (host, path) ⇒ tag map (one store read per reload).
    private def stamp_tags(tags : Hash({String, String}, String)) : Nil
      return if tags.empty?
      @hosts.each { |h| stamp_node_tags(h, h.label, tags) }
    end

    private def stamp_node_tags(node : Node, host : String, tags : Hash({String, String}, String)) : Nil
      node.tag = tags[{host, node.path}]?
      node.children.each { |c| stamp_node_tags(c, host, tags) }
    end

    # Split `tag:`/`-tag:` tokens out of the query (whitespace-tokenised, matching
    # QL.parse). Returns positive + negative keywords (lowercased) and the residual
    # query for QL.parse.
    private def split_tag_terms(query : String) : {Array(String), Array(String), String}
      positives = [] of String
      negatives = [] of String
      residual = [] of String
      query.split.each do |tok|
        if (v = tag_token_value(tok, "tag:")) && !v.empty?
          positives << v.downcase
        elsif (v = tag_token_value(tok, "-tag:")) && !v.empty?
          negatives << v.downcase
        else
          residual << tok
        end
      end
      {positives, negatives, residual.join(' ')}
    end

    private def tag_token_value(tok : String, prefix : String) : String?
      tok.downcase.starts_with?(prefix) ? tok[prefix.size..] : nil
    end

    # Prune the tree to tag matches: a node survives a positive term if it (or an
    # ancestor) carries a matching tag, or any descendant does (so a tagged folder
    # shows its subtree + the path to it). A negative term drops the matched subtree.
    private def filter_by_tags(positives : Array(String), negatives : Array(String)) : Nil
      @hosts.select! { |h| keep_for_tags?(h, positives, false) } unless positives.empty?
      @hosts.select! { |h| !exclude_for_tags?(h, negatives) } unless negatives.empty?
    end

    # Returns true if `node` survives; prunes non-surviving children in place. `inside`
    # = an ancestor already matched all positives ⇒ keep the whole subtree.
    private def keep_for_tags?(node : Node, positives : Array(String), inside : Bool) : Bool
      within = inside || tag_has_all?(node, positives)
      kept_child = false
      node.children.select! do |c|
        keep = keep_for_tags?(c, positives, within)
        kept_child ||= keep
        keep
      end
      within || kept_child
    end

    # Returns true if `node`'s subtree should be dropped (it carries a negative tag);
    # otherwise prunes any dropped descendants in place.
    private def exclude_for_tags?(node : Node, negatives : Array(String)) : Bool
      return true if tag_has_any?(node, negatives)
      node.children.reject! { |c| exclude_for_tags?(c, negatives) }
      false
    end

    private def tag_has_all?(node : Node, keywords : Array(String)) : Bool
      t = node.tag
      return false unless t
      down = t.downcase
      keywords.all? { |kw| down.includes?(kw) }
    end

    private def tag_has_any?(node : Node, keywords : Array(String)) : Bool
      t = node.tag
      return false unless t
      down = t.downcase
      keywords.any? { |kw| down.includes?(kw) }
    end

    # --- numeric-sequence grouping -------------------------------------------

    # Fold a node's pure-numeric children into one collapsed `[1, 2, 3 … +N]` group when
    # they exceed the threshold; non-numeric siblings stay put. Recurses first so nested
    # sequences fold too. Sorting by (length, lexicographic) is numeric order without
    # parsing (handles arbitrarily long ids, no overflow).
    private def group_sequences(node : Node) : Nil
      node.children.each { |c| group_sequences(c) }
      numeric = node.children.select { |c| !c.grouped && numeric_label?(c.label) }
      return if numeric.size <= SEQUENCE_GROUP_THRESHOLD
      numeric.sort_by! { |c| {c.label.size, c.label} }
      rest = node.children.select { |c| c.grouped || !numeric_label?(c.label) }
      group = Node.new(group_label(numeric))
      group.grouped = true
      group.expanded = false
      numeric.each { |c| group.children << c }
      node.children.clear
      node.children.concat(rest)
      node.children << group
    end

    private def numeric_label?(label : String) : Bool
      !label.empty? && label.each_char.all?(&.ascii_number?)
    end

    # "[1, 2, 3 … +47]" — the first three values then a remainder count.
    private def group_label(nodes : Array(Node)) : String
      head = nodes.first(3).map(&.label).join(", ")
      nodes.size > 3 ? "[#{head} … +#{nodes.size - 3}]" : "[#{head}]"
    end

    # # of captured endpoints under a host node: descendant nodes carrying ≥1 method
    # (= distinct (host, path) pairs, incl. folder-with-methods nodes like /api/users).
    private def endpoint_count(node : Node) : Int32
      n = node.methods.empty? ? 0 : 1
      node.children.each { |c| n += endpoint_count(c) }
      n
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

    # Whether numeric-sequence folding is on (shown in the bar / used by the `g` toggle).
    def grouping? : Bool
      @grouping
    end

    # `g` — toggle numeric-sequence folding. The caller reloads to rebuild the tree.
    def toggle_grouping : Nil
      @grouping = !@grouping
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

    # --- tag editor (a one-line text sub-mode; mirrors the QL `/` bar) --------

    def tagging? : Bool
      @tagging
    end

    # Open the tag editor for the selected node, seeding its current memo. Returns
    # false when the selection can't be tagged (a synthetic group node / empty tree),
    # so the controller can toast instead.
    def start_tag : Bool
      node = selected_node
      return false unless node && !node.grouped
      target = resolve_target # selection-based (host, path) — captured NOW, before any reload
      return false unless target
      @tag_host, @tag_path = target
      @tagging = true
      @tag_buffer = node.tag || ""
      @tag_cx = @tag_buffer.size
      @tag_preedit = ""
      true
    end

    def cancel_tag : Nil
      @tagging = false
      @tag_buffer = ""
      @tag_cx = 0
      @tag_preedit = ""
    end

    # Apply the committed memo to the selected node in place (blank clears it) and exit
    # the editor. No re-derive — the tree structure is unchanged, so the selection
    # stays put and draw_row reads the fresh tag live.
    def apply_tag(text : String) : Nil
      # Stamp the live node in place ONLY while the selection still points at the pinned
      # target (no external reload retargeted @selected); otherwise the persisted tag is
      # picked up by the next reload, so skip rather than stamp the WRONG node.
      if resolve_target == tag_target && (node = selected_node) && !node.grouped
        node.tag = text.blank? ? nil : text
      end
      cancel_tag
    end

    def tag_buffer : String
      @tag_buffer
    end

    def tag_insert(ch : Char) : Nil
      @tag_buffer = "#{@tag_buffer[0, @tag_cx]}#{ch}#{@tag_buffer[@tag_cx..]}"
      @tag_cx += 1
    end

    def tag_backspace : Nil
      return if @tag_cx == 0
      @tag_buffer = "#{@tag_buffer[0, @tag_cx - 1]}#{@tag_buffer[@tag_cx..]}"
      @tag_cx -= 1
    end

    def tag_move(d : Int32) : Nil
      @tag_cx = (@tag_cx + d).clamp(0, @tag_buffer.size)
    end

    def set_tag_preedit(text : String) : Nil
      @tag_preedit = text
    end

    # The (host, path) the tag editor targets — the selected node's address (the host
    # is the nearest depth-0 row above the selection). Nil when the selection isn't
    # taggable (a group node / empty tree). The controller persists the buffer here.
    # The PINNED (host, path) the open tag editor targets (captured at start_tag); nil
    # when not tagging. Commit persists to this so a mid-edit reload can't retarget it.
    def tag_target : {String, String}?
      @tagging ? {@tag_host, @tag_path} : nil
    end

    # Selection-based (host, path) for the row currently under the cursor — the LIVE
    # target, used to seed the pin at start_tag and to detect a reload in apply_tag.
    private def resolve_target : {String, String}?
      rows = visible_rows
      return nil unless row = rows[@selected]?
      return nil if row.node.grouped
      host = row.node.label # fallback (selection IS a host row)
      @selected.downto(0) do |i|
        if rows[i].depth == 0
          host = rows[i].node.label
          break
        end
      end
      {host, row.node.path}
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      render_ql_bar(screen, rect)
      # The bar takes the top row; while querying a suggestion row sits below it.
      offset = bar_rows
      tree = Rect.new(rect.x, rect.y + offset, rect.w, {rect.h - offset, 0}.max)
      return if tree.h <= 0

      unless @loaded && !@hosts.empty?
        # A recovery hint mirrors Findings/Prism. The QL-clear cue only applies to a
        # real `/` query — a Scope-lens-only empty set isn't cleared with esc//.
        msg, hint =
          if !@query.blank?
            {"no endpoints match", querying? ? "esc clears the filter" : "/ to edit the filter"}
          elsif filtering? # in-scope subset is empty (Scope lens, no QL query)
            {"no endpoints in scope", nil}
          else
            {"no traffic captured yet", "browse through the proxy, then return here"}
          end
        screen.text(tree.x + 1, tree.y, msg, Theme.muted)
        screen.text(tree.x + 1, tree.y + 2, hint, Theme.muted) if hint && tree.h > 2
        return
      end

      rect = tree
      rows = visible_rows
      # Reserve the bottom row for the tag prompt while editing (the tree scrolls above it).
      list_h = @tagging ? {rect.h - 1, 0}.max : rect.h
      ensure_visible(rows.size, list_h)
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= rows.size
        draw_row(screen, rect, rows[ri], rect.y + i, ri == @selected, focused)
      end
      render_tag_prompt(screen, rect) if @tagging
    end

    # The in-body "tag › …" prompt on the bottom row while the tag editor is open.
    private def render_tag_prompt(screen : Screen, rect : Rect) : Nil
      y = rect.bottom - 1
      screen.fill(Rect.new(rect.x, y, rect.w, 1), Theme.panel)
      prefix = "tag › "
      screen.text(rect.x + 1, y, prefix, Theme.accent, Theme.panel)
      base = rect.x + 1 + prefix.size
      screen.input_line(base, y, @tag_buffer, @tag_cx, @tag_preedit, Theme.text_bright,
        bg: Theme.panel, width: {rect.w - prefix.size - 2, 0}.max)
    end

    # Draw one tree row: selection band + tree guides + marker + label + a right-aligned
    # cluster (path count on host rows, colored method chips on endpoint rows).
    private def draw_row(screen : Screen, rect : Rect, row : VisibleRow, y : Int32, selected : Bool, focused : Bool) : Nil
      node = row.node
      host = row.depth == 0
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if selected
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      draw_guides(screen, rect, row, y, bg)

      mx = rect.x + 1 + row.depth * 2
      marker, mcolor = node_marker(node, host && node.in_scope)
      screen.cell(mx, y, marker, mcolor, bg)
      lx = screen.text(mx + 2, y, node.label, label_color(host, node), bg)
      lx = draw_tag(screen, rect, node, y, bg, lx)
      draw_cluster(screen, rect, node, host, y, bg, lx)
    end

    # Inline path memo after the label (" # note") in accent, truncated to leave a
    # gap before the right edge. Returns the new label-end x so the right cluster sits
    # clear of it (a long tag legitimately crowds out the chips — it's a deliberate note).
    private def draw_tag(screen : Screen, rect : Rect, node : Node, y : Int32, bg : Color, label_end : Int32) : Int32
      tag = node.tag
      return label_end if tag.nil? || node.grouped
      avail = rect.right - 1 - label_end
      return label_end if avail < 5 # not worth a stub
      text = " # #{tag}"
      text = "#{text[0, avail - 1]}…" if text.size > avail
      screen.text(label_end, y, text, Theme.accent, bg)
      label_end + text.size
    end

    # Faint vertical guides at each ancestor level whose branch continues below this row.
    private def draw_guides(screen : Screen, rect : Rect, row : VisibleRow, y : Int32, bg : Color) : Nil
      (0...row.depth).each do |l|
        screen.cell(rect.x + 1 + l * 2, y, '│', Theme.border, bg) unless (row.guides & (1_u64 << l)) == 0
      end
    end

    # Label colour: in-scope hosts pop (bright); out-of-scope hosts recede (muted);
    # otherwise the depth tone (host bright, deeper nodes normal). `in_scope` is only ever
    # set on host nodes, so depth-0 alone decides the scope branch.
    private def label_color(host : Bool, node : Node) : Color
      return Theme.accent if node.grouped # the synthetic [1, 2, 3 …] fold pops as accent
      if host && @scope_configured
        node.in_scope ? Theme.text_bright : Theme.muted
      else
        host ? Theme.text_bright : Theme.text
      end
    end

    # The right-aligned cluster: a folded-value count on group rows, an endpoint count on
    # host rows, colored method chips on endpoint rows (the three never collide — a node
    # is at most one of group / host / endpoint).
    private def draw_cluster(screen : Screen, rect : Rect, node : Node, host : Bool, y : Int32, bg : Color, label_end : Int32) : Nil
      if node.grouped
        draw_aside(screen, rect, y, bg, "#{node.children.size} values", label_end)
      elsif host
        draw_aside(screen, rect, y, bg, node.endpoints == 1 ? "1 path" : "#{node.endpoints} paths", label_end) if node.endpoints > 0
      elsif !node.methods.empty?
        draw_methods(screen, rect, y, bg, node.methods, label_end)
      end
    end

    # The marker glyph + colour for a node. In-scope hosts use a filled/hollow diamond
    # (fill encodes expand state); everything else keeps the chevron (folders) / bullet
    # (leaves) so the expand affordance is never lost.
    private def node_marker(node : Node, in_scope : Bool) : {Char, Color}
      if in_scope
        {node.expanded ? '◆' : '◇', Theme.accent}
      elsif node.leaf?
        {'▪', Theme.muted}
      else
        {node.expanded ? '▾' : '▸', Theme.muted}
      end
    end

    # Right-aligned muted aside ("3 paths" / "50 values"). Omitted when it would collide
    # with the label/tag to its left.
    private def draw_aside(screen : Screen, rect : Rect, y : Int32, bg : Color, txt : String, label_end : Int32) : Nil
      start = rect.right - txt.size - 1
      screen.text(start, y, txt, Theme.muted, bg) if start >= label_end + 1
    end

    # Right-aligned, per-verb-coloured method chips (GET green, POST/… yellow), mirroring
    # the History list. Dropped whole when it can't sit clear of the label.
    private def draw_methods(screen : Screen, rect : Rect, y : Int32, bg : Color, methods : Array(String), label_end : Int32) : Nil
      total = methods.sum(&.size) + (methods.size - 1) # +1-col gap between chips
      x = rect.right - total - 1
      return if x < label_end + 1
      methods.each_with_index do |m, i|
        x = screen.text(x, y, m, Theme.method_color(m), bg)
        x = screen.text(x, y, " ", Theme.muted, bg) if i < methods.size - 1
      end
    end

    # Rows the QL bar occupies at the top of the body: 1 (the bar) + 1 suggestion
    # row while querying. The tree renders below it; clicks subtract the same offset.
    private def bar_rows : Int32
      @querying ? 2 : 1
    end

    private def render_ql_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "filter › "
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
        screen.text(rect.x + 1, rect.y, "/ filter  ·  host:  method:  path:  status:>=500  size:>10000  dur:>500  header:  body~regex  tag:", Theme.muted, width: left_w)
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
      mx == rect.x + 1 + row.depth * 2
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
      rows[@selected]?.try(&.node)
    end

    private def visible_rows : Array(VisibleRow)
      @visible_cache ||= begin
        rows = [] of VisibleRow
        @hosts.each_with_index { |host, i| collect(host, 0, 0_u64, i < @hosts.size - 1, rows) }
        rows
      end
    end

    # Flatten the expanded tree, threading the tree-guide bitmask down. `has_next` is
    # whether `node` has a following sibling: when it does, descendants draw a `│` at
    # `node`'s level (bit `depth`) so the branch reads as continuing.
    private def collect(node : Node, depth : Int32, guides : UInt64, has_next : Bool, rows : Array(VisibleRow)) : Nil
      rows << VisibleRow.new(node, depth, guides)
      return unless node.expanded
      child_guides = has_next ? (guides | (1_u64 << depth)) : guides
      last = node.children.size - 1
      node.children.each_with_index { |child, i| collect(child, depth + 1, child_guides, i < last, rows) }
    end

    private def add(host : String, path : String, method : String) : Nil
      host_node = @hosts.find { |h| h.label == host } || begin
        node = Node.new(host)
        @hosts << node
        node
      end
      segments = path.split('/').reject(&.empty?)
      if segments.empty?
        node = host_node.child("/")
        node.path = "/"
      else
        acc = ""
        node = host_node
        segments.each do |seg|
          acc = "#{acc}/#{seg}"
          node = node.child(seg)
          node.path = acc # idempotent on revisits; the durable tag key
        end
      end
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
