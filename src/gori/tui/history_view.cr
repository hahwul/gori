require "./screen"
require "./theme"
require "./frame"
require "./highlight"
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
      @rows = [] of Store::FlowRow
      @index = {} of Int64 => Int32 # flow id -> position in @rows
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
      reindex
      @filter_dirty = false
      @selected =
        if @follow
          0
        elsif prev_id && (idx = @index[prev_id]?)
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
        return if @index.has_key?(event.id)
        if row = store.flow_row(event.id)
          # Newest-first: prepend so the latest sits at the top. Positions of all
          # existing rows shift by one, so reindex (bounded by MAX_ROWS).
          @rows.unshift(row)
          reindex
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
        if (idx = @index[event.id]?) && (row = store.flow_row(event.id))
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
      !@detail.nil?
    end

    def close_detail : Nil
      @detail = nil
    end

    def scroll_detail(delta : Int32) : Nil
      @detail_scroll = (@detail_scroll + delta).clamp(0, {detail_styled.size - 1, 0}.max)
    end

    def toggle_pane : Nil
      @detail_pane = case @detail_pane
                     when :request  then :response
                     when :response then (@detail_frames ? :frames : :request)
                     else                :request
                     end
      @detail_scroll = 0
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
      method_x = rect.x + 10
      proto_x = rect.x + 18
      host_x = rect.x + 25
      path_x = rect.x + 56
      status_x = {rect.right - 7, path_x + 4}.max
      host_w = {path_x - host_x - 1, 1}.max
      path_w = {status_x - path_x - 1, 1}.max

      screen.text(time_x, hdr_y, "TIME", Theme::MUTED)
      screen.text(method_x, hdr_y, "METHOD", Theme::MUTED)
      screen.text(proto_x, hdr_y, "PROTO", Theme::MUTED)
      screen.text(host_x, hdr_y, "HOST", Theme::MUTED)
      screen.text(path_x, hdr_y, "PATH", Theme::MUTED)
      screen.text(status_x, hdr_y, "STATUS", Theme::MUTED)
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
      end
    end

    # Local HH:MM:SS for the captured-at micros (created_at is unix microseconds).
    private def fmt_time(created_at : Int64) : String
      Time.unix(created_at // 1_000_000).to_local.to_s("%H:%M:%S")
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
      title = if @detail_pane == :frames
                "FRAMES (h2)"
              elsif @detail_pane == :response && @detail_ws
                "MESSAGES"
              else
                @detail_pane.to_s.upcase
              end
      screen.text(rect.x + 1, rect.y, title, Theme::ACCENT, attr: Attribute::Bold)
      screen.text(rect.x + 12, rect.y, "tab: switch · esc: back", Theme::MUTED)
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))

      lines = detail_styled
      top = rect.y + 2
      vis = {rect.bottom - top, 0}.max
      (0...vis).each do |i|
        li = @detail_scroll + i
        break if li >= lines.size
        Highlight.draw(screen, rect.x + 1, top + i, lines[li], width: rect.w - 2)
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

    # Rebuild the id→position index from @rows (after a reload or a window trim).
    private def reindex : Nil
      @index = {} of Int64 => Int32
      @rows.each_with_index { |r, i| @index[r.id] = i }
    end

    # Drop the oldest rows so the window stays at MAX_ROWS. Newest-first, so the
    # oldest are at the END — pop them. Selection/scroll live near the top (newest)
    # and are unaffected, but clamp in case the user had scrolled into the tail.
    # Batched (see TRIM_SLACK) so the O(n) reindex amortizes, not per flow.
    private def trim_window : Nil
      drop = @rows.size - @max_rows
      return if drop <= 0
      @rows.pop(drop)
      reindex
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = @scroll.clamp(0, {@rows.size - 1, 0}.max)
    end

    # The detail body as styled lines (request/response head + body with HTTP
    # syntax highlighting). The non-HTTP panes — raw h2 frames, WebSocket
    # messages, opaque gRPC hex — carry no code to colour, so they wrap as plain
    # body text; only their HTTP head (gRPC) gets highlighted.
    private def detail_styled : Array(Highlight::Line)
      detail = @detail
      return [] of Highlight::Line unless detail
      if @detail_pane == :frames && (frames = @detail_frames)
        return wrap(frame_lines(frames, detail.h2_stream_id))
      end
      if @detail_pane == :response && (msgs = @detail_ws)
        return wrap(ws_lines(msgs))
      end
      request = @detail_pane == :request
      head, body = request ? {detail.request_head, detail.request_body} : {detail.response_head, detail.response_body}
      truncated = request ? detail.request_body_truncated? : detail.response_body_truncated?
      lines =
        if (body && !body.empty?) && grpc_body?(head)
          ls = Highlight.message(head, nil, request)
          ls << Highlight::Line.new
          ls.concat(wrap(grpc_lines(body)))
          ls
        else
          Highlight.message(head, body, request)
        end
      if truncated
        lines << Highlight::Line.new
        lines << [Highlight::Span.new("— body truncated at capture limit (#{Proxy::Codec::Body::CAPTURE_MAX // (1024 * 1024)} MiB); full size in the list —", Theme::YELLOW)]
      end
      lines
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
