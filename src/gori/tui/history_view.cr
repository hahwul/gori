require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./hex_view"
require "./gutter"
require "./search_hi"
require "./reveal"
require "./url"
require "./fmt"
require "./flow_status"
require "../store"
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
    PAGE = 1000
    # Hard cap on rows held in memory. The initial load is PAGE; live capture
    # then appends, but never past MAX_ROWS — the oldest are dropped from the
    # window (in TRIM_SLACK batches so the id index is rebuilt amortized, not per
    # flow). This keeps a long high-traffic session's footprint bounded; the
    # authoritative history still lives in SQLite (reload/QL re-query it).
    MAX_ROWS   = 5000
    TRIM_SLACK =  512
    # Cap on h2 frames / WS messages loaded into a detail view. A long-lived WS
    # (100k+ messages) or a heavily-multiplexed h2 connection would otherwise
    # materialize the whole log (objects + payloads + built lines) on detail-open.
    # We load the MOST RECENT this-many (so a live tail keeps updating) and show an
    # "older not loaded" note; the raw frames remain whole in SQLite.
    DETAIL_LOG_CAP = 10_000
    QL_FIELDS      = %w(host method status path scheme body header size reqsize respsize dur flag)
    METHOD_VAL     = %w(GET POST PUT DELETE PATCH HEAD OPTIONS QUERY)

    getter rows : Array(Store::FlowRow)
    getter? follow : Bool
    getter? querying : Bool
    getter query : String

    def initialize(@max_rows : Int32 = MAX_ROWS, @trim_slack : Int32 = TRIM_SLACK)
      @rows = [] of Store::FlowRow # always kept id-DESCENDING (newest first)
      @selected = 0
      @scroll = 0
      @follow = true
      @filter_dirty = false # a filtered view needs a coalesced reload after draining
      @query = ""
      @qcx = 0
      @preedit = ""
      @querying = false
      @scope = nil.as(Scope?)
      @detail = nil.as(Store::FlowDetail?)
      @detail_ws = nil.as(Array(Store::WsMessage)?)
      @detail_frames = nil.as(Array(Store::H2Frame)?)
      @detail_ws_total = 0 # full message count (≥ loaded; drives the "older not loaded" note)
      @detail_frames_total = 0
      @detail_sse = false # response is a text/event-stream → offer the EVENTS pane
      # Decoded protocol projections, parsed once per opened flow (no DB table) — each
      # drives an optional detail pane like EVENTS. nil/empty ⇒ the pane isn't offered.
      @detail_saml = nil.as(Saml::Doc?)              # SAMLRequest/Response → SAML pane
      @detail_jwts = [] of Jwt::Found                # located JWTs → JWT pane
      @detail_graphql = nil.as(Graphql::Op?)         # GraphQL operation → GRAPHQL pane
      @detail_form = nil.as(Array(FormData::Field)?) # form/multipart params → PARAMS pane
      @decoded_id = nil.as(Int64?)                   # flow the decoded panes above were parsed from (skip re-decode)
      @detail_scroll = 0
      @detail_pane = :request
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
      @detail_cache_rev = Theme.revision # the theme the cached (colour-baked) head/notes were built under
    end

    # head (styled, bounded) ++ body (raw, styled lazily per visible line) ++
    # trailer (styled notes). For the WS/frames/grpc panes the whole content is in
    # `head` (bounded); only a plain request/response body uses the windowed `body`.
    private record DetailView,
      head : Array(Highlight::Line),
      body : Array(String),
      kind : Symbol,
      trailer : Array(Highlight::Line),
      pretty : Bool = false do # whether Pretty actually reflowed this body (drives the indicator)
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
      # body lines raw, so it never re-styles (keeps ^F cheap on a huge body).
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

    # True when the displayed list is a filtered subset (QL query or Scope lens).
    def filtering? : Bool
      !@query.blank? || (@scope.try(&.active?) == true)
    end

    # Load flows (newest-first so the latest sit at the top, like Burp/Caido),
    # applying the Scope lens AND the QL query. store.search already returns
    # newest-first (ORDER BY id DESC), so no reverse.
    def reload(store : Store) : Nil
      prev_id = @rows[@selected]?.try(&.id) # anchor the highlight to the flow, not the index
      combined = QL.and(@scope.try(&.filter) || QL::EMPTY, QL.parse(@query))
      @rows = store.search(combined, PAGE)
      @filter_dirty = false
      @selected =
        if @follow
          0
        elsif prev_id && (idx = index_of(prev_id))
          idx # keep the highlight on the same flow across a reload
        else
          @selected.clamp(0, {@rows.size - 1, 0}.max)
        end
    end

    # Apply any filtered-view staleness accumulated during a drain cycle in ONE
    # reload (vs reloading per flow event — a search+reverse of up to PAGE rows).
    def flush_filter(store : Store) : Nil
      reload(store) if @filter_dirty
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
          # Newest-first: prepend so the latest sits at the top. Inserts arrive in
          # increasing id order (committed FIFO), so @rows stays id-descending and
          # no index rebuild is needed — lookups binary-search it.
          @rows.unshift(row)
          if @follow
            @selected = 0
          else
            # Keep the highlight + viewport on the same flows the user is looking at.
            @selected += 1
            @scroll += 1
          end
          trim_window if @rows.size > @max_rows + @trim_slack
        end
      when :updated
        if (idx = index_of(event.id)) && (row = store.flow_row(event.id))
          @rows[idx] = row
        end
      end
    end

    def move(delta : Int32) : Nil
      return if @rows.empty?
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
      # Newest-first: "following" the live tail means sitting on the top row (0).
      @follow = (@selected == 0)
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
      return nil if rect.empty? || !rect.contains?(mx, my)
      lt = list_top(rect)
      list_h = {rect.bottom - lt, 0}.max
      i = my - lt
      return nil if i < 0 || i >= list_h
      ri = @scroll + i
      ri < @rows.size ? ri : nil
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
      @follow = (@selected == 0)
    end

    # At the first (top) row — used by the Runner to pop focus up to the tab bar
    # when ↑ is pressed at the top (natural upward keyboard flow).
    def at_top? : Bool
      @selected == 0
    end

    def toggle_follow : Nil
      @follow = !@follow
      @selected = 0 if @follow && !@rows.empty?
    end

    def selected_id : Int64?
      @rows[@selected]?.try(&.id)
    end

    # --- QL bar editing ------------------------------------------------------

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

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed query — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Tab-complete the current token to the first suggestion.
    def query_complete : Bool
      sugg = query_suggestions
      return false if sugg.empty?
      s, e = current_token_bounds
      @query = "#{@query[0, s]}#{sugg.first}#{@query[e..]}"
      @qcx = s + sugg.first.size
      true
    end

    # Suggestions for the token under the cursor: field names, then field values.
    def query_suggestions : Array(String)
      token = current_token
      return [] of String if token.empty?
      if (colon = token.index(':'))
        suggest_values(token[0...colon].downcase, token[(colon + 1)..])
      else
        QL_FIELDS.select(&.starts_with?(token.downcase)).map { |f| "#{f}:" }
      end
    end

    # --- detail view ---------------------------------------------------------

    def open_detail(store : Store) : Bool
      id = selected_id
      return false unless id
      open_detail_id(id, store)
    end

    # Open a specific flow's detail by id, regardless of the current list selection
    # (used by the Findings tab to jump back to a finding's linked evidence). Also
    # syncs @selected to it when the row is in the current list, so back/▲▼ behave.
    def open_detail_id(id : Int64, store : Store) : Bool
      @detail = store.get_flow(id)
      return false if @detail.nil?
      if idx = @rows.index { |r| r.id == id }
        @selected = idx
      end
      # WebSocket flows (101) carry a captured message log; h2 flows link to their
      # connection's raw frame log. Both are loaded as a bounded most-recent window
      # (DETAIL_LOG_CAP) with the full count kept for the "older not loaded" note.
      load_detail_logs(store)
      @detail_scroll = 0
      @detail_pane = :request
      @detail_cache = nil
      @detail_hex = false # hex is a deliberate per-open peek — don't carry it into the next flow
      @detail_hex_bytes = nil
      true
    end

    def close_detail : Nil
      @detail = nil
      @detail_cache = nil
      @detail_frames = nil # release the h2-frame / ws-message payload arrays (can be MiB)
      @detail_ws = nil
      @detail_frames_total = 0
      @detail_ws_total = 0
      @detail_sse = false
      @detail_saml = nil
      @detail_jwts = [] of Jwt::Found
      @detail_graphql = nil
      @detail_form = nil
      @decoded_id = nil
      @detail_hex_bytes = nil
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
        @decoded_id = nil
        return
      end
      # A Complete, non-101 flow's bytes are immutable, so re-decoding the SAME flow on a
      # refresh poll (which still re-runs for h2 flows, to pick up frames) just re-scans
      # unchanged — possibly multi-MiB — bodies. Skip it; a pending/streaming flow's bytes
      # still grow, so it re-decodes each poll (id stays nil-guarded until Complete).
      if @decoded_id == detail.row.id && detail.row.state.complete? && detail.row.status != 101
        return
      end
      tgt = detail.row.target
      rh, rb = detail.request_head, detail.request_body
      sh, sb = detail.response_head, detail.response_body
      @detail_saml = Saml.from_flow(tgt, rh, rb, sh, sb)
      @detail_jwts = Jwt.from_flow(tgt, rh, rb, sh, sb)
      @detail_graphql = Graphql.from_flow(tgt, rh, rb)
      @detail_form = FormData.from_flow(tgt, rh, rb)
      @decoded_id = detail.row.state.complete? ? detail.row.id : nil
    end

    # The synthetic log panes (FRAMES / EVENTS) and the decoded-protocol panes render
    # as text and have no raw-byte hex view, unlike REQUEST/RESPONSE.
    private def log_pane? : Bool
      case @detail_pane
      when :frames, :events, :saml, :jwt, :graphql, :params then true
      else                                                       false
      end
    end

    # 'x' toggles a raw hex dump of the current pane (request/response bytes).
    def toggle_detail_hex : Nil
      return if log_pane? # frames/events have no raw-bytes hex; don't strand a hidden flag
      @detail_hex = !@detail_hex
      @detail_scroll = 0 # row-based offset differs from the line-based one
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
      @detail_cache = nil # content changed → rebuild (windowed) on next render
      @detail_hex_bytes = nil
      @detail_scroll = @detail_scroll.clamp(0, detail_scroll_max) # content may have shrunk
      true
    end

    def scroll_detail(delta : Int32) : Nil
      @detail_scroll = (@detail_scroll + delta).clamp(0, detail_scroll_max)
    end

    # ^G go-to-line in the detail view: scroll so 1-based line `n` is at the top
    # (interpreted in the active pane/mode — request/response/frames/hex row).
    def goto_detail_line(n : Int32) : Nil
      @detail_scroll = (n - 1).clamp(0, detail_scroll_max)
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
    end

    # Pretty toggle feeds `build_detail_view`, so a change must drop the windowed
    # cache (unlike reveal/hex, which render on separate paths). Change-detected
    # because the runner pushes this every frame.
    def pretty=(on : Bool) : Nil
      return if @pretty == on
      @pretty = on
      @detail_cache = nil
      @detail_scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like hex/pane toggles)
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
                   when :response then {detail.response_head, detail.response_body}
                   when :request  then {detail.request_head, detail.request_body}
                   else                {nil, nil} # frames: no raw-bytes hex
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
      panes << :saml if @detail_saml           # decoded SAML XML (request/response)
      panes << :jwt unless @detail_jwts.empty? # located + decoded JWT(s)
      panes << :graphql if @detail_graphql     # parsed GraphQL operation
      panes << :params if @detail_form         # decoded form/multipart params
      panes << :events if @detail_sse          # parsed SSE events (text/event-stream response)
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
      @detail_cache = nil     # pane switch changes the content
      @detail_hex_bytes = nil # …and the hex source bytes
    end

    # Public wrapper around the private set_detail_pane — lets the Runner switch
    # panes from a chip click (it ignores an unknown/inactive pane symbol).
    def set_detail_pane_public(pane : Symbol) : Nil
      set_detail_pane(pane) if detail_panes.includes?(pane)
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

    def render_list(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      render_ql_bar(screen, rect)
      hdr_y = rect.y + 1
      if @querying
        render_suggestions(screen, rect, hdr_y)
        hdr_y += 1
      end

      time_x = rect.x + 1
      method_x = rect.x + 16 # time column widened to fit MM-DD HH:MM:SS
      proto_x = rect.x + 24
      host_x = rect.x + 31
      # Right cluster STA · TYPE · SIZE · DUR (status code, response MIME, size,
      # latency — frequently-scanned), anchored to the right edge and sized to FIT:
      # STA always shows; TYPE/SIZE/DUR drop right-to-left when the pane is too narrow
      # to also keep HOST+PATH legible, so the cluster never spills past the frame.
      # (Each span includes its trailing 1-col gap.) HOST+PATH split the rest.
      cluster_w = 4                                # STA (3-digit code + gap)
      spare = rect.right - host_x - 18 - cluster_w # reserve 18 for HOST+PATH first
      if (show_type = spare >= 7)
        cluster_w += 7
        spare -= 7
      end
      if (show_size = spare >= 7)
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
        # Mirror Findings/Prism: a recovery hint under the message. The QL-clear
        # cue only applies to a real query (not a Scope-lens-only empty set, which
        # ⇧S toggles off), so branch on @querying / @query before filtering?.
        # Branch on a real `/` query FIRST (querying-aware hint): a blank-query empty
        # set is caused by the Scope lens or no traffic, where "esc clears the filter"
        # would mislead (⇧S clears the lens). Mirrors sitemap_view's ordering.
        msg, hint =
          if !@query.blank?
            {"no flows match", @querying ? "esc clears the filter" : "/ to edit the filter"}
          elsif filtering? # in-scope subset is empty (Scope lens, no QL query)
            {"no flows in scope", "⇧S clears the scope lens"}
          else
            {"waiting for traffic…", "browse through the proxy, then return here"}
          end
        screen.text(time_x, list_top, msg, Theme.muted)
        screen.text(time_x, list_top + 2, hint, Theme.muted) if list_h > 2
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @rows.size
        row = @rows[ri]
        y = list_top + i
        selected = ri == @selected
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        fg = selected ? Theme.text_bright : Theme.text

        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme.accent, bg)
        end
        screen.text(time_x, y, fmt_time(row.created_at), Theme.muted, bg)
        screen.text(method_x, y, row.method, Theme.method_color(row.method), bg)
        screen.text(proto_x, y, row.scheme.upcase, Theme.muted, bg)
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
    end

    # Local MM-DD HH:MM:SS for the captured-at micros (created_at is unix microseconds).
    # The brief date makes flows captured across days/sessions legible at a glance.
    private def fmt_time(created_at : Int64) : String
      Time.unix(created_at // 1_000_000).to_local.to_s("%m-%d %H:%M:%S")
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

    def render_detail(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      detail = @detail
      unless detail
        screen.text(rect.x + 1, rect.y, "no flow selected", Theme.muted)
        return
      end
      # Pane strip: show ALL panes as chips with the active one highlighted, so it's
      # obvious there's more behind (←/→ walk REQUEST → RESPONSE → FRAMES).
      x = rect.x + 1
      detail_panes.each do |pane|
        active = pane == @detail_pane
        x = screen.text(x, rect.y, " #{detail_pane_label(pane)} ",
          active ? Theme.text_bright : Theme.muted,
          active ? Theme.accent_bg : Theme.bg,
          attr: active ? Attribute::Bold : Attribute::None) + 1
      end
      hex = detail_hex?(detail)
      ws = @reveal && !hex
      applied = !hex && !ws && detail_view.pretty # Pretty actually reflowed this body
      mode = hex ? "HEX" : (ws ? "RAW" : (applied ? "PRETTY" : "RAW"))
      ptog = applied ? "p:raw" : "p:pretty"
      mode_hint = hex ? "#{mode} · x:text" : (ws ? "#{mode} · b:raw" : "#{mode} · x:hex · b:ws · #{ptog}")
      screen.text(x + 1, rect.y, "↑/↓ scroll · #{mode_hint} · esc back", Theme.muted)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))

      body = Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 2), 0}.max)
      if hex && (bytes = detail_pane_bytes)
        HexView.render(screen, body, bytes, @detail_scroll)
        return
      end
      if ws && (rl = reveal_lines)
        render_reveal(screen, body, rl)
        return
      end

      dv = detail_view
      total = dv.total
      gw = {Gutter.width(total), body.w}.min
      cw = {body.w - gw, 0}.max
      (0...body.h).each do |i|
        li = @detail_scroll + i
        break if li >= total
        Gutter.draw(screen, body.x, body.y + i, li, gw)
        Highlight.draw(screen, body.x + gw, body.y + i, dv.line_at(li), width: cw) # styles only this visible line
        SearchHi.mark(screen, body.x + gw, body.y + i, dv.line_text(li), @search_hl, body.x + gw + cw) unless @search_hl.empty?
      end
    end

    # Windowed render of revealed (whitespace-visible) lines — mirrors the normal
    # detail body loop but styles each visible line via Reveal.
    private def render_reveal(screen : Screen, body : Rect, lines : Array(String)) : Nil
      total = lines.size
      gw = {Gutter.width(total), body.w}.min
      cw = {body.w - gw, 0}.max
      (0...body.h).each do |i|
        li = @detail_scroll + i
        break if li >= total
        Gutter.draw(screen, body.x, body.y + i, li, gw)
        Highlight.draw(screen, body.x + gw, body.y + i, Reveal.styled(lines[li], li < total - 1, cw), width: cw)
        SearchHi.mark(screen, body.x + gw, body.y + i, lines[li], @search_hl, body.x + gw + cw) unless @search_hl.empty?
      end
    end

    private def render_ql_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright, width: rect.w - prefix.size - 2)
        return
      end

      # Right cluster: a scope-lens chip (always shown so the ⇧S toggle is discoverable)
      # and, when filtering, the row count. The scope lens is a filter too, so it lives
      # on the filter bar next to the QL query.
      scope_on = @scope.try(&.active?) == true
      chip, chip_color = scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted}
      rx = rect.right - 1
      if filtering?
        count = @rows.size.to_s
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end
      screen.text({rx - chip.size, rect.x}.max, rect.y, chip, chip_color)

      left_w = {(rx - chip.size) - (rect.x + 1) - 1, 0}.max
      if filtering?
        label = @query.blank? ? "(in-scope only)" : ": #{@query}"
        screen.text(rect.x + 1, rect.y, label, Theme.text, width: left_w)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  host:  method:  status:>=500  path:  scheme:  size:>10000  dur:>500  header:  body~regex", Theme.muted, width: left_w)
      end
    end

    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      sugg = query_suggestions
      return if sugg.empty?
      screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme.muted, width: rect.w - 2)
    end

    private def suggest_values(field : String, prefix : String) : Array(String)
      values = case field
               when "scheme" then ["http", "https"]
               when "method" then METHOD_VAL
               when "status" then ["2xx", "3xx", "4xx", "5xx", ">=400", ">=500"]
               when "size"   then [">10000", ">100000", "<1000"]
               when "dur"    then [">500", ">1s", ">=200", "<100"]
               else               return [] of String
               end
      values.select(&.downcase.starts_with?(prefix.downcase)).map { |v| "#{field}:#{v}" }
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

    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - list_h + 1 if @selected >= @scroll + list_h
      @scroll = 0 if @scroll < 0
    end

    # Position of `id` in @rows, which is kept sorted by id DESCENDING (newest
    # first) — so an O(log n) binary search replaces the per-insert O(n) hash
    # rebuild that used to run on the UI fiber for every captured flow.
    private def index_of(id : Int64) : Int32?
      lo = 0
      hi = @rows.size - 1
      while lo <= hi
        mid = (lo + hi) // 2
        mid_id = @rows[mid].id
        return mid if mid_id == id
        if mid_id > id
          lo = mid + 1 # descending: smaller ids are to the right
        else
          hi = mid - 1
        end
      end
      nil
    end

    # Drop the oldest rows so the window stays at MAX_ROWS. Newest-first, so the
    # oldest are at the END — pop them (keeps @rows id-descending; no reindex).
    # Selection/scroll live near the top (newest) and are unaffected, but clamp in
    # case the user had scrolled into the tail.
    private def trim_window : Nil
      drop = @rows.size - @max_rows
      return if drop <= 0
      @rows.pop(drop)
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = @scroll.clamp(0, {@rows.size - 1, 0}.max)
    end

    # The detail content as a windowed view (request/response head + body with HTTP
    # syntax highlighting). The non-HTTP panes — raw h2 frames, WebSocket messages,
    # opaque gRPC hex — are bounded, so they go in `head` (eager, wrapped plain);
    # only a plain request/response body is windowed (styled per visible line).
    private def detail_view : DetailView
      @detail_cache = nil if @detail_cache_rev != Theme.revision # theme switched → rebuild with new colours
      @detail_cache_rev = Theme.revision
      @detail_cache ||= build_detail_view
    end

    EMPTY_LINES = [] of Highlight::Line

    private def build_detail_view : DetailView
      detail = @detail
      return DetailView.new(EMPTY_LINES, [] of String, :text, EMPTY_LINES) unless detail
      if @detail_pane == :frames && (frames = @detail_frames)
        head = log_head(frame_lines(frames, detail.h2_stream_id), @detail_frames_total, frames.size, "frames")
        return DetailView.new(head, [] of String, :text, EMPTY_LINES)
      end
      if @detail_pane == :response && (msgs = @detail_ws)
        head = log_head(ws_lines(msgs), @detail_ws_total, msgs.size, "messages")
        return DetailView.new(head, [] of String, :text, EMPTY_LINES)
      end
      if @detail_pane == :events
        # Derived view: content-decode + split into SSE events at render time — no
        # table, like the gRPC framing pane (shared with `gori run show` / MCP).
        events = Sse.from_response(detail.response_head, detail.response_body)
        dropped = {events.size - DETAIL_LOG_CAP, 0}.max # older events not shown (windowed)
        shown = dropped > 0 ? events[dropped..] : events
        head = log_head(sse_lines(shown, dropped), events.size, shown.size, "events")
        return DetailView.new(head, [] of String, :text, EMPTY_LINES)
      end
      # Decoded-protocol panes (SAML/JWT/GRAPHQL/PARAMS) — derived projections styled
      # eagerly (bounded; shared with `gori run show` / MCP).
      if dv = decoded_pane_view
        return dv
      end
      request = @detail_pane == :request
      # A failed/pending flow has no response bytes — surface WHY (like Replay does)
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
        return DetailView.new([[span]], [] of String, :text, EMPTY_LINES)
      end
      head, body = request ? {detail.request_head, detail.request_body} : {detail.response_head, detail.response_body}
      truncated = request ? detail.request_body_truncated? : detail.response_body_truncated?

      trailer = [] of Highlight::Line
      if truncated
        trailer << Highlight::Line.new
        trailer << [Highlight::Span.new("— body truncated at capture limit (#{Proxy::Codec::Body::CAPTURE_MAX // (1024 * 1024)} MiB); full size in the list —", Theme.yellow)]
      end

      # gRPC: bounded framed hex view — style eagerly into `head`.
      if (body && !body.empty?) && grpc_body?(head)
        ls = Highlight.message(head, nil, request)
        ls << Highlight::Line.new
        ls.concat(wrap(grpc_lines(body)))
        return DetailView.new(ls, [] of String, :text, trailer)
      end

      # Plain body → WINDOWED. Decode compressed/chunked bodies for display
      # (gzip/deflate/br/zstd + de-chunk); storage stays the raw wire bytes. The head
      # is styled eagerly; the (possibly multi-MiB) body stays RAW and is styled per
      # visible line at render — so opening a huge response doesn't freeze the UI.
      display, decode_note = Proxy::Codec::ContentDecode.decode(head, body)
      src = display || body
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
      # signals the reflow, so the "— pretty: … —" footer is redundant (and Replay
      # never showed one — this keeps the two response views consistent).
      DetailView.new(win.head, win.body, win.kind, trailer, pretty: pretty != nil)
    end

    # Wrap pre-formatted plain strings (frames / ws / gRPC hex) as single-span
    # body-text lines so they share the styled rendering path.
    private def wrap(strs : Array(String)) : Array(Highlight::Line)
      strs.map { |s| [Highlight::Span.new(s, Theme.text)] of Highlight::Span }
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

    private def grpc_body?(head : Bytes?) : Bool
      return false unless head
      String.new(head).downcase.includes?("content-type: application/grpc")
    end

    # Renders a gRPC body as framed messages with a hex preview (protobuf is
    # opaque without the .proto schema — hex is the honest view).
    private def grpc_lines(body : Bytes) : Array(String)
      msgs = Proxy::H2::Grpc.messages(body)
      return ["(no complete gRPC messages — streaming or partial)"] if msgs.empty?
      lines = [] of String
      msgs.each_with_index do |m, i|
        lines << "▸ message ##{i + 1}  #{m.data.size}b#{m.compressed ? "  (compressed)" : ""}"
        lines.concat(hex_preview(m.data))
      end
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
        when :graphql then (op = @detail_graphql) ? graphql_detail_lines(op) : nil
        when :params  then (f = @detail_form) ? form_detail_lines(f) : nil
        end
      lines ? DetailView.new(lines, [] of String, :text, EMPTY_LINES) : nil
    end

    # Max styled lines a decoded-protocol pane renders, so a pathological document
    # can't materialise a giant line array (the decoders cap their inputs too).
    DERIVED_LINE_CAP = 20_000

    # A "▸ …" accent header line introducing a decoded-protocol section.
    private def derived_header(text : String) : Highlight::Line
      [Highlight::Span.new("▸ #{text}", Theme.accent)] of Highlight::Span
    end

    # Append `raw`'s lines to `lines`, styled per `kind`, stopping at DERIVED_LINE_CAP.
    private def append_styled(lines : Array(Highlight::Line), raw : String, kind : Symbol) : Nil
      raw.split('\n').each do |ln|
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

    private def graphql_detail_lines(op : Graphql::Op) : Array(Highlight::Line)
      lines = [] of Highlight::Line
      append_styled(lines, Graphql.display(op), :text)
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
        Highlight::Span.new("#{tag} #{f.name}", Theme.syn_string),
        Highlight::Span.new(" = ", Theme.muted),
        Highlight::Span.new(note ? "(#{note})" : f.value, note ? Theme.yellow : Theme.text),
      ] of Highlight::Span
    end
  end
end
