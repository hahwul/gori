require "./screen"
require "./theme"
require "./frame"
require "./query_suggest"
require "./suggest_popup"
require "./traffic_empty_state"
require "../settings"
require "./highlight"
require "./hex_view"
require "./gutter"
require "./reveal"
require "./url"
require "./fmt"
require "./flow_status"
require "./read_cursor"
require "./wrap"
require "./copy_menu"
require "./preview_split"
require "../store"
require "../repeater/flow_request"
require "../ql"
require "../scope"
require "../proxy/h2/frame"
require "../proxy/h2/grpc"
require "../proxy/codec/body"

module Gori::Tui
  # The History tab — gori's home. A plain, append-only log of captured flows
  # (no queue/ranking, P8). A QL bar (`/`) filters the list; analysis is by query
  # (pull), with field/value suggestions while typing. Also owns the detail view.
  class HistoryView
    # `list_split` only — the focus half (PreviewPane) is two-way and this preview is not.
    include PreviewSplit

    PAGE = 1000
    # Hard cap on rows held in memory. The initial load is PAGE; live capture
    # then appends, but never past MAX_ROWS — the oldest are dropped from the
    # window (in TRIM_SLACK batches so the id index is rebuilt amortized, not per
    # flow). This keeps a long high-traffic session's footprint bounded; the
    # authoritative history still lives in SQLite (reload/QL re-query it).
    MAX_ROWS = 5000
    # Width the Colormarker `strip` column costs the fixed left block when armed: one colour
    # cell plus a one-column gap. See render_list_body.
    STRIP_W    =   2
    TRIM_SLACK = 512
    # Cap on h2 frames / WS messages loaded into a detail view. A long-lived WS
    # (100k+ messages) or a heavily-multiplexed h2 connection would otherwise
    # materialize the whole log (objects + payloads + built lines) on detail-open.
    # We load the MOST RECENT this-many (so a live tail keeps updating) and show an
    # "older not loaded" note; the raw frames remain whole in SQLite.
    DETAIL_LOG_CAP = 10_000
    # Tab-completion offers exactly what `QL.field_cond` implements — no more, no less. It used
    # to say that by keeping a hand-written copy, which is how `flag:` (a field with no store
    # behind it — Store#flags_for is a stub) came to head the list while `url:` (real and
    # working) was missing from it. It is now THE list, read from `QL::FIELDS`, so the drift the
    # spec below was written to catch cannot happen at all.
    QL_FIELDS  = QL::FIELDS
    METHOD_VAL = %w[GET POST PUT DELETE PATCH HEAD OPTIONS QUERY]
    # Discoverability hints for the QL filter. Both are GENERATED from the field pool and the
    # grammar's own operator list (`QuerySuggest`) rather than written out here: as prose they
    # drifted from `QL_FIELDS` and from each other — this pair listed `AND OR NOT` and never `-`,
    # while Intercept's listed both — so an operator looking for "everything EXCEPT" found nothing
    # on the two surfaces most likely to be asked the question.
    #
    # FILTER_HINT sits on the idle bar (press `/` to start filtering); QUERY_HINT sits on the
    # suggestion row at a cold start (already editing, nothing to Tab-complete yet).
    FILTER_HINT = QuerySuggest.idle_hint("/ filter")
    QUERY_HINT  = QuerySuggest.cold_hint(help_key: true)
    # The editing bar's label. A constant because `render_query_popup` has to line the dropdown
    # up under the token, which means knowing exactly how far the query text is indented.
    QUERY_PREFIX = "filter › "
    # The highlighter's field vocabulary. `QL.known_field?`, not `QL_FIELDS.includes?`: the pool
    # is what Tab OFFERS and is a strict subset of what QL accepts, so testing against it would
    # paint `res.body:` — which compiles perfectly — as a typo.
    QL_KNOWN = ->(f : String) { QL.known_field?(f) }

    getter rows : Array(Store::FlowRow)
    getter? follow : Bool
    getter? querying : Bool
    getter query : String
    # The detail body's read caret (mirrors RepeaterView#resp_cursor) — the pane's own
    # position, which the wrap walkers move in visual rows.
    getter detail_read : ReadCursor

    def initialize(@max_rows : Int32 = MAX_ROWS, @trim_slack : Int32 = TRIM_SLACK)
      # Display order follows Settings.history_list_order: newest-first (id DESC) or
      # oldest-first (id ASC). index_of binary-searches the matching direction.
      @rows = [] of Store::FlowRow
      @selected = 0
      @scroll = 0
      @follow = true
      # Multi-select marks (#442), keyed by FLOW ID rather than row index: the list
      # reloads, re-sorts and re-filters constantly (the cursor itself is already
      # id-anchored across a reload — see `prev_id` in #reload), so an index-keyed set
      # would silently retarget on the next data_version tick. A mark whose flow falls
      # out of the current filter/window stays marked (marked_hidden_count reports it);
      # a mark whose flow is gone simply fails to resolve at the verb.
      @marks = Set(Int64).new
      @mark_anchor = nil.as(Int64?) # id-keyed range anchor for the ⇧arrow extend
      # Ids the CURRENT ⇧arrow gesture added, so shrinking the range gives them back — a GUI
      # shift+click shrinks the selection, where a plain union would only ever grow. Scoped to
      # the gesture, so marks made by `t`/⇧T outside the range are never disturbed. Cleared
      # whenever the anchor is.
      @mark_extent = Set(Int64).new
      @filter_dirty = false                       # a filtered view needs a coalesced reload after draining
      @last_filter_flush = nil.as(Time::Instant?) # debounce clock for flush_filter (nil ⇒ first flush is immediate)
      @query = ""
      @qcx = 0
      @preedit = ""
      @querying = false
      @query_note = nil.as(String?) # why an active filter is empty when it's INVALID (not just no-match)
      # Weak back-pointer for host: Tab suggestions (set on every reload). Nil until
      # the first reload — suggestions simply skip the host pool then.
      @suggest_store = nil.as(Store?)
      @host_suggest_prefix = nil.as(String?) # cache key (downcase prefix)
      @host_suggest_values = [] of String
      # The `↓` completion dropdown. Closed until asked for — see `SuggestPopup`.
      @popup = SuggestPopup.new
      @scope = nil.as(Scope?)
      # Colormarker (the row-colour lens). Nil until `set_colormarker` — every construction
      # site outside HistoryController leaves it nil, which is what makes the whole feature a
      # no-op for the existing History specs (no swatch column, no tint, byte-identical render).
      @colormarker = nil.as(Colormarker?)
      # Per-row answers, keyed by FLOW ID like @marks and for the same reason: the list
      # reloads, re-sorts and re-filters constantly, so an index-keyed memo would retarget.
      # Dropped wholesale whenever the engine's revision moves — see `color_for`.
      @color_memo = {} of Int64 => Store::ColorRule?
      @color_rev = 0_u64
      @detail = nil.as(Store::FlowDetail?)
      @detail_ws = nil.as(Array(Store::WsMessage)?)
      @detail_frames = nil.as(Array(Store::H2Frame)?)
      @detail_ws_total = 0 # full message count (≥ loaded; drives the "older not loaded" note)
      @detail_frames_total = 0
      @detail_sse = false # response is a text/event-stream → offer the EVENTS pane
      # Decoded protocol projections, parsed once per opened flow (no DB table) — each
      # drives an optional detail pane like EVENTS. nil/empty ⇒ the pane isn't offered.
      @detail_saml = nil.as(Saml::Doc?)      # SAMLRequest/Response → SAML pane
      @detail_jwts = [] of Jwt::Found        # located JWTs → JWT pane
      @detail_graphql = nil.as(Graphql::Op?) # GraphQL operation → GRAPHQL pane
      # …and the operations a 101 flow carries in its FRAMES (graphql-transport-ws /
      # subscriptions-transport-ws). A subscription's document never touches a request body,
      # so the same pane has to be fed from the transcript for a WebSocket flow.
      @detail_graphql_ws = [] of GraphqlWs::Frame
      # The ws message COUNT @detail_graphql_ws was last built from, so a 101 detail left open
      # during a live socket re-parses the transcript only when it actually GREW, not on every
      # refresh poke. −1 = never built / a different flow.
      @graphql_ws_len = -1
      @detail_form = nil.as(Array(FormData::Field)?) # form/multipart params → PARAMS pane
      @decoded_id = nil.as(Int64?)                   # flow the decoded panes above were parsed from (skip re-decode)
      # Scroll anchor: a (logical line, visual sub-row) pair rather than a flat visual-row
      # index — see the header of `Wrap`. @detail_scroll_sub is 0 in hex (which draws its own
      # fixed rows) and before the first frame has published a content width.
      @detail_scroll = 0
      @detail_scroll_sub = 0
      # Horizontal offset in display columns, and the OTHER half of the anchor: it is dead
      # while the pane wraps (nothing sits off to the side of a wrapped row) and
      # @detail_scroll_sub is dead while it doesn't. `Settings.wrap_lines?` picks which,
      # live, so each render branch zeroes the one it isn't using. Moved only by the caret
      # (ensure_detail_visible_x) — this pane never had an h-scroll binding, even before it
      # learned to wrap.
      @detail_xscroll = 0
      # Per-line wrap memo for the detail body, keyed by the content width below.
      @detail_wrap = {} of Int32 => Wrap::Layout
      @detail_wrap_w = -1
      # One-entry memo for the PLAIN text of a detail line — see `detail_line_text`.
      @detail_text_i = -1
      @detail_text = ""
      @detail_pane = initial_detail_pane
      @detail_focus = :strip                 # :strip (chip row) | :body (caret/text) — two-level detail focus
      @search_hl = ""                        # active ^F query → highlight in the detail body
      @reveal = false                        # 'w' shows whitespace/CR/LF as glyphs (smuggling)
      @reveal_lines = nil.as(Array(String)?) # cached revealed lines, keyed on the pane bytes ptr
      @reveal_lines_src = Pointer(UInt8).null
      @detail_hex = false                      # 'x' toggles a raw hex dump of the current pane (req/resp)
      @detail_hex_bytes = nil.as(Bytes?)       # cached combined head+body for the current pane (hex source)
      @pretty = Settings.pretty_bodies_default # 'p' pretty-prints bodies (display only); pushed from the runner
      # Windowed detail content, rebuilt only when the detail/pane changes (NOT on
      # scroll or every frame). The head/notes are pre-styled; the body is kept RAW
      # and styled per VISIBLE line, so opening a multi-MiB response is instant
      # instead of tokenising 100k+ off-screen lines up front.
      @detail_cache = nil.as(DetailView?)
      # Per-visible-line styled BODY memo (keyed by absolute line index), mirroring
      # RepeaterView's @resp_styled_cache: a held/scrolling detail was re-tokenising every
      # visible body line (BodyLines#[] scrub + body_styled) on EVERY frame — spinner ticks,
      # live-capture drains, cursor moves. Dropped in lockstep with @detail_cache (drop_detail_cache).
      @detail_styled_cache = {} of Int32 => Highlight::Line
      @detail_cache_rev = Theme.revision # the theme the cached (colour-baked) head/notes were built under
      @detail_read = ReadCursor.new
      # The geometry the last text render actually drew with. Hit-testing reads these back
      # rather than re-deriving them: `detail_gutter_w` is fed a different total by each
      # render path (dv.total vs reveal_lines.size), so a re-derivation could key the wrap
      # memo at a width the rows were never laid out at — flushing it on every click.
      @detail_last_h = 0
      @detail_last_gw = 0
      @detail_last_cw = 0
      # settings:layout History Req/Res preview (list page bottom pane) — separate from full detail.
      @preview_detail = nil.as(Store::FlowDetail?)
      @preview_id = nil.as(Int64?)
      # Split preview lines, computed once per (re)fetched @preview_detail — NOT per frame.
      # A ≤64 KiB body scrub+split+array is wasteful to redo every render tick while the
      # selected flow is unchanged (which is every captured flow under live capture).
      @preview_req_lines = nil.as(Array(String)?)
      @preview_res_lines = nil.as(Array(String)?)
      @preview_scroll_req = 0
      @preview_scroll_res = 0
      @preview_focus = :list # :list | :req | :res
    end

    # True when the list page should reserve a bottom Req|Res preview pane.
    def preview_enabled? : Bool
      Settings.history_preview
    end

    getter preview_focus : Symbol

    # Load/refresh the preview cache for the selected flow (no-op when preview is off).
    # Uses a capped body read (Settings.preview_body_cap+1) so selecting through the list never
    # pulls multi-MiB BLOBs from SQLite for a pane that only shows a short prefix.
    def refresh_preview(store : Store) : Nil
      return clear_preview unless preview_enabled?
      id = selected_id
      return clear_preview unless id
      if @preview_id != id
        @preview_scroll_req = 0
        @preview_scroll_res = 0
      elsif (d = @preview_detail) && d.row.state.complete? && d.row.status != 101 && d.h2_conn_id.nil?
        # Same flow, already cached, and its captured bytes are immutable (Complete,
        # non-streaming) — a data_version poke from OTHER flows committing has nothing
        # to pick up here. Skip the SQLite round-trip + body re-split every render tick
        # (mirrors refresh_detail's guard). A pending / 101 / h2 flow still re-fetches.
        return
      end
      detail = store.get_flow(id, body_max: Settings.preview_body_cap + 1)
      @preview_detail = detail
      @preview_id = id
      # Split the (bounded) preview text once, here — render reads the cached arrays.
      if detail
        @preview_req_lines = preview_text_lines(detail.request_head, detail.request_body)
        @preview_res_lines = preview_text_lines(detail.response_head, detail.response_body)
      else
        @preview_req_lines = nil
        @preview_res_lines = nil
      end
    end

    def clear_preview : Nil
      @preview_detail = nil
      @preview_id = nil
      @preview_req_lines = nil
      @preview_res_lines = nil
      @preview_scroll_req = 0
      @preview_scroll_res = 0
    end

    # Tab cycles list → request → response → list (only when preview is on).
    def cycle_preview_focus : Nil
      return unless preview_enabled?
      @preview_focus = case @preview_focus
                       when :list then :req
                       when :req  then :res
                       else            :list
                       end
    end

    def set_preview_focus(f : Symbol) : Nil
      @preview_focus = f if {:list, :req, :res}.includes?(f)
    end

    def scroll_preview(delta : Int32) : Nil
      case @preview_focus
      when :req then @preview_scroll_req = {@preview_scroll_req + delta, 0}.max
      when :res then @preview_scroll_res = {@preview_scroll_res + delta, 0}.max
      end
    end

    # `list_split` — the split geometry — comes from PreviewSplit, shared with Issues/Probe.
    # The focus vocabulary above is NOT shared: this preview holds two panes (request and
    # response), so its ⇥ cycles three ways where theirs cycles two.

    # head (styled, bounded) ++ body (raw, styled lazily per visible line) ++
    # trailer (styled notes). For the WS/frames/grpc panes the whole content is in
    # `head` (bounded); only a plain request/response body uses the windowed `body`.
    private record DetailView,
      head : Array(Highlight::Line),
      body : Highlight::BodyLines,
      kind : Symbol,
      trailer : Array(Highlight::Line),
      pretty : Bool = false,   # whether Pretty actually reflowed this body (drives the indicator)
      binary : Bool = false do # a binary body shown as a placeholder — reveal/pretty don't apply
      def total : Int32
        head.size + body.size + trailer.size
      end

      def line_at(i : Int32) : Highlight::Line
        return head[i] if i < head.size
        j = i - head.size
        return Highlight.body_styled(body[j], kind) if j < body.size
        trailer[j - body.size]
      end

      # Plain text of line `i` for searching — joins head/trailer spans and returns
      # body lines raw (lazy materialise), so it never re-styles (keeps ^F cheap on a huge body).
      def line_text(i : Int32) : String
        return head[i].map(&.text).join if i < head.size
        j = i - head.size
        return body[j] if j < body.size
        trailer[j - body.size].map(&.text).join
      end
    end

    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    def set_colormarker(cm : Colormarker) : Nil
      @colormarker = cm
    end

    # Which rule paints `row`, or nil.
    #
    # Memoised per flow id, and invalidated by comparing the engine's `revision` ONCE per call
    # rather than by any callback: an edit on the Colormarker tab, an `apply_external_change`
    # pulling in an MCP/CLI/peer-process edit, and a theme-independent reload all move the same
    # counter, so the counter IS the notification and no cross-tab plumbing is needed.
    #
    # The memo (not a per-reload stamp like `Sitemap.stamp_tags!`) because History is the wrong
    # shape for a stamp: it APPENDS live — `on_event(:inserted)` returns early when not
    # filtering and never calls `reload`, so on an unfiltered list the next reload may never
    # come — and it holds MAX_ROWS rows while a screenful is ~50. A stamp would be 100× the work
    # for the same visible answer, and would leave every live-captured row uncoloured.
    # `proto` is passed in because the row loop already computes it for the PROTO column —
    # classifying twice per row per frame would be pure waste.
    private def color_for(row : Store::FlowRow, proto : Proto::Kind) : Store::ColorRule?
      cm = @colormarker
      return nil unless cm
      if cm.revision != @color_rev
        @color_rev = cm.revision
        @color_memo.clear
      end
      @color_memo.fetch(row.id) { @color_memo[row.id] = cm.match(row, proto) }
    end

    # Resolve the STORE-tier colour rules for the whole visible window at once, before the row
    # loop starts asking about them one row at a time. A condition like `body:secret` cannot be
    # answered from the row projection, so the engine has to read the database; batching turns a
    # screenful of single-id queries into one query per such rule.
    #
    # A no-op — no allocation, no engine call — when every enabled rule is answerable from the
    # row, which is the ordinary case and why nothing about the common path changed.
    #
    # Only the rows the loop will really draw, and only those the memo has no answer for: paging
    # back over rows already painted asks for nothing. The revision check is the SAME one
    # `color_for` makes, made first so a stale memo cannot make this skip a row the loop then
    # resolves one at a time.
    private def prefetch_colors(list_h : Int32) : Nil
      cm = @colormarker
      return unless cm && cm.needs_store?
      if cm.revision != @color_rev
        @color_rev = cm.revision
        @color_memo.clear
      end
      pending = [] of Store::FlowRow
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @rows.size
        row = @rows[ri]
        pending << row unless @color_memo.has_key?(row.id)
      end
      cm.prefetch(pending)
    end

    # True when the displayed list is a filtered subset (QL query or Scope lens).
    def filtering? : Bool
      !@query.blank? || (@scope.try(&.active?) == true)
    end

    # Load flows applying the Scope lens AND the QL query. store.search returns
    # newest-first (ORDER BY id DESC); reverse when the layout pref is oldest-first.
    def reload(store : Store) : Nil
      @suggest_store = store
      invalidate_host_suggest_cache
      prev_id = @rows[@selected]?.try(&.id) # anchor the highlight to the flow, not the index
      query_filter = QL.parse(@query)
      @query_note = query_note_for(query_filter, store)
      # A non-blank query that compiles to EMPTY (every term invalid — a typo'd field,
      # a bad numeric like dur:>2sec, an unterminated value) must NOT fall through to a
      # match-all search: that would show EVERY flow while the bar claims a filter is
      # active — the opposite of the ask, and dangerous on a security proxy. Reject it
      # (empty list + a note), mirroring the MCP/CLI surfaces which both reject_empty?.
      if QL.reject_empty?(@query, query_filter)
        @rows = [] of Store::FlowRow
        @filter_dirty = false
        @selected = 0
        @scroll = 0
        return
      end
      combined = QL.and(@scope.try(&.filter) || QL::EMPTY, query_filter)
      @rows =
        begin
          store.search(combined, PAGE, raise_on_error: true)
        rescue
          # A VALID QL parse that SQLite still can't run (a huge OR chain past the
          # expression-tree-depth limit, a pathological FTS phrase). Degrade to empty like
          # before, but SAY why via the note so it doesn't read as a genuine "no flows match"
          # (#411). The store already logged it to gori.log; the live loop must never crash.
          @query_note = "query too complex to run — narrow the filter"
          [] of Store::FlowRow
        end
      @rows.reverse! unless newest_first?
      @filter_dirty = false
      @selected =
        if @follow
          follow_index
        elsif prev_id && (idx = index_of(prev_id))
          idx # keep the highlight on the same flow across a reload
        else
          @selected.clamp(0, {@rows.size - 1, 0}.max)
        end
    end

    # A short note explaining a filter that matches nothing because it is INVALID (vs a
    # valid filter that genuinely has no matches) — surfaced in the empty-state hint so a
    # typo'd status:/dur:/size: or a broken body~[regex isn't misread as "no traffic".
    private def query_note_for(filter : QL::Filter, store : Store) : String?
      return nil if @query.blank?
      return "invalid filter — no valid terms" if QL.reject_empty?(@query, filter)
      bad = QL.invalid_regex_terms(@query)
      return "invalid regex in #{bad.first}" unless bad.empty?
      fts_backlog_note(filter, store)
    end

    # `body:`/free-text read the trigram index, which is written OFF the capture commit
    # (Store V4) so a busy proxy is never throttled by tokenization. The cost is that during
    # a burst the newest flows are captured but not yet indexed — and "not indexed yet" would
    # otherwise be indistinguishable from "no match", which on a security proxy is the kind of
    # silence that hides a finding. So SAY it. A live view must not stall to fix this (the
    # one-shot CLI/MCP surfaces call Store#index_pending! instead), and the backlog drains on
    # its own as soon as capture goes quiet.
    #
    # Probed only for a filter that actually reads the index, since reload re-runs on every
    # tick while a filter is active.
    private def fts_backlog_note(filter : QL::Filter, store : Store) : String?
      return nil unless filter.uses_fts?
      pending = store.fts_backlog
      return nil if pending == 0
      count = pending >= Store::FTS_BACKLOG_PROBE_MAX ? "#{Store::FTS_BACKLOG_PROBE_MAX}+" : pending.to_s
      "body search is #{count} flow(s) behind — still indexing"
    end

    # settings:layout History list order — newest first (default) or oldest first.
    private def newest_first? : Bool
      Settings.history_newest_first?
    end

    # Index of the live tail (newest flow) in the current display order.
    private def follow_index : Int32
      return 0 if @rows.empty?
      newest_first? ? 0 : @rows.size - 1
    end

    # Minimum spacing between live-capture filter reloads. A filtered / Scope-lens list
    # can't update incrementally, so every captured flow flags @filter_dirty and would
    # otherwise re-run the FULL-table search + reverse (up to PAGE rows) on each drain
    # tick — ~20×/sec under sustained capture, and a Scope lens alone puts every session
    # in this state. Coalescing to this cadence drops the frequency ~10-40× with no
    # correctness loss (@filter_dirty just accumulates until the window elapses). The
    # FIRST dirtying still reloads immediately (last-flush is nil), so the view stays live.
    FILTER_FLUSH_INTERVAL = 250.milliseconds

    # Apply any filtered-view staleness accumulated during a drain cycle in ONE
    # reload (vs reloading per flow event — a search+reverse of up to PAGE rows),
    # debounced to FILTER_FLUSH_INTERVAL so a busy capture can't thrash the search.
    # Returns true if it actually reloaded (so the caller can mark the frame dirty).
    def flush_filter(store : Store) : Bool
      return false unless @filter_dirty
      now = Time.instant
      if (last = @last_filter_flush) && now - last < FILTER_FLUSH_INTERVAL
        return false
      end
      @last_filter_flush = now
      reload(store)
      true
    end

    def on_event(event : Store::FlowEvent, store : Store) : Nil
      if filtering?
        @filter_dirty = true # coalesce: the Runner reloads once after draining
        return
      end
      case event.kind
      when :inserted
        return if index_of(event.id)
        if row = store.flow_row(event.id)
          # Inserts arrive increasing-id (FIFO). Prepend for newest-first (id DESC),
          # append for oldest-first (id ASC) so binary search stays valid.
          if newest_first?
            # An EMPTY list has no row under the cursor: @selected/@scroll are the 0
            # placeholder, not an anchor on anything. Shifting them for the prepend below
            # would put the cursor one past the end on every insert (selected_id nil ⇒
            # ↵/r/t/d/copy all silent no-ops) — and off-tab nothing re-clamps it, so the
            # reload on_enter runs loses the id anchor too and parks the cursor on the
            # OLDEST flow of a newest-first list. Reachable after `Clear history` (or `f`
            # on an already-empty list), which leaves @follow off with @selected at 0.
            anchored = !@rows.empty?
            @rows.unshift(row)
            if @follow
              @selected = 0
            elsif anchored
              # Keep the highlight + viewport on the same flows the user is looking at.
              @selected += 1
              @scroll += 1
            end
          else
            @rows << row
            @selected = @rows.size - 1 if @follow
            # Not following: selection/scroll stay put (new row is past the end).
          end
          trim_window if @rows.size > @max_rows + @trim_slack
        end
      when :updated
        if (idx = index_of(event.id)) && (row = store.flow_row(event.id))
          @rows[idx] = row
          # The row's ANSWERS changed, so its colour has to be re-asked. An in-flight row has
          # `status` and `content_type` nil, so `status:>=500` and `proto:sse` genuinely answer
          # differently once the response lands — without this the row would keep the colour it
          # had while pending, for the rest of the session. The engine's own store-tier cache is
          # dropped for the same id and the same reason: a `body:` rule asked while the flow was
          # still in flight was asked about a response that had not arrived.
          @color_memo.delete(event.id)
          @colormarker.try(&.forget(event.id))
        end
      end
    end

    def move(delta : Int32) : Nil
      return if @rows.empty?
      # When the preview pane is focused, ↑/↓ scroll that side instead of the list.
      if preview_enabled? && (@preview_focus == :req || @preview_focus == :res)
        scroll_preview(delta)
        return
      end
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
      # "Following" the live tail means sitting on the newest row (top or bottom).
      @follow = (@selected == follow_index)
      @preview_id = nil # force refresh_preview to re-fetch on the next controller tick
      reset_mark_anchor # a plain move re-seeds the range anchor, like a GUI list
    end

    getter selected : Int32

    # Alias getter for the selected row index (mouse dispatch readability).
    def selected_index : Int32
      @selected
    end

    # Inverts render_list's vertical layout: QL bar (rect.y), optional suggestion
    # row (only while querying), header + divider, then flow rows from list_top.
    # Returns the @rows index under (mx,my), or nil outside the list / past the
    # last populated row. Mirrors list_top/list_h and the @scroll+i row math.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if list_rect.empty? || !list_rect.contains?(mx, my)
      lt = list_top(list_rect)
      list_h = {list_rect.bottom - lt, 0}.max
      i = my - lt
      return nil if i < 0 || i >= list_h
      ri = @scroll + i
      ri < @rows.size ? ri : nil
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the frame's right
    # hairline — one column OUTSIDE the list rect, which is why `list_row_at` cannot answer it
    # — and this list's `@scroll` is DERIVED from the selection by render's `ensure_visible`,
    # so the answer is a selection, not an offset. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if list_rect.empty?
      lt = list_top(list_rect)
      Frame.scroll_gauge_row(Rect.new(list_rect.x, lt, list_rect.w, {list_rect.bottom - lt, 0}.max),
        @rows.size, mx, my)
    end

    # Which preview sub-pane (if any) contains (mx,my). :req | :res | nil.
    def preview_pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      _, prev = list_split(rect)
      return nil unless prev && prev.contains?(mx, my)
      return nil if prev.h < 2
      body = Rect.new(prev.x, prev.y + 1, prev.w, prev.h - 1)
      if body.w >= 60
        mid = body.x + body.w // 2
        mx < mid ? :req : :res
      else
        half = body.y + body.h // 2
        my < half ? :req : :res
      end
    end

    # The first flow-row screen-y — mirrors render_list: hdr_y = rect.y+1 (+1 for
    # the suggestion row while querying), then +2 past the header row + divider.
    private def list_top(rect : Rect) : Int32
      hdr_y = rect.y + 1
      hdr_y += 1 if @querying
      hdr_y + 2
    end

    # Click-select a row WITHOUT opening detail: same post-conditions as `move`
    # (clamp @selected, @follow only when on the top/newest row); @scroll is left
    # to render's ensure_visible, exactly as the keyboard path relies on.
    def select_row(idx : Int32) : Nil
      return if @rows.empty?
      @selected = idx.clamp(0, @rows.size - 1)
      @follow = (@selected == follow_index)
      @preview_id = nil # force preview refresh
      reset_mark_anchor # same as the keyboard `move`: a plain click re-seeds the anchor
      @preview_focus = :list
    end

    # At the first (top) row — used by the Runner to pop focus up to the tab bar
    # when ↑ is pressed at the top (natural upward keyboard flow).
    def at_top? : Bool
      @selected == 0
    end

    def toggle_follow : Nil
      @follow = !@follow
      @selected = follow_index if @follow && !@rows.empty?
    end

    # The flow id currently open in the detail overlay (nil when the list is showing).
    def detail_flow_id : Int64?
      @detail.try(&.row.id)
    end

    def selected_id : Int64?
      @rows[@selected]?.try(&.id)
    end

    def empty? : Bool
      @rows.empty?
    end

    # Selected list row (nil when empty) — used to name the flow in the delete confirm.
    def selected_row : Store::FlowRow?
      @rows[@selected]?
    end

    # --- marks (multi-select, #442) -------------------------------------------

    def marked?(id : Int64) : Bool
      @marks.includes?(id)
    end

    def mark_count : Int32
      @marks.size
    end

    # Marks whose flow is NOT in the current window (filtered out, trimmed, or deleted).
    # Surfaced next to the count so a set larger than what's on screen is never a surprise.
    def marked_hidden_count : Int32
      return 0 if @marks.empty?
      visible = 0
      @rows.each { |r| visible += 1 if @marks.includes?(r.id) }
      @marks.size - visible
    end

    # Marks in DISPLAY order. Flow ids are monotonic with capture time and the list is
    # ordered by id, so sorting by id reproduces display order exactly — including for
    # marks that are currently off-window, which no @rows walk could place.
    def marked_ids : Array(Int64)
      ids = @marks.to_a.sort!
      ids.reverse! if newest_first?
      ids
    end

    # The effective target set every batch verb acts on: the marks if any are set, else
    # the cursor row (#442). One rule, so a verb needs no notion of "batch mode".
    def target_ids : Array(Int64)
      return marked_ids unless @marks.empty?
      [selected_id].compact
    end

    # The ONE flow a batch verb should treat as privileged when it genuinely needs a single
    # representative — the issue form's title/host, Discover's header donor. NOT `target_ids.first`:
    # that follows the display order, so a pure layout preference (history_list_order) would flip
    # which flow gets to name the issue or donate its cookies. The cursor row wins when it is
    # itself a target (it is the flow you were looking at); otherwise the oldest, which is stable
    # under every sort and filter.
    def primary_target_id : Int64?
      ids = target_ids
      return nil if ids.empty?
      cur = selected_id
      return cur if cur && ids.includes?(cur)
      ids.min
    end

    # `t` — flip the cursor row's mark, then step to the next OLDER flow, so a run of `t` marks
    # consecutive rows. "Older", not "down": follow parks the cursor on the newest row, which is
    # the BOTTOM row under oldest-first order — stepping down there is a clamp, so the second `t`
    # would land on the same row and un-mark what the first just marked. Walking away from the
    # live tail is the triage gesture ("this one and the next few older ones") and works in both
    # orders. The anchor lands on the row just toggled, so `t` then ⇧↓ extends from it.
    def toggle_mark : Nil
      return unless id = selected_id
      @marks.includes?(id) ? @marks.delete(id) : @marks.add(id)
      step_cursor(newest_first? ? 1 : -1)
      @mark_anchor = id
      @mark_extent.clear
    end

    # ⇧T — mark every row in the CURRENT filtered list, unioned with what's already
    # marked (so narrowing the filter twice accumulates rather than replaces).
    def mark_all : Nil
      @rows.each { |r| @marks.add(r.id) }
      @mark_anchor = selected_id
      @mark_extent.clear
    end

    def clear_marks : Nil
      @marks.clear
      reset_mark_anchor
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow anchors
    # at the cursor instead of sweeping back to a stale point.
    private def reset_mark_anchor : Nil
      @mark_anchor = nil
      @mark_extent.clear
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead of
    # being left behind. Only the gesture's own ids go (@mark_extent): `t`/⇧T marks are
    # deliberate tags, and there is no ctrl+arrow here to step the cursor past them without
    # disturbing them, so dropping those too would put a discontiguous set out of reach
    # ("mark this one, skip three, mark that one"). Returns how many marks it gave back, so
    # the caller can say so rather than let a range vanish silently.
    def end_mark_gesture : Int32
      before = @marks.size
      @mark_extent.each { |id| @marks.delete(id) }
      reset_mark_anchor
      before - @marks.size
    end

    # Drop specific marks — the post-batch-delete prune, so a deleted flow's id can't
    # linger in the set and inflate the next count.
    def unmark_ids(ids : Enumerable(Int64)) : Nil
      ids.each { |id| @marks.delete(id); @mark_extent.delete(id) }
      reset_mark_anchor if (a = @mark_anchor) && !@marks.includes?(a) && index_of(a).nil?
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. The anchor is seeded from the cursor when it's unset or off-window
    # (a plain move/click clears it), so the first ⇧arrow always starts from where you are.
    def extend_marks(delta : Int32) : Nil
      return if @rows.empty?
      anchor_idx = @mark_anchor.try { |a| index_of(a) }
      unless anchor_idx
        @mark_anchor = selected_id
        anchor_idx = @selected
        @mark_extent.clear
      end
      step_cursor(delta)
      lo, hi = {anchor_idx, @selected}.minmax
      wanted = Set(Int64).new
      (lo..hi).each { |i| @rows[i]?.try { |r| wanted.add(r.id) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after ⇧↓⇧↓
      # leaves two rows marked rather than three. @mark_extent holds only ids the gesture itself
      # added, so a mark made earlier by `t`/⇧T survives a range sweeping over it and back off.
      (@mark_extent - wanted).each { |id| @marks.delete(id) }
      added = wanted - @marks
      @marks.concat(added)
      @mark_extent = (@mark_extent & wanted) | added
    end

    # Cursor step used by the mark gestures. Deliberately NOT `move` (which redirects to
    # scroll_preview when a preview pane is focused) and NOT the controller's
    # move_selection (which pops focus to the tab bar at the top row — that would eject
    # you mid-range-selection). Clamps, so it saturates at both ends instead of wrapping.
    private def step_cursor(delta : Int32) : Nil
      return if @rows.empty?
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
      @follow = (@selected == follow_index)
      @preview_id = nil # force refresh_preview on the next controller tick
    end

    # Short "METHOD /path" label for confirm dialogs; falls back to "flow #id".
    def flow_summary(id : Int64) : String
      if (d = @detail) && d.row.id == id
        return "#{d.row.method} #{Url.origin_path(d.row.target)}"
      end
      if row = @rows.find { |r| r.id == id }
        return "#{row.method} #{Url.origin_path(row.target)}"
      end
      "flow ##{id}"
    end

    # Hard-delete one flow by id, then re-anchor the list. Closes the detail if it was
    # showing that flow. Id is captured by the controller at confirm-open time so a
    # live-capture reload can't retarget the delete.
    def delete_by_id(store : Store, id : Int64) : Bool
      delete_ids(store, [id])
    end

    # Batch form (#442): one store round-trip for N marked flows, then the same
    # re-anchoring. The deleted ids are pruned from the mark set so a stale mark can't
    # inflate the next count.
    #
    # Returns whether the write committed. On a rollback NOTHING local is touched — the marks
    # in particular stay put, because they are the only remaining handle on the set the user
    # asked to delete, and dropping them on a failed write would leave no way to retry.
    def delete_ids(store : Store, ids : Array(Int64)) : Bool
      return true if ids.empty?
      return false unless store.delete_flows(ids)
      close_detail if @detail.try(&.row.id).try { |d| ids.includes?(d) }
      clear_preview if @preview_id.try { |p| ids.includes?(p) }
      unmark_ids(ids)
      reload(store)
      true
    end

    # Wipe every History flow, close detail/preview, and reload the list.
    #
    # Returns whether the wipe COMMITTED. `delete_ids` one method up already answers this and
    # its caller branches on it; `clear` was the one History write that dropped it — and the
    # `reload` below made the contradiction visible, repopulating the list with the flows that
    # are still there while the status line said they were gone.
    def clear(store : Store) : Bool
      ok = store.clear_flows
      close_detail
      clear_preview
      clear_marks
      reload(store)
      ok
    end

    # --- QL bar editing ------------------------------------------------------

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

    # --- the opt-in completion dropdown (`↓`) ---------------------------------
    # The inline row stays the default; this is the roomier second view of the same candidates.
    # See `SuggestPopup` for why it is opt-in rather than the primary shape.

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

    # Keep the candidate set in step with the query on every edit. The popup re-anchors its
    # selection onto the same candidate when it survived, and shuts itself when the edit left
    # nothing to show — an empty dropdown is a hole in the list for no content.
    private def sync_popup : Nil
      @popup.set(query_suggestions) if @popup.open?
    end

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed query — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Tab-complete the current token: to the SELECTED candidate when the dropdown is open,
    # otherwise to the first — so a bar whose popup was never opened behaves exactly as before.
    #
    # `close` is what ↵ passes and ↹ does not, and it is load-bearing rather than cosmetic. With
    # the dropdown open, re-deriving candidates after the splice can hand back a list containing
    # the token that was just completed (`method:GET` narrows the value pool to exactly
    # `["method:GET"]`), so the popup never shuts, ↵ re-splices the identical string forever, and
    # `stop_query` becomes unreachable — the bar could not be left with Enter at all. ↹ keeps it
    # open on purpose, because chaining field → value is the whole point of Tab.
    def query_complete(close : Bool = false) : Bool
      sugg = query_suggestions
      pick = @popup.choice(sugg)
      return false unless pick
      cur = FilterAst.token_at(@query, @qcx)
      @query = "#{@query[0, cur.start]}#{pick}#{@query[cur.stop..]}"
      @qcx = cur.start + pick.size
      # Completing consumes the choice: the token is now whole, so the old candidate set is
      # stale. Re-derive it (a field completion opens a value list) and let `set` close the
      # popup if that leaves nothing.
      close ? @popup.close : (@popup.set(query_suggestions) if @popup.open?)
      true
    end

    # Suggestions for the token under the cursor: field names, then field values.
    # FilterAst::Cursor carries the grammar's punctuation through, so `-ho` → `-host:`
    # and `(ho` → `(host:` — the same peeling every other filter bar uses.
    def query_suggestions : Array(String)
      cur = FilterAst.token_at(@query, @qcx)
      return [] of String if cur.core.empty?
      fields =
        if colon = cur.core.index(':')
          field = cur.core[0...colon].downcase
          prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..])
          suggest_values(field, prefix).map { |s| "#{cur.prefix}#{s}" }
        else
          QL_FIELDS.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}:" }
        end
      # ...then the boolean operators, which no field pool can offer. The whole CURSOR, so an
      # operator candidate carries the token's `(` the way a field one does. See
      # `QuerySuggest::OPERATORS`.
      QuerySuggest.with_operators(fields, cur)
    end

    # --- detail view ---------------------------------------------------------

    # settings:display — which detail pane opens first: request (default) or response.
    private def initial_detail_pane : Symbol
      Settings.default_detail_pane == "response" ? :response : :request
    end

    def open_detail(store : Store) : Bool
      id = selected_id
      return false unless id
      open_detail_id(id, store)
    end

    # Open a specific flow's detail by id, regardless of the current list selection
    # (used by the Issues tab to jump back to an issue's linked evidence). Also
    # syncs @selected to it when the row is in the current list, so back/▲▼ behave.
    def open_detail_id(id : Int64, store : Store) : Bool
      @detail = store.get_flow(id)
      return false if @detail.nil?
      if idx = @rows.index { |r| r.id == id }
        @selected = idx
        # A deep-linked OLDER flow must survive a live reload — otherwise follow mode snaps
        # @selected back to the tail on the next data_version tick, losing the anchor.
        @follow = false if idx != follow_index
      end
      # WebSocket flows (101) carry a captured message log; h2 flows link to their
      # connection's raw frame log. Both are loaded as a bounded most-recent window
      # (DETAIL_LOG_CAP) with the full count kept for the "older not loaded" note.
      load_detail_logs(store)
      @detail_scroll = 0
      detail_wrap_reset
      @detail_pane = initial_detail_pane
      @detail_focus = :strip # open lands on the strip (sub-tabs/chips); down-arrow enters the body
      drop_detail_cache
      @detail_hex = false # hex is a deliberate per-open peek — don't carry it into the next flow
      @detail_hex_bytes = nil
      @detail_read.reset
      true
    end

    def close_detail : Nil
      @detail = nil
      drop_detail_cache
      @detail_frames = nil # release the h2-frame / ws-message payload arrays (can be MiB)
      @detail_ws = nil
      @detail_frames_total = 0
      @detail_ws_total = 0
      @detail_sse = false
      @detail_saml = nil
      @detail_jwts = [] of Jwt::Found
      @detail_graphql = nil
      @detail_graphql_ws = [] of GraphqlWs::Frame
      @graphql_ws_len = -1
      @detail_form = nil
      @decoded_id = nil
      @detail_hex_bytes = nil
      @detail_read.reset
    end

    # Load @detail's WS/h2 logs as a bounded most-recent window + record full counts.
    # Reads @detail (both callers set it first); a frame/message-less flow → nil.
    private def load_detail_logs(store : Store) : Nil
      detail = @detail
      if detail && detail.row.status == 101
        @detail_ws = store.ws_messages(detail.row.id, DETAIL_LOG_CAP)
        @detail_ws_total = store.count_ws_messages(detail.row.id)
      else
        @detail_ws = nil
        @detail_ws_total = 0
      end
      if detail && (cid = detail.h2_conn_id)
        @detail_frames = store.h2_frames(cid, DETAIL_LOG_CAP)
        @detail_frames_total = store.count_h2_frames(cid)
      else
        @detail_frames = nil
        @detail_frames_total = 0
      end
      # SSE events are a derived view (parsed from the stored response body at
      # render time — no table), so here we only flag whether to offer the pane.
      @detail_sse = !!(detail && sse_response?(detail))
      decode_protocols(detail)
    end

    # The response is a Server-Sent Events stream (drives the EVENTS pane). Scans
    # the response head like grpc_body? — content-type may carry a charset param.
    private def sse_response?(detail : Store::FlowDetail) : Bool
      Sse.event_stream?(detail.response_head)
    end

    # Parse the optional decoded-protocol panes (SAML / JWT / GraphQL / PARAMS) ONCE
    # per opened flow — derived from the stored bytes, no table. Each result is cached
    # in an ivar; a nil/empty one means that pane isn't offered (see detail_panes).
    private def decode_protocols(detail : Store::FlowDetail?) : Nil
      unless detail
        @detail_saml, @detail_jwts, @detail_graphql, @detail_form = nil, [] of Jwt::Found, nil, nil
        @detail_graphql_ws = [] of GraphqlWs::Frame
        @graphql_ws_len = -1
        @decoded_id = nil
        return
      end
      # The HANDSHAKE panes (SAML / JWT / GraphQL body / PARAMS) read the request/response
      # bytes, which are immutable once captured — INCLUDING a 101 flow, whose handshake never
      # grows even though its message transcript does. So they re-decode only when the FLOW
      # changes or its own bytes are still arriving (a pending non-101 flow). Re-scanning a
      # multi-MiB body on every refresh poke bought nothing; the 101 exclusion that used to sit
      # here forced exactly that, because it made the whole method re-run for a WebSocket.
      if @decoded_id != detail.row.id || (!detail.row.state.complete? && detail.row.status != 101)
        tgt = detail.row.target
        rh, rb = detail.request_head, detail.request_body
        sh, sb = detail.response_head, detail.response_body
        @detail_saml = Saml.from_flow(tgt, rh, rb, sh, sb)
        @detail_jwts = Jwt.from_flow(tgt, rh, rb, sh, sb)
        @detail_graphql = Graphql.from_flow(tgt, rh, rb)
        @detail_form = FormData.from_flow(tgt, rh, rb)
        @decoded_id = detail.row.state.complete? ? detail.row.id : nil
        @graphql_ws_len = -1 # the flow changed → force the transcript pane to rebuild below
      end
      # The WS GraphQL pane is the one derived from a GROWING source, so it alone tracks the
      # transcript length: a busy socket left open re-parses its frames only when the window
      # actually gained rows, not on every poll. `load_detail_logs` fills @detail_ws before
      # this runs, so the count here is the same window the MESSAGES pane shows.
      ws = @detail_ws || [] of Store::WsMessage
      if @graphql_ws_len != ws.size
        @detail_graphql_ws = GraphqlWs.from_messages(ws)
        @graphql_ws_len = ws.size
      end
    end

    # The synthetic log panes (FRAMES / EVENTS) and the decoded-protocol panes render
    # as text and have no raw-byte hex view, unlike REQUEST/RESPONSE. The WebSocket
    # MESSAGES pane reuses the :response slot but is also a synthetic transcript (its
    # bytes live in the ws_messages table, NOT response_body), so it belongs here too —
    # otherwise x/w would fall back to hex/reveal of the bare 101 handshake head.
    private def log_pane? : Bool
      return true if ws_messages_pane?
      case @detail_pane
      when :frames, :events, :saml, :jwt, :graphql, :params then true
      else                                                       false
      end
    end

    # The :response pane renders the WebSocket message transcript (not the handshake
    # bytes) for a 101 flow — a synthetic log with no raw-byte hex/reveal view.
    private def ws_messages_pane? : Bool
      @detail_pane == :response && !@detail_ws.nil?
    end

    # 'x' toggles a raw hex dump of the current pane (request/response bytes).
    def toggle_detail_hex : Nil
      return if log_pane? # frames/events have no raw-bytes hex; don't strand a hidden flag
      @detail_hex = !@detail_hex
      @detail_scroll = 0 # row-based offset differs from the line-based one
      detail_wrap_reset
      @detail_read.reset
    end

    # Re-fetch the currently-open detail from the store (e.g. a peer instance filled
    # in the response, or appended ws/h2 frames) WITHOUT resetting the pane/scroll.
    # No-op when no detail is open. Returns true if it refreshed.
    def refresh_detail(store : Store) : Bool
      return false unless detail = @detail
      # A Complete, non-streaming flow's captured bytes are immutable (written once),
      # so a data_version poke from OTHER flows committing has nothing to pick up here.
      # Skipping avoids re-running the windowed/pretty body build on a stable open flow
      # every poll during a live capture. Pending flows (response still arriving) and
      # streaming flows — WebSocket (101) and HTTP/2, whose message/frame logs keep
      # growing — still refresh.
      return false if detail.row.state.complete? && detail.row.status != 101 && detail.h2_conn_id.nil?
      id = detail.row.id
      return false unless fresh = store.get_flow(id)
      @detail = fresh
      load_detail_logs(store)
      drop_detail_cache # content changed → rebuild (windowed) on next render
      @detail_hex_bytes = nil
      @detail_scroll = @detail_scroll.clamp(0, detail_scroll_max) # content may have shrunk
      true
    end

    def scroll_detail(delta : Int32) : Nil
      if detail_navigable?
        detail_move(delta, 0)
      else
        @detail_scroll = (@detail_scroll + delta).clamp(0, detail_scroll_max)
      end
    end

    # Home / End over the open detail: the caret to the LINE's start or end (`dir` < 0 / > 0),
    # extending the selection when `selecting`. False when this pane is not navigable text (the
    # hex dump), so the caller can fall through to the shell's page/jump keys.
    #
    # This pane had NO Home/End of its own, so both fell through to `Runner#page_nav_delta`'s
    # ±JUMP_ROWS and jumped the caret to the top/bottom of the body — and ⇧Home/⇧End did the
    # same and selected NOTHING, while the footer advertised "⇧arrows select". Every other
    # multi-line pane in the tree (Repeater, Notes, Issues, Project, Decoder, Fuzzer, and
    # `ReadPane#motion_key`) already spells Home/End as line-start/line-end with ⇧ extending;
    # this is that same keymap, and ⌃/⌥+Home/End keeps the buffer jump (the controller lets
    # the modified form fall through, matching `TextArea#handle_motion_key`).
    def detail_line_edge(dir : Int32, selecting : Bool = false) : Bool
      return false unless detail_navigable?
      size, line_at = detail_line_source
      return false if size <= 0
      cy = @detail_read.cy.clamp(0, size - 1)
      @detail_read.move_to(cy, dir < 0 ? 0 : line_at.call(cy).size, selecting: selecting)
      ensure_detail_visible(@detail_last_h) if @detail_last_h > 0
      true
    end

    # One screenful of the open detail, for ⇧PgUp/⇧PgDn. Same "minus a couple of rows of
    # overlap" step `ReadPane#motion_key` uses, measured from this pane's own last drawn height.
    def detail_page_rows : Int32
      {@detail_last_h - 2, 1}.max
    end

    # True when the detail is at its very top: caret on the FIRST VISUAL ROW of line 0
    # (navigable text) or the scroll offset pinned to 0 (hex dump). Mirrors the list's
    # at_top? so a ↑ here pops focus to the tab bar exactly as it does from the list's
    # first row. The sub-row half matters under wrap: a caret parked three rows into a
    # wrapped line 0 is not at the top, and popping focus from there would skip the very
    # rows the ↑ was asked to walk.
    def detail_at_top? : Bool
      return @detail_scroll == 0 unless detail_navigable?
      @detail_read.cy == 0 && detail_caret_sub == 0
    end

    # The caret's visual row WITHIN its logical line, or 0 when nothing has been laid out
    # yet (hex, or before the first frame published a content width).
    private def detail_caret_sub : Int32
      cw = @detail_last_cw
      return 0 if @detail_hex || cw <= 0 || !detail_wrap?
      size, line_at = detail_line_source
      return 0 if size <= 0 || @detail_read.cy >= size
      detail_layout(@detail_read.cy, cw, line_at).row_of(@detail_read.cx)
    end

    # READ-mode caret move (+ optional shift selection). Arrow keys / detail.up/down
    # route here when the pane is navigable text (not a raw hex dump).
    # Lazy (size + line_at): a vertical step only materialises the destination line —
    # never every BodyLines entry on a multi-MiB body.
    #
    # ↑/↓ step one VISUAL row (see `detail_visual_target`), so they walk the continuation
    # rows the pane is drawing instead of jumping over them to the next line number.
    def detail_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return unless detail_navigable?
      size, line_at = detail_line_source
      return if size <= 0
      if target = detail_visual_target(dr, size, line_at)
        @detail_read.move_to(target[0], target[1], selecting: selecting)
      else
        @detail_read.move(dr, dc, size, line_at, selecting)
      end
      ensure_detail_visible(@detail_last_h) if @detail_last_h > 0
    end

    # The caret `dr` visual rows away, or nil when this pane has no wrap to walk — hex draws
    # its own fixed rows, and before the first frame there is no content width to have laid
    # anything out at. The caller then steps logical lines, which is what a row is there.
    private def detail_visual_target(dr : Int32, size : Int32,
                                     line_at : Int32 -> String) : {Int32, Int32}?
      return nil if dr == 0 || @detail_hex || @detail_last_cw <= 0 || !detail_wrap?
      Wrap.step_caret(@detail_read.cy, @detail_read.cx, dr, size, line_at,
        detail_layout_fn(@detail_last_cw, line_at))
    end

    # Wheel: scroll the viewport by DRAWN rows without moving the caret (READ panes).
    # Still O(viewport) — the anchor walk never counts the pane's total rows (see
    # @detail_scroll_sub) and only the caret's line is materialised.
    def detail_scroll_view(step : Int32) : Nil
      return unless detail_navigable?
      size, line_at = detail_line_source
      return if @detail_last_h <= 0 || size <= 0
      cw = @detail_last_cw
      if cw <= 0 || !detail_wrap?
        return if size <= @detail_last_h
        @detail_scroll = (@detail_scroll + step).clamp(0, size - @detail_last_h)
        @detail_scroll_sub = 0 # no layout to carry a sub-row against (none yet, or wrap is off)
      else
        fn = detail_layout_fn(cw, line_at)
        @detail_scroll = @detail_scroll.clamp(0, size - 1)
        @detail_scroll, @detail_scroll_sub = if step < 0
                                               Wrap.step_back(@detail_scroll, @detail_scroll_sub, -step, fn)
                                             else
                                               Wrap.step_forward(@detail_scroll, @detail_scroll_sub, step, size, fn)
                                             end
        mli, msub = Wrap.max_anchor(size, @detail_last_h, fn)
        if @detail_scroll > mli || (@detail_scroll == mli && @detail_scroll_sub > msub)
          @detail_scroll = mli
          @detail_scroll_sub = msub
        end
      end
      # Pull the caret into the window, compared in VISUAL rows: a caret on the anchor LINE
      # can still be several wrapped rows above the anchor ROW, and a line-only clamp would
      # leave it there to drag the view straight back on the next ensure_detail_visible.
      rows = detail_rows(cw, @detail_last_h, size, line_at)
      if rows.empty?
        cy = @detail_read.cy.clamp(0, size - 1)
        @detail_read.sync(cy, @detail_read.cx.clamp(0, line_at.call(cy).size))
        return
      end
      first = rows[0]
      last = rows[rows.size - 1]
      cy = @detail_read.cy
      cx = @detail_read.cx
      if cy < first.li || (cy == first.li && cx < first.a)
        cy, cx = first.li, first.a
      elsif cy > last.li || (cy == last.li && cx > last.b)
        cy, cx = last.li, last.a
      end
      @detail_read.sync(cy, cx.clamp(0, line_at.call(cy).size))
    end

    # `selecting` is the DRAG half: the anchor stays where the press left it and the caret
    # follows the pointer, so a drag over the request/response text selects it — the mouse
    # spelling of the ⇧arrows this pane already had.
    #
    # The hit test is the wrap's inverse, not `@detail_scroll + row`: a screen row is a
    # VISUAL row now, and the continuation rows between it and the anchor are exactly what
    # the old arithmetic skipped.
    def detail_click_to_cursor(rect : Rect, mx : Int32, my : Int32, focused : Bool,
                               selecting : Bool = false) : Nil
      @detail_click_hit = false
      return unless focused && detail_navigable?
      size, line_at = detail_line_source
      return if rect.empty? || size <= 0
      # Render's own numbers, not a re-derivation — see @detail_last_gw. Falls back to the
      # gutter estimate only before the first frame, when nothing has been laid out yet.
      gw = @detail_last_cw > 0 ? @detail_last_gw : detail_gutter_w(rect, size)
      cw = @detail_last_cw > 0 ? @detail_last_cw : {rect.w - gw, 0}.max
      row = my - rect.y
      # A drag above the pane pins to its first visible row — the pointer left the top edge
      # with the button held, which is an upward selection, not a miss.
      if row < 0
        return unless selecting
        row = 0
      end
      rows = detail_rows(cw, rect.h, size, line_at)
      return if rows.empty?
      @detail_click_hit = true
      # `Wrap.row_index` clamps to the row it was given, so a click past the end of a wrapped
      # row stops at the break rather than selecting the next row's first char.
      vr = rows[row]? || rows[rows.size - 1]
      # `+ @detail_xscroll` puts the pointer back into the LINE's column space: it is 0 under
      # wrap and the columns panned off the left edge without it, so a click on a sideways-
      # scrolled line would land that many columns early.
      cx = Wrap.row_index(line_at.call(vr.li), nil, vr.a, vr.b,
        mx - (rect.x + gw) + detail_xscroll, nearest: true)
      if selecting
        @detail_read.move_to(vr.li, cx, selecting: true) # keeps (or plants) the anchor
      else
        @detail_read.clear_selection
        @detail_read.sync(vr.li, cx)
      end
      ensure_detail_visible(rect.h)
    end

    # Whether the last `detail_click_to_cursor` actually landed on the pane (as opposed to
    # returning early on a click outside it) — the double-click needs to tell "the caret did
    # not move because the pointer was already there" from "the click missed entirely".
    @detail_click_hit = false

    # Double-click: select the word under the pointer. The hit test is
    # `detail_click_to_cursor`'s (the pane's own wrap + windowed line source), so this only
    # has to supply the word spread. False when the pane is not navigable (the hex dump) or
    # the pointer is on whitespace — the caller then leaves the plain click's caret standing.
    def detail_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless detail_navigable?
      size, line_at = detail_line_source
      return false if rect.empty? || size <= 0
      detail_click_to_cursor(rect, mx, my, focused: true)
      return false unless @detail_click_hit
      hit = @detail_read.select_word_at_cursor(size, line_at)
      ensure_detail_visible(rect.h)
      hit
    end

    def detail_copy_text : String
      size, line_at = detail_line_source
      return "" if size <= 0
      @detail_read.selection_text(size, line_at) || @detail_read.current_line(size, line_at)
    end

    # The "copy as X" menu for the open detail pane: {picker title, options}. REQUEST
    # offers url/headers/body/cookies/curl/raw (parsed from the captured bytes + the
    # flow's target URL); RESPONSE offers status+headers/body/raw. Decoded panes
    # (SAML/JWT/…) and the hex dump have no format variants — an empty list there lets
    # the runner fall back to the plain selection copy.
    # Max flows a BYTE-CARRYING copy format (curl/raw) will span. ⇧T over a filtered list can
    # mark up to PAGE rows, and concatenating a thousand full head+body pairs into one
    # clipboard string is not a copy anyone asked for — above this those rows simply aren't
    # offered (CopyMenu already drops formats that don't apply). URLs/hosts stay uncapped:
    # they're a line each, and "the URLs of everything I marked" is the whole point.
    COPY_BYTES_CAP = 20

    # "Copy as…" for the LIST (#442) — the detail's twin above works per pane; this one works
    # per TARGET SET. One flow gets exactly the familiar single-message format list (so a
    # single-target copy-as behaves identically to the drill-in's REQUEST pane); N flows get
    # the set-shaped formats, since "copy the URLs" is what marking 12 rows is for.
    def list_copy_as_menu(store : Store, ids : Array(Int64)) : {String, Array(CopyMenu::Option)}
      return {"COPY AS", [] of CopyMenu::Option} if ids.empty?
      if ids.size == 1
        # Resolved through the store, not @rows: a mark can outlive the visible window.
        d = store.get_flow(ids.first)
        return {"COPY AS", [] of CopyMenu::Option} unless d
        req = request_wire(d)
        opts = CopyMenu.request_options(req, copy_target(d))
        # …plus the response, on the same 's' key the multi-flow set uses. Without it, marking a
        # SECOND flow would be the only way to reach the raw response, and the guide advertises
        # the format unconditionally. 's' rather than response_options' own keys because those
        # collide with the request list's 'h'/'b'/'r', and CopyPicker dispatches on unique keys.
        if bytes = combine_bytes(d.response_head, d.response_body)
          opts << CopyMenu::Option.new("Raw response", 's', String.new(bytes))
        end
        if pair = pair_option(d, req)
          opts << pair
        end
        return {"COPY REQUEST AS", opts}
      end
      # URLs and the host list need only the ROW, so read flow_row here — get_flow pulls the
      # full request+response bodies (2 MiB each), and ⇧T can hand this a full PAGE of marks.
      # Loading a thousand bodies to print a thousand URLs would freeze the render loop for the
      # duration of the keypress. The byte-carrying formats below load bodies only INSIDE the cap.
      rows = ids.compact_map { |id| store.flow_row(id) }
      return {"COPY AS", [] of CopyMenu::Option} if rows.empty?
      opts = [] of CopyMenu::Option
      urls = rows.map(&.url).reject(&.empty?)
      opts << CopyMenu::Option.new("URLs", 'u', urls.join('\n')) unless urls.empty?
      hosts = rows.map(&.host).reject(&.empty?).uniq!
      opts << CopyMenu::Option.new("Host list", 'h', hosts.join('\n')) unless hosts.empty?
      opts.concat(byte_copy_options(store, ids)) if rows.size <= COPY_BYTES_CAP
      {"COPY #{rows.size} FLOWS AS", opts}
    end

    # curl / raw-request / raw-response across the set. Only called within COPY_BYTES_CAP, so
    # this is the one place that loads N full details.
    private def byte_copy_options(store : Store, ids : Array(Int64)) : Array(CopyMenu::Option)
      details = ids.compact_map { |id| store.get_flow(id) }
      opts = [] of CopyMenu::Option
      # cURL comes from the SAME serialiser the single-flow path uses, via the narrow entry point
      # — request_options would allocate the headers/body/raw variants per flow too, several extra
      # copies of a multi-MiB body, for one line we keep.
      curls = details.compact_map { |d| CopyMenu.curl_text(request_wire(d), copy_target(d)) }
      opts << CopyMenu::Option.new("cURL", 'l', curls.join("\n\n")) unless curls.empty?
      # A raw HTTP message contains blank lines, so joining on one would be ambiguous about
      # where a message ends — each gets a labelled separator line instead. The message bytes
      # themselves are untouched (P7).
      {"Raw requests" => 'r', "Raw responses" => 's'}.each do |label, key|
        parts = details.compact_map do |d|
          bytes = key == 'r' ? combine_bytes(d.request_head, d.request_body) : combine_bytes(d.response_head, d.response_body)
          bytes ? "#{copy_separator(d.row)}\n#{String.new(bytes)}" : nil
        end
        opts << CopyMenu::Option.new(label, key, parts.join("\n\n")) unless parts.empty?
      end
      # The per-flow exchange (single-flow 'p'): request then response under one separator,
      # so a marked set pastes as N complete transactions rather than two disjoint lists.
      # A flow still in flight has no response — it contributes its request alone.
      pairs = details.compact_map do |d|
        next nil unless req = combine_bytes(d.request_head, d.request_body)
        res = combine_bytes(d.response_head, d.response_body)
        body = res ? "#{String.new(req)}\n\n#{String.new(res)}" : String.new(req)
        "#{copy_separator(d.row)}\n#{body}"
      end
      opts << CopyMenu::Option.new("Req + Res pairs", 'p', pairs.join("\n\n")) unless pairs.empty?
      opts
    end

    # The whole exchange — request, one blank line, response — both messages verbatim (P7).
    # Neither raw variant carries it, and it is what actually goes into a ticket or a note.
    # Offered wherever a SINGLE flow is in hand: the list menu and BOTH detail panes. The
    # detail's pane-local format list describes what that pane SHOWS; it is not a rule that
    # the exchange has to be reassembled by hand, and a flow you are staring at is exactly
    # when you want it whole. `req` is passed in where the caller already built it.
    private def pair_option(d : Store::FlowDetail, req : String? = nil) : CopyMenu::Option?
      request = req || request_wire(d)
      return nil if request.empty?
      res = combine_bytes(d.response_head, d.response_body)
      return nil unless res
      CopyMenu::Option.new("Req + Res pair", 'p', "#{request}\n\n#{String.new(res)}")
    end

    private def request_wire(d : Store::FlowDetail) : String
      String.new(combine_bytes(d.request_head, d.request_body) || Bytes.empty)
    end

    private def copy_target(d : Store::FlowDetail) : String
      Repeater::FlowRequest.build_target(d.row.scheme, d.row.host, d.row.port)
    end

    private def copy_separator(row : Store::FlowRow) : String
      "===== flow ##{row.id} #{row.method} #{row.url} ====="
    end

    def detail_copy_as_menu : {String, Array(CopyMenu::Option)}
      detail = @detail
      return {"COPY AS", [] of CopyMenu::Option} unless detail
      case @detail_pane
      when :request
        wire = String.new(combine_bytes(detail.request_head, detail.request_body) || Bytes.empty)
        row = detail.row
        target = Repeater::FlowRequest.build_target(row.scheme, row.host, row.port)
        opts = CopyMenu.request_options(wire, target)
        if pair = pair_option(detail, wire)
          opts << pair
        end
        {"COPY REQUEST AS", opts}
      when :response
        # The WS MESSAGES pane reuses the :response slot but renders the transcript
        # (ws_messages), NOT the bare 101 handshake that response_head/body still hold —
        # offering head/body variants here would copy the handshake (the same leak x/w
        # had before log_pane? gating). Empty list ⇒ copy_as falls back to the plain
        # selection copy, which yields the visible transcript via detail_copy_text.
        return {"COPY RESPONSE AS", [] of CopyMenu::Option} if ws_messages_pane?
        head = detail.response_head
        opts = if head
                 body = detail.response_body
                 CopyMenu.response_options(String.new(head), body ? String.new(body) : "")
               else
                 [] of CopyMenu::Option
               end
        # …and the exchange, on the same 'p' as everywhere else — the response pane is where
        # you decide a flow is worth reporting, and the request half is one pane away.
        if pair = pair_option(detail)
          opts << pair
        end
        {"COPY RESPONSE AS", opts}
      else
        {"COPY AS", [] of CopyMenu::Option}
      end
    end

    def detail_selection? : Bool
      detail_navigable? && @detail_read.selection?
    end

    def detail_select_line : Nil
      return unless detail_navigable?
      size, line_at = detail_line_source
      return if size <= 0
      @detail_read.select_line(size, line_at)
      ensure_detail_visible(@detail_last_h) if @detail_last_h > 0
    end

    def detail_clear_selection : Nil
      @detail_read.clear_selection
    end

    def detail_navigable? : Bool
      detail = @detail
      return false unless detail
      return false if detail_hex?(detail) # req/resp hex dump — scroll rows, no caret
      true
    end

    # Plain text lines for the active detail pane. Prefer `detail_line_source` on hot
    # paths (move/scroll/paint) so BodyLines stay lazy; this full array is for
    # rare full-materialise callers (e.g. selection span rebuild when selecting).
    private def detail_plain_lines : Array(String)
      if @reveal && (rl = reveal_lines)
        rl
      else
        dv = detail_view
        (0...dv.total).map { |i| dv.line_text(i) }
      end
    end

    # O(1) total + lazy line fetch for caret/scroll/copy on windowed req/resp bodies.
    private def detail_line_source
      if @reveal && (rl = reveal_lines)
        {rl.size, ->(i : Int32) { rl[i] }}
      else
        dv = detail_view
        {dv.total, ->(i : Int32) { detail_line_text(dv, i) }}
      end
    end

    # One-entry memo over `DetailView#line_text`. A BODY line is materialised out of the raw
    # capture bytes on EVERY call (`String.new` + `scrub` + `rstrip`), and a single frame asks
    # for the same line up to four times — the row list, the h-scroll clamp, the caret and
    # selection chrome, and the search overdraw. On a minified body that ONE line is megabytes,
    # so the repeat is most of the frame: a 1 MB single-line body cost 16.5 ms per frame with
    # the caret elsewhere in the document and 1.0 ms with this memo.
    #
    # ONE entry, not a cache: every consumer above asks about the same line the draw is on, and
    # a windowful of distinct lines would be a windowful of live megabyte strings.
    #
    # Invalidated exactly where the WRAP memo is (`detail_wrap_reset`, `drop_detail_cache`),
    # for exactly its reason: both are keyed by line INDEX alone, so new content at the same
    # index would otherwise be handed the old line's text — and then the old line's breaks.
    private def detail_line_text(dv : DetailView, i : Int32) : String
      return @detail_text if @detail_text_i == i
      @detail_text_i = i
      @detail_text = dv.line_text(i)
    end

    private def detail_gutter_w(body : Rect, total : Int32) : Int32
      return 0 unless Settings.show_gutter # keep click→cursor mapping aligned with the gutter-less render
      {Gutter.width(total), body.w}.min
    end

    # Keep the caret's VISUAL row inside the pane. Line-indexed scrolling drifts the moment
    # anything wraps — the caret can be on the anchor line and still be a dozen drawn rows
    # off-screen — so the comparison and the re-anchor both happen in rows (Wrap). Falls back
    # to the line-based arithmetic before the first render, when no width is known yet and
    # nothing has been laid out to disagree with.
    private def ensure_detail_visible(view_h : Int32) : Nil
      return if view_h <= 0
      cy = @detail_read.cy
      cw = @detail_last_cw
      size, line_at = detail_line_source
      if @detail_hex || cw <= 0 || size <= 0 || !detail_wrap?
        if cy < @detail_scroll
          @detail_scroll = cy
        elsif cy >= @detail_scroll + view_h
          @detail_scroll = cy - view_h + 1
        end
        @detail_scroll = 0 if @detail_scroll < 0
        # The horizontal half, and the ONLY way sideways here: this pane has never had an
        # h-scroll binding (`verbs/history.cr` says so), so ⇧←/→ moves the caret and the
        # view has to come with it. Hex draws its own fixed rows and never pans.
        ensure_detail_visible_x(cw, size, line_at) unless @detail_hex
        return
      end
      @detail_xscroll = 0 # nothing sits off to the side of a wrapped row
      @detail_scroll = @detail_scroll.clamp(0, size - 1)
      fn = detail_layout_fn(cw, line_at)
      csub = fn.call(cy.clamp(0, size - 1)).row_of(@detail_read.cx)
      @detail_scroll, @detail_scroll_sub =
        Wrap.ensure_visible(@detail_scroll, @detail_scroll_sub, cy.clamp(0, size - 1), csub, view_h, fn)
    end

    # Slide @detail_xscroll so the caret column stays inside [xscroll, xscroll + cw). Only ever
    # reached with wrap off — the wrapped branch above returns before it, and `render` pins the
    # offset to 0 there.
    #
    # `Wrap.row_col` is the measure, not a second one of its own: it is what `Highlight.draw`
    # advances by and what `Highlight.slice_left` consumes the offset in. The pre-wrap pane
    # carried the bug that comes from getting this wrong — a `display_width` clamp scoring a tab
    # as 0 columns clawed the offset back every frame, so a tabbed line's caret could never
    # scroll into view at all. The "is it even too wide" test stops counting at cw + 1 columns,
    # so a multi-MiB minified line is never measured whole just to answer "wider than the pane".
    # THE only writer of `@detail_xscroll`, deliberately. The pre-wrap pane had this AND a
    # per-frame clamp against the widest row on screen, and the two moved the same field in
    # opposite directions: the clamp's ceiling is `widest - cw`, one column short of what an
    # END-OF-LINE caret needs (it sits one past the last char), so on the widest visible line
    # the caret was pushed off the pane and vanished — and on a tabbed line the two measures
    # disagreed outright. Caret-follow needs no help: it resets to 0 the moment the line fits,
    # and otherwise pins the offset inside [curx - cw + 1, curx], which is by construction a
    # valid window into that line. Dropping the clamp also drops an O(widest) walk per frame.
    private def ensure_detail_visible_x(cw : Int32, size : Int32, line_at : Int32 -> String) : Nil
      if cw <= 0 || size <= 0
        @detail_xscroll = 0
        return
      end
      line = line_at.call(@detail_read.cy.clamp(0, size - 1))
      if Screen.draw_width_upto(line, cw + 1) <= cw
        @detail_xscroll = 0 # the line fits whole — never hold an offset for it
        return
      end
      curx = Wrap.row_col(line, nil, 0, @detail_read.cx.clamp(0, line.size))
      @detail_xscroll = curx if curx < @detail_xscroll
      @detail_xscroll = curx - cw + 1 if curx >= @detail_xscroll + cw
      @detail_xscroll = 0 if @detail_xscroll < 0
    end

    # --- detail soft wrap ------------------------------------------------------

    # Ceiling on the detail wrap memo — see RepeaterView::RESP_WRAP_CACHE_CAP, same reasoning.
    DETAIL_WRAP_CACHE_CAP = 512

    # Whether the detail body lays a long line out as continuation rows (`Settings.wrap_lines?`,
    # Preferences ▸ Appearance ▸ Display) or as one row per line with the tail off to the right.
    # Read LIVE at every mapping rather than latched, so the toggle lands on the next frame; the
    # memo survives the flip untouched because a `Wrap::Layout` is a pure function of (line,
    # width) and is simply not consulted while wrap is off.
    private def detail_wrap? : Bool
      Settings.wrap_lines?
    end

    # The h-scroll offset AS THE ACTIVE MODEL SEES IT: the stored field while the pane draws one
    # row per line, 0 while it wraps. Every consumer — the draw's left slice, the caret, the
    # selection band, the click inverse — goes through here, so none of them can act on state
    # the other model owns. The field itself is only reeled in by `ensure_detail_visible_x`,
    # which does not run on an UNFOCUSED pane: without this gate, turning wrap back on while
    # some other pane held focus would slice every wrapped row left by a dead offset.
    private def detail_xscroll : Int32
      detail_wrap? ? 0 : @detail_xscroll
    end

    # Drop the wrap memo and put the anchor back on a first row — BOTH halves of it, since the
    # live preference decides which one is in use. Called from every site that swaps what the
    # pane is showing (a fresh open, a pane/hex/reveal/pretty toggle) — the same sites that used
    # to zero the horizontal offset, which is not a coincidence: those are exactly the moments
    # the old layout stops describing the pane.
    private def detail_wrap_reset : Nil
      @detail_scroll_sub = 0
      @detail_xscroll = 0
      @detail_wrap.clear
      @detail_text_i = -1 # keyed by line index like the wrap memo — see `detail_line_text`
    end

    # Publish the geometry the active detail pane just drew with, so hit-testing and the
    # scroll walkers key the wrap memo on exactly the width the rows were laid out at.
    private def detail_record_metrics(gw : Int32, cw : Int32) : Nil
      @detail_last_gw = gw
      @detail_last_cw = cw
    end

    private def detail_layout(li : Int32, cw : Int32, line_at : Int32 -> String) : Wrap::Layout
      if @detail_wrap_w != cw
        @detail_wrap.clear
        @detail_wrap_w = cw
      end
      if hit = @detail_wrap[li]?
        return hit
      end
      @detail_wrap.clear if @detail_wrap.size >= DETAIL_WRAP_CACHE_CAP
      @detail_wrap[li] = Wrap.layout(line_at.call(li), cw)
    end

    private def detail_layout_fn(cw : Int32, line_at : Int32 -> String) : Int32 -> Wrap::Layout
      ->(i : Int32) { detail_layout(i, cw, line_at) }
    end

    # The detail pane's drawn rows for an `h`-row viewport at content width `cw`. Without wrap
    # this is the identity the pane had before it learned to wrap — one row per logical line
    # from the anchor, holding the WHOLE line — and the horizontal offset is applied at the
    # draw instead (see `render_detail_body`), which is what keeps every consumer of these rows
    # (the click inverse, the caret, the selection band, the search overdraw) on one model.
    private def detail_rows(cw : Int32, h : Int32, size : Int32,
                            line_at : Int32 -> String) : Array(Wrap::Row)
      return [] of Wrap::Row if size <= 0 || h <= 0 || cw <= 0
      @detail_scroll = @detail_scroll.clamp(0, size - 1)
      unless detail_wrap?
        @detail_scroll = @detail_scroll.clamp(0, {size - h, 0}.max)
        return Wrap.plain_rows(@detail_scroll, h, size, line_at)
      end
      Wrap.rows(@detail_scroll, @detail_scroll_sub, h, size, detail_layout_fn(cw, line_at))
    end

    # ^G go-to-line in the detail view: scroll so 1-based line `n` is at the top
    # (interpreted in the active pane/mode — request/response/frames/hex row). Hex
    # has no caret; in navigable (cursor-tracked) modes, sync @detail_read too —
    # otherwise the first ↑/↓ after the jump moves from the caret's stale pre-jump
    # position instead of the line just jumped to.
    def goto_detail_line(n : Int32) : Nil
      if detail_navigable?
        size, _ = detail_line_source
        return if size <= 0
        cy = (n - 1).clamp(0, size - 1)
        @detail_read.sync(cy, 0)
        @detail_scroll = cy
        @detail_scroll_sub = 0 # ^G names a LOGICAL line, so land on its first visual row
      else
        @detail_scroll = (n - 1).clamp(0, detail_scroll_max)
      end
    end

    # ^F search: 0-based indices of the detail text lines containing `query` (case-
    # insensitive). Empty in hex mode (the hex view has no text lines).
    setter search_hl : String

    # Reveal-whitespace renders on a separate path with a different (usually much
    # shorter) line count than the normal/pretty view, so toggling it must reset
    # the scroll offset — otherwise a stale offset left over from scrolling the
    # longer view blanks the revealed pane (it has nothing to render that far down).
    # Change-detected because the runner pushes this every frame.
    def reveal=(on : Bool) : Nil
      return if @reveal == on
      @reveal = on
      @detail_scroll = 0
      # Reveal renders on its own line space, so the memo (keyed only by line index and
      # width) would hand the new path the OLD lines' layouts. drop_detail_cache is not on
      # this path — it clears the windowed view, which reveal doesn't use — so reset here.
      detail_wrap_reset
      @detail_read.reset
    end

    # Pretty toggle feeds `build_detail_view`, so a change must drop the windowed
    # cache (unlike reveal/hex, which render on separate paths). Change-detected
    # because the runner pushes this every frame.
    def pretty=(on : Bool) : Nil
      return if @pretty == on
      @pretty = on
      drop_detail_cache
      @detail_scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like hex/pane toggles)
      detail_wrap_reset
      @detail_read.reset
    end

    # Revealed (whitespace-visible) lines of the current pane, cached + rebuilt only
    # when the pane bytes change (compared by pointer — detail_pane_bytes memoizes).
    private def reveal_lines : Array(String)?
      bytes = detail_pane_bytes
      return nil unless bytes
      cached = @reveal_lines
      return cached if cached && @reveal_lines_src == bytes.to_unsafe
      @reveal_lines_src = bytes.to_unsafe
      @reveal_lines = Reveal.lines(bytes)
    end

    def detail_search_lines(query : String) : Array(Int32)
      hits = [] of Int32
      # FRAMES has no hex view, so it renders as text even when @detail_hex is set —
      # match the render/goto predicate so search agrees (not a bare @detail_hex).
      return hits if query.empty? || (@detail_hex && !log_pane?)
      q = query.downcase
      # Reveal-whitespace renders on its OWN line space (raw head+body bytes) with its own
      # scroll bounds (detail_scroll_max). Search must scan reveal_lines so the hit indices
      # match what goto_detail_line scrolls to — mirroring the hex exclusion above (the
      # decoded/pretty detail_view has a different line count, so its indices would scroll wrong).
      if @reveal && (rl = reveal_lines)
        rl.each_with_index { |ln, i| hits << i if ln.downcase.includes?(q) }
        return hits
      end
      dv = detail_view
      (0...dv.total).each { |i| hits << i if dv.line_text(i).downcase.includes?(q) }
      hits
    end

    private def detail_scroll_max : Int32
      if @detail_hex && (bytes = detail_pane_bytes)
        {HexView.rows(bytes.size) - 1, 0}.max
      elsif @reveal && (rl = reveal_lines)
        {rl.size - 1, 0}.max
      else
        {detail_view.total - 1, 0}.max
      end
    end

    # Whether the current pane supports the hex view (raw request/response bytes;
    # the FRAMES pane is a synthetic log, not raw bytes).
    private def detail_hex?(detail : Store::FlowDetail) : Bool
      @detail_hex && !log_pane?
    end

    # Combined head+body bytes for the current pane (the hex source), cached — built
    # only while hex is shown, invalidated on detail/pane change.
    private def detail_pane_bytes : Bytes?
      return @detail_hex_bytes if @detail_hex_bytes
      detail = @detail
      return nil unless detail
      head, body = case @detail_pane
                   when :response then ws_messages_pane? ? {nil, nil} : {detail.response_head, detail.response_body}
                   when :request  then {detail.request_head, detail.request_body}
                   else                {nil, nil} # frames/messages: no raw-bytes hex
                   end
      @detail_hex_bytes = combine_bytes(head, body)
    end

    private def combine_bytes(head : Bytes?, body : Bytes?) : Bytes?
      return nil if head.nil? && (body.nil? || body.empty?)
      return head || Bytes.empty if body.nil? || body.empty?
      return body if head.nil?
      io = IO::Memory.new(head.size + body.size)
      io.write(head)
      io.write(body)
      io.to_slice
    end

    # The detail sub-panes, in order: REQUEST → RESPONSE → decoded-protocol panes
    # (SAML/JWT/GRAPHQL/PARAMS, each present only when the flow carries one) → EVENTS
    # (sse) → FRAMES (intercepted h2). ←/→ walk this chain; Tab cycles it.
    private def detail_panes : Array(Symbol)
      panes = [:request, :response]
      panes << :saml if @detail_saml                                     # decoded SAML XML (request/response)
      panes << :jwt unless @detail_jwts.empty?                           # located + decoded JWT(s)
      panes << :graphql if @detail_graphql || !@detail_graphql_ws.empty? # parsed GraphQL operation (body or WS frames)
      panes << :params if @detail_form                                   # decoded form/multipart params
      panes << :events if @detail_sse                                    # parsed SSE events (text/event-stream response)
      panes << :frames if @detail_frames
      panes
    end

    # The chip label for a detail pane (the response pane shows WS messages for a
    # 101-Switching flow; frames only exist for an intercepted h2 connection).
    private def detail_pane_label(pane : Symbol) : String
      case pane
      when :frames   then "FRAMES (h2)"
      when :events   then "EVENTS (sse)"
      when :saml     then "SAML"
      when :jwt      then @detail_jwts.size > 1 ? "JWT (#{@detail_jwts.size})" : "JWT"
      when :graphql  then "GRAPHQL"
      when :params   then "PARAMS"
      when :response then @detail_ws ? "MESSAGES" : "RESPONSE"
      else                "REQUEST"
      end
    end

    private def set_detail_pane(pane : Symbol) : Nil
      @detail_pane = pane
      @detail_scroll = 0
      detail_wrap_reset
      drop_detail_cache       # pane switch changes the content
      @detail_hex_bytes = nil # …and the hex source bytes
      @detail_read.reset
    end

    # Public wrapper around the private set_detail_pane — lets the Runner switch
    # panes from a chip click (it ignores an unknown/inactive pane symbol).
    def set_detail_pane_public(pane : Symbol) : Nil
      set_detail_pane(pane) if detail_panes.includes?(pane)
    end

    # Two-level detail focus: the chip row (:strip) vs the caret/text body (:body).
    # ←/→ switch panes at the strip level and move the caret at the body level; the
    # split is invisible to the verb layer (current_scope keys off @overlay only).
    def detail_strip_focus? : Bool
      @detail_focus == :strip
    end

    def set_detail_focus(f : Symbol) : Nil
      @detail_focus = f
    end

    # Tab: cycle forward through the panes, wrapping back to REQUEST.
    def toggle_pane : Nil
      panes = detail_panes
      i = panes.index(@detail_pane) || 0
      set_detail_pane(panes[(i + 1) % panes.size])
    end

    # ←/→ navigation: step one pane in `dir` (+1 forward REQ→RES→FRAMES, −1 back).
    # Returns false when it would step off an end — the Runner closes the detail on a
    # left-past-REQUEST (back to the list) and no-ops a right-past-FRAMES.
    def detail_pane_advance(dir : Int32) : Bool
      panes = detail_panes
      i = (panes.index(@detail_pane) || 0) + dir
      return false if i < 0 || i >= panes.size
      set_detail_pane(panes[i])
      true
    end

    # --- rendering -----------------------------------------------------------

    def render_list(screen : Screen, rect : Rect, focused : Bool = true, *,
                    listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      list_rect, preview_rect = list_split(rect)
      # No preview pane at this size (or after a resize down — list_split collapses it below
      # rect.h 12, i.e. any terminal under 20 rows) ⇒ snap focus back to the list, or
      # move()/scroll would route arrows to an invisible pane and freeze list navigation.
      # HistoryController#refresh_preview re-homes focus when the preview PREF goes off; the
      # SIZE removing the pane has no other place to be heard (mirrors ProbeView#render).
      @preview_focus = :list if preview_rect.nil?
      render_list_body(screen, list_rect, focused, listen: listen, capturing: capturing)
      render_preview_pane(screen, preview_rect, focused) if preview_rect
    end

    # The list, then the `↓` dropdown OVER it. Split so the popup is drawn last unconditionally:
    # the body below returns early on several paths (no rows, the empty-state card), and a
    # dropdown that vanished exactly when the filter matched nothing would be missing from the
    # one moment an operator is most likely to be fixing a query.
    private def render_list_body(screen : Screen, rect : Rect, focused : Bool, *,
                                 listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_list_rows(screen, rect, focused, listen: listen, capturing: capturing)
      render_query_popup(screen, rect)
    end

    # Anchored under the suggestion row (so it never covers the inline hint it expands on) and
    # bounded by the list, which is the only region it is allowed to occlude.
    private def render_query_popup(screen : Screen, rect : Rect) : Nil
      return unless @querying && @popup.open?
      # `list_top`, not the row under the bar: the column header and its divider sit between the
      # two, and a card straddling them reads as a rendering fault rather than a menu. The list
      # is also the only region this is allowed to cover.
      top = list_top(rect)
      anchor_y = top - 1
      bounds = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
      # Anchored at the START of the query text, not at the token's offset within it.
      # `Screen#input_line` scrolls its window horizontally once the query outgrows the bar, so
      # `base + token.start` stops being the token's screen column on exactly the long queries
      # where precision would matter — the card would drift right of what it completes and then
      # clamp. A fixed anchor is always adjacent to the bar and never lies.
      @popup.render(screen, rect.x + 1 + QUERY_PREFIX.size, anchor_y, bounds)
    end

    private def render_list_rows(screen : Screen, rect : Rect, focused : Bool, *,
                                 listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      render_ql_bar(screen, rect)
      hdr_y = rect.y + 1
      if @querying
        render_suggestions(screen, rect, hdr_y)
        hdr_y += 1
      end

      # Colormarker's `strip` column: ONE cell of colour between the cursor gutter (rect.x,
      # which already carries ▎/▌) and TIME, plus a one-column gap so the swatch does not fuse
      # with the cursor bar into a single two-cell block of mixed colour.
      #
      # Reserved ONLY while an enabled `strip` rule exists. Always-on would charge EVERY session
      # two columns of the fixed left block for a default-hidden feature — and at 65 columns
      # those two are the DUR column. The cost is that arming a strip rule shifts the columns by
      # two, which happens on a deliberate edit on another tab and IS the feedback that the rule
      # took; this list already relayouts on width (the STA/TYPE/SIZE/DUR cluster) and on `/`
      # (the suggestion row). It also means a HistoryView with no engine renders exactly as it
      # did before this feature existed.
      sw = @colormarker.try(&.strip_active?) ? STRIP_W : 0
      strip_x = rect.x + 1
      time_x = rect.x + 1 + sw
      method_x = rect.x + 16 + sw # time column widened to fit MM-DD HH:MM:SS
      proto_x = rect.x + 24 + sw
      host_x = rect.x + 31 + sw
      # Right cluster STA · TYPE · SIZE · DUR (status code, response MIME, size,
      # latency — frequently-scanned), anchored to the right edge and sized to FIT:
      # STA always shows; TYPE/SIZE/DUR drop right-to-left when the pane is too narrow
      # to also keep HOST+PATH legible, so the cluster never spills past the frame.
      # (Each span includes its trailing 1-col gap.) HOST+PATH split the rest.
      cluster_w = 4                                # STA (3-digit code + gap)
      spare = rect.right - host_x - 18 - cluster_w # reserve 18 for HOST+PATH first
      if show_type = spare >= 7
        cluster_w += 7
        spare -= 7
      end
      if show_size = spare >= 7
        cluster_w += 7
        spare -= 7
      end
      show_dur = spare >= 6
      cluster_w += 6 if show_dur

      status_x = {rect.right - cluster_w, host_x}.max
      type_x = status_x + 4
      size_x = status_x + 11
      dur_x = status_x + 18
      mid = {status_x - host_x, 0}.max
      host_w = {(mid * 2 // 5).clamp(6, 40), mid}.min # never crosses STA even when pinned
      path_x = host_x + host_w + 1
      path_w = {status_x - path_x - 1, 0}.max

      screen.text(time_x, hdr_y, "TIME", Theme.muted)
      screen.text(method_x, hdr_y, "METHOD", Theme.muted)
      screen.text(proto_x, hdr_y, "PROTO", Theme.muted)
      screen.text(host_x, hdr_y, "HOST", Theme.muted, width: host_w) if host_w > 0
      screen.text(path_x, hdr_y, "PATH", Theme.muted, width: path_w) if path_w > 0
      screen.text(status_x, hdr_y, "STA", Theme.muted, width: 3)
      screen.text(type_x, hdr_y, "TYPE", Theme.muted, width: 6) if show_type
      screen.text(size_x, hdr_y, "SIZE", Theme.muted, width: 6) if show_size
      screen.text(dur_x, hdr_y, "DUR", Theme.muted, width: 6) if show_dur
      Frame.inner_divider(screen, rect, hdr_y + 1, border: Frame.pane_border(focused))

      list_top = hdr_y + 2
      list_h = {rect.bottom - list_top, 0}.max
      ensure_visible(list_h)

      if @rows.empty?
        # Mirror Issues/Probe: a recovery hint under the message. The QL-clear
        # cue only applies to a real query (not a Scope-lens-only empty set, which
        # ⇧S toggles off), so branch on @querying / @query before filtering?.
        # Branch on a real `/` query FIRST (querying-aware hint): a blank-query empty
        # set is caused by the Scope lens or no traffic, where "esc clears the filter"
        # would mislead (⇧S clears the lens). Mirrors sitemap_view's ordering.
        msg, hint =
          if !@query.blank?
            # An INVALID query (all terms bad, or a broken regex) reads as "no flows match"
            # unless we say why — @query_note distinguishes it from a genuine empty result.
            {@query_note || "no flows match", @querying ? "esc clears the filter" : "/ to edit the filter"}
          elsif filtering? # in-scope subset is empty (Scope lens, no QL query)
            {"no flows in scope", "⇧S clears the scope lens"}
          else
            list_rect = Rect.new(time_x, list_top, rect.right - time_x, list_h)
            TrafficEmptyState.render(screen, list_rect, variant: :history, listen: listen, capturing: capturing)
            return
          end
        screen.text(time_x, list_top, msg, Theme.muted)
        screen.text(time_x, list_top + 2, hint, Theme.muted) if list_h > 2
        return
      end

      prefetch_colors(list_h)

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @rows.size
        row = @rows[ri]
        y = list_top + i
        selected = ri == @selected
        # A marked row (#442) reads as a dim band with a FULLER gutter bar, so it stays
        # distinguishable from the cursor row (which keeps the accent band) and from a
        # cursor row that is ALSO marked (accent band + full bar). Both glyphs are
        # single-width, so no column offset moves — list_top/list_row_at stay valid.
        marked = @marks.includes?(row.id)
        # PROTO is classified here rather than at its own column below, because Colormarker
        # needs it to build the match subject and classifying twice per row per frame is waste.
        kind = Proto.classify(row.status, row.content_type, row.request_content_type)
        mark = color_for(row, kind)
        base = if selected
                 focused ? Theme.accent_bg : Theme.selection_dim
               elsif marked
                 Theme.selection_dim
               else
                 Theme.bg
               end
        # A `full` rule MIXES its hue into whatever band the row would already have; it never
        # replaces it. The band is a lightness step (canvas → dim → accent) and the rule is a
        # hue, so the two compose: a selected coloured row keeps the accent band's brightness
        # AND gains the hue, and a marked one keeps the dim band plus its fuller ▌ bar.
        # Replacing the band would make "this is the cursor row" invisible on every coloured
        # row — the one state the operator navigates by.
        bg = (m = mark) && m.style.full? ? Theme.row_tint(Theme.mark_color(m.color), base) : base
        fg = selected || marked ? Theme.text_bright : Theme.text

        # The fill guard covers a TINTED row too, not just a selected/marked one: without it the
        # tint would land only in the cells that pass an explicit bg and the gaps between
        # columns would stay on the canvas — a striped row rather than a band.
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg) if selected || marked || bg != Theme.bg
        screen.cell(rect.x, y, marked ? '▌' : '▎', Theme.accent, bg) if selected || marked
        # Drawn AFTER the band fill, so on a selected or marked row this one cell overwrites the
        # band and the rule's colour survives at full saturation — which is what makes "selected
        # AND red" read as both rather than as a slightly-tinted cursor row. A '█' on the row's
        # own bg (not a space with a coloured background) composes correctly over a `full` tint
        # and never punches a hole in the selection band.
        if sw > 0 && (m = mark) && m.style.strip?
          screen.cell(strip_x, y, '█', Theme.mark_color(m.color), bg)
        end
        screen.text(time_x, y, fmt_time(row.created_at), Theme.muted, bg)
        # METHOD is a FIXED 8-column cell (method_x .. proto_x), so it needs its own clamp —
        # without a `width:` the limit is the whole SCREEN. RFC 9110 permits any token here and
        # the parser caps nothing, so a long method (`VERSION-CONTROL`, a smuggled
        # `X-CUSTOM-METHOD`) ran straight through PROTO/HOST/PATH.
        #
        # 8, not the 7-in-8 the neighbouring cells use. PROTO is drawn at its own absolute
        # `proto_x`, so a full 8 cannot bleed into it — the only thing 7 buys is a blank gap,
        # and it costs `PROPFIND` and `CHECKOUT`, both exactly 8 and both methods this tool is
        # pointed at (WebDAV, DeltaV). Truncating a real method the unclamped code rendered
        # correctly would be a regression introduced by the clamp; a tight column is not.
        screen.text(method_x, y, row.method, Theme.method_color(row.method), bg, width: 8)
        # PROTO: surface WS/GRPC/SSE (accented so they pop out of the HTTP stream), each
        # carrying the plaintext-vs-TLS signal the HTTP/HTTPS pair has always carried —
        # `Proto::Kind#label` owns that spelling, because a bare WS tag REPLACED the scheme
        # and made a `ws://` row and a `wss://` row byte-identical here. (`kind` is classified
        # at the top of the row, where Colormarker also needs it.)
        # A short-circuited flow says so IN the PROTO column, replacing HTTP/HTTPS (#511).
        # That column already answers "what kind of exchange was this", and for a stub the
        # honest answer is that it was not an exchange at all — gori wrote the response from
        # a rule and no origin was dialed. It has to displace the scheme rather than sit
        # beside it: the row is fixed-width, and a marker that drops off a narrow terminal is
        # a marker that lets someone screenshot a finding the server never took part in. The
        # scheme is still on the row's URL and in the detail pane. Yellow, like #507's
        # `bypass:N` chip — "you are not seeing what you think", not a blocked/failed state.
        stub = row.short_circuited?
        proto_label = stub ? "STUB" : kind.label(row.scheme)
        proto_color = stub ? Theme.yellow : (kind.http? ? Theme.muted : Theme.accent)
        screen.text(proto_x, y, proto_label, proto_color, bg)
        screen.text(host_x, y, row.host, fg, bg, width: host_w) if host_w > 0
        screen.text(path_x, y, Url.origin_path(row.target), fg, bg, width: path_w) if path_w > 0
        # Failed flows store status 0 — FlowStatus shows the STATE (ERR/ABT) instead of
        # a cryptic "0" indistinguishable from a still-pending "···".
        status, scolor = FlowStatus.cell(row)
        screen.text(status_x, y, status, scolor, bg, width: 3)
        screen.text(type_x, y, fmt_mime(row.content_type), Theme.muted, bg, width: 6) if show_type
        screen.text(size_x, y, fmt_size(row.response_size), Theme.muted, bg, width: 6) if show_size
        screen.text(dur_x, y, fmt_dur(row.duration_us), Theme.muted, bg, width: 6) if show_dur
      end
      # The busiest list in gori, and it had no position feedback at all: a 12-row window over
      # 400 flows looked exactly like a 12-row window over 12. `rect` is the framed interior,
      # so `rect.right` is the frame's own hairline — where `scroll_gauge` draws.
      Frame.scroll_gauge(screen, Rect.new(rect.x, list_top, rect.w, list_h),
        @rows.size, @scroll, focused)
    end

    # Bottom preview pane: REQUEST | RESPONSE for the selected flow (settings:layout).
    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      # Seam between list and preview: must use the same border colour as the enclosing
      # framed card (pane_border(focused)), or ├ / ┤ sit as grey nubs on a gold frame.
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      detail = @preview_detail
      unless detail
        screen.text(rect.x + 1, rect.y + 1, "preview — select a flow", Theme.muted, width: {rect.w - 2, 0}.max)
        return
      end
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      if body.w >= 60
        half = body.w // 2
        left = Rect.new(body.x, body.y, half, body.h)
        right = Rect.new(body.x + half, body.y, body.w - half, body.h)
        # Vertical hairline between Req and Res; top cell sits on the horizontal seam as ┬.
        screen.cell(body.x + half, rect.y, '┬', border)
        (0...body.h).each { |i| screen.cell(body.x + half, body.y + i, '│', border) }
        render_preview_side(screen, left, "REQUEST", @preview_req_lines,
          @preview_scroll_req, active: focused && @preview_focus == :req)
        render_preview_side(screen, right, "RESPONSE", @preview_res_lines,
          @preview_scroll_res, active: focused && @preview_focus == :res)
      else
        # Stack Req above Res; reserve one row for a tee-joined mid seam when height allows.
        if body.h >= 3
          half_h = body.h // 2
          mid_y = body.y + half_h
          top = Rect.new(body.x, body.y, body.w, half_h)
          bot = Rect.new(body.x, mid_y + 1, body.w, body.h - half_h - 1)
          Frame.inner_divider(screen, rect, mid_y, border: border)
          render_preview_side(screen, top, "REQUEST", @preview_req_lines,
            @preview_scroll_req, active: focused && @preview_focus == :req)
          render_preview_side(screen, bot, "RESPONSE", @preview_res_lines,
            @preview_scroll_res, active: focused && @preview_focus == :res) if bot.h > 0
        else
          render_preview_side(screen, body, "REQUEST", @preview_req_lines,
            @preview_scroll_req, active: focused && @preview_focus == :req)
        end
      end
    end

    private def render_preview_side(screen : Screen, rect : Rect, title : String,
                                    lines : Array(String)?, scroll : Int32, *, active : Bool) : Nil
      return if rect.empty?
      bg = active ? Theme.selection_dim : Theme.bg
      screen.fill(rect, bg) if active
      # `▎` in the marker column, not trailing the title — this was the one place in gori
      # where the bar followed its label instead of leading the row. Written on both states so
      # the title sits at the same column either way.
      screen.cell(rect.x, rect.y, active ? '▎' : ' ', Theme.accent, bg)
      screen.text(rect.x + 1, rect.y, " #{title} ", active ? Theme.accent : Theme.muted, bg, attr: Attribute::Bold)
      lines ||= ["(empty)"]
      content_y = rect.y + 1
      content_h = {rect.bottom - content_y, 0}.max
      return if content_h <= 0
      sc = scroll.clamp(0, {lines.size - 1, 0}.max)
      w = {rect.w - 2, 0}.max
      (0...content_h).each do |i|
        li = sc + i
        break if li >= lines.size
        screen.text(rect.x + 1, content_y + i, lines[li], Theme.text, bg, width: w)
      end
      # Both preview halves scroll independently and neither said so. `rect.right` is the
      # frame's hairline for the stacked layout and the RIGHT half of the split one; for the
      # LEFT half it is the vertical `│` this pane draws between them, which the gauge
      # replaces in place — a vertical rule either way, now one that also says where you are.
      Frame.scroll_gauge(screen, Rect.new(rect.x, content_y, rect.w, content_h),
        lines.size, sc, active, bg)
    end

    private def preview_text_lines(head : Bytes?, body : Bytes?) : Array(String)
      return ["(empty)"] if head.nil? || head.empty?
      cap = Settings.preview_body_cap
      io = IO::Memory.new
      io.write(head)
      if body && !body.empty?
        n = {body.size, cap}.min
        io.write(body[0, n])
        io << "\n… [truncated]" if body.size > cap
      end
      String.new(io.to_slice).scrub.split('\n').map(&.rstrip('\r'))
    end

    # The captured-at column: an absolute local MM-DD HH:MM:SS timestamp, or a compact
    # relative age per Settings.history_time_format. The absolute date makes flows
    # captured across days/sessions legible at a glance; relative is handier during a
    # live session. created_at is unix microseconds.
    private def fmt_time(created_at : Int64) : String
      t = Time.unix(created_at // 1_000_000)
      return fmt_time_relative(t) if Settings.history_time_format == "relative"
      t.to_local.to_s("%m-%d %H:%M:%S")
    end

    # Compact relative age from now: "3s" / "5m" / "2h" / "1d". This said it "mirrors
    # notifications_overlay#ago" — a copy that no longer exists as one: that overlay and its
    # two siblings were collapsed into `Fmt.ago` for exactly this reason, and the two methods
    # right below already delegate to `Fmt`. Byte-identical to the home, so this is the last
    # copy going home rather than a behaviour change.
    private def fmt_time_relative(t : Time) : String
      Fmt.ago(t)
    end

    # Compact response size (B/KB/MB/GB), bounded to ≤6 cols. "—" until the response
    # lands. The unit is picked from the ROUNDED magnitude so a value just under a
    # boundary (e.g. 1023.6 KB) rolls up to the next unit ("1.0MB") instead of the
    # misleading "1024KB".
    private def fmt_size(bytes : Int64?) : String
      Fmt.size(bytes)
    end

    # Compact request→response latency (ms/s/m/h), bounded to ≤6 cols. "—" until the
    # response lands; a minute/hour tier keeps very slow flows from overflowing.
    private def fmt_dur(us : Int64?) : String
      Fmt.dur(us)
    end

    # Compact response MIME — the useful subtype (json/html/png/js…), params dropped.
    # "—" until the response lands. Clipped to the column width by the caller.
    private def fmt_mime(ct : String?) : String
      return "—" unless ct
      main = ct.split(';', 2)[0].strip.downcase
      return "—" if main.empty?
      sub = main.includes?('/') ? main.split('/', 2)[1] : main
      case
      when sub.in?("javascript", "x-javascript", "ecmascript") then "js"
      when sub == "x-www-form-urlencoded", sub == "form-data"  then "form"
      when sub == "event-stream"                               then "sse"
      when sub == "octet-stream"                               then "bin"
      when sub == "plain"                                      then "text"
      when sub.ends_with?("+json")                             then "json"
      when sub.ends_with?("+xml")                              then sub == "svg+xml" ? "svg" : "xml"
      else                                                          sub.lchop("vnd.").lchop("x-")
      end
    end

    # Inverts render_detail's chip strip (the one-row REQUEST/RESPONSE/FRAMES band
    # at rect.y): each chip is " LABEL " (width label.size+2) from rect.x+1 with a
    # 1-col gap between. Returns the pane symbol whose chip is under (mx,my), else nil.
    def detail_pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @detail.nil? || my != rect.y
      x = rect.x + 1
      detail_panes.each do |pane|
        w = detail_pane_label(pane).size + 2 # " LABEL "
        return pane if mx >= x && mx < x + w
        x += w + 1 # render's trailing 1-col gap between chips
      end
      nil
    end

    # Mode chips after the pane strip + status word (x:hex / b:ws / p:pretty).
    # Geometry matches render_detail. Miss → nil.
    def detail_mode_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @detail.nil? || my != rect.y
      x = rect.x + 1
      detail_panes.each do |pane|
        x += detail_pane_label(pane).size + 2 + 1
      end
      hex = detail_hex?(@detail.not_nil!)
      dv = detail_view
      ws = @reveal && !hex && !dv.binary
      # status word + 1-col gap, then chips (same as render)
      start = x + 1 + detail_mode_status(hex, ws, dv).size + 1
      chips = detail_mode_chips(hex, ws, dv).map { |(id, label, _)| {id, label} }
      Frame.left_chip_hit(mx, my, rect.y, start, chips)
    end

    # Compact mode word shown before the toggle chips (and asserted by specs).
    private def detail_mode_status(hex : Bool, ws : Bool, dv : DetailView) : String
      return "HEX" if hex
      return "RAW" if ws
      return "BINARY" if dv.binary
      dv.pretty ? "PRETTY" : "RAW"
    end

    # Mode toggle chips for the detail strip: {id, label, lit}.
    private def detail_mode_chips(hex : Bool, ws : Bool, dv : DetailView) : Array({Symbol, String, Bool})
      if hex
        [{:hex, " ^X:text ", true}] of {Symbol, String, Bool}
      elsif ws
        [{:ws, " b:raw ", true}] of {Symbol, String, Bool}
      elsif dv.binary
        [{:hex, " ^X:hex ", false}] of {Symbol, String, Bool}
      else
        [
          {:hex, " ^X:hex ", false},
          {:ws, " b:ws ", false},
          {:pretty, dv.pretty ? " p:raw " : " p:pretty ", dv.pretty},
        ] of {Symbol, String, Bool}
      end
    end

    def render_detail(screen : Screen, rect : Rect, focused : Bool = true, strip_focused : Bool = false) : Nil
      return if rect.empty?
      detail = @detail
      unless detail
        screen.text(rect.x + 1, rect.y, "no flow selected", Theme.muted)
        return
      end
      # Back-to-list affordance on the top border (← past REQUEST / esc → the list).
      Frame.list_back_hint(screen, rect)
      # Pane strip: show ALL panes as chips with the active one highlighted, so it's
      # obvious there's more behind (←/→ walk REQUEST → RESPONSE → FRAMES).
      x = render_detail_chips(screen, rect, strip_focused)
      hex = detail_hex?(detail)
      dv = detail_view
      # A binary body is shown as a placeholder; the reveal-whitespace path renders raw
      # bytes as text, so gate it off there too — otherwise `b` re-triggers the very
      # cursor-desync corruption the placeholder exists to avoid. Pretty likewise n/a.
      ws = @reveal && !hex && !dv.binary
      nav = detail_navigable? ? "↑/↓←/→ · ⇧sel · y" : "↑/↓ scroll"
      # Status word + mode toggle chips (mouse + same chords as keys), then muted nav.
      x = screen.text(x + 1, rect.y, detail_mode_status(hex, ws, dv), Theme.muted) + 1
      detail_mode_chips(hex, ws, dv).each do |(_, label, lit)|
        x = Frame.chip(screen, x, rect.y, label, lit) + 1
      end
      screen.text(x + 1, rect.y, "· #{nav} · space · esc", Theme.muted)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))

      body = Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 2), 0}.max)
      if hex && (bytes = detail_pane_bytes)
        HexView.render(screen, body, bytes, @detail_scroll)
        return
      end
      if ws && (rl = reveal_lines)
        render_reveal(screen, body, rl, focused: focused)
        return
      end

      render_detail_body(screen, body, focused: focused)
    end

    # Draws the pane chip strip and returns the x column just past the last chip. The
    # active chip is a gold pill when the strip holds focus (same "gold = focus is here"
    # cue as the sub-tab strips one level up), else the accent pill; body-focused keeps
    # today's look.
    private def render_detail_chips(screen : Screen, rect : Rect, strip_focused : Bool) : Int32
      x = rect.x + 1
      detail_panes.each do |pane|
        active = pane == @detail_pane
        fg = active ? (strip_focused ? Theme.ink_on(Theme.focus_gold) : Theme.text_bright) : Theme.muted
        bg = active ? (strip_focused ? Theme.focus_gold : Theme.accent_bg) : Theme.bg
        x = screen.text(x, rect.y, " #{detail_pane_label(pane)} ", fg, bg,
          attr: active ? Attribute::Bold : Attribute::None) + 1
      end
      x
    end

    # The normal (non-hex, non-reveal) detail body: request/response/decoded-pane text,
    # windowed + soft-wrapped. Split out of render_detail to keep that dispatch's
    # cyclomatic complexity under ameba's threshold.
    # Steady-scroll hot path: only materialises/styles VISIBLE lines — never the full
    # multi-MiB body. Full plain-line materialisation is reserved for selection spans
    # (rare) and caret/search helpers outside the every-frame loop.
    private def render_detail_body(screen : Screen, body : Rect, focused : Bool = true) : Nil
      dv = detail_view
      total = dv.total
      @detail_last_h = body.h
      gw = Settings.show_gutter ? {Gutter.width(total), body.w}.min : 0
      cw = {body.w - gw, 0}.max
      detail_record_metrics(gw, cw)
      return if cw <= 0
      ensure_detail_visible(body.h) if detail_navigable? && focused
      # Selection spans only fetch lines in the selected range (lazy line_at).
      sel_spans = if focused && detail_navigable? && @detail_read.selection?
                    size, line_at = detail_line_source
                    @detail_read.highlight_spans(size, line_at)
                  end
      # The wrap is computed on the PLAIN text (`line_text`) and the styled overlay is then
      # sliced to the same char range — Highlight is a 1:1 colour overlay, so one layout
      # describes both and the colours cannot land a column off the glyphs.
      rows = detail_rows(cw, body.h, total, ->(i : Int32) { detail_line_text(dv, i) })
      xs = detail_xscroll
      rows.each_with_index do |vr, i|
        li = vr.li
        y = body.y + i
        draw_detail_gutter(screen, body.x, y, gw, vr, focused)
        shown = Highlight.slice_chars(styled_detail_line(dv, li), vr.a, vr.b)
        shown = Highlight.slice_left(shown, xs) if xs > 0
        Highlight.draw(screen, body.x + gw, y, shown, width: cw)
        need_plain = (focused && detail_navigable? && (li == @detail_read.cy || sel_spans)) || !@search_hl.empty?
        plain = need_plain ? detail_line_text(dv, li) : nil
        paint_detail_line_chrome(screen, body.x + gw, y, li, plain, focused, sel_spans, vr.a, vr.b) if plain
        # The plain-text line feeds ONLY the search overlay, so skip it when no query is
        # active (else every frame builds/scans discarded strings per row).
        if (text = plain) && !@search_hl.empty?
          Wrap.mark_search(screen, body.x + gw, y, text, vr.a, vr.b, @search_hl, body.x + gw + cw, xoff: xs)
        end
      end
      # The detail body scrolls (`@detail_scroll`) and had no gauge, while the Repeater's
      # structurally identical response pane has had one all along. `total` is LINES, and
      # `detail_rows` windows by wrapped ROWS, so the two disagree on a wrapped line — the
      # gauge is a proportion, and lines are the number the operator's ↑/↓ and the gutter
      # both count in, which makes it the honest one to show.
      Frame.scroll_gauge(screen, body, total, @detail_scroll, focused)
    end

    # Windowed render of revealed (whitespace-visible) lines — mirrors the normal
    # detail body loop but styles each visible line via Reveal.
    private def render_reveal(screen : Screen, body : Rect, lines : Array(String), focused : Bool = true) : Nil
      total = lines.size
      @detail_last_h = body.h
      gw = Settings.show_gutter ? {Gutter.width(total), body.w}.min : 0
      cw = {body.w - gw, 0}.max
      detail_record_metrics(gw, cw)
      return if cw <= 0
      ensure_detail_visible(body.h) if detail_navigable? && focused
      # Reveal substitutes a 1-column marker for every control char (tab → '→', CR → '␍'),
      # which is exactly what `Screen.grapheme_cols` already scores them, so the wrap of the
      # RAW line and the wrap of the revealed line are the same break — no second layout.
      rows = detail_rows(cw, body.h, total, ->(i : Int32) { lines[i] })
      xs = detail_xscroll
      rows.each_with_index do |vr, i|
        y = body.y + i
        line = lines[vr.li]
        draw_detail_gutter(screen, body.x, y, gw, vr, focused)
        # `last` only on the row that actually ends the line — the ␊ marker belongs at the
        # true end of the line, not at every wrap break inside it.
        eol = vr.b >= line.size && vr.li < total - 1
        styled = Reveal.styled(line[vr.a...vr.b], eol, cw + xs)
        styled = Highlight.slice_left(styled, xs) if xs > 0
        Highlight.draw(screen, body.x + gw, y, styled, width: cw)
        paint_detail_line_chrome(screen, body.x + gw, y, vr.li, line, focused, nil, vr.a, vr.b)
        Wrap.mark_search(screen, body.x + gw, y, line, vr.a, vr.b, @search_hl, body.x + gw + cw, xoff: xs) unless @search_hl.empty?
      end
    end

    # Detail-pane gutter: the line number rides the FIRST visual row of a logical line only
    # (Burp style); a continuation gets a blank of the same width so the text column stays
    # put and no stale digits survive there.
    private def draw_detail_gutter(screen : Screen, x : Int32, y : Int32, gw : Int32,
                                   vr : Wrap::Row, focused : Bool) : Nil
      return if gw <= 0
      if vr.sub == 0
        Gutter.draw(screen, x, y, vr.li, gw, current: focused && vr.li == @detail_read.cy)
      else
        screen.text(x, y, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
      end
    end

    # Selection tint + block caret for ONE drawn row. `rs`/`re` bound the row's slice of the
    # line (the whole line when nothing wrapped), so a selection spanning a wrap break is
    # painted on each row it covers and the caret paints on exactly one of them — the row
    # that STARTS at its column, matching Wrap::Layout#row_of.
    #
    # `@detail_xscroll` shifts both left (0 under wrap) and the caret is dropped when that puts
    # it outside the visible content: it addresses a column the base draw did not paint, and a
    # block caret over the gutter — or over the pane next door — is a lie about where it is.
    private def paint_detail_line_chrome(screen : Screen, x : Int32, y : Int32, li : Int32,
                                         line : String, focused : Bool,
                                         sel_spans : Array({Int32, Int32, Int32})? = nil,
                                         rs : Int32 = 0, re : Int32 = -1) : Nil
      return unless focused && detail_navigable?
      re = line.size if re < 0
      cw = @detail_last_cw
      if spans = sel_spans
        spans.each do |(l, x0, x1)|
          next unless l == li
          a = {x0, rs}.max
          b = {x1, re}.min
          paint_char_span_bg(screen, x, y, line, a, b, Theme.accent_bg, rs, cw) if a < b
        end
      end
      return unless li == @detail_read.cy
      cx = @detail_read.cx.clamp(0, line.size)
      return unless cx >= rs && (cx < re || re >= line.size)
      px = x + Wrap.row_col(line, nil, rs, cx) - detail_xscroll
      # Clipped only while the pane is PANNED. With no offset the caret is inside the row by
      # construction, save for one case: an end-of-line caret on a row exactly as wide as the
      # pane sits at x + cw, which is the border cell. That is where this pane (and every
      # other one in the tree) has always drawn it, so clipping it unconditionally would trade
      # a caret one column too far right for no caret at all.
      return if detail_xscroll > 0 && (px < x || (cw > 0 && px >= x + cw))
      ch = cx < line.size ? line[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
    end

    # `row_start` is the char index the drawn row begins at — 0 for an unwrapped line, the
    # wrap break for a continuation row. Columns are measured from THERE, so a tint on a
    # continuation row starts at the pane's left edge like the text it covers.
    # `cw` is the visible content width, used only to clip a tint that the h-scroll offset
    # pushed outside the pane (0 ⇒ no clip, which is what every wrapped row wants: it cannot
    # exceed the width it was laid out at).
    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color, row_start : Int32 = 0,
                                   cw : Int32 = 0) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = {Screen.cluster_start(line, {x0, line.size}.min), row_start}.max
      b = Screen.cluster_end(line, {x1, line.size}.min)
      return if a >= b
      px = x + Wrap.row_col(line, nil, row_start, a) - detail_xscroll
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        w = Screen.draw_width(seg)
        # Clipped only while panned — see `paint_detail_line_chrome`. A wrapped row cannot
        # exceed the width it was laid out at, so the unpanned draw is byte-identical.
        screen.text(px, y, seg, Theme.text, bg) if detail_xscroll <= 0 || (px >= x && (cw <= 0 || px + w <= x + cw))
        px += w
        i = e
      end
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

      # Right cluster: a scope-lens chip (always shown so the ⇧S toggle is discoverable)
      # and, when filtering, the row count. The scope lens is a filter too, so it lives
      # on the filter bar next to the QL query.
      # One right-anchored chain, drawn by `Frame.right_text_chain` — rightmost first. The
      # `f:follow` toggle shares the scope chip's accent/muted dress so the two read as one
      # cluster, and the mark chip joins them rather than being placed by hand afterwards.
      chips = [] of {String, Color}
      if filtering?
        # @rows is capped at PAGE by the search LIMIT; show "N+" at the cap so the count
        # isn't silently misread as the exact match total when more actually match.
        chips << {@rows.size >= PAGE ? "#{PAGE}+" : @rows.size.to_s, Theme.muted}
      end
      scope_on = @scope.try(&.active?) == true
      chips << (scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted})
      chips << {"f:follow", @follow ? Theme.accent : Theme.muted}
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

    # Mark count (#442), drawn right-to-left ending just left of `right_x`; returns the new
    # left edge of the chip cluster. Always shown while any mark is set — marks deliberately
    # survive a tab switch, so this chip is what keeps the set from being invisible when you
    # come back. The hidden split covers marks the current filter/window doesn't show, so the
    # count never silently exceeds what's on screen.
    # The mark chip's TEXT, or nil when there is nothing marked. It used to place itself,
    # which is why it needed a `right_x` and its own too-narrow guard; as a string it joins
    # the same chain as its neighbours and `Frame.right_text_chain` drops it on a narrow bar
    # for the same reason it drops any of them.
    private def mark_chip_text : String?
      return nil if @marks.empty?
      hidden = marked_hidden_count
      hidden > 0 ? "#{@marks.size} marked ·#{hidden} hidden" : "#{@marks.size} marked"
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
      return unless QuerySuggest.hint_slot?(FilterAst.token_at(@query, @qcx).core)
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: rect.w - 2)
    end

    # Static pools for low-cardinality fields; `host:` is DISTINCT from the store
    # (capped + prefix-filtered) so a large History stays cheap to complete.
    private def suggest_values(field : String, prefix : String) : Array(String)
      p = prefix.downcase
      values = case field
               when "scheme" then ["http", "https"]
               when "proto"  then ["ws", "grpc", "sse", "http"]
               when "method" then METHOD_VAL
               when "status" then ["2xx", "3xx", "4xx", "5xx", ">=400", ">=500", "200", "301", "302", "401", "403", "404", "500", "502", "503"]
               when "host"   then host_values_for(prefix)
               when "size"   then [">10000", ">100000", "<1000"]
               when "dur"    then [">500", ">1s", ">=200", "<100"]
               else               return [] of String
               end
      # host_values_for is already prefix-filtered by SQL; still apply starts_with so a
      # stale cache entry can't surface a non-matching host if the key ever drifts.
      values.select(&.downcase.starts_with?(p)).map { |v| "#{field}:#{FilterAst.quote(v)}" }
    end

    # DISTINCT hosts for the typed prefix. Cached per prefix so Tab + suggestion
    # re-renders on the same token don't re-query SQLite every frame.
    private def host_values_for(prefix : String) : Array(String)
      key = prefix.downcase
      if @host_suggest_prefix == key
        return @host_suggest_values
      end
      store = @suggest_store
      @host_suggest_prefix = key
      @host_suggest_values = store ? store.distinct_hosts(prefix: prefix, limit: 16) : [] of String
      @host_suggest_values
    end

    private def invalidate_host_suggest_cache : Nil
      @host_suggest_prefix = nil
      @host_suggest_values = [] of String
    end

    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - list_h + 1 if @selected >= @scroll + list_h
      # Never scroll past what fits: on_event's `@scroll += 1` (not-following) and the
      # trim clamp can leave @scroll above (rows.size - list_h), stranding the newest
      # rows off the top with blank space below. Pull it back when the list underfills.
      @scroll = {@scroll, {@rows.size - list_h, 0}.max}.min
      @scroll = 0 if @scroll < 0
    end

    # Position of `id` in @rows. Sorted id-DESC (newest first) or id-ASC (oldest
    # first) per Settings.history_list_order — O(log n) binary search either way.
    private def index_of(id : Int64) : Int32?
      lo = 0
      hi = @rows.size - 1
      desc = newest_first?
      while lo <= hi
        mid = (lo + hi) // 2
        mid_id = @rows[mid].id
        return mid if mid_id == id
        if desc
          if mid_id > id
            lo = mid + 1 # descending: smaller ids to the right
          else
            hi = mid - 1
          end
        else
          if mid_id < id
            lo = mid + 1 # ascending: larger ids to the right
          else
            hi = mid - 1
          end
        end
      end
      nil
    end

    # Drop the oldest rows so the window stays at MAX_ROWS. Newest-first: oldest
    # are at the END (pop). Oldest-first: oldest are at the START (shift).
    private def trim_window : Nil
      drop = @rows.size - @max_rows
      return if drop <= 0
      if newest_first?
        @rows.pop(drop)
      else
        @rows.shift(drop)
        @selected = {@selected - drop, 0}.max
        @scroll = {@scroll - drop, 0}.max
      end
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = @scroll.clamp(0, {@rows.size - 1, 0}.max)
      # The colour memo is keyed by flow id and nothing else prunes it, so a long capture would
      # otherwise accumulate an entry per flow ever seen. Cleared rather than pruned per dropped
      # id: it refills from a screenful of rows on the next frame.
      @color_memo.clear if @color_memo.size > @max_rows
    end

    # The detail content as a windowed view (request/response head + body with HTTP
    # syntax highlighting). The non-HTTP panes — raw h2 frames, WebSocket messages,
    # opaque gRPC hex — are bounded, so they go in `head` (eager, wrapped plain);
    # only a plain request/response body is windowed (styled per visible line).
    private def detail_view : DetailView
      drop_detail_cache if @detail_cache_rev != Theme.revision # theme switched → rebuild with new colours
      @detail_cache_rev = Theme.revision
      @detail_cache ||= build_detail_view
    end

    # Drop the memoized detail view AND its per-line styled-body cache together — the styled
    # lines are built from the current view (theme colours + pretty/raw body), so the two MUST
    # move in lockstep. Every site that invalidates the detail view goes through here (mirrors
    # RepeaterView#drop_resp_view_cache).
    private def drop_detail_cache : Nil
      @detail_cache = nil
      @detail_styled_cache.clear
      # …and the wrap memo, which is keyed by (line index, width) only: new content at the
      # same index would be laid out against the OLD line's breaks. `refresh_detail` reaches
      # here without touching the anchor (by design — it must not scroll a live-updating
      # flow), so the anchor is deliberately left alone; `Wrap.rows` re-clamps a sub-row that
      # the new content made too large.
      @detail_wrap.clear
      @detail_text_i = -1 # same keying, same hazard — see `detail_line_text`
    end

    # Ceiling on the styled-body memo (a visible window is ~tens of lines, so this covers many
    # screens of local scroll while capping memory on a huge body; on overflow the whole memo is
    # dropped and the next frame re-styles just the visible window). Mirrors RepeaterView.
    DETAIL_STYLED_CACHE_CAP = 2048

    # The styled line at absolute index `li`, memoized for BODY lines only — head/trailer are
    # already-materialised arrays (DetailView#line_at returns them directly), so they skip the
    # memo. Without this a held/scrolling detail re-tokenises every visible body line each frame.
    private def styled_detail_line(dv : DetailView, li : Int32) : Highlight::Line
      hs = dv.head.size
      return dv.line_at(li) if li < hs || li >= hs + dv.body.size # head or trailer → pre-built
      if cached = @detail_styled_cache[li]?
        return cached
      end
      @detail_styled_cache.clear if @detail_styled_cache.size >= DETAIL_STYLED_CACHE_CAP
      @detail_styled_cache[li] = dv.line_at(li)
    end

    EMPTY_LINES = [] of Highlight::Line
    EMPTY_BODY  = Highlight::BodyLines.empty

    private def build_detail_view : DetailView
      detail = @detail
      return DetailView.new(EMPTY_LINES, EMPTY_BODY, :text, EMPTY_LINES) unless detail
      if @detail_pane == :frames && (frames = @detail_frames)
        head = log_head(frame_lines(frames, detail.h2_stream_id), @detail_frames_total, frames.size, "frames")
        return DetailView.new(head, EMPTY_BODY, :text, EMPTY_LINES)
      end
      if @detail_pane == :response && (msgs = @detail_ws)
        head = log_head(ws_lines(msgs), @detail_ws_total, msgs.size, "messages")
        return DetailView.new(head, EMPTY_BODY, :text, EMPTY_LINES)
      end
      if @detail_pane == :events
        # Derived view: content-decode + split into SSE events at render time — no
        # table, like the gRPC framing pane (shared with `gori run show` / MCP).
        events = Sse.from_response(detail.response_head, detail.response_body)
        dropped = {events.size - DETAIL_LOG_CAP, 0}.max # older events not shown (windowed)
        shown = dropped > 0 ? events[dropped..] : events
        head = log_head(sse_lines(shown, dropped), events.size, shown.size, "events")
        return DetailView.new(head, EMPTY_BODY, :text, EMPTY_LINES)
      end
      # Decoded-protocol panes (SAML/JWT/GRAPHQL/PARAMS) — derived projections styled
      # eagerly (bounded; shared with `gori run show` / MCP).
      if dv = decoded_pane_view
        return dv
      end
      request = @detail_pane == :request
      # A failed/pending flow has no response bytes — surface WHY (like Repeater does)
      # instead of a blank pane.
      if !request && ((rh = detail.response_head).nil? || rh.empty?)
        span = if (err = detail.error) && !err.empty?
                 Highlight::Span.new("upstream error: #{err}", Theme.red)
               elsif detail.row.state.aborted?
                 Highlight::Span.new("— connection aborted (no response captured) —", Theme.yellow)
               elsif detail.row.state.pending?
                 Highlight::Span.new("— waiting for response… —", Theme.muted)
               else
                 Highlight::Span.new("— no response —", Theme.muted)
               end
        return DetailView.new([[span]], EMPTY_BODY, :text, EMPTY_LINES)
      end
      head, body = request ? {detail.request_head, detail.request_body} : {detail.response_head, detail.response_body}
      truncated = request ? detail.request_body_truncated? : detail.response_body_truncated?

      trailer = [] of Highlight::Line
      if truncated
        trailer << Highlight::Line.new
        trailer << [Highlight::Span.new("— body truncated at capture limit (#{Settings.effective_capture_max_mib} MiB); full size in the list —", Theme.yellow)]
      end
      # What gori has to say about this exchange that its bytes cannot (`FlowRow#advisory`).
      # In the TRAILER, beside the truncation notice, and not spliced into the head: this is
      # gori's sentence, and the panes above it are the wire's bytes (P7). Only on the
      # REQUEST pane — an advisory is a property of the exchange, so printing it under both
      # would read as two different findings.
      if request
        detail.row.advisories.each do |a|
          trailer << Highlight::Line.new
          trailer << [Highlight::Span.new("! #{a}", Theme.yellow)]
        end
      end

      # gRPC: bounded framed hex view — style eagerly into `head`. Flagged binary so the
      # reveal-whitespace path is gated off (like any other binary body): a gRPC body is
      # opaque protobuf whose bytes would desync the terminal if rendered as text (the
      # very 잔상 the binary placeholder avoids). Hex (x) stays available on this pane.
      if (body && !body.empty?) && grpc_body?(head)
        ls = Highlight.message(head, nil, request)
        ls << Highlight::Line.new
        ls.concat(wrap(grpc_lines(MediaType.of(head), body)))
        return DetailView.new(ls, EMPTY_BODY, :text, trailer, binary: true)
      end

      # Plain body → WINDOWED. Decode compressed/chunked bodies for display
      # (gzip/deflate/br/zstd + de-chunk); storage stays the raw wire bytes. The head
      # is styled eagerly; the (possibly multi-MiB) body stays as lazy BodyLines and
      # is styled per visible line at render — so opening a huge response doesn't freeze.
      display, decode_note = Proxy::Codec::ContentDecode.decode(head, body)
      src = display || body
      # Binary bodies (images/webp/fonts/media/…) are NOT text: decoding their raw
      # bytes as UTF-8 and rendering them yields garbage AND — worse — the accidental
      # wide/emoji graphemes among the bytes desync the terminal's cursor tracking, so
      # the diff-renderer leaves stray glyphs it can never reach (the reported "잔상").
      # Show a placeholder and point at the byte-exact hex view (^X), like Burp/mitmproxy.
      if (b = src) && !b.empty? && binary_body?(b)
        head_lines = Highlight.message_windowed(head, nil, request).head
        head_lines << Highlight::Line.new
        head_lines << [Highlight::Span.new(
          "— binary body (#{Fmt.size(b.size.to_i64)}) — not shown as text; press ^X for the hex view —", Theme.muted)]
        return DetailView.new(head_lines, EMPTY_BODY, :text, trailer, binary: true)
      end
      # Pretty-print AFTER decode (so JSON/XML/… are reflowed from the decoded bytes),
      # display only — storage is untouched. nil = leave raw. `pretty.kind` overrides
      # the styler when the reflow is no longer the content-type's language.
      pretty = @pretty ? Pretty.format(head, src) : nil
      pretty_kind = pretty.try(&.kind)
      win = Highlight.message_windowed(head, pretty.try(&.bytes) || src, request, kind: pretty_kind)
      if decode_note
        note = [] of Highlight::Line
        note << Highlight::Line.new
        color = (decode_note.includes?("unsupported") || decode_note.includes?("error")) ? Theme.yellow : Theme.green
        note << [Highlight::Span.new("— #{decode_note} —", color)]
        trailer = note + trailer # decode note before the truncation note
      end
      # No pretty trailer: the "PRETTY" mode indicator in the pane header already
      # signals the reflow, so the "— pretty: … —" footer is redundant (and Repeater
      # never showed one — this keeps the two response views consistent).
      DetailView.new(win.head, win.body, win.kind, trailer, pretty: pretty != nil)
    end

    # How many leading bytes to sniff for the binary heuristic. Binary formats carry
    # NUL in their header/framing, so a bounded prefix scan is enough — and keeps this
    # O(1) on a multi-MiB body rather than walking every byte on each cache rebuild.
    BINARY_SNIFF_LIMIT = 8192

    # A body is treated as binary (→ hex view, not text) when a NUL byte appears in its
    # leading bytes — the classic git/grep detector. Real text, including UTF-8 Korean/
    # CJK/emoji, never contains NUL; images, fonts, media and protobufs do.
    private def binary_body?(bytes : Bytes) : Bool
      n = {bytes.size, BINARY_SNIFF_LIMIT}.min
      n.times { |i| return true if bytes[i] == 0u8 }
      false
    end

    # Wrap pre-formatted plain strings (frames / ws / gRPC hex) as single-span
    # body-text lines so they share the styled rendering path.
    private def wrap(strs : Array(String)) : Array(Highlight::Line)
      # `.scrub` maps invalid UTF-8 to U+FFFD (width-1) so stray bytes in a WS text
      # payload or SSE data line never desync the terminal — the same guard every
      # sibling surface (Repeater/CLI/MCP) already applies on this byte→line seam.
      strs.map { |s| [Highlight::Span.new(s.scrub, Theme.text)] of Highlight::Span }
    end

    # Wrap a bounded log (frames/messages) and, when the window dropped older rows,
    # prepend a visible note so nothing is hidden silently (this is a wire-inspection
    # tool). `shown` is the loaded window size; `total` the full count in SQLite.
    private def log_head(lines : Array(String), total : Int32, shown : Int32, what : String) : Array(Highlight::Line)
      head = wrap(lines)
      if total > shown
        head.unshift(Highlight::Line.new) # blank separator beneath the note
        head.unshift([Highlight::Span.new(
          "— showing the latest #{shown} of #{total} #{what}; #{total - shown} older not loaded —", Theme.yellow)] of Highlight::Span)
      end
      head
    end

    # A gRPC message by its own Content-Type — the same question `Proto`'s PROTO column, the
    # QL `proto:` filter and the Repeater all ask, asked the same way. The substring search it
    # replaces missed the (legal) `Content-Type:application/grpc` with no space after the
    # colon, and could match the text inside another header's value.
    private def grpc_body?(head : Bytes?) : Bool
      Proxy::H2::Grpc.grpc?(MediaType.of(head))
    end

    # Renders a gRPC body as framed messages with a hex preview (protobuf is
    # opaque without the .proto schema — hex is the honest view).
    #
    # `scan`, not `messages`: the tail bytes that could NOT be framed are the finding in a
    # gRPC parser test, and `messages` drops them. A body whose length prefix claims more
    # than arrived rendered here as "(no complete gRPC messages)" with no byte count —
    # indistinguishable from a body that simply is not gRPC, while `gori run show
    # --format json` reported it in full.
    private def grpc_lines(content_type : String?, body : Bytes) : Array(String)
      # `scan_body`: a grpc-web-text body carries its frames base64-encoded, so scanning the
      # raw bytes finds a length prefix made of base64 characters and reports nothing.
      msgs, residual = Proxy::H2::Grpc.scan_body(content_type, body)
      note = Proxy::H2::Grpc.framing_error(residual)
      return ["(no complete gRPC messages — streaming or partial)"] if msgs.empty? && note.nil?
      lines = [] of String
      msgs.each_with_index do |m, i|
        if m.trailer
          lines << "▸ trailer  #{m.data.size}b"
          Proxy::H2::Grpc.trailer_headers(m.data).each { |k, v| lines << "  #{k}: #{v}" }
        else
          lines << "▸ message ##{i + 1}  #{m.data.size}b#{m.compressed ? "  (compressed)" : ""}"
          lines.concat(hex_preview(m.data))
        end
      end
      lines << "⚠ #{note}" if note
      lines
    end

    private def hex_preview(data : Bytes, max : Int32 = 64) : Array(String)
      slice = data[0, {data.size, max}.min]
      lines = [] of String
      slice.each_slice(16) do |chunk|
        hex = chunk.map(&.to_s(16).rjust(2, '0')).join(' ')
        ascii = chunk.map { |b| 0x20 <= b <= 0x7e ? b.unsafe_chr : '.' }.join
        lines << "  #{hex.ljust(48)} #{ascii}"
      end
      lines << "  … (#{data.size - max} more bytes)" if data.size > max
      lines
    end

    # Renders the connection's raw h2 frame log; `*` marks this flow's stream so
    # the surrounding multiplexed traffic stays visible (P7, desync insight).
    private def frame_lines(frames : Array(Store::H2Frame), stream_id : Int64?) : Array(String)
      return ["(no frames)"] if frames.empty?
      frames.map do |f|
        arrow = f.direction == "out" ? "→" : "←"
        name = Proxy::H2::Frame::Type.from_value?(f.type.to_u8).try(&.to_s) || "TYPE#{f.type}"
        mark = f.stream_id == stream_id ? "*" : " "
        "#{arrow}#{mark}#{name.ljust(12)} stream=#{f.stream_id} flags=0x#{f.flags.to_s(16).rjust(2, '0')} #{f.length}b"
      end
    end

    private def ws_lines(msgs : Array(Store::WsMessage)) : Array(String)
      return ["(no websocket messages)"] if msgs.empty?
      msgs.map do |m|
        arrow = m.direction == "out" ? "→" : "←"
        m.text? ? "#{arrow} #{String.new(m.payload)}" : "#{arrow} «binary #{m.payload.size}b»"
      end
    end

    # Renders parsed SSE events: a header line per event (type/id/retry when set)
    # then its data, indented. The whole stream is server→client, so no arrows.
    # `base` is the count of older events the window dropped, so the visible numbers
    # stay continuous with the "showing latest N of M" note (no restart at #1).
    private def sse_lines(events : Array(Sse::Event), base : Int32 = 0) : Array(String)
      return ["(no events)"] if events.empty?
      lines = [] of String
      events.each_with_index do |e, i|
        meta = String.build do |io|
          io << "▸ event ##{base + i + 1}"
          io << "  type=" << e.type if e.type
          io << "  id=" << e.id if e.id
          io << "  retry=" << e.retry if e.retry
        end
        lines << meta
        # Cap a single event's data lines so one pathological multi-MB event can't
        # materialise a giant row array (the event COUNT is windowed separately).
        dls = e.data.split('\n')
        dls.first(EVENT_DATA_LINE_CAP).each { |dl| lines << "    #{dl}" }
        lines << "    … (#{dls.size - EVENT_DATA_LINE_CAP} more lines)" if dls.size > EVENT_DATA_LINE_CAP
      end
      lines
    end

    EVENT_DATA_LINE_CAP = 1000 # max rendered data lines per SSE event

    # --- decoded-protocol panes (SAML / JWT / GRAPHQL / PARAMS) --------------

    # The DetailView for the active decoded-protocol pane, or nil when the active pane
    # isn't one (each ivar was populated in decode_protocols, so the pane was offered).
    private def decoded_pane_view : DetailView?
      lines =
        case @detail_pane
        when :saml    then (doc = @detail_saml) ? saml_detail_lines(doc) : nil
        when :jwt     then @detail_jwts.empty? ? nil : jwt_detail_lines(@detail_jwts)
        when :graphql then graphql_pane_lines
        when :params  then (f = @detail_form) ? form_detail_lines(f) : nil
        end
      lines ? DetailView.new(lines, EMPTY_BODY, :text, EMPTY_LINES) : nil
    end

    # Max styled lines a decoded-protocol pane renders, so a pathological document
    # can't materialise a giant line array (the decoders cap their inputs too).
    DERIVED_LINE_CAP = 20_000

    # A "▸ …" accent header line introducing a decoded-protocol section.
    private def derived_header(text : String) : Highlight::Line
      [Highlight::Span.new("▸ #{text.scrub}", Theme.accent)] of Highlight::Span
    end

    # Append `raw`'s lines to `lines`, styled per `kind`, stopping at DERIVED_LINE_CAP.
    private def append_styled(lines : Array(Highlight::Line), raw : String, kind : Symbol) : Nil
      # Scrub before styling: decoded SAML/JWT/GraphQL payloads come from URL-/base64-
      # decoded bytes that can be invalid UTF-8, and the `:text`/`plain` styler keeps
      # them raw — matching the `.scrub` the CLI/MCP/decoded_view emitters apply.
      raw.scrub.split('\n').each do |ln|
        if lines.size >= DERIVED_LINE_CAP
          lines << [Highlight::Span.new("… (truncated)", Theme.yellow)] of Highlight::Span
          break
        end
        lines << Highlight.body_styled(ln, kind)
      end
    end

    private def saml_detail_lines(doc : Saml::Doc) : Array(Highlight::Line)
      lines = [derived_header(Saml.summary(doc))]
      lines << Highlight::Line.new
      append_styled(lines, Saml.pretty_xml(doc.xml), :xml)
      lines
    end

    private def jwt_detail_lines(found : Array(Jwt::Found)) : Array(Highlight::Line)
      lines = [] of Highlight::Line
      found.each_with_index do |f, i|
        lines << Highlight::Line.new if i > 0
        brief = f.brief
        lines << derived_header(brief ? "#{f.location} · #{brief}" : f.location)
        lines << [Highlight::Span.new(token_preview(f.token), Theme.muted)] of Highlight::Span
        lines << Highlight::Line.new
        append_styled(lines, f.decoded, :json)
      end
      lines
    end

    # A JWT can be hundreds of chars; show a head…tail preview so the raw token is
    # available (to read/copy) without dominating the pane.
    private def token_preview(tok : String) : String
      tok.size > 64 ? "#{tok[0, 40]}…#{tok[-12, 12]}" : tok
    end

    # The GRAPHQL pane: the request body's operation, the transcript's operations, or both —
    # a 101 flow has no body to decode and an HTTP flow has no frames, so in practice exactly
    # one of the two is populated. nil only when neither is (the pane was not offered).
    private def graphql_pane_lines : Array(Highlight::Line)?
      op = @detail_graphql
      ws = @detail_graphql_ws
      return nil if op.nil? && ws.empty?
      lines = [] of Highlight::Line
      append_styled(lines, Graphql.display(op), :graphql) if op
      unless ws.empty?
        lines << Highlight::Line.new unless lines.empty?
        lines << derived_header(GraphqlWs.summary(ws))
        lines << Highlight::Line.new
        append_styled(lines, GraphqlWs.display(ws), :graphql)
      end
      lines
    end

    private def form_detail_lines(fields : Array(FormData::Field)) : Array(Highlight::Line)
      lines = [derived_header("#{fields.size} field#{fields.size == 1 ? "" : "s"}")]
      lines << Highlight::Line.new
      fields.each do |f|
        break if lines.size >= DERIVED_LINE_CAP
        lines << form_field_line(f)
      end
      lines
    end

    # One "name = value" row; a `?` tags a query-string param, and a multipart
    # file/binary part shows its note in place of an inline value.
    private def form_field_line(f : FormData::Field) : Highlight::Line
      tag = f.source == :query ? "?" : " "
      note = f.note
      [
        Highlight::Span.new("#{tag} #{f.name.scrub}", Theme.syn_string),
        Highlight::Span.new(" = ", Theme.muted),
        Highlight::Span.new(note ? "(#{note})" : f.value.scrub, note ? Theme.yellow : Theme.text),
      ] of Highlight::Span
    end
  end
end
