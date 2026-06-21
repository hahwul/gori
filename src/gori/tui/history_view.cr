require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./hex_view"
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
    QL_FIELDS  = %w(host method status path scheme body flag)
    METHOD_VAL = %w(GET POST PUT DELETE PATCH HEAD OPTIONS)

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
      @detail_scroll = 0
      @detail_pane = :request
      @detail_hex = false                # 'x' toggles a raw hex dump of the current pane (req/resp)
      @detail_hex_bytes = nil.as(Bytes?) # cached combined head+body for the current pane (hex source)
      # Windowed detail content, rebuilt only when the detail/pane changes (NOT on
      # scroll or every frame). The head/notes are pre-styled; the body is kept RAW
      # and styled per VISIBLE line, so opening a multi-MiB response is instant
      # instead of tokenising 100k+ off-screen lines up front.
      @detail_cache = nil.as(DetailView?)
    end

    # head (styled, bounded) ++ body (raw, styled lazily per visible line) ++
    # trailer (styled notes). For the WS/frames/grpc panes the whole content is in
    # `head` (bounded); only a plain request/response body uses the windowed `body`.
    private record DetailView,
      head : Array(Highlight::Line),
      body : Array(String),
      kind : Symbol,
      trailer : Array(Highlight::Line) do
      def total : Int32
        head.size + body.size + trailer.size
      end

      def line_at(i : Int32) : Highlight::Line
        return head[i] if i < head.size
        j = i - head.size
        return Highlight.body_styled(body[j], kind) if j < body.size
        trailer[j - body.size]
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
      @detail = store.get_flow(id)
      # WebSocket flows (101) carry a captured message log.
      @detail_ws = @detail.try(&.row.status) == 101 ? store.ws_messages(id) : nil
      # HTTP/2 flows link to their connection's raw frame log.
      @detail_frames = (cid = @detail.try(&.h2_conn_id)) ? store.h2_frames(cid) : nil
      @detail_scroll = 0
      @detail_pane = :request
      @detail_cache = nil
      @detail_hex_bytes = nil
      !@detail.nil?
    end

    def close_detail : Nil
      @detail = nil
      @detail_cache = nil
      @detail_frames = nil # release the h2-frame / ws-message payload arrays (can be MiB)
      @detail_ws = nil
      @detail_hex_bytes = nil
    end

    # 'x' toggles a raw hex dump of the current pane (request/response bytes).
    def toggle_detail_hex : Nil
      return if @detail_pane == :frames # frames has no raw-bytes hex; don't strand a hidden flag
      @detail_hex = !@detail_hex
      @detail_scroll = 0 # row-based offset differs from the line-based one
    end

    # Re-fetch the currently-open detail from the store (e.g. a peer instance filled
    # in the response, or appended ws/h2 frames) WITHOUT resetting the pane/scroll.
    # No-op when no detail is open. Returns true if it refreshed.
    def refresh_detail(store : Store) : Bool
      return false unless detail = @detail
      id = detail.row.id
      return false unless fresh = store.get_flow(id)
      @detail = fresh
      @detail_ws = fresh.row.status == 101 ? store.ws_messages(id) : nil
      @detail_frames = (cid = fresh.h2_conn_id) ? store.h2_frames(cid) : nil
      @detail_cache = nil # content changed → rebuild (windowed) on next render
      @detail_hex_bytes = nil
      @detail_scroll = @detail_scroll.clamp(0, detail_scroll_max) # content may have shrunk
      true
    end

    def scroll_detail(delta : Int32) : Nil
      @detail_scroll = (@detail_scroll + delta).clamp(0, detail_scroll_max)
    end

    private def detail_scroll_max : Int32
      if @detail_hex && (bytes = detail_pane_bytes)
        {HexView.rows(bytes.size) - 1, 0}.max
      else
        {detail_view.total - 1, 0}.max
      end
    end

    # Whether the current pane supports the hex view (raw request/response bytes;
    # the FRAMES pane is a synthetic log, not raw bytes).
    private def detail_hex?(detail : Store::FlowDetail) : Bool
      @detail_hex && @detail_pane != :frames
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

    # The detail sub-panes, in order: REQUEST → RESPONSE → FRAMES (the frames pane
    # exists only for an intercepted h2 flow). ←/→ walk this chain; Tab cycles it.
    private def detail_panes : Array(Symbol)
      @detail_frames ? [:request, :response, :frames] : [:request, :response]
    end

    # The chip label for a detail pane (the response pane shows WS messages for a
    # 101-Switching flow; frames only exist for an intercepted h2 connection).
    private def detail_pane_label(pane : Symbol) : String
      case pane
      when :frames   then "FRAMES (h2)"
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
      # Right cluster anchored to the edge: STATUS · SIZE · DUR (response size +
      # latency — frequently-scanned). HOST+PATH share the middle responsively so
      # both stay readable from ~80 cols up to wide terminals.
      status_x = {rect.right - 21, host_x + 10}.max
      size_x = status_x + 7
      dur_x = status_x + 14
      mid = status_x - host_x
      host_w = (mid * 2 // 5).clamp(8, 40)
      path_x = host_x + host_w + 1
      path_w = {status_x - path_x - 1, 1}.max

      screen.text(time_x, hdr_y, "TIME", Theme::MUTED)
      screen.text(method_x, hdr_y, "METHOD", Theme::MUTED)
      screen.text(proto_x, hdr_y, "PROTO", Theme::MUTED)
      screen.text(host_x, hdr_y, "HOST", Theme::MUTED)
      screen.text(path_x, hdr_y, "PATH", Theme::MUTED)
      screen.text(status_x, hdr_y, "STATUS", Theme::MUTED)
      screen.text(size_x, hdr_y, "SIZE", Theme::MUTED)
      screen.text(dur_x, hdr_y, "DUR", Theme::MUTED)
      Frame.inner_divider(screen, rect, hdr_y + 1, border: Frame.pane_border(focused))

      list_top = hdr_y + 2
      list_h = {rect.bottom - list_top, 0}.max
      ensure_visible(list_h)

      if @rows.empty?
        msg = filtering? ? "no flows match" : "waiting for traffic…"
        screen.text(time_x, list_top, msg, Theme::MUTED)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @rows.size
        row = @rows[ri]
        y = list_top + i
        selected = ri == @selected
        bg = selected ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::BG
        fg = selected ? Theme::TEXT_BRIGHT : Theme::TEXT

        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme::ACCENT, bg)
        end
        screen.text(time_x, y, fmt_time(row.created_at), Theme::MUTED, bg)
        screen.text(method_x, y, row.method, Theme.method_color(row.method), bg)
        screen.text(proto_x, y, row.scheme.upcase, Theme::MUTED, bg)
        screen.text(host_x, y, row.host, fg, bg, width: host_w)
        screen.text(path_x, y, origin_path(row.target), fg, bg, width: path_w)
        status = row.status.try(&.to_s) || "···"
        screen.text(status_x, y, status, Theme.status_color(row.status), bg)
        screen.text(size_x, y, fmt_size(row.response_size), Theme::MUTED, bg, width: 6)
        screen.text(dur_x, y, fmt_dur(row.duration_us), Theme::MUTED, bg, width: {rect.right - dur_x, 1}.max)
      end
    end

    # Local MM-DD HH:MM:SS for the captured-at micros (created_at is unix microseconds).
    # The brief date makes flows captured across days/sessions legible at a glance.
    private def fmt_time(created_at : Int64) : String
      Time.unix(created_at // 1_000_000).to_local.to_s("%m-%d %H:%M:%S")
    end

    # Compact response size (B/KB/MB), bounded to ≤6 cols. "—" until the response lands.
    private def fmt_size(bytes : Int64?) : String
      return "—" unless bytes
      return "#{bytes}B" if bytes < 1024
      if bytes < 1024 * 1024
        kb = bytes / 1024.0
        return kb < 10 ? "#{kb.round(1)}KB" : "#{kb.round.to_i}KB"
      end
      mb = bytes / (1024.0 * 1024.0)
      mb < 10 ? "#{mb.round(1)}MB" : "#{mb.round.to_i}MB"
    end

    # Compact request→response latency (ms/s), bounded. "—" until the response lands.
    private def fmt_dur(us : Int64?) : String
      return "—" unless us
      ms = us // 1000
      return "#{ms}ms" if ms < 1000
      "#{(ms / 1000.0).round(1)}s"
    end

    # Display the request target in origin-form. Plaintext forward-proxy requests
    # are captured absolute-form (`http://host/path`, the truth — P7); here we
    # strip the scheme+authority so the PATH column matches the HTTPS rows. The
    # host/scheme live in their own columns.
    private def origin_path(target : String) : String
      return target unless target.starts_with?("http://") || target.starts_with?("https://")
      scheme_end = target.index("://")
      return target unless scheme_end
      slash = target.index('/', scheme_end + 3)
      slash ? target[slash..] : "/"
    end

    def render_detail(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      detail = @detail
      unless detail
        screen.text(rect.x + 1, rect.y, "no flow selected", Theme::MUTED)
        return
      end
      # Pane strip: show ALL panes as chips with the active one highlighted, so it's
      # obvious there's more behind (←/→ walk REQUEST → RESPONSE → FRAMES).
      x = rect.x + 1
      detail_panes.each do |pane|
        active = pane == @detail_pane
        x = screen.text(x, rect.y, " #{detail_pane_label(pane)} ",
          active ? Theme::TEXT_BRIGHT : Theme::MUTED,
          active ? Theme::ACCENT_BG : Theme::BG,
          attr: active ? Attribute::Bold : Attribute::None) + 1
      end
      hex = detail_hex?(detail)
      screen.text(x + 1, rect.y, "↑/↓ scroll · #{hex ? "x:text" : "x:hex"} · esc back", Theme::MUTED)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))

      body = Rect.new(rect.x + 1, rect.y + 2, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 2), 0}.max)
      if hex && (bytes = detail_pane_bytes)
        HexView.render(screen, body, bytes, @detail_scroll)
        return
      end

      dv = detail_view
      total = dv.total
      (0...body.h).each do |i|
        li = @detail_scroll + i
        break if li >= total
        Highlight.draw(screen, body.x, body.y + i, dv.line_at(li), width: body.w) # styles only this visible line
      end
    end

    private def render_ql_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "query › "
        screen.text(rect.x + 1, rect.y, prefix, Theme::ACCENT)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme::TEXT_BRIGHT, width: rect.w - prefix.size - 2)
      elsif filtering?
        screen.text(rect.x + 1, rect.y, ": #{@query}", Theme::TEXT, width: rect.w - 10)
        count = @rows.size.to_s
        screen.text({rect.right - count.size - 1, rect.x}.max, rect.y, count, Theme::MUTED)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  host:  method:  status:>=500  path:  scheme:", Theme::MUTED)
      end
    end

    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      sugg = query_suggestions
      return if sugg.empty?
      screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme::MUTED, width: rect.w - 2)
    end

    private def suggest_values(field : String, prefix : String) : Array(String)
      values = case field
               when "scheme" then ["http", "https"]
               when "method" then METHOD_VAL
               when "status" then ["2xx", "3xx", "4xx", "5xx", ">=400", ">=500"]
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
      @detail_cache ||= build_detail_view
    end

    EMPTY_LINES = [] of Highlight::Line

    private def build_detail_view : DetailView
      detail = @detail
      return DetailView.new(EMPTY_LINES, [] of String, :text, EMPTY_LINES) unless detail
      if @detail_pane == :frames && (frames = @detail_frames)
        return DetailView.new(wrap(frame_lines(frames, detail.h2_stream_id)), [] of String, :text, EMPTY_LINES)
      end
      if @detail_pane == :response && (msgs = @detail_ws)
        return DetailView.new(wrap(ws_lines(msgs)), [] of String, :text, EMPTY_LINES)
      end
      request = @detail_pane == :request
      head, body = request ? {detail.request_head, detail.request_body} : {detail.response_head, detail.response_body}
      truncated = request ? detail.request_body_truncated? : detail.response_body_truncated?

      trailer = [] of Highlight::Line
      if truncated
        trailer << Highlight::Line.new
        trailer << [Highlight::Span.new("— body truncated at capture limit (#{Proxy::Codec::Body::CAPTURE_MAX // (1024 * 1024)} MiB); full size in the list —", Theme::YELLOW)]
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
      win = Highlight.message_windowed(head, display || body, request)
      if decode_note
        note = [] of Highlight::Line
        note << Highlight::Line.new
        color = (decode_note.includes?("unsupported") || decode_note.includes?("error")) ? Theme::YELLOW : Theme::GREEN
        note << [Highlight::Span.new("— #{decode_note} —", color)]
        trailer = note + trailer # decode note before the truncation note
      end
      DetailView.new(win.head, win.body, win.kind, trailer)
    end

    # Wrap pre-formatted plain strings (frames / ws / gRPC hex) as single-span
    # body-text lines so they share the styled rendering path.
    private def wrap(strs : Array(String)) : Array(Highlight::Line)
      strs.map { |s| [Highlight::Span.new(s, Theme::TEXT)] of Highlight::Span }
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
  end
end
