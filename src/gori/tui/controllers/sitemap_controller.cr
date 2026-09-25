require "../tab_controller"
require "../sitemap_view"
require "../../export/openapi"
require "../../js_refs"
require "../../durable_file"

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
      @sitemap.set_registry(@host.session.registry)
      @sitemap.set_hide_static(StaticAsset.hidden?(@host.session.store))
      @query_reload_at = nil.as(Time::Instant?)
      # The `/` bar's reload off the main fiber (the History #967 shape): one running read
      # and one replaceable request. A superseded read is cancelled and its answer dropped
      # by generation, so a fast typist never sees an older query's tree land last.
      @search_generation = 0_i64
      @search_control = nil.as(Store::QueryControl?)
      @search_pending = nil.as({Store, SitemapView::ReloadPlan, Int64}?)
      @search_results = Channel({Int64, SitemapView::ReloadPlan, SitemapView::Fetched?}).new(1)
      @export_results = Channel(String).new(4)
      # The JavaScript reference scan (#1243), off the event loop like the export: it reads
      # whole bodies, and the engine yields between flows and within one. One at a time.
      @js_scan_results = Channel(String).new(4)
      @js_scanning = false
    end

    def view : SitemapView
      @sitemap
    end

    # The OpenAPI export (#1241), off the event loop: the build reads up to `max_flows` flows
    # with their bodies, and on the one cooperative scheduler a synchronous walk would freeze
    # the terminal for its length. The engine yields between flows; the finished toast lands
    # through `drain_export`. `.yaml`/`.yml` writes YAML, anything else JSON.
    def export_openapi(path : String, filter : QL::Filter, targets : Hash(String, Set(String)?),
                       label : String) : Nil
      store = @host.session.store
      results = @export_results
      opts = Export::OpenApi::Options.new(filter: filter, targets: targets)
      yaml = {".yaml", ".yml"}.includes?(File.extname(path).downcase)
      @host.status("exporting #{label} as OpenAPI…")
      spawn(name: "gori-openapi-export") do
        message = begin
          result = Export::OpenApi.build(store, opts)
          # An empty document is not a file anyone asked for; the toast says why it is empty.
          if result.report.operations > 0
            text = yaml ? Export::OpenApi.to_yaml(result.doc) : Export::OpenApi.to_json(result.doc)
            DurableFile.write(path, text, perm: File::Permissions.new(0o644))
          end
          SitemapController.export_toast(result.report, path)
        rescue ex
          "OpenAPI export failed: #{ex.message || ex.class.name}"
        end
        results.send(message)
      end
    end

    # The finished export as one line: what was written, every cap that was hit (a capped
    # document looks complete, so the toast is where that has to be said), what was skipped,
    # and — last, because it is the long part a narrow status line cuts — where it went.
    def self.export_toast(report : Export::OpenApi::Report, path : String) : String
      if report.operations == 0
        why = report.notes.first? || "no captured request under the selection"
        return "OpenAPI: nothing to export — #{why}; no file written"
      end
      msg = "OpenAPI: #{report.summary}"
      msg += " · TRUNCATED (#{report.cap_notes.join("; ")})" if report.truncated?
      skipped = report.skipped.values.sum
      msg += " · #{skipped} skipped" if skipped > 0
      "#{msg} → #{path}"
    end

    # Called each run-loop tick: land a finished export's toast. True when one arrived.
    def drain_export : Bool
      select
      when message = @export_results.receive
        @host.status(message)
        true
      else
        false
      end
    end

    # `sitemap.js-scan` — read the JS responses and HTML pages behind the tree's own flow set
    # (its `/` query and lenses, the Params sub-tab's rule) that no scan has read yet, and store
    # what they reference. Sends nothing. A project switch mid-scan stops it between flows.
    def js_scan(filter : QL::Filter) : Nil
      if @js_scanning
        @host.status("a JavaScript scan is already running")
        return
      end
      store = @host.session.store
      results = @js_scan_results
      me = self
      @js_scanning = true
      @host.status("scanning captured JavaScript…")
      spawn(name: "gori-js-scan") do
        message = begin
          report = JsRefs.scan(store, JsRefs::ScanOptions.new(filter: filter), -> { !me.bound_to?(store) })
          SitemapController.js_scan_toast(report)
        rescue ex
          "JavaScript scan failed: #{ex.message || ex.class.name}"
        end
        results.send(message)
      end
    end

    # Whether `store` is still the project this tab shows — a scan started before a switch
    # stops at its next flow instead of writing on into a store the session let go of.
    def bound_to?(store : Store) : Bool
      @host.session.store.same?(store)
    end

    # The finished scan as one line: what it found, then every cap and failure — a capped scan
    # looks complete, and a rolled-back write leaves a flow unscanned, so the toast says both.
    def self.js_scan_toast(r : JsRefs::ScanReport) : String
      msg = "JS scan: #{r.flows_scanned} response#{r.flows_scanned == 1 ? "" : "s"}, " \
            "#{r.new_endpoints} new endpoint#{r.new_endpoints == 1 ? "" : "s"}"
      msg += " · #{r.bodies_capped} read only to #{JsRefs::MAX_SCAN // 1024 // 1024} MiB" if r.bodies_capped > 0
      msg += " · #{r.refs_capped} stopped at #{JsRefs::MAX_REFS} literals" if r.refs_capped > 0
      msg += " · #{r.write_failures} NOT recorded (project busy) — scan again" if r.write_failures > 0
      msg += " · more unscanned — scan again" if r.truncated
      msg
    end

    # Called each run-loop tick: land a finished scan's toast and rebuild the tree with what it
    # stored. True when one arrived.
    def drain_js_scan : Bool
      select
      when message = @js_scan_results.receive
        @js_scanning = false
        @host.status(message)
        reload
        true
      else
        false
      end
    end

    def js_scanning? : Bool
      @js_scanning
    end

    # `sitemap.toggle-js-refs` — show/hide the JavaScript-referenced nodes, then rebuild.
    def sitemap_toggle_js_refs : Nil
      @sitemap.toggle_js_refs
      reload
      @host.status(@sitemap.js_refs? ? "JavaScript references shown" : "JavaScript references hidden")
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

    def page_rows : Int32?
      @sitemap.list_page_rows
    end

    # esc clears the marks. Runs BEFORE the Sitemap keymap, so this shadows sitemap.to-menu
    # ONLY while marks are set — with none set, esc still pops to the sub-tab strip. (The QL
    # bar and the tag editor claim every key ahead of this while either is up, so their own
    # esc handling is unaffected.)
    # The `/` query bar and the tag prompt — the two panes that take characters here.
    def body_takes_text? : Bool
      @sitemap.querying? || @sitemap.tagging?
    end

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

    # Display… rows (#1274). The static lens is the shell's (`Runner#menu_state`).
    def menu_state(verb_id : String) : String?
      case verb_id
      when "sitemap.toggle-grouping"   then SpaceMenu.on_off(@sitemap.grouping?)
      when "sitemap.toggle-query-fold" then SpaceMenu.on_off(@sitemap.fold_query?)
      when "sitemap.toggle-js-refs"    then SpaceMenu.on_off(@sitemap.js_refs?)
      end
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

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_double_click_content(rect.inset(1, 1), mx, my)
    end

    # `y`: every marked row as `host/path`, one per line — or the cursor row's seed, which is
    # the host for a host row and `host/path` below it (the string `a` would scope). The tree
    # carries no scheme, so this is the URL minus its scheme, the way the rows read.
    def copy_row : Nil
      keys = @sitemap.marked_keys
      text = if keys.empty?
               @sitemap.selected_scope_seed.try(&.[:pattern]) || ""
             else
               keys.map { |(host, path)| "#{host}#{path}" }.join("\n")
             end
      copy_text(text, keys.size > 1 ? "#{keys.size} paths" : nil)
    end

    # The universal tree gesture: a double-click on a row's LABEL folds or unfolds a folder
    # and opens a leaf's flow (what `o` does). Expand/collapse used to answer only on the
    # one-column ▾/▸ marker, and a double-click there was a net no-op — the first press of
    # the pair had already toggled, the second toggled back. So the marker column is
    # swallowed here (true, nothing done): the pair reads as one toggle. Off every row it
    # answers false and the shell delivers the second press as an ordinary click.
    def handle_double_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      return false unless ri = @sitemap.row_at(content, mx, my)
      return true if @sitemap.marker_hit?(content, mx, ri)
      @sitemap.select_index(ri)
      if @sitemap.leaf_at?(ri)
        @host.sitemap_open_flow
      else
        @sitemap.toggle_at(ri)
      end
      true
    end

    # Click hit-test against the content rect directly (TargetController passes the rect
    # below its sub-tab strip; the standalone path insets the frame itself).
    def handle_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      return true if click_filter_bar(content, mx, my)
      # The scroll gauge on the frame's right hairline — one column outside the tree rect, so
      # `row_at` never sees it. A click there moves the cursor to the row it points at.
      if row = @sitemap.gauge_row_at(content, mx, my)
        end_range_gesture unless row == @sitemap.selected_index
        @sitemap.select_index(row)
        return true
      end
      return true unless ri = @sitemap.row_at(content, mx, my)
      # A click that MOVES the cursor collapses the range, same as a plain arrow. A click on
      # the row already under the cursor doesn't: that reads as "expand this node" (the marker
      # hit below), not as a selection gesture — the distinction af7e561 drew for the wheel.
      end_range_gesture unless ri == @sitemap.selected_index
      @sitemap.select_index(ri)
      @sitemap.toggle_at(ri) if @sitemap.marker_hit?(content, mx, ri)
      true
    end

    # The filter bar row. Its chips do exactly what their own chords do — `s` flips the scope
    # lens, `g` id folding — and the field left of them opens for editing like `/`. The mirror
    # of HistoryController#click_filter_bar, including that a READOUT chip (the host count, the
    # mark count) still consumes the click: the bar is chrome, not a tree row, and falling
    # through would move the cursor out from under the pointer.
    private def click_filter_bar(content : Rect, mx : Int32, my : Int32) : Bool
      # The tag editor is a text sub-mode the shell routes every key into. Opening the QL bar
      # under it would leave two fields claiming the keyboard, so while it is up the bar row
      # falls through to the tree click it has always been.
      return false if @sitemap.tagging?
      if chip = @sitemap.ql_chip_at(content, mx, my)
        case chip
        when :scope  then @host.toggle_scope_lens
        when :fold   then sitemap_toggle_grouping
        when :static then @host.toggle_static_assets
        end
        return true
      end
      return false unless @sitemap.ql_bar_at?(content, mx, my)
      sitemap_query unless @sitemap.querying?
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
      # `space tag`, not `⇧T`: tagging is menu-only — ⇧T is "mark all" here as it is in every
      # other marked list, so a hand that learnt `t`/⇧T there finds it doing the same thing.
      return keys("↑/↓ move · {sitemap.query} filter · {sitemap.mark-toggle} mark · {sitemap.mark-all} all · {sitemap.copy} copy · space cmds (tag) · esc clears marks") if @sitemap.mark_count > 0
      # `space cmds` on BOTH branches. The mark-set branch above named it and this one did not,
      # so the same tab advertised the space menu only while marks happened to be set.
      keys("↑/↓ move · {sitemap.query} filter · {sitemap.mark-toggle} mark · {sitemap.mark-all} all · {sitemap.toggle-grouping} fold · ↵/→ expand · {sitemap.copy} copy · space cmds · esc sub-tabs")
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

    # Every reload re-reads the hide-static lens from the project, so a peer's flip (another
    # gori on this project) lands with the next tick rather than at restart — History does the
    # same on entry and on an external change (#1239).
    private def sync_hide_static : Nil
      @sitemap.set_hide_static(StaticAsset.hidden?(@host.session.store))
    end

    # Re-derive the tree from the store under the current scope filter + `/` query
    # (both held by the view). Public so the scope-lens toggle (a cross-tab action
    # mediated by the shell) can refresh it.
    # A synchronous reload (tab entry, an external change, an import) supersedes any read the
    # bar has in flight — its answer would otherwise land AFTER this one, showing an older
    # query's tree.
    def reload : Nil
      invalidate_search
      sync_hide_static
      @sitemap.searching = false
      @sitemap.reload(@host.session.store)
    end

    private def invalidate_search : Nil
      @search_generation += 1
      @search_control.try(&.cancel)
      @search_pending = nil
    end

    # The debounced flush: compile the query here, read on a worker, build on return.
    private def request_reload(store : Store) : Nil
      invalidate_search
      unless plan = @sitemap.prepare_reload
        @sitemap.searching = false # an invalid residual settled the tree by itself
        return
      end
      @sitemap.searching = true
      @search_pending = {store, plan, @search_generation}
      start_search
    end

    private def start_search : Nil
      return if @search_control
      return unless pending = @search_pending
      @search_pending = nil
      store, plan, generation = pending
      control = Store::QueryControl.new
      @search_control = control
      results = @search_results
      view = @sitemap
      spawn(name: "gori-sitemap-search") do
        result = nil.as(SitemapView::Fetched?)
        begin
          control.check!
          result = view.fetch_reload(store, plan, control)
        rescue Store::QueryCancelled
          # Superseded/closed is not a failed query and never means an empty tree.
        rescue ex
          ::Log.warn { "sitemap worker failed: #{ex.message}" }
        ensure
          results.send({generation, plan, result})
        end
      end
    end

    # Called each run-loop tick: land a finished read. True when it did (→ a frame).
    def drain_search : Bool
      select
      when done = @search_results.receive
        @search_control = nil
        generation, plan, result = done
        if generation == @search_generation
          @sitemap.searching = false
          @sitemap.apply_reload(result[0], result[1], plan, result[2], result[3]) if result
        end
        start_search
        true
      else
        false
      end
    end

    # --- QL filter bar (a text sub-mode; the shell claims it before the focus ring) ---
    # Returns true (swallows). Mirrors HistoryController#handle_query_key.
    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      store = @host.session.store
      return true if query_nav(ev)
      case
      when key.enter?  then query_enter
      when key.escape? then query_escape(store)
      when key.tab?    then (@sitemap.query_complete; schedule_query_reload)
      when key.backspace? then @sitemap.query_backspace; schedule_query_reload
      # Above the printable arm below, which would otherwise type the `?` (see ql_help_key?).
      when TabController.ql_help_key?(ev, @sitemap.query) then @host.open_help_query(:sitemap)
      else
        if c && !ev.ctrl? && !ev.alt?
          @sitemap.query_insert(c)
          schedule_query_reload
          @sitemap.set_preedit("") # clear preedit on committed char
        end
      end
      true
    end

    # Open dropdown ⇒ ↵ takes the highlighted candidate and shuts it; closed ⇒ apply and leave
    # edit mode. Mirrors HistoryController exactly — one grammar, one set of gestures.
    # ↓/↑ drive the dropdown, ←/→ the caret. Handled ahead of the `case` below rather than as
    # four more arms in it: the dropdown's two keys pushed `handle_query_key` past the complexity
    # gate CI runs, and "move something" is a different question from "what does this key do".
    # `↓`/`↑` were dead in this bar before the dropdown — a one-line field has no second row to
    # move a caret to — which is why they could be claimed without displacing anything.
    private def query_nav(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when act = LineEdit.action(ev) # ⌃/⌥←→, Home/End, Delete, ⌥⌫ — before the bare arrows
        @sitemap.query_edit(act)
        schedule_query_reload if LineEdit.mutating?(act)
      when key.down?  then @sitemap.popup_down
      when key.up?    then @sitemap.popup_up
      when key.left?  then @sitemap.query_move(-1)
      when key.right? then @sitemap.query_move(1)
      else                 return false
      end
      true
    end

    private def query_enter : Nil
      if @sitemap.popup_open?
        @sitemap.query_complete(close: true)
        schedule_query_reload
      else
        flush_query_reload
        @sitemap.stop_query
      end
    end

    # esc closes the dropdown first, so looking at the list never costs the typed query.
    private def query_escape(store) : Nil
      return @sitemap.popup_close if @sitemap.popup_open?
      @query_reload_at = nil
      @sitemap.cancel_query
      invalidate_search
      @sitemap.searching = false
      @sitemap.reload(store)
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
      request_reload(@host.session.store)
    end

    # `/` — focus the QL filter bar (verb-dispatched).
    def sitemap_query : Nil
      @sitemap.start_query
      @host.status("filter: type a query · ↹ complete · ↵ apply · esc clear")
    end

    # --- tag editor (a text sub-mode; the shell routes its keys via handle_tag_key) ---
    # Tag path (space menu, `sitemap.tag`) — open the tag editor over the target set (the marks if any, else the selected
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
      # The store answers whether each write COMMITTED (`set_sitemap_tag`'s own comment: the
      # answer exists because dropping it "made every caller report the change for a
      # rolled-back batch"). This dropped it, so a project whose writer a peer held reported
      # "tagged", stamped the memo onto the tree, and let the next reload take it back with no
      # word — the memo was on nobody's disk. Stamp what landed, name what did not; MCP's
      # `set_sitemap_tag` already refuses in the same terms.
      committed = targets.select { |(host, path)| store.set_sitemap_tag(host, path, text) }
      @sitemap.apply_tag(text, committed) # stamp in place — keeps the selection, no re-derive
      # A `tag:` filter must re-evaluate against the changed tags (the in-place stamp
      # doesn't re-filter), else the just-tagged node stays hidden / a cleared tag shown.
      reload if @sitemap.filtering?
      # `blank?`, not `empty?`: a memo of nothing but spaces is a CLEAR everywhere the write
      # lands — `Store#set_sitemap_tag` DELETEs on `tag.blank?` and `apply_tag` stamps nil on
      # the same test — so an `empty?` here said `tagged: "  "` over a tag that had just been
      # removed, and named a refused clear "NOT tagged". Same predicate, same sentence.
      cleared = text.blank?
      refused = targets.size - committed.size
      if refused > 0
        return @host.status(
          "#{paths(refused)} NOT #{cleared ? "cleared" : "tagged"} (project busy) — try again", :error)
      end
      n = targets.size
      @host.status(
        if cleared
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

    # ⇧G — fold/unfold query-string variants (/search?q=1 + /search?q=2 → /search), then
    # rebuild. Its own toggle, not a second meaning for `g`: one hides ids, the other hides
    # the query strings a fuzzed endpoint fills the tree with.
    def sitemap_toggle_query_fold : Nil
      @sitemap.toggle_fold_query
      reload
      @host.status(@sitemap.fold_query? ? "query folding on" : "query folding off")
    end

    # --- marks (multi-select, mirrors History #442) ---------------------------

    def marked_node_count : Int32
      @sitemap.mark_count
    end

    # --- the MCP selection snapshot (#1091) -----------------------------------
    # Reached through `TargetController`, which forwards these to its active child — Sitemap
    # is not registered in the Runner's @tabs.

    def selection_kind : String?
      "sitemap_node"
    end

    def list_selection_ident : SelectionIdent
      SelectionIdent.new(
        marks: @sitemap.mark_count,
        cursor: @sitemap.selected_index,
        # The PATH half only. Crossing hosts necessarily crosses a depth-0 node, which moves
        # `cursor`, and a reload that reassigns a given index to another host moves `rows`.
        cursor_key: @sitemap.selected_mark_key.try(&.[1]) || "",
        rows: @sitemap.row_count,
        scoped: @host.session.scope.active?)
    end

    def write_selection_fields(j : JSON::Builder) : Nil
      # NOT `ids`: a sitemap target is a {host, path} pair, which is the whole reason `kind`
      # is a field. An array whose element type depends on a sibling field is how a reader
      # ends up doing arithmetic on a hostname.
      #
      # The raw mark keys, never `target_endpoints` — that resolves through the current tree
      # and DROPS a key the tree no longer holds, which would silently shrink the operator's
      # selection on its way to the agent.
      keys = @sitemap.target_keys
      shown = keys.first(TabController::SELECTION_ID_CAP)
      j.field "nodes" do
        j.array do
          shown.each do |(host, path)|
            j.object do
              j.field "host", host
              j.field "path", path
            end
          end
        end
      end
      j.field "target_source", @sitemap.mark_count > 0 ? "marks" : "cursor"
      j.field "marked_count", @sitemap.mark_count
      j.field "marked_hidden_count", @sitemap.marked_hidden_count
      j.field "id_cap", TabController::SELECTION_ID_CAP
      j.field "truncated", shown.size < keys.size
      j.field "visible_rows", @sitemap.row_count
      j.field "query", @sitemap.query unless @sitemap.query.blank?
      j.field "scope_lens", @host.session.scope.active?
    end

    def mcp_mark_count : Int32
      @sitemap.mark_count
    end

    # `t` — flip the cursor row's mark and step down. A fold carries no path, so it can't be
    # marked (nor tagged, nor resolved to an endpoint) — say so rather than eat the key.
    def sitemap_mark_toggle : Nil
      return @host.status("can't mark a fold — expand it and mark a value") unless @sitemap.toggle_mark
      @host.status(mark_status)
    end

    def sitemap_mark_all : Nil
      added = @sitemap.mark_all_visible
      return @host.status("nothing to mark — this view shows no captured paths") if added == 0 && @sitemap.mark_count == 0
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
