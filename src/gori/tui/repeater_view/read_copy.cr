# READ mode: moving the read cursor through the request and response panes, and what the
# copy verbs hand the clipboard — per-pane selection, whole-buffer copy, and the plain-text
# projection each pane is read from. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # READ-mode caret move in the request column. A single-row `dc == 0` step first asks
  # whether it leaves the sub-pane entirely — the same question INS asks in `edit_move`,
  # through the same helper — so the split column is one continuous document in both modes.
  def request_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
    return if request_insert? || request_hex?
    return if dc == 0 && try_cross_req_pane(dr)
    request_read_step(dr, dc, selecting)
  end

  # PageUp / PageDown with the request pane in READ mode: the read cursor steps a screenful,
  # sized from the editor that draws the same pane. `ReadCursor#move` clamps the row itself,
  # so a page past the last line lands on it rather than doing nothing.
  #
  # Deliberately NOT through `request_read_move`: a page clamps inside its own sub-pane
  # rather than crossing into the next one, which is what `edit_page` does in INS (it never
  # went through `edit_move` either). A screenful is a viewport gesture; crossing panes on it
  # would skip past everything between the caret and the boundary.
  def request_read_page(dir : Int32, selecting : Bool = false) : Nil
    return if request_insert? || request_hex?
    request_read_step(dir * req_editor.page_rows, 0, selecting)
  end

  private def request_read_step(dr : Int32, dc : Int32, selecting : Bool) : Nil
    return if request_read_lines.empty?
    @req_read.move(req_editor, dr, dc, selecting: selecting)
  end

  def request_read_lines : Array(String)
    req_editor.lines_snapshot
  end

  # The INS branch is the other half of `pane_selection?` — see the comment there for why
  # the two must move together. `selection_text` is `String?` (nil when nothing is
  # selected); the `||` keeps the NOR path's caret-line fallback rather than letting insert
  # mode be the one place where a copy with no selection yields nothing.
  def request_copy_text : String
    if pane_insert?(:request)
      req_editor.selection_text || @req_read.copy_text(req_editor)
    else
      @req_read.copy_text(req_editor)
    end
  end

  def request_copy_all_text : String
    @req_read.copy_all(req_editor)
  end

  # The active transcript rows when the response pane is a transcript (WS / gRPC / group
  # send), else nil (a normal single response). The single source these read/copy/search
  # paths share so a new transcript mode wires into all of them at once.
  private def transcript_rows? : Array({String, Color})?
    return ws_transcript_lines if ws_mode?
    return grpc_transcript_lines if @grpc_mode
    return group_transcript_lines if group_mode?
    nil
  end

  def resp_plain_lines : Array(String)
    size, line_at = resp_line_source
    (0...size).map { |i| line_at.call(i) }
  end

  # O(1) count + lazy line fetch for the response pane the read cursor is on. THE one
  # definition of "what lines is this pane showing" — the caret, the selection, the copy, the
  # search, the wheel and the click inverse all read it, so a new pane wires into every one of
  # them by appearing here and nowhere else.
  #
  # The handshake branch comes FIRST because `transcript_rows?` answers for the whole of WS
  # mode: on a WebSocket tab both cards exist, and which one this returns is exactly what
  # `@resp_pane` decides.
  def resp_line_source
    if resp_handshake_active?
      rv = resp_view # the 101 head, the same source render_ws_handshake draws
      {rv.total, ->(i : Int32) { resp_line_text(rv, i) }}
    elsif t = transcript_rows?
      {t.size, ->(i : Int32) { t[i][0] }}
    elsif @resp_mode == :diff
      data = diff_lines
      {data.size, ->(i : Int32) { data[i].text }}
    elsif @reveal && (rl = reveal_lines)
      {rl.size, ->(i : Int32) { rl[i] }}
    else
      rv = resp_view
      {rv.total, ->(i : Int32) { resp_line_text(rv, i) }}
    end
  end

  # One-entry memo over `RespView#line_text`, the twin of `HistoryView#detail_line_text` —
  # see there for the why. In short: a BODY line is materialised out of the raw response
  # bytes on every call, and one frame asks for the same line up to four times (the row
  # list, the h-scroll clamp, the caret/selection chrome, the search overdraw). The other
  # `resp_line_source` branches hand back an already-materialised array and need no memo.
  #
  # Invalidated with the WRAP memo (`resp_wrap_reset`, `drop_resp_view_cache`): both are
  # keyed by row index alone, so a new response at the same index would otherwise be handed
  # the old one's text.
  private def resp_line_text(rv : RespView, i : Int32) : String
    return @resp_text if @resp_text_i == i
    @resp_text_i = i
    @resp_text = rv.line_text(i)
  end

  def resp_copy_text : String
    size, line_at = resp_line_source
    return "" if size <= 0
    @resp_cursor.selection_text(size, line_at) || @resp_cursor.current_line(size, line_at)
  end

  def resp_copy_all_text : String
    size, line_at = resp_line_source
    return "" if size <= 0
    # Rare full-copy path — still build once for clipboard, not per frame.
    (0...size).map { |i| line_at.call(i) }.join("\n")
  end

  def pane_copy_text : String
    case @focus
    when :request  then request_copy_text
    when :response then resp_copy_text
    when :target   then target_copy_text
    else                ""
    end
  end

  def pane_copy_all_text : String
    case @focus
    when :request  then request_copy_all_text
    when :response then resp_copy_all_text
    when :target   then target_active_line
    else                ""
    end
  end

  def pane_selection? : Bool
    case @focus
    # Two selection models, one per mode, and they can never both be live: `@req_read` is
    # the NOR band (its painter is called with `focused && !ins`), `req_editor` holds the
    # INS one. Reporting only the NOR side made "Copy selection" absent in INS even with a
    # visible ⇧-arrow band. Changed together with `request_copy_text` below — this predicate
    # drives `Runner#read_selection_active?`, which gates BOTH the space-menu entry's title
    # and `read_copy`, so claiming a selection here while copy still read `@req_read` would
    # offer "Copy selection" and then copy the caret line.
    when :request  then pane_insert?(:request) ? req_editor.selection? : @req_read.selection?
    when :response then @resp_cursor.selection?
    when :target   then !pane_insert?(:target) && @target_read.selection?
    else                false
    end
  end

  def pane_select_line : Nil
    case @focus
    when :request
      return if pane_insert?(:request)
      @req_read.select_line(req_editor)
    when :response
      size, line_at = resp_line_source
      return if size <= 0
      @resp_cursor.select_line(size, line_at)
      ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
    when :target
      return if pane_insert?(:target)
      line = target_active_line
      cx = @target_read.select_line(line.size)
      @target_field == :sni ? (@scx = cx) : (@tcx = cx)
    end
  end

  def pane_clear_selection : Nil
    case @focus
    when :request  then @req_read.clear_selection
    when :response then @resp_cursor.clear_selection
    when :target   then @target_read.clear_selection
    end
  end
end
