require "./screen"
require "./theme"
require "./frame"
require "./query_suggest"
require "./suggest_popup"
require "./traffic_empty_state"
require "../settings"
require "../store"
require "../ql"
require "../scope"
require "../sitemap" # the host→path tree model + builder (URI normalisation lives there now)

module Gori::Tui
  # The Sitemap tab: a host → path tree built from captured flows. The tree is literal —
  # every distinct segment is its own node — and `g` folds the noise on top of it: opaque
  # ids into `{uuid}`/`{hex}`/`{date}` and long numeric runs into `[1, 2, 3 … +N]`, both
  # WRAPPING their children rather than rewriting any path. Helps answer "what does this
  # app do". Navigate with ↑/↓, expand/collapse with →/←/Enter.
  class SitemapView
    # The tree node + pure builder live in `Gori::Sitemap` (shared with the headless
    # `gori run sitemap`); this view layers scope markers, path-tag editing, and
    # rendering on top. The alias keeps the rest of this file reading as `Node`.
    alias Node = Gori::Sitemap::Node

    # A flattened tree row. `guides` is a bitmask: bit L set ⇒ a vertical `│` tree-guide
    # is drawn at ancestor level L (its branch continues below this row). Built once per
    # tree/expand change in `collect`, not re-walked per frame. `host` is the label of the
    # depth-0 node this row hangs under — stamped during the flatten so nothing has to walk
    # back up the row list to find it (the mark predicate needs it on every drawn row).
    private record VisibleRow, node : Node, depth : Int32, guides : UInt64, host : String

    # The QL fields meaningful for the endpoint tree. The same `/` query language History
    # takes, plus `tag:` — a Sitemap-local field (handled here, not in the shared QL) that
    # filters the tree by a node's path memo.
    #
    # Written out rather than read from `QL::FIELDS` (which History's own list now IS), and
    # deliberately: this is a CURATED subset. `tag:` is not in QL at all, and `url:`/`stub:`/
    # `reqsize:`/`respsize:` are dropped because a tree node is a path, not an exchange —
    # every term here still COMPILES through QL, this list only decides what Tab offers.
    # Anything added to `QL::FIELDS` is therefore usable here the moment it exists; it just
    # is not suggested until someone decides it reads well against a tree.
    # `resp.body`/`resp.header` are offered and their request twins are not, which is the same
    # curation rule the paragraph above states rather than an omission: a tree node groups the
    # exchanges under one path, and "did the server ever send this here" is a question about that
    # group, where the request side is a property of one call within it. Both still compile.
    QL_FIELDS = %w[host path method status scheme proto body header resp.body resp.header size dur tag]
    # Discoverability hints for the filter. GENERATED from the pool and the grammar's operator
    # list (`QuerySuggest`) rather than written out — as prose these drifted from `QL_FIELDS` and
    # never mentioned `-term` at all. `tag:` is appended because it is this surface's own field
    # and the shared sample cannot know about it.
    FILTER_HINT = QuerySuggest.idle_hint("/ filter", ["tag"] + QL::HINT_FIELDS)
    QUERY_HINT  = QuerySuggest.cold_hint(["tag"] + QL::HINT_FIELDS, help_key: true)
    # The highlighter's field vocabulary: everything QL ACCEPTS (a superset of `QL_FIELDS`, which
    # is only what Tab offers here) plus this surface's own `tag:`, which QL knows nothing about
    # because `partition` pulls it out before the query ever reaches the parser.
    QL_KNOWN = ->(f : String) { f == "tag" || QL.known_field?(f) }
    # The editing bar's label — a constant because `render_query_popup` lines the dropdown up
    # under the token, which means knowing how far the query text is indented.
    QUERY_PREFIX = "filter › "
    # QL's help plus this surface's own field, which the shared table cannot know about because
    # `tag:` never reaches the parser (`FilterAst.partition` pulls it out first).
    QL_HELP = ->(f : String) { f == "tag" ? "path memo on this node — set with space → T" : QL.field_help(f) }

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
      # The `↓` completion dropdown. Closed until asked for — see `SuggestPopup`.
      @popup = SuggestPopup.new
      # Numeric-sequence folding (Feature: path-param explosion). On by default; `g`
      # toggles it for the rare case of wanting every literal id.
      @grouping = true
      # Tag editor — a one-line text sub-mode (mirrors the QL `/` bar) that edits the
      # selected node's path memo. The controller persists @tag_buffer on commit.
      @tagging = false
      @tag_buffer = ""
      @tag_cx = 0
      @tag_preedit = ""
      # The (host, path) pairs the open editor targets, PINNED at start_tag — the marks if
      # any were set, else the cursor row. Pinned rather than re-derived so a mid-edit
      # rebuild (a data_version poll under live capture) can't retarget the commit.
      @tag_targets = [] of {String, String}
      # Multi-select marks, keyed by the durable (host, path) address rather than a row
      # index: the tree is rebuilt from the store ~1.3x/sec under capture, so an index-keyed
      # mark would silently retarget on the next poll. A mark whose node is currently
      # collapsed or filtered out stays marked (marked_hidden_count reports it); a mark whose
      # path is gone simply fails to resolve at the verb. Mirrors History's model (#442).
      @marks = Set({String, String}).new
      @mark_anchor = nil.as({String, String}?) # key-anchored range anchor for the ⇧arrow extend
      # Only the keys the CURRENT ⇧arrow gesture added. A plain arrow hands back exactly
      # these, so `t` marks outside the range are never disturbed. Cleared by every
      # non-extend mark action.
      @mark_extent = Set({String, String}).new
    end

    # Inject the Scope lens so the tree honours it AND the bar can show its state
    # (the scope chip). Mirrors HistoryController wiring the same Scope into its view.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    # Rebuild the tree from the store. Selection, scroll, and manual expand/collapse
    # are re-anchored by durable (host, path) keys so a data_version poll under live
    # capture does not jump the cursor to the top host every ~750ms.
    #
    # A FULL rebuild, deliberately, and measured before leaving it that way: the whole path —
    # `sitemap_entries` (DISTINCT, capped at `Store::SITEMAP_MAX`), `Sitemap.build`, the two
    # fold passes, tag stamping, expand-depth, the endpoint counts and the flatten — runs in
    # ~6.4 ms at 100k flows with the tree at its 10k-endpoint cap. Against the 750 ms
    # data_version cadence, and only while this tab is ACTIVE (`@tabs[@active_tab]` in
    # Runner#apply_external_change), that is under 1% of a core. An incremental rebuild would
    # trade that for cache-invalidation state across build, folding, tagging and expansion —
    # the four things whose interaction the anchoring above already has to get right.
    #
    # Roughly two thirds of the 6.4 ms is the DISTINCT query, which scales with the FLOW table
    # rather than the capped tree, so the number to watch is retention: at the 100k default it
    # is what is quoted here. Re-measure before assuming it still holds if that default moves.
    def reload(store : Store) : Nil
      prev_sel = selection_anchor
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
      if residual_has_terms?(residual) && QL.reject_empty?(residual, residual_filter)
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
      if @grouping
        # Opaque ids first, then numeric runs — the two passes partition the children.
        @hosts.each { |h| Sitemap.fold_templates!(h) }
        @hosts.each { |h| Sitemap.group_sequences!(h) }
      end
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
      # Exact row, else the fold that swallowed it, else the top.
      @selected = index_of_target(rows, prev_sel) || index_of_enclosing_fold(rows, prev_sel) || 0
      @selected = @selected.clamp(0, {rows.size - 1, 0}.max)
      @scroll = prev_scroll.clamp(0, {rows.size - 1, 0}.max)
      @loaded = true
    end

    # The reload-stable identity of a node: its path, or — for a synthetic fold, which has
    # no path — its fold_key. nil only for a fold that somehow carries no parent.
    private def expand_key(node : Node) : String?
      node.grouped ? node.fold_key : node.path
    end

    # Snapshot expanded? for every non-leaf node keyed by (host, expand_key).
    private def collect_expand_state : Hash({String, String}, Bool)
      state = {} of {String, String} => Bool
      # Iterative via Sitemap.post_order: the recursion these two walks used to do spent one
      # frame per tree level and overflowed the native stack (SIGSEGV) on a single
      # pathologically deep captured/imported path. Both visit every node independently, so
      # post-order vs pre-order makes no difference to the result.
      @hosts.each do |h|
        host = h.label
        # A fold is KEYED, not skipped. apply_expand_depth! re-collapses every fold on every
        # reload (~1.3x/sec during capture), so without a durable key a fold the user opened
        # could never stay open — and with id folding that means whole subtrees are unreadable.
        Sitemap.post_order(h) do |n|
          if (k = expand_key(n)) && !n.leaf?
            state[{host, k}] = n.expanded
          end
        end
      end
      state
    end

    private def reapply_expand_state(prev : Hash({String, String}, Bool)) : Nil
      return if prev.empty?
      @hosts.each do |h|
        host = h.label
        Sitemap.post_order(h) do |n|
          if (k = expand_key(n)) && !n.leaf?
            key = {host, k}
            n.expanded = prev[key] if prev.has_key?(key)
          end
        end
      end
    end

    # Index of the row whose (host, expand_key) matches `target`, or nil if gone. Folds
    # match too — parking the cursor on a `{uuid}` row must survive the next poll.
    private def index_of_target(rows : Array(VisibleRow), target : {String, String}?) : Int32?
      return nil unless target
      want_host, want_key = target
      rows.each_with_index do |row, i|
        next unless (k = expand_key(row.node)) && k == want_key
        return i if row.host == want_host
      end
      nil
    end

    # The previously selected row can vanish because a NEW sibling pushed its class over
    # the fold threshold and swallowed it into a collapsed fold. Land on that fold instead
    # of teleporting to row 0 — at the id-fold threshold this fires on ordinary browsing.
    private def index_of_enclosing_fold(rows : Array(VisibleRow), target : {String, String}?) : Int32?
      return nil unless target
      want_host, want_path = target
      return nil if want_path.empty? || want_path.includes?(Sitemap::FOLD_SEP)
      rows.each_with_index do |row, i|
        # Ask which fold actually SWALLOWED this row, rather than which folds share its
        # parent. A parent commonly holds both an id fold and a numeric fold, and
        # `fold_templates!` appends before `group_sequences!` does — so matching on the
        # parent alone landed the cursor on the {hex} fold when a numeric run collapsed.
        next unless row.node.grouped && row.node.children.any? { |c| encloses?(c.path, want_path) }
        return i if row.host == want_host
      end
      nil
    end

    # Is `want` the folded node itself, or something beneath it? (Prefix-compared without
    # building a "#{path}/" string per candidate — this runs per row on every reload.)
    private def encloses?(path : String, want : String) : Bool
      return true if path == want
      want.starts_with?(path) && want[path.size]? == '/'
    end

    # --- tags: filter (stamping lives in Gori::Sitemap.stamp_tags!) ----------

    # A short note explaining a filter that matches nothing because its QL residual is
    # INVALID (vs a valid filter that genuinely has no matches) — surfaced in the
    # empty-state so a typo'd status:/dur:/size: or a broken body~[regex isn't misread
    # as "no endpoints". Operates on the residual (tag: terms are handled separately).
    private def query_note_for(residual : String, filter : QL::Filter) : String?
      return nil if residual.blank?
      return "invalid filter — no valid terms" if residual_has_terms?(residual) && QL.reject_empty?(residual, filter)
      bad = QL.invalid_regex_terms(residual)
      bad.empty? ? nil : "invalid regex in #{bad.first}"
    end

    # Split `tag:` terms out of the query. Cut with the SHARED lexer, not `String#split`:
    # hand-tokenising saw no quotes (`tag:"my tag"` became `tag:"my` + `tag"`) and no
    # `NOT` (`NOT tag:done` filed `done` as a POSITIVE and then blanked the tree on the
    # leftover `NOT`), while the bar above it was already highlighting all of that as
    # real grammar. Negation now rides the same `Term#negate?` every other filter uses,
    # so `-tag:x` and `NOT tag:x` are finally the same thing here too.
    private def split_tag_terms(query : String) : {Array(String), Array(String), String}
      positives = [] of String
      negatives = [] of String
      # A half-typed `tag:` (no value yet) stays in the residual, exactly as before, so
      # the tree doesn't blank out mid-keystroke.
      taken, residual = FilterAst.partition(query) { |t| !tag_token_value(t.text).nil? }
      taken.each { |t| (t.negate? ? negatives : positives) << tag_token_value(t.text).not_nil! }
      {positives, negatives, residual}
    end

    # `reject_empty?` reads a non-blank query that compiled to nothing as "every term was
    # invalid". That is right for what the USER typed, but the residual here is what is
    # LEFT after the tag terms were cut out, so `tag:a OR tag:b` handed it the bare word
    # `OR` — no terms at all — and the whole sitemap blanked behind an "invalid filter"
    # note. Only a residual that still carries a term can be invalid.
    private def residual_has_terms?(residual : String) : Bool
      !FilterAst.terms(FilterAst.parse(residual)).empty?
    end

    # The keyword of a `tag:x` term, or nil if this isn't one (or has no value yet).
    private def tag_token_value(text : String) : String?
      return nil unless text.downcase.starts_with?("tag:")
      v = text[4..].downcase
      v.empty? ? nil : v
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
    #
    # Two explicit passes rather than native recursion (see `Sitemap.post_order` for the
    # SIGSEGV this class of walk caused): this one threads `within` DOWN and combines
    # `kept_child` UP, which no single-direction work-list expresses. Pass 1 collects nodes
    # parent-before-child with their `within`; pass 2 walks that list in REVERSE, so every
    # node is pruned only after its whole subtree — exactly the order the recursion had.
    # `verdict` is keyed by Node identity (`Sitemap::Node` overrides neither `==` nor
    # `hash`, so Hash falls back to reference equality).
    private def keep_for_tags?(root : Node, positives : Array(String), inside : Bool) : Bool
      order = [{root, inside || tag_has_all?(root, positives)}]
      i = 0
      while i < order.size
        node, within = order[i]
        node.children.each { |c| order << {c, within || tag_has_all?(c, positives)} }
        i += 1
      end

      verdict = {} of Node => Bool
      i = order.size - 1
      while i >= 0
        node, within = order[i]
        kept_child = false
        node.children.select! do |c|
          keep = verdict[c]
          kept_child ||= keep
          keep
        end
        verdict[node] = within || kept_child
        i -= 1
      end
      verdict[root]
    end

    # Returns true if `node`'s subtree should be dropped (it carries a negative tag);
    # otherwise prunes any dropped descendants in place.
    #
    # Iterative for the same reason as `keep_for_tags?`. A node that matches is dropped
    # whole and never descended into, so this is just "reject matching children, then
    # descend into the survivors" — no verdict has to travel back up.
    private def exclude_for_tags?(root : Node, negatives : Array(String)) : Bool
      return true if tag_has_any?(root, negatives)
      stack = [root]
      while node = stack.pop?
        node.children.reject! { |c| tag_has_any?(c, negatives) }
        node.children.each { |c| stack << c }
      end
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

    # Whether id folding is on (shown in the bar / used by the `g` toggle).
    def grouping? : Bool
      @grouping
    end

    # `g` — toggle id folding (both passes). The caller reloads to rebuild the tree.
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

    # The committed filter text. HistoryView and InterceptView have carried this since they
    # were written; this bar simply never had a reader outside itself until `ql_help_key?`
    # needed to ask whether it was empty. Same name as its two siblings on purpose.
    def query : String
      @query
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
      @popup.close
    end

    def cancel_query : Nil # Esc: clear the filter, leave edit mode
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
      @popup.close
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
      sync_popup
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
      sync_popup
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
      sync_popup
    end

    # --- the opt-in completion dropdown (`\u2193`) ---------------------------------
    # Same component and same contract as History's; see `SuggestPopup` for why it is opt-in.

    def popup_open? : Bool
      @popup.open?
    end

    # `↓`: open the dropdown, or move down inside it. Nil rather than Bool — the key is claimed
    # either way, and an earlier Bool "so the key falls through" was a contract no controller
    # honoured, which is worse than not offering one.
    def popup_down : Nil
      return @popup.move(1) if @popup.open?
      @popup.set(query_suggestions)
      @popup.open!
    end

    def popup_up : Nil
      @popup.move(-1)
    end

    def popup_close : Nil
      @popup.close
    end

    private def sync_popup : Nil
      @popup.set(query_suggestions) if @popup.open?
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Complete the current token to the SELECTED candidate (dropdown open) or the first (closed).
    # `close` is ↵'s — see HistoryView#query_complete for why ↵ must shut the popup.
    def query_complete(close : Bool = false) : Bool
      sugg = query_suggestions
      pick = @popup.choice(sugg)
      return false unless pick
      s, e = current_token_bounds
      @query = "#{@query[0, s]}#{pick}#{@query[e..]}"
      @qcx = s + pick.size
      close ? @popup.close : (@popup.set(query_suggestions) if @popup.open?)
      true
    end

    # Field-name suggestions for the token under the cursor (values aren't suggested
    # — the tree's useful axes are host/path/method, which are open-ended).
    def query_suggestions : Array(String)
      token = current_token
      return [] of String if token.empty?
      fields = token.includes?(':') ? [] of String : QL_FIELDS.select(&.starts_with?(token.downcase)).map { |f| "#{f}:" }
      # `token_at` rather than the raw token: an operator candidate splices over the whole span,
      # so it has to carry any `(` the way the field candidates above would need to. (This bar's
      # own tokenizer does not peel punctuation — see `current_token_bounds` — which is a separate
      # gap; going through the shared cursor here at least keeps the operators honest.)
      QuerySuggest.with_operators(fields, FilterAst.token_at(@query, @qcx))
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

    # Open the tag editor over the target set — the marks if any are set, else the selected
    # node — seeding the buffer from the PRIMARY target's current memo. Returns false when
    # there is nothing taggable (a fold under the cursor with nothing marked / empty tree),
    # so the controller can toast instead.
    def start_tag : Bool
      targets = target_keys
      return false if targets.empty?
      @tag_targets = targets # pinned NOW, before any reload can retarget the selection
      @tagging = true
      @tag_buffer = node_index[primary_tag_target(targets)]?.try(&.tag) || ""
      @tag_cx = @tag_buffer.size
      @tag_preedit = ""
      true
    end

    # Which target's memo seeds the buffer. The cursor row wins when it is itself a target
    # (it is the row you were looking at); otherwise the first in tree order, which is stable
    # under every filter and expand state. Mirrors History's primary_target_id.
    private def primary_tag_target(targets : Array({String, String})) : {String, String}
      cur = resolve_target
      cur && targets.includes?(cur) ? cur : targets.first
    end

    def cancel_tag : Nil
      @tagging = false
      @tag_buffer = ""
      @tag_cx = 0
      @tag_preedit = ""
      @tag_targets = [] of {String, String}
    end

    # Apply the committed memo to every pinned target in place (blank clears it) and exit the
    # editor. No re-derive — the tree structure is unchanged, so the selection stays put and
    # draw_row reads the fresh tags live. Each target is looked up by its (host, path) key
    # rather than off the cursor, so a mid-edit reload that moved the selection (or a set of
    # marks the cursor was never on) still stamps the right nodes; a key the tree no longer
    # holds is skipped and picked up by the next reload from the store.
    def apply_tag(text : String) : Nil
      value = text.blank? ? nil : text
      index = node_index
      @tag_targets.each { |key| index[key]?.try(&.tag=(value)) }
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

    # The PINNED (host, path) set the open tag editor targets (captured at start_tag —
    # the marks if any were set, else the cursor row); empty when not tagging. The
    # controller persists the buffer to each of these, so a mid-edit reload can't
    # retarget the commit.
    def tag_targets : Array({String, String})
      @tagging ? @tag_targets : [] of {String, String}
    end

    # Selection-based (host, path) for the row currently under the cursor — the LIVE
    # target, used to seed the pin at start_tag and as the single-row fallback for
    # target_keys. Refuses a fold: a synthetic node has no path and is not taggable.
    private def resolve_target : {String, String}?
      visible_rows[@selected]?.try { |row| mark_key(row) }
    end

    # What selection is re-anchored on across a reload. Unlike resolve_target this DOES
    # resolve a fold (to its fold_key) — the cursor has to be able to rest on a `{uuid}`
    # row without being thrown back to the first host on the next poll.
    private def selection_anchor : {String, String}?
      return nil unless row = visible_rows[@selected]?
      return nil unless k = expand_key(row.node)
      {row.host, k}
    end

    # The selected endpoint's {host, method, target} for cross-surface actions (Send to
    # Repeater / Discover / Sequencer). GET-preferred method.
    #
    # A synthetic fold has no path of its own, so `prefer` decides what it resolves to:
    #   :descendant — the first real endpoint under it. Repeater and Sequencer need a
    #                 CONCRETE target; they look it up by exact equality on flows.target.
    #   :container  — the fold's parent path. Discover scans a SUBTREE, and on a `{uuid}`
    #                 row the user means "under /users", not "under this one uuid".
    # Both are identity on a normal node.
    def selected_endpoint(prefer : Symbol = :descendant) : {host: String, method: String, target: String}?
      return nil unless row = visible_rows[@selected]?
      host = row.host
      node = row.node
      if node.grouped
        if prefer == :container
          parent = node.fold_parent
          return nil unless parent
          return {host: host, method: "GET", target: parent.empty? ? "/" : parent}
        end
        return nil unless node = first_endpoint(node)
      end
      endpoint_of(node, host)
    end

    # The cursor row's scope-rule seed — what "add THIS to the scope" means at this depth:
    #   host row (depth 0) → a `host` rule for the whole site
    #   path row           → a `string` rule on "host/path", because Scope has no path type.
    #                        A string rule is a substring of the same `scheme://host/target`
    #                        the SQL lens builds (QL::URL_EXPR, port-free), so "example.com/api"
    #                        covers the subtree under /api on any port.
    # A fold resolves to its CONTAINER ("/users", not one uuid child) — the same reading
    # `selected_endpoint(:container)` gives Discover, and the only one a scope prefix can mean.
    def selected_scope_seed : {match_type: String, pattern: String}?
      return nil unless row = visible_rows[@selected]?
      node = row.node
      return {match_type: "host", pattern: row.host} if row.depth == 0
      path = node.grouped ? node.fold_parent : node.path
      return nil unless path
      # A fold sitting directly under the host root has no container path to prefix with —
      # scoping it is scoping the host.
      return {match_type: "host", pattern: row.host} if path.empty?
      {match_type: "string", pattern: "#{row.host}#{path}"}
    end

    # One node's {host, method, target}, GET-preferred. A node with no captured method of
    # its own (an intermediate folder, a host row) still yields a tuple — it just resolves
    # to no flow at the store, which is the same "no captured request for this path" the
    # cursor already reports. Shared by the cursor path and the marked-set batch, so a mark
    # can never resolve differently from pressing the same key on that row.
    private def endpoint_of(node : Node, host : String) : {host: String, method: String, target: String}
      methods = node.methods
      method = methods.includes?("GET") ? "GET" : (methods.first? || "GET")
      {host: host, method: method, target: node.path}
    end

    # DFS for the first descendant carrying a method — a fold's stand-in for the actions
    # that need a real captured request behind the selection.
    private def first_endpoint(node : Node) : Node?
      node.children.each do |c|
        return c unless c.methods.empty?
        if found = first_endpoint(c)
          return found
        end
      end
      nil
    end

    # --- marks (multi-select, mirrors History #442) ---------------------------

    # A row's durable mark key, or nil when the row can't carry one. A synthetic fold is
    # refused for the same reason it can't be tagged (it is not a real path) AND because it
    # keeps `path` empty — exactly like its host node, so keying one would light the other up.
    private def mark_key(row : VisibleRow) : {String, String}?
      row.node.grouped ? nil : {row.host, row.node.path}
    end

    def mark_count : Int32
      @marks.size
    end

    # Marks that aren't on a visible row right now — collapsed under a folded ancestor,
    # filtered out, or gone from the tree. Surfaced next to the count so a set larger than
    # what's on screen is never a surprise.
    def marked_hidden_count : Int32
      return 0 if @marks.empty?
      visible = 0
      visible_rows.each { |r| visible += 1 if (k = mark_key(r)) && @marks.includes?(k) }
      @marks.size - visible
    end

    # Marks in TREE order — a full walk, not a visible_rows scan, so a mark under a
    # collapsed ancestor still places. Any mark the tree no longer holds is appended
    # (sorted) rather than dropped: it is still a legitimate tag target, and the Repeater
    # batch reports it as unresolved instead of silently shrinking the set.
    def marked_keys : Array({String, String})
      ordered = [] of {String, String}
      seen = Set({String, String}).new
      each_node do |node, host|
        k = {host, node.path}
        next unless @marks.includes?(k)
        next if seen.includes?(k) # a path is unique per host, so this is belt-and-braces
        ordered << k
        seen << k
      end
      ordered.concat((@marks - seen).to_a.sort!)
      ordered
    end

    # The effective target set every batch verb acts on: the marks if any are set, else the
    # cursor row. One rule, so a verb needs no notion of "batch mode". Empty when the cursor
    # sits on a fold with nothing marked — the same refusal `t` and the tag editor give.
    def target_keys : Array({String, String})
      return marked_keys unless @marks.empty?
      resolve_target.try { |k| [k] } || [] of {String, String}
    end

    # The endpoints behind `target_keys`, resolved through the CURRENT tree (so a collapsed
    # node still resolves). A key the tree no longer holds drops out — the caller compares
    # the size against target_keys to report the shortfall.
    def target_endpoints : Array({host: String, method: String, target: String})
      keys = target_keys
      return [] of {host: String, method: String, target: String} if keys.empty?
      index = node_index
      keys.compact_map { |key| index[key]?.try { |node| endpoint_of(node, key[0]) } }
    end

    def marked?(host : String, path : String) : Bool
      @marks.includes?({host, path})
    end

    # `t` — flip the mark on the cursor row, then step DOWN one row so a run of `t` marks
    # consecutive rows (a tree reads top-down; unlike History's list there is no live tail
    # to walk away from). The anchor lands on the row just toggled, so `t` then ⇧↓ extends
    # from it. Returns false when the cursor row can't carry a mark (a fold / empty tree),
    # so the caller can toast rather than look like a dropped keystroke.
    def toggle_mark : Bool
      return false unless row = visible_rows[@selected]?
      return false unless key = mark_key(row)
      @marks.includes?(key) ? @marks.delete(key) : @marks.add(key)
      # The view's own clamping move, NOT the controller's sitemap_move — that pops focus to
      # the sub-tab strip at the top row, which would eject you mid-gesture.
      move(1)
      @mark_anchor = key
      @mark_extent.clear
      true
    end

    def clear_marks : Nil
      @marks.clear
      reset_mark_anchor
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow
    # anchors at the cursor instead of sweeping back to a stale point.
    private def reset_mark_anchor : Nil
      @mark_anchor = nil
      @mark_extent.clear
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead
    # of being left behind (#442 / af7e561). Only the gesture's own keys go (@mark_extent):
    # `t` marks are deliberate, and dropping them too would put a discontiguous set out of
    # reach ("mark this one, skip three, mark that one"). Returns how many marks it gave
    # back, so the caller can say so rather than let a range vanish silently.
    def end_mark_gesture : Int32
      before = @marks.size
      @mark_extent.each { |k| @marks.delete(k) }
      reset_mark_anchor
      before - @marks.size
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. The anchor is re-seeded from the cursor whenever it can't be found on a
    # visible row, which is also what covers "the user collapsed the subtree the anchor was
    # in" — no special case for it. Fold rows inside the range are stepped over, not marked.
    def extend_marks(delta : Int32) : Nil
      rows = visible_rows
      return if rows.empty?
      anchor_idx = @mark_anchor.try { |a| index_of_mark(rows, a) }
      unless anchor_idx
        @mark_anchor = rows[@selected]?.try { |r| mark_key(r) }
        anchor_idx = @selected
        @mark_extent.clear
      end
      move(delta)
      lo, hi = {anchor_idx, @selected}.minmax
      wanted = Set({String, String}).new
      (lo..hi).each { |i| rows[i]?.try { |r| mark_key(r).try { |k| wanted.add(k) } } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three. @mark_extent holds only keys the
      # gesture itself added, so a `t` mark survives a range sweeping over it and back off.
      (@mark_extent - wanted).each { |k| @marks.delete(k) }
      added = wanted - @marks
      @marks.concat(added)
      @mark_extent = (@mark_extent & wanted) | added
    end

    # Row index carrying mark key `key`, or nil when it isn't on screen (collapsed/filtered).
    private def index_of_mark(rows : Array(VisibleRow), key : {String, String}) : Int32?
      rows.index { |r| mark_key(r) == key }
    end

    # (host, path) → Node over the whole CURRENT tree, folds excluded. Built on demand by
    # the batch verbs and the tag commit only — never per frame.
    private def node_index : Hash({String, String}, Node)
      index = {} of {String, String} => Node
      each_node { |node, host| index[{host, node.path}] ||= node }
      index
    end

    # Every real (non-fold) node with the host it hangs under, in tree order.
    private def each_node(& : Node, String ->) : Nil
      stack = [] of {Node, String}
      @hosts.reverse_each { |h| stack << {h, h.label} }
      while entry = stack.pop?
        node, host = entry
        yield node, host unless node.grouped
        node.children.reverse_each { |c| stack << {c, host} }
      end
    end

    # The tree, then the `↓` dropdown OVER it. Split so the popup is drawn last unconditionally:
    # the body below returns early on several paths (no endpoints, the empty-state card), and a
    # dropdown that vanished exactly when the filter matched nothing would be missing from the
    # one moment an operator is most likely to be fixing a query. Mirrors HistoryView.
    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_tree_body(screen, rect, focused, listen: listen, capturing: capturing)
      render_query_popup(screen, rect)
    end

    # Anchored below the column header's divider — never over it — and bounded by the tree,
    # which is the only region it may occlude.
    private def render_query_popup(screen : Screen, rect : Rect) : Nil
      return unless @querying && @popup.open?
      top = list_top(rect)
      bounds = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
      # Anchored at the START of the query text, not at the token's offset within it.
      # `Screen#input_line` scrolls its window horizontally once the query outgrows the bar, so
      # `base + token.start` stops being the token's screen column on exactly the long queries
      # where precision would matter — the card would drift right of what it completes and then
      # clamp. A fixed anchor is always adjacent to the bar and never lies.
      @popup.render(screen, rect.x + 1 + QUERY_PREFIX.size, top - 1, bounds, QL_HELP)
    end

    private def render_tree_body(screen : Screen, rect : Rect, focused : Bool = true, *,
                                 listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
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
            TrafficEmptyState.render(screen, tree, variant: :sitemap, listen: listen, capturing: capturing)
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
      # `list_h`, not `rect.h`: while the tag prompt is open it owns the bottom row, and a
      # gauge measured against the full height would report a viewport one row taller than
      # the tree actually gets.
      Frame.scroll_gauge(screen, Rect.new(rect.x, rect.y, rect.w, list_h),
        rows.size, @scroll, focused)
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
      # A marked row reads as a dim band with a FULLER gutter bar, so it stays
      # distinguishable from the cursor row (accent band) and from a cursor row that is ALSO
      # marked (accent band + full bar). Both glyphs are single-width, so no column moves.
      marked = mark_key(row).try { |k| @marks.includes?(k) } || false
      bg = if selected
             focused ? Theme.accent_bg : Theme.selection_dim
           elsif marked
             Theme.selection_dim
           else
             Theme.bg
           end
      if selected || marked
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, marked ? '▌' : '▎', Theme.accent, bg)
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
      lx = screen.text(lx0, y, row_label(node), label_color(host, node), bg, width: label_width(rect, node, host, lx0))
      draw_cluster(screen, rect, node, host, y, bg, lx)
    end

    # The drawn label. A node that a target deeper than `Sitemap::MAX_DEPTH` was cut onto
    # gets a visible marker: its `path` is only a PREFIX of the captured target, so without
    # this the row reads as an ordinary leaf and the operator has no way to tell.
    private def row_label(node : Node) : String
      node.truncated ? "#{node.label} …+depth" : node.label
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
      # Budget, right-alignment origin AND clip all in display COLUMNS. A memo of Hangul
      # syllables is one char but TWO columns each, so `text.size > avail` read false at
      # twice the budget (nothing truncated) and `tag_right - text.size + 1` started the run
      # columns too far right — through the mandated gap, over the METHODS chips and the
      # card's right border. `column_for` is the exact inverse of `draw_width` at cluster
      # boundaries, so the cut can never split a wide glyph. `comparer_view.cr#slot_short`
      # solves the same problem the same way.
      w = Screen.draw_width(text)
      if w > avail
        text = "#{text[0, Screen.column_for(text, avail - 1)]}…"
        w = Screen.draw_width(text)
      end
      x = tag_right - w + 1
      # `width:` as well as a column-derived origin: a hard ceiling at `tag_right`, so any
      # future drift between the measure and the draw clips instead of overwriting the
      # column to its right.
      screen.text(x, y, text, Theme.accent, bg, width: {tag_right - x + 1, 0}.max) if x >= label_end + 1
    end

    # Screen-x where the right cluster (methods/aside) begins; nil when the row has none.
    private def cluster_start(rect : Rect, node : Node, host : Bool) : Int32?
      if node.grouped
        w = "#{node.children.size} values".size
        w += methods_width(node.fold_methods) + COL_GAP unless node.fold_methods.empty?
        return rect.right - w - 1
      elsif host && node.endpoints > 0
        txt = node.endpoints == 1 ? "1 path" : "#{node.endpoints} paths"
      elsif !node.methods.empty?
        return rect.right - methods_width(node.methods) - 1
      else
        return nil
      end
      rect.right - txt.size - 1
    end

    # Rendered width of a method-chip run (chips plus their 1-col gaps).
    private def methods_width(methods : Array(String)) : Int32
      methods.sum(&.size) + (methods.size - 1)
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
    # (plus the fold's stand-in method chips) on group rows, an endpoint count on host
    # rows, or method chips on endpoint rows — one of the three per row.
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
        # Chips at the right edge, folded-value count to their left: a collapsed fold has
        # to answer "which verbs" without being expanded, or the row hides what it stands for.
        shift =
          if node.fold_methods.empty?
            0
          else
            draw_methods(screen, rect, y, bg, node.fold_methods, label_end)
            methods_width(node.fold_methods) + COL_GAP
          end
        draw_aside(screen, rect, y, bg, "#{node.children.size} values", label_end, shift)
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
    # `right_shift` reserves columns already taken on the right (a fold's method chips).
    private def draw_aside(screen : Screen, rect : Rect, y : Int32, bg : Color, txt : String,
                           label_end : Int32, right_shift : Int32 = 0) : Nil
      start = rect.right - right_shift - txt.size - 1
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
        screen.text(rect.x + 1, rect.y, QUERY_PREFIX, Theme.accent)
        base = rect.x + 1 + QUERY_PREFIX.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright,
          width: rect.w - QUERY_PREFIX.size - 2,
          colors: Highlight.filter_query(@query, Theme.text_bright, known: QL_KNOWN))
        return
      end

      # Right cluster: the scope-lens chip (always shown so the ⇧S toggle is
      # discoverable — the Scope lens filters the tree too) and, when filtering, the
      # matching host count.
      # One right-anchored chain — see HistoryView#render_ql_bar, which this mirrors. The
      # `g:fold` toggle keeps the scope chip's accent/muted dress so the two lenses read as
      # one cluster, and its `g` chord stays in view (folding on vs off renders identically
      # when a tree has no ids to fold).
      chips = [] of {String, Color}
      chips << {"#{@hosts.size}h", Theme.muted} if filtering?
      scope_on = @scope.try(&.active?) == true
      chips << (scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted})
      chips << {"g:fold", @grouping ? Theme.accent : Theme.muted}
      chips << {mark_chip_text.not_nil!, Theme.accent} if mark_chip_text
      lx = Frame.right_text_chain(screen, rect.right - 1, rect.y, rect.x + 2, chips)

      left_w = {lx - (rect.x + 1) - 1, 0}.max
      if !@query.blank?
        # The committed query stays highlighted — this readout is what you scan to
        # check how the active filter is actually being read.
        qx = screen.text(rect.x + 1, rect.y, ": ", Theme.muted, width: left_w)
        screen.styled_text(qx, rect.y, @query, Highlight.filter_query(@query, Theme.text, known: QL_KNOWN),
          Theme.text, width: {rect.x + 1 + left_w - qx, 0}.max)
      else
        # No QL query typed — whether or not a Scope lens is active. Surface the filter
        # affordance + fields rather than a bare "(in-scope only)": the Scope lens is
        # already signalled by the ⇧S chip on the right, so this row isn't wasted
        # repeating it, and the user's next move here is to ADD a query atop the lens.
        screen.text(rect.x + 1, rect.y, FILTER_HINT, Theme.muted, width: left_w)
      end
    end

    # Mark count, drawn right-to-left ending just left of `right_x`; returns the new left edge
    # of the chip cluster. Always shown while any mark is set — marks deliberately survive a
    # sub-tab switch and a reload, so this chip is what keeps the set from being invisible when
    # you come back. The hidden split covers marks the current filter/expand state doesn't
    # show, so the count never silently exceeds what's on screen.
    # The mark chip's TEXT, or nil when nothing is marked — see HistoryView#mark_chip_text.
    private def mark_chip_text : String?
      return nil if @marks.empty?
      hidden = marked_hidden_count
      hidden > 0 ? "#{@marks.size} marked ·#{hidden} hidden" : "#{@marks.size} marked"
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
        QuerySuggest.render(screen, rect.x + 1, y, rect.w - 2, sugg)
        return
      end
      # No live completions to Tab through. At a cold start (nothing typed yet, or the
      # cursor sits just after a space) show a standing hint so the query language is
      # discoverable from the moment `/` opens; on a non-empty token with no match stay
      # quiet — the user is deliberately free-texting a word.
      return unless QuerySuggest.hint_slot?(current_token)
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: rect.w - 2)
    end

    # Inverts render's tree placement (offset below the chrome band) to find which
    # visible_rows index a click lands on; nil past the last populated row.
    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if mx < rect.x || mx >= rect.right # reject the frame border columns (mirror the other list helpers)
      top = list_top(rect)
      i = my - top
      # `@tagging` takes the bottom row for the prompt, exactly as render and the gauge on
      # the same pass already account for. Without it a click on the `tag › …` prompt row
      # selected the tree row one past the last VISIBLE one — and on the marker column it
      # folded a node the operator could not see. Same shape as the Colormarker note row.
      bottom = @tagging ? rect.bottom - 1 : rect.bottom
      return nil if i < 0 || i >= {bottom - top, 0}.max
      idx = @scroll + i
      idx < visible_rows.size ? idx : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline
    # — one column outside the list rect, which is why `row_at` cannot answer it — and `@scroll`
    # here is DERIVED from the selection by `ensure_visible`, so the answer is a selection, not
    # an offset. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      rows = visible_rows
      # `list_h`, matching the draw: while the tag prompt is open the tree gets one row less.
      list_h = @tagging ? {rect.h - 1, 0}.max : rect.h
      Frame.scroll_gauge_row(Rect.new(rect.x, rect.y, rect.w, list_h), rows.size, mx, my)
    end

    # Inverts render's marker column `rect.x + 1 + depth*2` for visible_rows[ri].
    def marker_hit?(rect : Rect, mx : Int32, ri : Int32) : Bool
      row = visible_rows[ri]?
      return false unless row
      mx == rect.x + 1 + row.depth * 2
    end

    # The cursor row index — what lets the controller tell a click that MOVES the selection
    # from one that lands on the row already under it (only the former is a cursor gesture).
    def selected_index : Int32
      @selected
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
        @hosts.each_with_index { |host, i| collect(host, 0, 0_u64, i < @hosts.size - 1, rows, host.label) }
        rows
      end
    end

    # Flatten the expanded tree, threading the tree-guide bitmask down. `has_next` is
    # whether `node` has a following sibling: when it does, descendants draw a `│` at
    # `node`'s level (bit `depth`) so the branch reads as continuing. `host` is the depth-0
    # ancestor's label, carried down so every row knows its host without a back-walk.
    # Explicit stack rather than native recursion (see `Sitemap.post_order`): this walk is
    # PRE-order and threads depth + the guide bitmask DOWN, so children are pushed in
    # REVERSE and popped left-to-right, which reproduces the recursion's row order exactly.
    # It only descends into EXPANDED nodes — but the factory-default expand depth is "fully
    # expanded" (`Sitemap.apply_expand_depth!`, depth < 0), so on a default install this
    # walks the whole tree and was a live stack-overflow path like the other seven.
    private def collect(node : Node, depth : Int32, guides : UInt64, has_next : Bool,
                        rows : Array(VisibleRow), host : String) : Nil
      stack = [{node, depth, guides, has_next}]
      while entry = stack.pop?
        n, d, g, hn = entry
        rows << VisibleRow.new(n, d, g, host)
        next unless n.expanded
        child_guides = hn ? (g | (1_u64 << d)) : g
        last = n.children.size - 1
        i = last
        while i >= 0
          stack << {n.children[i], d + 1, child_guides, i < last}
          i -= 1
        end
      end
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
