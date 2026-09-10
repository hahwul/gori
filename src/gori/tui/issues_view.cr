require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./gutter"
require "./viewport"
require "../settings"
require "../store"
require "../issues_query"
require "../links"
require "./preview_split"
require "./line_edit"
require "./query_suggest"
require "./suggest_popup"
require "./issue_presentation"

module Gori::Tui
  # The Issues tab (DESIGN.md §6: the final output — human-confirmed vulns). A
  # severity-sorted list + a detail with inline-editable notes and a severity
  # control. Created from a flow (History `F`) or blank (`n`).
  class IssuesView
    include QueryBarEdit # ⌃/⌥←→ word motion, Home/End, Delete, ⌥⌫ on the `/` bar
    # The list-over-preview layout and the severity/status vocabulary, both shared with
    # the sibling tab that lists the same records through the other lens.
    include PreviewSplit
    include PreviewPane
    include IssuePresentation

    # The `/` bar's own label, hoisted out of `render_filter_bar` because the dropdown
    # anchors to the column the query text starts in and must not re-measure it.
    QUERY_PREFIX = "filter › "

    # The idle bar's one-liner and the cold-start suggestion row, both GENERATED from this
    # backend's vocabulary rather than written out. The literal they replace named `severity:`,
    # `cvss:>=7`, `status:` and `host:` but not `title:`, and no boolean operator at all — the
    # exact drift `QuerySuggest`'s own header cites Issues for.
    #
    # `regex: false` and `compare:` are not decoration. `cold_hint`'s defaults name `~regex`
    # and `>= < on status size dur`; `Issues::Filter.known_field?` refuses `~` outright and
    # this backend has no `size`/`dur`, so the default text would re-break what
    # b28aaaaa fixed — a filter bar naming a field it does not have.
    FILTER_HINT = QuerySuggest.idle_hint("/ filter", Issues::Filter::HINT_FIELDS)
    QUERY_HINT  = QuerySuggest.cold_hint(Issues::Filter::HINT_FIELDS, help_key: true,
      regex: false, compare: "severity cvss")

    # The bar's field vocabulary, asked per separator (`FilterAst.spans`). Without it an
    # unrecognised `hsot:` rendered in the same confident blue as a real field — the one
    # visible signal an operator has while typing, saying the opposite of the truth, since
    # `Issues::Filter` free-texts the whole token and it matches nothing. `SEPS_FIELD` below
    # already keeps `~` out of the question; this keeps a MISSPELLED name out of it too.
    QUERY_KNOWN = ->(f : String, op : Char) { Issues::Filter.known_field?(f, regex: op == '~') }

    def initialize
      @all = [] of Store::Issue    # the raw store list (severity-desc)
      @issues = [] of Store::Issue # the filtered/visible subset
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::Issue?)
      @detail_flow = nil.as(Store::FlowRow?)
      @detail_links = [] of Store::EntityLink
      @detail_resolved = [] of Links::Resolved
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links # :links | :notes — which detail region owns plain arrows
      # Multi-select marks, keyed by ISSUE ID rather than row index (the History list's
      # rule, #442): the list re-sorts on every severity/status edit and re-filters on
      # every `/` keystroke, and the cursor is already id-anchored across a reload (see
      # apply_filter), so an index-keyed set would silently retarget. A mark the current
      # filter hides stays marked (marked_hidden_count reports it); a mark whose issue is
      # gone simply fails to resolve at the verb.
      @marks = Set(Int64).new
      @mark_anchor = nil.as(Int64?) # id-keyed range anchor for the ⇧arrow extend
      # Ids the CURRENT ⇧arrow gesture added, so shrinking the range gives them back the way
      # a GUI shift+click does. Scoped to the gesture, so marks made by `t`/⇧T outside the
      # range are never disturbed. Cleared whenever the anchor is.
      @mark_extent = Set(Int64).new
      @notes_mode = InputMode::Read
      @notes_read = TextReadState.new
      @notes = TextArea.new
      # Soft wrap, like every other reading surface in the tree. An issue's notes are prose —
      # a pasted payload or a paragraph of reproduction steps is one logical line — so the
      # `follow_x` sideways pan this used to carry showed one screenful and hid the rest.
      @notes.wrap = true
      # The stored text the notes buffer was last SEEDED from — the common ancestor of this
      # window's edit and whatever a peer has since written. `@detail.notes` cannot serve: the
      # data_version tick re-reads the row while INS is open (the other detail fields have to
      # stay live), so it moves to the peer's text and a three-way comparison against it would
      # report "no divergence" for exactly the case that loses the peer's writeup. Kept in
      # lock-step with every `@notes.set_text` of stored text — see `seed_notes`.
      @notes_base = ""
      # The peer text already announced, so the lost-update toast fires ONCE per divergence.
      # The tick runs on this session's OWN captures too (data_version cannot say whose commit
      # moved it), which during a live capture is ~1.3×/sec of the same warning.
      @notes_peer_seen = nil.as(String?)
      @loaded = false
      # The `/` filter bar (mirrors History's QL bar but matches in memory).
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
      # The `↓` completion dropdown. Closed until asked for — see `SuggestPopup`.
      @popup = SuggestPopup.new
      # `host:` completion pool, rebuilt on reload — see `host_pool`.
      @host_pool = nil.as(Array(String)?)
      # settings:layout Issues preview (list page bottom pane)
      @preview_scroll = 0
      @preview_focus = :list # :list | :preview
    end

    def preview_enabled? : Bool
      Settings.issues_preview
    end

    def reload(store : Store) : Nil
      @all = store.issues
      @host_pool = nil
      apply_filter
      @loaded = true
    end

    # Recompute the visible list from the raw list through the active filter, then
    # re-anchor selection by issue id (not index) so a data_version reload under
    # live capture doesn't jump the highlight to a different row.
    private def apply_filter : Nil
      prev_id = @issues[@selected]?.try(&.id)
      @issues = Issues::Filter.parse(@query).apply(@all)
      @selected =
        if prev_id && (idx = @issues.index { |f| f.id == prev_id })
          idx
        else
          @selected.clamp(0, {@issues.size - 1, 0}.max)
        end
    end

    def move(delta : Int32) : Nil
      if preview_enabled? && @preview_focus == :preview
        scroll_preview(delta)
        return
      end
      return if @issues.empty?
      @selected = (@selected + delta).clamp(0, @issues.size - 1)
      @preview_scroll = 0
      reset_mark_anchor # a plain move re-seeds the range anchor, like a GUI list
    end

    # The first ISSUE-row screen-y — ONE derivation, so `render_list` and both hit-tests
    # cannot drift. The filter bar owns `rect.y`; while the bar is being EDITED the suggestion
    # row takes the next one; then the column header and its divider.
    #
    # Extracted before the suggestion row existed: `rect.y + 3` was written out at three
    # sites, and a row added without this puts every click one row off — but only while the
    # bar is open, which is a state a render assertion never reaches. Mirrors
    # `HistoryView#list_top`.
    private def list_top(list_rect : Rect) : Int32
      hdr_y = list_rect.y + 1
      hdr_y += 1 if @querying
      hdr_y + 2 # past the column header and its divider
    end

    # Inverts render_list's row layout: maps a click to an issue index, or nil past the last
    # populated row / outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_top(list_rect)
      list_h = {list_rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @issues.size ? idx : nil
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the frame's right
    # hairline — one column OUTSIDE the list rect, which is why `list_row_at` cannot answer it
    # — and this list's `@scroll` is DERIVED from the selection by render's `ensure_visible`,
    # so the answer is a selection, not an offset. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      top = list_top(list_rect) # same band list_row_at and the gauge draw measure
      Frame.scroll_gauge_row(Rect.new(list_rect.x, top, list_rect.w, {list_rect.bottom - top, 0}.max),
        @issues.size, mx, my)
    end

    def preview_at?(rect : Rect, mx : Int32, my : Int32) : Bool
      _, prev = list_split(rect)
      !!prev.try(&.contains?(mx, my))
    end

    # Sets the list selection (clamped like #move); render's ensure_visible then
    # reconciles @scroll on the next frame.
    # Mouse: place the inline NOTES-editor cursor at a click. `rect` is the framed
    # detail interior render() receives; the NOTES editor sits at rect.y + 6 (after
    # the badge/hint/meta/flow rows + divider + "NOTES" label), mirroring render_detail.
    def notes_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      notes_rect = notes_body_rect(rect)
      return if notes_rect.empty?
      @detail_focus = :notes
      enter_notes_insert!
      @notes.click_to_cursor(notes_rect, mx, my)
    end

    def select_index(idx : Int32) : Nil
      return if @issues.empty?
      @selected = idx.clamp(0, @issues.size - 1)
      @preview_scroll = 0
      reset_mark_anchor # same as the keyboard `move`: a plain click re-seeds the anchor
      @preview_focus = :list
    end

    def selected_index : Int32
      @selected
    end

    def selected_id : Int64?
      @issues[@selected]?.try(&.id)
    end

    def empty? : Bool
      @issues.empty?
    end

    # At the first (top) issue — lets the Runner pop focus to the tab bar on ↑.
    def at_top? : Bool
      @selected == 0
    end

    def detail_open? : Bool
      !@detail.nil?
    end

    getter notes_mode : InputMode

    def notes_insert_mode? : Bool
      @notes_mode == InputMode::Insert
    end

    def notes_focused? : Bool
      @detail_focus == :notes
    end

    def focus_links! : Nil
      @detail_focus = :links
    end

    def focus_notes! : Nil
      @detail_focus = :notes
    end

    # The detail's pane ring, top to bottom — the shape every multi-pane view in the tree
    # uses (`DiscoverView#pane_advance` is the canonical copy). `@detail_focus` was always a
    # two-value symbol; what it never had was a ring the shell's ⇥ could walk.
    DETAIL_PANES = [:links, :notes]

    # ⇥ / ⇧⇥ inside an open detail. WRAPS, and always answers true, rather than returning
    # false at the ends like a list-page ring does.
    #
    # `false` is how a view tells `Runner#focus_advance` to hand focus to the TAB BAR — and
    # `handle_detail_key` is gated on `@focus == :body` (see the arm in `runner.cr` that
    # routes it). So the old `return false if detail_open?` left the detail fully DRAWN with
    # every key dead, back keys included, and the very next ← switched tab. ⇥ is exactly what
    # an operator presses to move between two panes, which made it the fastest route into a
    # screen that looked alive and answered nothing.
    #
    # Two panes, and the detail is a drill-in with its own way out (`esc`, `←`, `h`), so
    # wrapping is both what the keypress means here and the only answer that cannot strand
    # anyone.
    def step_detail_focus(dir : Int32) : Bool
      i = DETAIL_PANES.index(@detail_focus) || 0
      @detail_focus = DETAIL_PANES[(i + dir) % DETAIL_PANES.size]
      true
    end

    # At the last RELATED row — the edge `↓` hands focus to NOTES from. An EMPTY list answers
    # true, so `↓` reaches NOTES on an issue with no links at all: that is the shape `n`
    # creates, and it was the one where a focus move had no visible effect whatsoever.
    def links_at_bottom? : Bool
      @detail_resolved.empty? || @selected_link >= @detail_resolved.size - 1
    end

    # The NOTES read caret has no row above it — the edge `↑` crosses back to RELATED on.
    #
    # This pane WRAPS (`@notes.wrap = true`), and `TextReadState#move` routes every `dr != 0`
    # through `TextArea#visual_row_target`, so `↑` steps one VISUAL row, not one logical line.
    # A wrapped first paragraph is N drawn rows of logical line 0, so testing `cursor.cy <= 0`
    # ejected the pane on every `↑` inside it — which for prose in a ~34-column card is the
    # normal case, not an edge. Ask the layout's owner instead: `visual_row_target(-1)` returns
    # the position the step would land on, and a step with nowhere to go returns the caret
    # itself (`Wrap.step_caret` breaks at the document top and re-derives the same row). It
    # answers nil only when the pane is not wrapping at all — no width measured yet, or the
    # app-wide preference off — and there the logical line IS the row.
    def notes_at_top? : Bool
      if target = @notes.visual_row_target(-1)
        target == {@notes.cy, @notes.cx}
      else
        @notes_read.cursor.cy <= 0
      end
    end

    # The NOTES read caret sits at the very start of the document — the edge `←` crosses back
    # to RELATED on.
    #
    # DOCUMENT start, not line start. `ReadCursor#move` clamps the column only in its
    # SELECTING branch; a bare `←` takes the branch below it (`read_cursor.cr:138-147`), which
    # WRAPS a column-0 press to the previous line's end. So gating on `cx <= 0` alone stole a
    # real motion on every note with more than one line. The caret is seeded at (0, 0) whenever
    # the pane is entered, so `←` still reads as "back" on arrival; it stops being back exactly
    # once you have navigated into the text, which is when you want the motion instead.
    def notes_at_doc_start? : Bool
      @notes_read.cursor.cy <= 0 && @notes_read.cursor.cx <= 0
    end

    # --- `/` filter bar ------------------------------------------------------
    # Issues are in memory, so filtering is live (no debounce) — each edit
    # re-derives the visible list. Mirrors History's QL-bar editing surface.

    def querying? : Bool
      @querying
    end

    def filtering? : Bool
      !@query.blank?
    end

    # The committed filter string (for tests / external inspection).
    getter query : String

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil # Enter: keep the filter, leave edit mode
      @querying = false
      popup_close
    end

    def cancel_query : Nil # Esc: clear the filter, leave edit mode
      @querying = false
      popup_close
      @query = ""
      @qcx = 0
      @preedit_q = ""
      apply_filter
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
      query_edited
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
      query_edited
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
      sync_popup
    end

    # `QueryBarEdit`'s hook, and the ONE place an edit to this bar settles. It also closes a
    # gap older than the dropdown: `query_edit` (⌃/⌥←→, Home/End, Delete, ⌥⌫) went through
    # `LineEdit.apply` and then the base no-op, so a word-delete on this bar changed the query
    # and never re-derived the list — the results stayed stale until the next plain keystroke.
    def query_edited : Nil
      apply_filter
      sync_popup
    end

    # …and the other half of that gap, in the other direction. `QueryBarEdit#query_edit` fires
    # the hook for EVERY action, so Home, End, ⌥← and ⌥→ — four actions that change no text —
    # re-parsed the query and re-ran the predicate over every issue. A caret move takes the
    # caret-move path, exactly the split `HistoryController` and `SitemapController` write as
    # `schedule_query_reload if LineEdit.mutating?(act)`.
    def query_edit(action : Symbol) : Nil
      @query, @qcx = LineEdit.apply(action, @query, @qcx)
      LineEdit.mutating?(action) ? query_edited : sync_popup
    end

    # --- the opt-in completion dropdown (`↓`) ---------------------------------
    # Same component and contract as History's and Sitemap's; see `SuggestPopup`.

    def popup_open? : Bool
      @popup.open?
    end

    # `↓`: open the dropdown, or move down inside it.
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

    # Field names until a `:` is typed, then that field's values, then the boolean operators
    # no field pool can offer. All of it comes from `Issues::Filter`, which is also what
    # EVALUATES the query — so the bar cannot offer a term its own backend refuses.
    def query_suggestions : Array(String)
      # …then the boolean operators, which no field pool can ever offer: `NOT (` is the only
      # way to exclude a disjunction (`-` negates a TERM, not a GROUP) and it had no discovery
      # at all. Appended HERE and not in the backend — `QuerySuggest` is a TUI module, and a
      # parser must not require the view layer. Same seam `InterceptView` uses.
      QuerySuggest.with_operators(Issues::Filter.suggestions(@query, @qcx, host_pool),
        FilterAst.token_at(@query, @qcx))
    end

    # Distinct hosts for `host:` completion. `@all`, not `@issues`: completing off the
    # FILTERED list would offer only the hosts the half-typed query already matches, so
    # narrowing a filter would shrink its own vocabulary. Memoised because `render_suggestions`
    # runs on the draw path; `reload` is the only thing that moves `@all`, and it clears this.
    private def host_pool : Array(String)
      pool = @host_pool
      return pool if pool
      seen = Set(String).new
      @all.each do |f|
        h = f.host
        seen << h if h && !h.empty?
      end
      @host_pool = seen.to_a.sort!
    end

    # IME composing text for the filter bar (underlined, doesn't touch @query).
    def query_set_preedit(text : String) : Nil
      @preedit_q = text
    end

    # Complete the token under the cursor to the SELECTED candidate (dropdown open) or the
    # first (closed). `close` is ↵'s — see `HistoryView#query_complete` for why ↵ must shut
    # the popup.
    #
    # Splices over `FilterAst::Cursor`'s span rather than a `[/\S*\z/]` trailing run. Three
    # things the old tokenizer could not do: complete a NEGATED or grouped field (`-sev` lexes
    # as one word, so `"severity:".starts_with?("-sev")` was false and nothing was offered),
    # complete a VALUE (it bailed on any `:`), and see the text to the RIGHT of the caret.
    def query_complete(close : Bool = false) : Bool
      sugg = query_suggestions
      pick = @popup.choice(sugg)
      return false unless pick
      cur = FilterAst.token_at(@query, @qcx)
      @query = "#{@query[0, cur.start]}#{pick}#{@query[cur.stop..]}"
      @qcx = cur.start + pick.size
      # Completing consumes the choice: the token is whole now, so the old candidate set is
      # stale. Re-derive it (a field completion opens a value list) and let `set` close the
      # popup if that leaves nothing.
      close ? popup_close : sync_popup
      apply_filter
      true
    end

    def open_detail(store : Store) : Bool
      issue = @issues[@selected]?
      return false unless issue
      @detail = issue
      @detail_flow = issue.flow_id.try { |fid| store.flow_row(fid) }
      reload_detail_links(store)
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links
      @notes_mode = InputMode::Read
      seed_notes(issue.notes)
      true
    end

    # The one place the notes buffer takes stored text on. Every caller is a re-seed from a
    # row that was just read (open, re-read, discard, post-save), so the lost-update baseline
    # and the announce latch move with it — a seed that skipped either would leave the pane
    # either refusing a save that has nothing to lose or accepting one that clobbers a peer.
    private def seed_notes(text : String) : Nil
      @notes.set_text(text)
      @notes_read.sync_from(@notes)
      @notes_base = notes_key(text)
      @notes_peer_seen = nil
    end

    # A stored notes value in the form the BUFFER would hold it. `TextArea#set_text` splits on
    # `\n` and rstrips a segment's trailing `\r` into the eol record, so `#text` hands back LF —
    # while `issues.notes` may carry CRLF from an older TUI write (see `save_notes`). Comparing
    # a raw column against `@notes.text` would then read every such issue as "a peer changed
    # this" on the first tick and refuse a save that had nothing to lose. Mirrors `split_wire`'s
    # rule rather than a blanket `\r` strip: only a segment terminator is a line ending, so a
    # lone `\r` inside a payload pasted into the writeup is content and stays.
    private def notes_key(text : String) : String
      parts = text.split('\n')
      last = parts.size - 1
      parts.each_with_index.map { |p, i| i == last ? p : p.rstrip('\r') }.join('\n')
    end

    # Jump to a specific issue (create-and-link "open" path). Reloads, clears a
    # filter that would hide the id, selects the row, and opens detail.
    def open_by_id(store : Store, id : Int64) : Bool
      reload(store)
      unless @issues.index { |f| f.id == id }
        cancel_query # drop any filter that would hide the freshly created issue
      end
      return false unless idx = @issues.index { |f| f.id == id }
      select_index(idx)
      open_detail(store)
    end

    def close_detail : Nil
      @detail = nil
      @detail_links = [] of Store::EntityLink
      @detail_resolved = [] of Links::Resolved
      @detail_focus = :links
      @notes_mode = InputMode::Read
    end

    def reload_detail_links(store : Store) : Nil
      return unless issue = @detail
      @detail_links = store.list_links(Store::LinkOwnerKind::Issue, issue.id)
      @detail_links = Links.dedupe_issue_flow(@detail_links, issue.flow_id)
      @detail_resolved = Links.resolve_all(store, @detail_links)
      @selected_link = @selected_link.clamp(0, {@detail_resolved.size - 1, 0}.max)
    end

    def move_links(delta : Int32) : Nil
      return if @detail_resolved.empty?
      @selected_link = (@selected_link + delta).clamp(0, @detail_resolved.size - 1)
      ensure_links_visible
    end

    def scroll_links_wheel(delta : Int32) : Nil
      move_links(delta)
    end

    # `@detail_resolved` is the RELATED list the detail pane windows from `@links_scroll`.
    private def ensure_links_visible : Nil
      @links_scroll = Viewport.scroll_to_show(@selected_link, @links_scroll,
        links_visible_rows, @detail_resolved.size)
    end

    def selected_resolved_link : Links::Resolved?
      @detail_resolved[@selected_link]?
    end

    # Max link rows shown in the detail pane (the rest scroll).
    LINKS_VISIBLE = 4

    # Rows the last RELATED frame drew — see `links_visible_rows`.
    @links_last_h = LINKS_VISIBLE

    # The hidden `]`/`[` one-step cycle. Returns whether the write COMMITTED, like the
    # picker path (`Runner#apply_issue_choice`) and `delete_ids` beside it — an
    # `exec_task_ok` false means a cross-process SQLite busy/lock rolled the batch back, and
    # `refresh_detail` then re-reads the OLD row, so the chip silently snaps back to where it
    # was with nothing said. The caller reports it.
    def severity_delta(delta : Int32, store : Store) : Bool
      issue = @detail
      return true unless issue
      level = (issue.severity.value + delta).clamp(0, 4)
      return false unless store.update_issue(issue.id, severity: Store::Severity.new(level))
      refresh_detail(store)
      true
    end

    # ditto for the `}`/`{` triage-status cycle.
    def status_delta(delta : Int32, store : Store) : Bool
      issue = @detail
      return true unless issue
      level = (issue.status.value + delta).clamp(0, 3)
      return false unless store.update_issue(issue.id, status: Store::Status.new(level))
      refresh_detail(store)
      true
    end

    # The issue currently open in the detail view (for title-edit / evidence
    # jumps driven from the Runner).
    def detail_issue : Store::Issue?
      @detail
    end

    # The issue a delete would act on — the open detail, else the list selection — so the
    # Runner can name it in the confirm. Deliberately singular and mark-free: the detail is
    # pinned to ONE issue, and the plural path is target_ids.
    def target_issue : Store::Issue?
      @detail || @issues[@selected]?
    end

    # Re-fetch the open detail + list after an external update (e.g. a title edit
    # committed via the Runner's form overlay).
    def resync(store : Store) : Nil
      refresh_detail(store)
    end

    # --- marks (multi-select) -------------------------------------------------

    def marked?(id : Int64) : Bool
      @marks.includes?(id)
    end

    def mark_count : Int32
      @marks.size
    end

    # Marks the current filter does NOT show (or whose issue a peer deleted). Surfaced next
    # to the count so a set larger than what's on screen is never a surprise.
    def marked_hidden_count : Int32
      return 0 if @marks.empty?
      visible = 0
      @issues.each { |f| visible += 1 if @marks.includes?(f.id) }
      @marks.size - visible
    end

    # How many of `ids` the current filter does NOT show. Computed over the SET BEING ACTED
    # ON rather than the whole mark set, so the number the delete confirm prints always
    # refers to the rows that dialog names — the last thing read before data is destroyed.
    def hidden_count(ids : Enumerable(Int64)) : Int32
      visible = @issues.map(&.id).to_set
      ids.count { |id| !visible.includes?(id) }
    end

    # Marks in DISPLAY order. Unlike History (where flow ids are monotonic with the list
    # order, so sorting ids is enough), issues are ordered by severity DESC, created_at DESC
    # — so the order has to come from the list itself. @all, not @issues: the unfiltered
    # store list is still in display order AND still places marks the active filter hides.
    # An id missing from @all was deleted by a peer session; dropping it here is the same
    # "a stale mark simply fails to resolve" rule the batch handlers follow.
    # The rows `y` copies from the LIST: the marks if any, else the cursor row — each as
    # `[severity] title (host)`, one per line.
    def copy_rows_text : String
      rows = @marks.empty? ? [@issues[@selected]?].compact : @all.select { |f| @marks.includes?(f.id) }
      rows.map { |f| "[#{f.severity.label}] #{f.title}#{f.host ? " (#{f.host})" : ""}" }.join("\n")
    end

    def marked_ids : Array(Int64)
      return [] of Int64 if @marks.empty?
      @all.compact_map { |f| f.id if @marks.includes?(f.id) }
    end

    # The effective target set every batch verb acts on: the marks if any are set, else the
    # cursor row. One rule, so a verb needs no notion of "batch mode".
    def target_ids : Array(Int64)
      return marked_ids unless @marks.empty?
      [selected_id].compact
    end

    # The ONE issue a batch verb treats as privileged when it needs a single representative —
    # the severity/status picker's pre-selected value. NOT `target_ids.first`: that follows
    # the severity sort, so re-triaging one issue would flip which of the marks seeds the
    # picker. The cursor row wins when it is itself a target (it is the issue you were
    # looking at); otherwise the oldest, which is stable under every sort and filter.
    def primary_target_id : Int64?
      ids = target_ids
      return nil if ids.empty?
      cur = selected_id
      return cur if cur && ids.includes?(cur)
      ids.min
    end

    # `t` — flip the cursor row's mark, then step DOWN, so a run of `t` marks consecutive
    # rows. Plain +1 (History conditionalises this on its list order only because `follow`
    # parks its cursor at the clamp end; Issues has one fixed sort and no tail). The anchor
    # lands on the row just toggled, so `t` then ⇧↓ extends from it.
    def toggle_mark : Nil
      return unless id = selected_id
      @marks.includes?(id) ? @marks.delete(id) : @marks.add(id)
      step_cursor(1)
      @mark_anchor = id
      @mark_extent.clear
    end

    # ⇧T — mark every issue the CURRENT filter shows, unioned with what's already marked (so
    # narrowing the filter twice accumulates rather than replaces).
    def mark_all : Nil
      @issues.each { |f| @marks.add(f.id) }
      @mark_anchor = selected_id
      @mark_extent.clear
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
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead of
    # being left behind. Only the gesture's own ids go (@mark_extent): `t`/⇧T marks are
    # deliberate tags, and dropping those too would put a discontiguous set out of reach
    # ("mark this one, skip three, mark that one"). Returns how many marks it gave back, so
    # the caller can say so rather than let a range vanish silently.
    def end_mark_gesture : Int32
      before = @marks.size
      @mark_extent.each { |id| @marks.delete(id) }
      reset_mark_anchor
      before - @marks.size
    end

    # Drop specific marks — the post-batch-delete prune, so a deleted issue's id can't linger
    # in the set and inflate the next count.
    def unmark_ids(ids : Enumerable(Int64)) : Nil
      ids.each { |id| @marks.delete(id); @mark_extent.delete(id) }
      reset_mark_anchor if (a = @mark_anchor) && !@marks.includes?(a) && index_of(a).nil?
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. The anchor is re-seeded from the cursor when it's unset or off-window (a
    # plain move/click clears it), so the first ⇧arrow always starts from where you are.
    def extend_marks(delta : Int32) : Nil
      return if @issues.empty?
      anchor_idx = @mark_anchor.try { |a| index_of(a) }
      unless anchor_idx
        @mark_anchor = selected_id
        anchor_idx = @selected
        @mark_extent.clear
      end
      step_cursor(delta)
      lo, hi = {anchor_idx, @selected}.minmax
      wanted = Set(Int64).new
      (lo..hi).each { |i| @issues[i]?.try { |f| wanted.add(f.id) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three, while a `t`/⇧T mark the range swept
      # over and back off survives.
      (@mark_extent - wanted).each { |id| @marks.delete(id) }
      added = wanted - @marks
      @marks.concat(added)
      @mark_extent = (@mark_extent & wanted) | added
    end

    # Cursor step used by the mark gestures. Deliberately NOT `move` (which redirects to
    # scroll_preview when the preview pane is focused) and NOT the controller's issues_move
    # (which pops focus to the tab bar at the top row — that would eject you mid-range-
    # selection). Clamps, so it saturates at both ends instead of wrapping.
    private def step_cursor(delta : Int32) : Nil
      return if @issues.empty?
      @selected = (@selected + delta).clamp(0, @issues.size - 1)
      @preview_scroll = 0
    end

    # Row index of an id in the VISIBLE list (nil when the filter hides it, or it's gone).
    # A linear scan, like apply_filter's own re-anchor: the severity sort gives no key to
    # binary-search on.
    private def index_of(id : Int64) : Int32?
      @issues.index { |f| f.id == id }
    end

    # Short "SEV title" label for confirm dialogs; falls back to "issue #id".
    def issue_summary(id : Int64) : String
      if f = @all.find { |i| i.id == id }
        return "#{severity_badge(f.severity)} #{f.title}"
      end
      "issue ##{id}"
    end

    # Batch delete: one store round-trip for N issues, then the same re-anchoring the
    # singular path did. Closes the detail when it was showing one of them and prunes the
    # deleted ids from the mark set so a stale mark can't inflate the next count.
    #
    # Returns whether the write committed. On a rollback NOTHING local is touched — the marks
    # in particular stay put, because they are the only remaining handle on the set the user
    # asked to delete.
    def delete_ids(store : Store, ids : Array(Int64)) : Bool
      return true if ids.empty?
      return false unless store.delete_issues(ids)
      close_detail if @detail.try(&.id).try { |d| ids.includes?(d) }
      unmark_ids(ids)
      reload(store)
      true
    end

    # ⇧X: every issue in the project, past the controller's confirm. Returns whether the write
    # committed — on a rollback NOTHING local is touched, the same contract `delete_ids` keeps,
    # so a busy project leaves the list (and its marks) exactly as they were to retry.
    #
    # `clear_marks`, not `unmark_ids`: there is no surviving row for a mark to point at, and
    # the anchor has to go with them or the next ⇧arrow would sweep from a stale one.
    def clear(store : Store) : Bool
      return false unless store.clear_issues
      close_detail
      clear_marks
      reload(store)
      true
    end

    # --- notes READ/INS (inline editor) ---
    def start_notes_edit : Nil
      enter_notes_insert!
    end

    def enter_notes_insert! : Nil
      return unless issue = @detail
      @detail_focus = :notes
      if @notes_mode == InputMode::Read && !notes_dirty?
        # Re-seeding HERE is what closes `open_detail`'s window: that one seeds from the LIST
        # row, which the tick re-anchors but does not re-read per issue, so the baseline an
        # edit is measured against has to be taken from the row this detail is holding now.
        #
        # Skipped over unsaved text. The NOR/INS chip exits INS without saving, so re-entry is
        # the ordinary way back into an edit in progress — and a re-seed there would hand the
        # operator the STORED notes with their own paragraph gone and nothing said. (`^W` is
        # the discard, and it re-seeds unconditionally.)
        seed_notes(issue.notes)
      end
      @notes_mode = InputMode::Insert
      @notes_read.sync_from(@notes)
    end

    def exit_notes_insert! : Nil
      @notes_mode = InputMode::Read
      # Carry an INS ⇧arrow selection over to READ — see TextReadState#adopt_editor_selection.
      @notes_read.adopt_editor_selection(@notes)
    end

    def notes_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if notes_insert_mode?
      @notes_read.move(@notes, dr, dc, selecting: selecting)
    end

    def notes_scroll_wheel(step : Int32) : Nil
      @notes.scroll_view(step)
    end

    # One selection model per mode — see NotesView#selection? / RepeaterView#pane_selection?.
    # This pair changes together: claiming a selection while copy still read `@notes_read`
    # would offer "Copy selection" and then copy the caret line.
    def notes_copy_text : String
      if notes_insert_mode?
        @notes.selection_text || @notes_read.copy_text(@notes)
      else
        @notes_read.copy_text(@notes)
      end
    end

    def notes_copy_all : String
      @notes_read.copy_all(@notes)
    end

    def notes_selection? : Bool
      return false unless notes_focused?
      notes_insert_mode? ? @notes.selection? : @notes_read.selection?
    end

    def notes_select_line : Nil
      return if notes_insert_mode?
      @detail_focus = :notes
      @notes_read.select_line(@notes)
    end

    def notes_clear_selection : Nil
      @notes_read.clear_selection
    end

    def notes_undo : Nil
      @notes.undo if notes_insert_mode?
    end

    def notes_insert(ch : Char) : Nil
      @notes.insert(ch) if notes_insert_mode?
    end

    # Characters the last `notes_insert` replaced — see TextArea#last_replaced.
    def notes_last_replaced : Int32
      @notes.last_replaced
    end

    def notes_newline : Nil
      @notes.insert_newline if notes_insert_mode?
    end

    def notes_backspace : Nil
      @notes.backspace if notes_insert_mode?
    end

    def notes_move(dr : Int32, dc : Int32) : Nil
      @notes.move(dr, dc) if notes_insert_mode?
    end

    # INSERT-mode motion: the shared editor keymap (⇧arrows select, Page keys, ⌥←/→ by word,
    # ⌥⌫ deletes one) — see `TextArea#handle_motion_key`.
    def notes_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless notes_insert_mode?
      @notes.handle_motion_key(ev)
    end

    # READ-mode Home/End/Page. Home/End move the EDITOR caret, so they are mirrored back onto
    # the read cursor this mode paints.
    def notes_read_motion_key(ev : Termisu::Event::Key) : Bool
      return false if notes_insert_mode?
      key = ev.key
      shift = ev.shift?
      case
      when key.home?      then @notes.home(shift)
      when key.end?       then @notes.end_of_line(shift)
      when key.page_up?   then notes_read_move(-@notes.page_rows, 0, selecting: shift)
      when key.page_down? then notes_read_move(@notes.page_rows, 0, selecting: shift)
      else                     return false
      end
      @notes_read.sync_to(@notes, selecting: shift) if key.home? || key.end?
      true
    end

    def notes_word_delete_key?(ev : Termisu::Event::Key) : Bool
      @notes.word_delete_key?(ev)
    end

    # Mouse DRAG / DOUBLE-CLICK over the notes pane. The click already forced INSERT (see
    # `notes_click_to_cursor`), so both work on the editor's own selection.
    def notes_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless notes_insert_mode?
      notes_rect = notes_body_rect(rect)
      return if notes_rect.empty?
      @notes.click_to_cursor(notes_rect, mx, my, selecting: true)
    end

    def notes_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      notes_rect = notes_body_rect(rect)
      return false if notes_rect.empty?
      @detail_focus = :notes
      enter_notes_insert!
      @notes.select_word_at(notes_rect, mx, my)
    end

    # Live IME composing text for the notes editor (delegates to the TextArea).
    def set_preedit(text : String) : Nil
      @notes.set_preedit(text) if notes_insert_mode?
    end

    def save_notes(store : Store) : Bool
      return true unless issue = @detail
      # `#text`, not `#to_bytes`. `to_bytes` joins with CRLF because it exists for WIRE text;
      # this is prose in a DB column, and the CRLF made `issues.notes` mean two different
      # things depending on the writer — the TUI stored `a\r\nb` while MCP `update_issue` and
      # `gori run issues` store the caller's LF string verbatim, so `get_issue` and the export
      # hand an agent one or the other. The TUI hid it from itself because `set_text` rstrips
      # `\r` on load. `NotesView` uses `#text` throughout for exactly this reason.
      #
      # Returns whether the write COMMITTED. On a rollback NOTHING local moves: the buffer
      # keeps the typed text and the pane stays in INS. That is not cosmetic — every step
      # below is destructive to the edit. `refresh_detail` re-reads the row and (once INS is
      # off) `set_text`s the notes buffer back to the STORED text, so swallowing the false
      # made a busy project silently throw away the operator's writeup and show them the old
      # one, with no toast and nothing left to retry from. Leaving INS on is what keeps the
      # text on screen and a second `esc` a real retry. Same correction `NotesView#save` and
      # `ProjectView#save` already carry.
      return false unless store.update_issue(issue.id, notes: @notes.text)
      exit_notes_insert!
      # refresh_detail already re-syncs @notes from the re-fetched @detail (now that
      # notes-insert mode is off), and it nil-guards a peer-deleted issue — so no
      # separate (unsafe) set_text here.
      refresh_detail(store)
      true
    end

    # Leave the notes editor WITHOUT persisting (^W) — discards the in-buffer
    # edits; the next edit re-seeds from the stored notes (enter_notes_insert!).
    def cancel_notes_edit : Nil
      return unless issue = @detail
      seed_notes(issue.notes)
      exit_notes_insert!
      @notes_read.sync_from(@notes)
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      if @detail
        render_detail(screen, rect, focused)
      else
        list_rect, preview_rect = list_split(rect)
        # No preview pane at this size (or after a resize down) ⇒ snap focus back to the list,
        # or move()/scroll would route arrows to an invisible pane and freeze list navigation.
        # IssuesController#preview_scroll_focused? gates on the PREF alone, so the geometry has
        # no other place to be heard (mirrors ProbeView#render).
        @preview_focus = :list if preview_rect.nil?
        render_list(screen, list_rect, focused && @preview_focus == :list)
        render_preview_pane(screen, preview_rect, focused) if preview_rect
        # LAST: the dropdown is the only thing allowed to occlude the list, so it has to be
        # painted over both panes rather than inside `render_list`.
        render_query_popup(screen, list_rect)
      end
    end

    @list_last_h = 0 # rows the last list frame drew — the PgUp/PgDn step (list_page_rows)

    # One screenful of the list, for PgUp/PgDn: the rows the last frame drew minus two of
    # overlap (the History convention).
    def list_page_rows : Int32
      {@list_last_h - 2, 1}.max
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      render_filter_bar(screen, rect)
      # The suggestion row exists only while the bar is being edited, so the column header
      # and everything under it shift down by one for exactly that state. `list_top` is the
      # inverse and the hit-tests read it.
      hdr_y = rect.y + 1
      if @querying
        render_suggestions(screen, rect, hdr_y)
        hdr_y += 1
      end
      # Bounds-guarded like Probe's twin: `Screen#text` clips to the SCREEN, not to this pane,
      # so on a one-row interior the header used to paint over the shell's key hints. The
      # divider clamps itself (see `Frame.inner_divider`); this row did not.
      # Contract: `spec/tui/contract_render_bounds_spec.cr`.
      if hdr_y < rect.bottom
        screen.text(rect.x + 1, hdr_y, "SEV", Theme.muted)
        screen.text(rect.x + 6, hdr_y, "ST", Theme.muted)
        screen.text(rect.x + 11, hdr_y, "TITLE", Theme.muted)
      end
      Frame.inner_divider(screen, rect, hdr_y + 1, border: Frame.pane_border(focused))
      top = list_top(rect)
      list_h = {rect.bottom - top, 0}.max
      @list_last_h = list_h

      if @issues.empty?
        render_empty_list(screen, rect, top)
        return
      end

      ensure_visible(list_h)
      title_x = rect.x + 11
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @issues.size
        f = @issues[idx]
        y = top + i
        selected = idx == @selected
        # A marked row reads as a dim band with a FULLER gutter bar, so it stays
        # distinguishable from the cursor row (which keeps the accent band) and from a cursor
        # row that is ALSO marked (accent band + full bar). Both glyphs are single-width, so
        # no column offset moves — the `top` math and list_row_at stay valid.
        marked = @marks.includes?(f.id)
        bg = row_bg(selected, marked, focused)
        if selected || marked
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, marked ? '▌' : '▎', Theme.accent, bg)
        end
        screen.text(rect.x + 1, y, severity_badge(f.severity), severity_color(f.severity), bg, Attribute::Bold)
        screen.text(rect.x + 6, y, status_tag(f.status), status_color(f.status), bg)
        # Right-aligned host; the title fills the gap up to it (ellipsized).
        # Both the alignment origin AND the title budget must be measured in COLUMNS, not
        # characters: this is the flow's raw wire `Host` and nothing on the path applies
        # punycode/IDNA, so `日本語.test` (8 chars / 11 columns) would start 3 columns too far
        # right — over the card's border — and hand the title 3 columns it doesn't have,
        # sliding it underneath the host so the two garble each other.
        #
        # The host is CAPPED at the columns left of the title, not just measured. `Screen#text`
        # clips to the SCREEN, not to this pane, so a host longer than the row simply started
        # left of `title_x` and painted straight over the status tag and the severity badge —
        # at 40 columns this row's `▎CRIT open` was gone entirely. The title is drawn last with
        # its width floored at 0, so it never repaints those cells and the damage stays. Cap,
        # then ellipsize: an ellipsized host still tells you which host, a missing badge does
        # not tell you anything. (Pre-existing; the score below inherited the same trap.)
        right = rect.right - 1
        if (host = f.host) && !host.empty?
          hw = {Screen.display_width(host), {rect.right - 1 - title_x, 0}.max}.min
          if hw > 0
            screen.text(rect.right - hw - 1, y, ellipsize(host, hw), Theme.muted, bg, width: hw)
            right = rect.right - hw - 2
          end
        end
        # The score reads as a severity, so it wears the severity's colour — the SEV badge on
        # the left and this number are the same claim, and a fixed accent made them look like
        # two unrelated facts.
        #
        # Gated on clearing `title_x`, because `Screen#text` clips to the SCREEN, not to this
        # pane: on a narrow list a long host walks `right` left past the title column, and an
        # ungated draw then paints the score ON the status tag and the severity badge. The
        # title is drawn afterwards with `tw` floored at 0, so it never repaints those cells
        # and the damage stays. Dropping the score is the right loss — the SEV badge already
        # carries the same claim.
        if (score = f.cvss_score) && right - (sc_w = sprintf("%.1f", score).size) >= title_x
          screen.text(right - sc_w, y, sprintf("%.1f", score), severity_color(f.severity), bg, width: sc_w)
          right = right - sc_w - 2
        end
        title_fg = selected || marked ? Theme.text_bright : Theme.text
        tw = {right - title_x, 0}.max
        screen.text(title_x, y, ellipsize(f.title, tw), title_fg, bg, width: tw)
      end
      # `ensure_visible`'s own comment already named what was missing here: without a gauge,
      # 44 results silently read as the 3 that happen to be under the window.
      Frame.scroll_gauge(screen, Rect.new(rect.x, top, rect.w, list_h),
        @issues.size, @scroll, focused)
    end

    # The cursor row keeps the accent band; a marked row gets the dim one; a row that is both
    # keeps the accent band (and is told apart by its fuller gutter bar).
    private def row_bg(selected : Bool, marked : Bool, focused : Bool) : Color
      return focused ? Theme.accent_bg : Theme.selection_dim if selected
      marked ? Theme.selection_dim : Theme.bg
    end

    # Nothing to list: the standing empty state when no filter is on, else a no-match line
    # that names the way out (esc while the bar is open, `/` once it isn't).
    private def render_empty_list(screen : Screen, rect : Rect, top : Int32) : Nil
      unless filtering?
        list_rect = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
        TrafficEmptyState.render(screen, list_rect, variant: :issues)
        return
      end
      # `Screen#text` clips to the SCREEN, not to this pane, so this line owes both bounds
      # itself. The row guard is what the suggestion row's +1 shift made load-bearing: at
      # h = 10 or 11 with the bar open, `top` lands past the pane and the message painted over
      # the shell's key hints. The width has been missing since the message was written — 38
      # chars overran a 36-column interior at every height.
      return if top >= rect.bottom
      hint = querying? ? "esc clears the filter" : "/ to edit the filter"
      screen.text(rect.x + 1, top, "no issues match · #{hint}", Theme.muted,
        width: {rect.w - 2, 0}.max)
    end

    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      f = @issues[@selected]?
      unless f
        screen.text(rect.x + 1, rect.y + 1, "preview — select an issue", Theme.muted,
          width: {rect.w - 2, 0}.max)
        return
      end
      active = focused && @preview_focus == :preview
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      screen.fill(body, Theme.selection_dim) if active
      bg = active ? Theme.selection_dim : Theme.bg
      lines = issues_preview_lines(f)
      # Write the clamp back (as Probe's twin does) so overscrolling a short preview can't
      # inflate @preview_scroll and leave later scroll-up presses dead until it drains back.
      @preview_scroll = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      sc = @preview_scroll
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
      Frame.scroll_gauge(screen, body, lines.size, sc, false, bg)
    end

    private def issues_preview_lines(f : Store::Issue) : Array({Color, String})
      lines = [] of {Color, String}
      lines << {Theme.text_bright, "#{severity_badge(f.severity)}  #{f.title}"}
      host = f.host.try(&.presence) || "—"
      lines << {Theme.muted, "#{host}  ·  #{f.status.label}  ·  ##{f.id}"}
      # ONE cvss line: the score is the reading and the vector behind it is the provenance,
      # so they belong on the same row rather than as a summary chip plus a repeat of the
      # string two lines apart.
      if cvss = f.cvss
        score = f.cvss_score
        lines << {Theme.muted, score ? "cvss      #{sprintf("%.1f", score)}  ·  #{cvss}" : "cvss      #{cvss}"}
      end
      if fid = f.flow_id
        lines << {Theme.muted, "evidence  flow ##{fid}"}
      else
        lines << {Theme.muted, "evidence  (none — standalone issue)"}
      end
      notes = f.notes.strip
      if notes.empty?
        lines << {Theme.muted, "notes  (empty)"}
      else
        lines << {Theme.accent, "NOTES"}
        notes.split('\n').first(12).each { |ln| lines << {Theme.text, ln} }
        more = notes.split('\n').size - 12
        lines << {Theme.muted, "… +#{more} more lines"} if more > 0
      end
      lines
    end

    # The `/` filter bar on the list's top row: while editing, `filter › <input>`;
    # otherwise the applied query (+ a match count) or a usage hint.
    private def render_filter_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        screen.text(rect.x + 1, rect.y, QUERY_PREFIX, Theme.accent)
        base = rect.x + 1 + QUERY_PREFIX.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - QUERY_PREFIX.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD,
            known: QUERY_KNOWN))
        return
      end
      # One right-anchored chain — see HistoryView#render_ql_bar.
      chips = [] of {String, Color}
      chips << {@issues.size.to_s, Theme.muted} if filtering?
      chips << {mark_chip_text.not_nil!, Theme.accent} if mark_chip_text
      rx = Frame.right_text_chain(screen, rect.right - 1, rect.y, rect.x + 2, chips)
      left_w = {rx - (rect.x + 1), 0}.max
      if filtering?
        # The committed query stays highlighted — this readout is what you scan to
        # check how the active filter is actually being read.
        qx = screen.text(rect.x + 1, rect.y, ": ", Theme.muted, width: left_w)
        screen.styled_text(qx, rect.y, @query,
          Highlight.filter_query(@query, Theme.text, FilterAst::SEPS_FIELD, known: QUERY_KNOWN),
          Theme.text, width: {rect.x + 1 + left_w - qx, 0}.max)
      else
        screen.text(rect.x + 1, rect.y, FILTER_HINT, Theme.muted, width: left_w)
      end
    end

    # The completion row under the bar: what ↹ would take, what it MEANS, and what else is on
    # offer — else the standing hint at a cold start. `Issues::Filter::FIELD_HELP_PROC`, never
    # the default: `QuerySuggest`'s fallback is `QL::FIELD_HELP`, which would describe this
    # bar's triage-state `status:` as an HTTP code.
    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      # This row owes its own vertical bound, like the column header below it: `Screen#text`
      # clips to the SCREEN, not to this pane, and a 40x9 terminal (`Layout.usable?`'s floor
      # plus a row) leaves this list a one-row interior — the `↹ …` row landed on the shell's
      # key-hint line. Contract: `spec/tui/contract_render_bounds_spec.cr`.
      return if y >= rect.bottom
      w = {rect.w - 2, 0}.max
      sugg = query_suggestions
      unless sugg.empty?
        QuerySuggest.render(screen, rect.x + 1, y, w, sugg, Issues::Filter::FIELD_HELP_PROC)
        return
      end
      # Nothing to complete. At a cold start (nothing typed, or the caret just past a space)
      # show the standing hint so the grammar is discoverable from the moment `/` opens; on a
      # non-empty token that matches nothing stay quiet — the operator is free-texting a word.
      return unless QuerySuggest.hint_slot?(FilterAst.token_at(@query, @qcx).core)
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: w)
    end

    # Anchored under the suggestion row and bounded by the list, which is the only region it
    # may occlude. Anchored at the START of the query text, not at the token's offset within
    # it: `Screen#input_line` scrolls its window once the query outgrows the bar, so
    # `base + token.start` stops being the token's screen column on exactly the long queries
    # where precision would matter.
    private def render_query_popup(screen : Screen, rect : Rect) : Nil
      return unless @querying && @popup.open?
      top = list_top(rect)
      bounds = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
      @popup.render(screen, rect.x + 1 + QUERY_PREFIX.size, top - 1, bounds,
        Issues::Filter::FIELD_HELP_PROC)
    end

    # Mark count, drawn right-to-left ending just left of `right_x`; returns the new left
    # edge of the chip cluster. Always shown while any mark is set — marks survive a tab
    # switch, so this chip is what keeps the set from being invisible when you come back. The
    # hidden split covers marks the current filter doesn't show, so the count never silently
    # exceeds what's on screen.
    # The mark chip's TEXT, or nil when nothing is marked — see HistoryView#mark_chip_text.
    private def mark_chip_text : String?
      return nil if @marks.empty?
      hidden = marked_hidden_count
      hidden > 0 ? "#{@marks.size} marked ·#{hidden} hidden" : "#{@marks.size} marked"
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      issue = @detail.not_nil!
      # Back-to-list affordance on the top border (←/esc → the issue list).
      Frame.list_back_hint(screen, rect)
      w = {rect.w - 2, 0}.max

      # y0 — title row: a severity-coloured bullet + the bright title; #id at the right.
      id_label = "##{issue.id}"
      screen.text(rect.right - id_label.size - 1, rect.y, id_label, Theme.muted)
      screen.cell(rect.x + 1, rect.y, '●', severity_color(issue.severity))
      title_w = {(rect.right - id_label.size - 2) - (rect.x + 3), 0}.max
      screen.text(rect.x + 3, rect.y, issue.title, Theme.text_bright, width: title_w, attr: Attribute::Bold)

      # y1 — chips: a filled severity chip + a status chip.
      cx = rect.x + 1
      cx = Frame.tag_chip(screen, cx, rect.y + 1, " #{severity_badge(issue.severity)} ", severity_color(issue.severity))
      cx = Frame.tag_chip(screen, cx + 1, rect.y + 1, " #{issue.status.label} ", status_color(issue.status))
      # The cvss chip is the ONE chip whose width is unbounded — a v4.0 vector is 60-odd
      # columns — and `Frame.tag_chip` clips to the SCREEN, not to this pane. So the vector
      # half is appended only when it fits: the score alone still reads, and a chip that ran
      # off the panel would paint over the border.
      if cvss = issue.cvss
        room = {rect.right - 1 - (cx + 1), 0}.max
        chip = if score = issue.cvss_score
                 long = " CVSS #{sprintf("%.1f", score)} · #{cvss} "
                 Screen.draw_width(long) <= room ? long : " CVSS #{sprintf("%.1f", score)} "
               else
                 " CVSS #{cvss} "
               end
        Frame.tag_chip(screen, cx + 1, rect.y + 1, chip, severity_color(issue.severity)) if Screen.draw_width(chip) <= room
      end

      # y2 — timestamps.
      meta = "created #{fmt_ts(issue.created_at)}"
      meta += " · edited #{fmt_ts(issue.updated_at)}" if issue.updated_at > issue.created_at
      # The vector itself rides the chip row above, not this one — a timestamp line is where
      # you look for WHEN, and a third copy of the same string is not a third fact.
      screen.text(rect.x + 1, rect.y + 2, meta, Theme.muted, width: w)

      # y3 — primary linked-flow evidence.
      evidence = if flow = @detail_flow
                   "evidence  #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
                 elsif fid = issue.flow_id
                   "evidence  flow ##{fid} (no longer captured)"
                 else
                   "evidence  (none — standalone issue)"
                 end
      screen.text(rect.x + 1, rect.y + 3, evidence, Theme.muted, width: w)

      # y4+ — RELATED and NOTES, two CLOSED sibling cards.
      #
      # RELATED used to be an OPEN region — an `inner_divider`, a text heading, then the link
      # rows — with the closed NOTES card directly beneath it, and an open-ended block above a
      # closed one reads as containment: NOTES looked like it lived INSIDE RELATED.
      #
      # Worse, nothing in that region varied with `@detail_focus`. The divider and gauge took
      # the pane-level `focused`, the row band took the selected INDEX, and the heading was
      # unconditional — so `esc` out of NOTES moved focus somewhere with no signal at all, and
      # on an issue with no links (the shape `n` creates) there was not even a band to notice.
      # One `Frame.card` whose border reads `@detail_focus` answers both.
      rel_card, notes_card = detail_split(rect)
      render_related_card(screen, rel_card, focused && @detail_focus == :links)
      render_notes_card(screen, notes_card, focused)
    end

    # The RELATED card. Costs exactly the six rows the divider + heading + `LINKS_VISIBLE`
    # rows used to: the heading rides the top border, so closing the card is free.
    private def render_related_card(screen : Screen, card : Rect, active : Bool) : Nil
      return if card.h < 2 || card.w < 2
      Frame.card(screen, card, "RELATED", bg: Theme.bg, border: Frame.pane_border(active))
      # The count and the `space l` affordance share the RIGHT-ALIGNED meta slot instead of
      # riding the title. Two rules meet here, both `shared_chrome_spec`'s: a hand-placed
      # `rect.right - hint.size - 1` string is forbidden (`Frame.border_meta` is the slot), and
      # so is a count inside a card title — it makes the title's width a moving target, which
      # is what a badge's `min_x` is derived from. The hint half drops while INS owns the
      # keyboard, exactly as the old inline hint did; the count never does.
      n = @detail_resolved.size
      Frame.border_meta(screen, card, "RELATED", notes_insert_mode? ? n.to_s : "#{n} · space l")
      body = card.inset(1, 1)
      # The scroll window the NEXT `move_links` measures against — the `@list_last_h`
      # convention. It has to be the rows this card ACTUALLY drew, not `LINKS_VISIBLE`: a
      # short pane clamps the card (see `detail_split`), and a viewport wider than the card
      # would scroll the selection to a row nothing paints.
      @links_last_h = {body.h, 0}.max
      return if body.empty?
      @links_scroll = Viewport.clamp_scroll(@links_scroll, body.h, @detail_resolved.size)
      if @detail_resolved.empty?
        screen.text(body.x, body.y, "(none — space l to link History/Repeater/…)",
          Theme.muted, width: body.w)
        return
      end
      (0...body.h).each do |i|
        idx = @links_scroll + i
        break if idx >= @detail_resolved.size
        res = @detail_resolved[idx]
        y = body.y + i
        sel = idx == @selected_link
        fg = res.stale? ? Theme.muted : (sel ? Theme.text_bright : Theme.text)
        # Dim band when the pane is not focused, accent when it is — `render_list`'s own
        # `row_bg` rule. The cursor row used to keep the accent band in both states, which
        # is the other half of why a focus move in and out of this pane was invisible.
        bg = sel ? (active ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(body.x, y, body.w, 1), bg) if sel
        screen.cell(body.x, y, sel ? '▎' : ' ', Theme.accent, bg)
        screen.text(body.x + 1, y, res.line, fg, bg, width: {body.w - 1, 1}.max)
      end
      Frame.scroll_gauge(screen, body, @detail_resolved.size, @links_scroll, active)
    end

    # NOTES — a real Frame.card (like Decoder INPUT) so INS/READ borders are rounded
    # and the editor body is inset, never colliding with the outline.
    private def render_notes_card(screen : Screen, card : Rect, focused : Bool) : Nil
      return if card.h < 2
      notes_active = focused && notes_focused?
      ins = focused && notes_insert_mode?
      Frame.card(screen, card, "NOTES", bg: Theme.bg, border: Frame.pane_border(notes_active || ins))
      # The REAL mode, always drawn — `Frame.mode_badge`'s contract, and this call broke it
      # in the worst of the three possible ways. In insert-but-unfocused neither branch below
      # ran, so NOTHING was painted on the border while `issues_controller` went on hit-testing
      # the bare `notes_insert_mode?`: five blank cells that toggled insert when clicked. The
      # `elsif` was a third geometry on top of that — a 3-cell ` ↵ ` the hit-test never knew
      # about. `mode_badge` already draws its READ label muted on the canvas, which is the
      # same quiet ↵ cue that branch existed to provide.
      Frame.mode_badge(screen, card.right - 1, card.y, card.x + 7, notes_insert_mode?)
      body = card.inset(1, 1)
      return if body.empty?
      @notes.render(screen, body, cursor: ins, gauge: true, gauge_focused: notes_active)
      paint_notes_read_chrome(screen, body, notes_active && !notes_insert_mode?)
    end

    # Rows the detail's meta block owns before the two cards: title, chips, timestamps,
    # evidence.
    DETAIL_HEAD_ROWS = 4

    # The RELATED and NOTES rects for a detail interior — ONE derivation, so `render_detail`
    # and the four hit-tests in `IssuesController` (the NOR/INS chip, click-to-cursor, drag,
    # double-click) can never disagree about which row a click landed on. `render_detail` and
    # `notes_card_rect` used to derive the same arithmetic independently, with the controller
    # reading only the second: move one and not the other and clicks land on the wrong rows
    # with nothing raising.
    #
    # RELATED asks for `LINKS_VISIBLE` rows plus its own frame, which is exactly the six the
    # divider + heading + rows cost before — so this is row-budget neutral and NOTES keeps
    # the height it had.
    #
    # CLAMPED, not merely floored. `Frame.card` needs two rows for its own frame and the
    # container may grant fewer than the meta block plus both cards want (a 40x9 terminal is
    # inside `Layout.usable?`). RELATED gives its rows up first — NOTES is the pane you read
    # and type in — and both rects stay inside `rect`, which every view owes
    # `pane_overspill_spec`.
    def detail_split(rect : Rect) : {Rect, Rect}
      top = rect.y + DETAIL_HEAD_ROWS
      avail = {rect.bottom - top, 0}.max
      # Leave NOTES a frame plus one text row wherever the height allows one at all.
      rel_h = {LINKS_VISIBLE + 2, {avail - 3, 0}.max}.min
      # …and never keep a row RELATED cannot draw with. `Frame.card` needs two rows for its
      # own frame, so a granted `h == 1` paints nothing at all — it just costs NOTES the row.
      rel_h = 0 if rel_h < 2
      notes_top = top + rel_h
      {Rect.new(rect.x, top, rect.w, rel_h),
       Rect.new(rect.x, notes_top, rect.w, {rect.bottom - notes_top, 0}.max)}
    end

    # Outer NOTES card geometry (full width of the detail pane, under RELATED).
    def notes_card_rect(rect : Rect) : Rect
      detail_split(rect)[1]
    end

    # Interior of the NOTES card (where TextArea draws) — matches Frame.card inset.
    def notes_body_rect(rect : Rect) : Rect
      notes_card_rect(rect).inset(1, 1)
    end

    # Outer RELATED card geometry (full width of the detail pane, over NOTES) — the twin of
    # `notes_card_rect`, read off the same `detail_split` so the four RELATED hit-tests below
    # can never disagree with `render_related_card` about which row a click landed on.
    def links_card_rect(rect : Rect) : Rect
      detail_split(rect)[0]
    end

    # Interior of the RELATED card (where the link rows draw) — matches Frame.card's inset.
    # `Rect#inset` clamps at zero, so a card too short to draw one answers an empty rect and
    # every caller below refuses on `empty?`.
    def links_body_rect(rect : Rect) : Rect
      links_card_rect(rect).inset(1, 1)
    end

    # Inverts `render_related_card`'s row layout: maps a click to a link index, or nil past
    # the last populated row / outside the card. `list_row_at`'s twin, windowed from
    # `@links_scroll` the same way the draw loop is.
    def links_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      body = links_body_rect(rect)
      return nil if body.empty?
      return nil if mx < body.x || mx >= body.right
      i = my - body.y
      return nil if i < 0 || i >= body.h
      idx = @links_scroll + i
      idx < @detail_resolved.size ? idx : nil
    end

    # The row a click on the RELATED scroll gauge asks for. The gauge rides the card's right
    # border column — one OUTSIDE `links_body_rect`, which is why `links_row_at` cannot answer
    # it — and `@links_scroll` is DERIVED from the selection by `ensure_links_visible`, so the
    # answer is a selection and not an offset (see `gauge_row_at`).
    def links_gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      body = links_body_rect(rect)
      return nil if body.empty?
      Frame.scroll_gauge_row(body, @detail_resolved.size, mx, my)
    end

    # Put the RELATED cursor on `idx` (clamped) and scroll it into view — the pointer's
    # `move_links`, which is relative and cannot express "this row".
    def select_link(idx : Int32) : Nil
      return if @detail_resolved.empty?
      @selected_link = idx.clamp(0, @detail_resolved.size - 1)
      ensure_links_visible
    end

    # The shared over-paint — see `TextReadState#paint_chrome`. This pane's own copy also
    # skipped the `sync_from` its four siblings carry, so an MCP `update_issue` shrinking the
    # notes under a stale read cursor could index off the end of the buffer mid-render.
    private def paint_notes_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      @notes_read.paint_chrome(screen, rect, @notes, active)
    end

    # A filled "chip": ` LABEL ` painted with `color` as the background. Returns the
    # x just past it so chips lay out left-to-right.
    # The buffer holds text no `seed_notes` put there. Deliberately mode-INDEPENDENT: the
    # NOR/INS chip (and a click on it) leaves INS without saving, so unsaved text outlives the
    # editor, and a "dirty" test that asked the mode instead would call that buffer clean and
    # let the next re-seed erase it.
    def notes_dirty? : Bool
      @notes.text != @notes_base
    end

    # Re-read the open issue (and the list). Returns true ONCE for each distinct peer notes
    # value that arrived over an unsaved buffer, so the controller can say so — the toast is
    # latched here rather than there because the latch has to reset with the seed, and the seed
    # is this pane's business.
    #
    # `announce` is what arms the latch, and it is off by default because the four LOCAL
    # re-readers (a severity/status cycle, a saved notes write) ignore the verdict: latching for
    # them would consume the one announcement the operator was owed and never print it.
    #
    # PUBLIC because the data_version tick is now a caller: without it, an open detail showed
    # the severity/status/notes it was opened with for as long as it stayed open, while the
    # LIST behind it (the only thing `on_external_change` refreshed) already showed the peer's.
    def refresh_detail(store : Store, *, announce : Bool = false) : Bool
      peer_notes = false
      if issue = @detail
        @detail = store.get_issue(issue.id)
        @detail_flow = @detail.try { |f| f.flow_id.try { |fid| store.flow_row(fid) } }
        reload_detail_links(store)
        # get_issue returns nil when the row was deleted by a peer session (supported
        # cross-session scenario) — guard the deref, mirroring ProbeView#refresh_detail.
        # When @detail is nil the render path already falls back to the list view.
        if d = @detail
          if notes_insert_mode? || notes_dirty?
            # NOT a re-seed. In INS `set_text` would discard what is being typed AND reset the
            # caret and undo stack mid-keystroke; dirty-in-READ is the chip-click case above,
            # where the text is on screen and `y` is the only thing that can rescue it. Report
            # instead — and only for a value the operator has not already been told about,
            # because this tick fires on this session's OWN captures too.
            key = notes_key(d.notes)
            if key != @notes_base && key != @notes_peer_seen
              @notes_peer_seen = key if announce
              peer_notes = announce
            end
          else
            seed_notes(d.notes)
          end
        end
      end
      reload(store)
      peer_notes
    end

    # True when saving would silently drop a peer's writeup: this window has unsaved text AND
    # the stored notes have moved off the value the buffer was seeded from. Deliberately a
    # PREDICATE rather than a branch inside `save_notes` — that method's `false` already means
    # "the project was busy, your text is still here, esc to retry", and a conflict must not
    # borrow it: retrying is exactly the wrong move, because the second esc would win.
    #
    # A read failure answers false. This is not the authorization kind of check — refusing to
    # save on an unreadable row would strand the operator's text with no way out, and the write
    # underneath is a plain UPDATE that will fail on its own if the store is really gone.
    def notes_conflict?(store : Store) : Bool
      !notes_conflict_key(store).nil?
    end

    # The PEER'S text (as a `notes_key`) when saving this buffer would overwrite it, else nil.
    #
    # The value, not just a flag, because the refusal it feeds is one the operator can decide to
    # push through — and "push through" has to mean "through the version I was shown". Arming an
    # overwrite against a value latches it against THAT value, so a peer who writes again between
    # the refusal and the second `esc` gets a fresh refusal rather than being silently clobbered
    # by an arm that was granted for text nobody has now seen.
    def notes_conflict_key(store : Store) : String?
      return nil unless issue = @detail
      return nil unless notes_dirty? # nothing local to lose
      stored = store.get_issue(issue.id)
      return nil unless stored # deleted by a peer — a different case, and `update_issue` reports it
      key = notes_key(stored.notes)
      key == @notes_base ? nil : key
    rescue DB::Error | SQLite3::Exception
      nil
    end

    # The RELATED scroll window: the rows the last frame drew, floored at 1 so a
    # never-rendered or fully-clamped card still lets `move_links` step. Written by
    # `render_related_card`, the same shape `@list_last_h` / `list_page_rows` use.
    private def links_visible_rows : Int32
      {@links_last_h, 1}.max
    end

    private def ellipsize(s : String, w : Int32) : String
      return "" if w <= 0
      return s if s.size <= w
      w <= 1 ? "…" : "#{s[0, w - 1]}…"
    end

    # created_at/updated_at are unix MICROSECONDS (the issues.* unit) — to seconds
    # for Time.unix, like Project/History formatting.
    private def fmt_ts(us : Int64) : String
      Time.unix(us // 1_000_000).to_local.to_s("%Y-%m-%d %H:%M")
    end

    # `@issues` is the FILTERED list (apply_filter rebuilds it from the `/` query and from
    # batch deletes) and it is what the draw loop walks — so it is the count the tail clamp
    # is measured against. That clamp is why this pane no longer reads 44 results as the 3
    # under a stale window; see `Viewport.clamp_scroll`.
    private def ensure_visible(h : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, h, @issues.size)
    end
  end
end
