require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "../settings"
require "../store"
require "../ql"
require "../scope"
require "../sitemap" # the host→path tree model + builder (URI normalisation lives there now)

module Gori::Tui
  # The Sitemap tab: a literal host → path tree built from captured flows (no ID
  # templating — every distinct segment is its own node, P3/DESIGN.md §3). Helps
  # answer "what does this app do". Navigate with ↑/↓, expand/collapse with
  # →/←/Enter.
  class SitemapView
    # The tree node + pure builder live in `Gori::Sitemap` (shared with the headless
    # `gori run sitemap`); this view layers scope markers, path-tag editing, and
    # rendering on top. The alias keeps the rest of this file reading as `Node`.
    alias Node = Gori::Sitemap::Node

    # A flattened tree row. `guides` is a bitmask: bit L set ⇒ a vertical `│` tree-guide
    # is drawn at ancestor level L (its branch continues below this row). Built once per
    # tree/expand change in `collect`, not re-walked per frame.
    private record VisibleRow, node : Node, depth : Int32, guides : UInt64

    # The QL fields meaningful for the endpoint tree. Mirrors History's set so the same
    # `/` query language applies, plus `tag:` — a Sitemap-local field (handled here, not
    # in the shared QL) that filters the tree by a node's path memo.
    QL_FIELDS = %w(host path method status scheme proto body header size dur tag)
    # Discoverability hints for the filter, kept loosely in sync with QL_FIELDS.
    # FILTER_HINT sits on the idle bar (press `/` to start); QUERY_HINT sits on the
    # suggestion row at a cold start (already editing, nothing to Tab-complete yet) and
    # spells out that bare words are a free-text search. Example values double as cues.
    FILTER_HINT = "/ filter  ·  host:  method:  path:  status:>=500  proto:ws  size:>10000  dur:>500  header:  body~regex  tag:"
    QUERY_HINT  = "fields:  host:  method:  path:  status:  proto:  scheme:  size:  dur:  header:  body:  tag:    ·    or type words to search"

    # Right-aligned column widths: path memo sits left of the method/aside cluster.
    TAG_COL_W     = 16
    METHODS_COL_W =  8
    COL_GAP       =  1 # minimum blank column between tag text and methods/aside

    getter? loaded : Bool

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
      @qcx = 0                      # caret position within @query
      @preedit = ""                 # IME composition, drawn at the caret
      @query_note = nil.as(String?) # why an active filter is empty when its QL residual is INVALID
      # Numeric-sequence folding (Feature: path-param explosion). On by default; `g`
      # toggles it for the rare case of wanting every literal id.
      @grouping = true
      # Tag editor — a one-line text sub-mode (mirrors the QL `/` bar) that edits the
      # selected node's path memo. The controller persists @tag_buffer on commit.
      @tagging = false
      @tag_buffer = ""
      @tag_cx = 0
      @tag_preedit = ""
      # The (host, path) the open editor targets, PINNED at start_tag — belt-and-braces
      # if a mid-edit rebuild drops the row; selection is also re-anchored by key on reload.
      @tag_host = ""
      @tag_path = ""
    end

    # Inject the Scope lens so the tree honours it AND the bar can show its state
    # (the scope chip). Mirrors HistoryController wiring the same Scope into its view.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    # Rebuild the tree from the store. Selection, scroll, and manual expand/collapse
    # are re-anchored by durable (host, path) keys so a data_version poll under live
    # capture does not jump the cursor to the top host every ~750ms.
    def reload(store : Store) : Nil
      prev_sel = resolve_target
      prev_scroll = @scroll
      prev_expand = collect_expand_state

      # `tag:`/`-tag:` are Sitemap-local (the shared QL has no tag column): split them
      # out, hand the residual to QL.parse, and apply the tag filter to the built tree.
      positives, negatives, residual = split_tag_terms(@query)
      residual_filter = QL.parse(residual)
      @query_note = query_note_for(residual, residual_filter)
      # A non-blank QL residual that compiles to EMPTY means every QL term was invalid
      # (typo'd field, bad numeric, unterminated value). Mirror HistoryView / MCP / CLI:
      # reject it (empty tree + a note) rather than fall through to a match-all search
      # that shows the WHOLE sitemap behind an "active" filter. A tag-only query has a
      # blank residual, so reject_empty? is false and the tag filter still applies below.
      if QL.reject_empty?(residual, residual_filter)
        @hosts = [] of Node
        @visible_cache = nil
        @selected = 0
        @scroll = 0
        @loaded = true
        return
      end
      combined = QL.and(@scope.try(&.filter) || QL::EMPTY, residual_filter)
      @hosts = Sitemap.build(store.sitemap_entries(combined))
      Sitemap.stamp_tags!(@hosts, store.sitemap_tags)
      filter_by_tags(positives, negatives)
      @hosts.each { |h| Sitemap.group_sequences!(h) } if @grouping
      # settings:layout Sitemap expand depth seeds NEW nodes; prior session expand
      # overrides are re-applied below for keys that still exist.
      Sitemap.apply_expand_depth!(@hosts, Settings.sitemap_expand_depth)
      reapply_expand_state(prev_expand)
      # Stamp host-level scope state + endpoint counts on the FINAL tree, so the render
      # loop is a pure read (no per-frame Scope mutex hits). host_in_scope?/configured?
      # evaluate the rules regardless of the ⇧S enabled flag, so targets are marked even
      # with the lens off (all traffic shown).
      @scope_configured = @scope.try(&.configured?) == true
      @hosts.each do |h|
        h.in_scope = @scope_configured && (@scope.try(&.host_in_scope?(h.label)) == true)
        h.endpoints = Sitemap.endpoint_count(h)
      end
      @visible_cache = nil
      rows = visible_rows
      @selected =
        if (idx = index_of_target(rows, prev_sel))
          idx
        else
          0
        end
      @selected = @selected.clamp(0, {rows.size - 1, 0}.max)
      @scroll = prev_scroll.clamp(0, {rows.size - 1, 0}.max)
      @loaded = true
    end

    # Snapshot expanded? for every non-group, non-leaf node keyed by (host, path).
    private def collect_expand_state : Hash({String, String}, Bool)
      state = {} of {String, String} => Bool
      @hosts.each { |h| walk_collect_expand(h, h.label, state) }
      state
    end

    private def walk_collect_expand(node : Node, host : String, state : Hash({String, String}, Bool)) : Nil
      # Skip recording only the synthetic fold node's OWN (unkeyed) state, but still recurse
      # into its children — real descendants under a grouped numeric fold have stable keys
      # and their expand state must survive a reload (which fires ~1.3x/sec during capture).
      state[{host, node.path}] = node.expanded if !node.grouped && !node.leaf?
      node.children.each { |c| walk_collect_expand(c, host, state) }
    end

    private def reapply_expand_state(prev : Hash({String, String}, Bool)) : Nil
      return if prev.empty?
      @hosts.each { |h| walk_reapply_expand(h, h.label, prev) }
    end

    private def walk_reapply_expand(node : Node, host : String, prev : Hash({String, String}, Bool)) : Nil
      key = {host, node.path}
      if !node.grouped && !node.leaf? && prev.has_key?(key)
        node.expanded = prev[key]
      end
      node.children.each { |c| walk_reapply_expand(c, host, prev) }
    end

    # Index of the row whose (host, path) matches `target`, or nil if gone.
    private def index_of_target(rows : Array(VisibleRow), target : {String, String}?) : Int32?
      return nil unless target
      want_host, want_path = target
      rows.each_with_index do |row, i|
        next if row.node.grouped
        host = host_label_for_row(rows, i)
        return i if host == want_host && row.node.path == want_path
      end
      nil
    end

    private def host_label_for_row(rows : Array(VisibleRow), idx : Int32) : String
      idx.downto(0) do |i|
        return rows[i].node.label if rows[i].depth == 0
      end
      rows[idx].node.label
    end

    # --- tags: filter (stamping lives in Gori::Sitemap.stamp_tags!) ----------

    # A short note explaining a filter that matches nothing because its QL residual is
    # INVALID (vs a valid filter that genuinely has no matches) — surfaced in the
    # empty-state so a typo'd status:/dur:/size: or a broken body~[regex isn't misread
    # as "no endpoints". Operates on the residual (tag: terms are handled separately).
    private def query_note_for(residual : String, filter : QL::Filter) : String?
      return nil if residual.blank?
      return "invalid filter — no valid terms" if QL.reject_empty?(residual, filter)
      bad = QL.invalid_regex_terms(residual)
      bad.empty? ? nil : "invalid regex in #{bad.first}"
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
    # target, used to seed the pin at start_tag, re-anchor selection on reload, and
    # detect a reload in apply_tag.
    private def resolve_target : {String, String}?
      rows = visible_rows
      return nil unless row = rows[@selected]?
      return nil if row.node.grouped
      {host_label_for_row(rows, @selected), row.node.path}
    end

    # The selected endpoint's {host, method, target} for cross-surface actions (Send to
    # Repeater / Discover here). GET-preferred method; nil for a grouped fold node.
    def selected_endpoint : {host: String, method: String, target: String}?
      rows = visible_rows
      return nil unless row = rows[@selected]?
      return nil if row.node.grouped
      methods = row.node.methods
      method = methods.includes?("GET") ? "GET" : (methods.first? || "GET")
      {host: host_label_for_row(rows, @selected), method: method, target: row.node.path}
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : String? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_ql_bar(screen, rect)
      hdr_y = rect.y + 1
      if @querying
        render_suggestions(screen, rect, hdr_y)
        hdr_y += 1
      end
      render_column_headers(screen, rect, hdr_y)
      Frame.inner_divider(screen, rect, hdr_y + 1, border: Frame.pane_border(focused))
      tree_top = hdr_y + 2
      tree = Rect.new(rect.x, tree_top, rect.w, {rect.bottom - tree_top, 0}.max)
      return if tree.h <= 0

      unless @loaded && !@hosts.empty?
        # A recovery hint mirrors Issues/Probe. The QL-clear cue only applies to a
        # real `/` query — a Scope-lens-only empty set isn't cleared with esc//.
        msg, hint =
          if !@query.blank?
            # An INVALID QL residual (all terms bad, or a broken regex) reads as "no
            # endpoints match" unless we say why — @query_note distinguishes it.
            {@query_note || "no endpoints match", querying? ? "esc clears the filter" : "/ to edit the filter"}
          elsif filtering? # in-scope subset is empty (Scope lens, no QL query)
            {"no endpoints in scope", nil}
          else
            addr = listen || "#{Settings.effective_bind_host}:#{Settings.effective_bind_port}"
            TrafficEmptyState.render(screen, tree, variant: :sitemap, listen: addr, capturing: capturing)
            return
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
      lx0 = mx + 2
      # Bound the label to the pane. Unbounded, a deeply-nested long leaf name overran
      # the pane's right BORDER and pushed label_end off-screen, so draw_cluster's
      # collision checks dropped this row's tag memo AND method chips. It's now clipped
      # (with an ellipsis) before whichever right column the row has.
      lx = screen.text(lx0, y, node.label, label_color(host, node), bg, width: label_width(rect, node, host, lx0))
      draw_cluster(screen, rect, node, host, y, bg, lx)
    end

    # The label's max width: it stops before the tag column (when the node carries a
    # memo), else before the right cluster (methods/aside), else the pane's right edge,
    # always leaving COL_GAP and the border column clear.
    private def label_width(rect : Rect, node : Node, host : Bool, lx0 : Int32) : Int32
      cx = cluster_start(rect, node, host)
      limit =
        if node.tag && !node.grouped
          tag_right = tag_col_right(rect)
          tag_right = {tag_right, cx - COL_GAP - 1}.min if cx
          {tag_right - TAG_COL_W + 1, rect.x + 1}.max
        elsif cx
          cx
        else
          rect.right
        end
      {limit - lx0 - COL_GAP, 1}.max
    end

    # Right edge of the tag column (COL_GAP clear of the METHODS column).
    private def tag_col_right(rect : Rect) : Int32
      methods_col_x(rect) - COL_GAP - 1
    end

    # Left edge of the tag column.
    private def tag_col_left(rect : Rect) : Int32
      {tag_col_right(rect) - TAG_COL_W + 1, rect.x + 1}.max
    end

    # Left edge of the methods/aside column.
    private def methods_col_x(rect : Rect) : Int32
      {rect.right - METHODS_COL_W, rect.x + 1 + 12}.max
    end

    # Path memo in the tag column (" # note"), right-aligned and truncated to fit.
    # `tag_right` may be pulled left when methods/aside share the row.
    private def draw_tag_column(screen : Screen, rect : Rect, tag : String, y : Int32, bg : Color, label_end : Int32, tag_right : Int32) : Nil
      avail = tag_right - tag_col_left(rect) + 1
      return if avail < 5 # not worth a stub
      text = " # #{tag}"
      text = "#{text[0, avail - 1]}…" if text.size > avail
      x = tag_right - text.size + 1
      screen.text(x, y, text, Theme.accent, bg) if x >= label_end + 1
    end

    # Screen-x where the right cluster (methods/aside) begins; nil when the row has none.
    private def cluster_start(rect : Rect, node : Node, host : Bool) : Int32?
      if node.grouped
        txt = "#{node.children.size} values"
      elsif host && node.endpoints > 0
        txt = node.endpoints == 1 ? "1 path" : "#{node.endpoints} paths"
      elsif !node.methods.empty?
        total = node.methods.sum(&.size) + (node.methods.size - 1)
        return rect.right - total - 1
      else
        return nil
      end
      rect.right - txt.size - 1
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

    # The right-aligned cluster: path memo in the tag column, then a folded-value count
    # on group rows, an endpoint count on host rows, or colored method chips on endpoint
    # rows (group / host / endpoint are mutually exclusive for the aside slot).
    private def draw_cluster(screen : Screen, rect : Rect, node : Node, host : Bool, y : Int32, bg : Color, label_end : Int32) : Nil
      cluster_x = cluster_start(rect, node, host)
      tag_right = tag_col_right(rect)
      if cx = cluster_x
        tag_right = {tag_right, cx - COL_GAP - 1}.min
      end
      if t = node.tag
        draw_tag_column(screen, rect, t, y, bg, label_end, tag_right) unless node.grouped
      end
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

    # The first tree-row screen-y — mirrors render: filter bar, optional suggestion
    # row while querying, column header, then divider.
    private def list_top(rect : Rect) : Int32
      hdr_y = rect.y + 1
      hdr_y += 1 if @querying
      hdr_y + 2
    end

    private def render_ql_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright, width: rect.w - prefix.size - 2)
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
      scope_x = {rx - chip.size, rect.x}.max
      screen.text(scope_x, rect.y, chip, chip_color)
      # The numeric path-param grouping toggle, left of the scope chip — same fg
      # accent/muted style so the two lens toggles read as one cluster, and its `g`
      # chord stays in view (grouping-on vs -off renders identically without sequences).
      gchip = "g:group"
      gx = scope_x - gchip.size - 1
      group_shown = gx > rect.x + 1
      screen.text(gx, rect.y, gchip, @grouping ? Theme.accent : Theme.muted) if group_shown

      left_w = {(group_shown ? gx : scope_x) - (rect.x + 1) - 1, 0}.max
      if !@query.blank?
        screen.text(rect.x + 1, rect.y, ": #{@query}", Theme.text, width: left_w)
      else
        # No QL query typed — whether or not a Scope lens is active. Surface the filter
        # affordance + fields rather than a bare "(in-scope only)": the Scope lens is
        # already signalled by the ⇧S chip on the right, so this row isn't wasted
        # repeating it, and the user's next move here is to ADD a query atop the lens.
        screen.text(rect.x + 1, rect.y, FILTER_HINT, Theme.muted, width: left_w)
      end
    end

    private def render_column_headers(screen : Screen, rect : Rect, hdr_y : Int32) : Nil
      label_x = rect.x + 1
      methods_x = methods_col_x(rect)
      tag_right = tag_col_right(rect)
      label_w = {tag_col_left(rect) - label_x - 1, 6}.max
      screen.text(label_x, hdr_y, "HOST / PATH", Theme.muted, width: label_w) if label_w > 0
      tag_hdr = "TAG"
      screen.text(tag_right - tag_hdr.size + 1, hdr_y, tag_hdr, Theme.muted) if tag_right - tag_hdr.size + 1 > label_x
      screen.text(methods_x, hdr_y, "METHODS", Theme.muted, width: METHODS_COL_W)
    end

    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      sugg = query_suggestions
      unless sugg.empty?
        screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme.muted, width: rect.w - 2)
        return
      end
      # No live completions to Tab through. At a cold start (nothing typed yet, or the
      # cursor sits just after a space) show a standing hint so the query language is
      # discoverable from the moment `/` opens; on a non-empty token with no match stay
      # quiet — the user is deliberately free-texting a word.
      return unless current_token.empty?
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: rect.w - 2)
    end

    # Inverts render's tree placement (offset below the chrome band) to find which
    # visible_rows index a click lands on; nil past the last populated row.
    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if mx < rect.x || mx >= rect.right # reject the frame border columns (mirror the other list helpers)
      top = list_top(rect)
      i = my - top
      return nil if i < 0 || i >= {rect.bottom - top, 0}.max
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

    private def ensure_visible(total : Int32, h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      # Never scroll past what fits: reload's `prev_scroll.clamp(0, rows.size-1)` can
      # leave @scroll above (total - h) after the tree shrinks, stranding rows off the
      # top with blank space below. Pull it back when the list underfills (mirrors
      # HistoryView#ensure_visible).
      @scroll = {@scroll, {total - h, 0}.max}.min
      @scroll = 0 if @scroll < 0
    end
  end
end
