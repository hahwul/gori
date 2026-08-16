# The TARGET card's two fields — the target URL and the optional TLS SNI override: editing
# them, moving between them, READ-mode motion and copy. Reopens Gori::Tui::RepeaterView
# (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- target field (focus == :target) ---
  # The TARGET pane edits one of two single-line fields — the URL or the SNI host
  # override — selected by @target_field (^S toggles). The mutators below act on
  # whichever is active so one set of keys drives both.
  getter sni : String

  # The SNI host to present in the TLS handshake, or nil when blank (→ the dialed
  # target host is used, the usual case).
  def sni_override : String?
    s = @sni.strip
    s.empty? ? nil : s
  end

  def editing_sni? : Bool
    @target_field == :sni
  end

  # ^S (on the TARGET pane): flip between editing the URL and the SNI host. Entering
  # the SNI field homes its caret to the end; leaving it returns to the URL.
  def toggle_sni_field : Nil
    if @target_field == :sni
      @target_field = :url
    else
      @target_field = :sni
      @scx = @sni.size
      @target_mode = InputMode::Insert
    end
  end

  # Drop back to URL editing (↵/esc in the SNI field) without changing the value.
  def exit_sni_field : Nil
    @target_field = :url
  end

  def target_insert(ch : Char) : Nil
    if @target_field == :sni
      @sni = "#{@sni[0, @scx]}#{ch}#{@sni[@scx..]}"
      @scx += 1
    else
      @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
      @tcx += 1
    end
    @dirty = true
  end

  def target_backspace : Nil
    if @target_field == :sni
      return if @scx == 0
      @sni = "#{@sni[0, @scx - 1]}#{@sni[@scx..]}"
      @scx -= 1
    else
      return if @tcx == 0
      @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
      @tcx -= 1
    end
    @dirty = true
  end

  def target_move(d : Int32) : Nil
    if @target_field == :sni
      @scx = (@scx + d).clamp(0, @sni.size)
    else
      @tcx = (@tcx + d).clamp(0, @target.size)
    end
    # Cursor navigation is not a content edit — do NOT dirty (caret is never persisted),
    # mirroring edit_move/goto_request_line/hex_move.
  end

  # Home/End on the single-line target/SNI field — pure caret moves, no dirty.
  # Home/End on the target/SNI row, ⇧ EXTENDING like every other pane's.
  #
  # These two assigned the caret directly, which meant ⇧Home/⇧End DROPPED the selection the
  # shift was asking them to grow — the read cursor's anchor lives in `@target_read` and
  # nothing here told it anything. Same defect #583 fixed in `TextArea#home`/`#end_of_line`,
  # left standing on the one field that is not a TextArea. Routed through `move_cx` with a
  # delta to the line edge so the anchor rule stays in ONE place: a bare press still clears
  # it, which is what the INSERT-mode callers (who pass no `selecting`) rely on.
  def target_home(selecting : Bool = false) : Nil
    cx = @target_read.move_cx(target_active_cx, -target_active_cx, target_active_line.size, selecting: selecting)
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
  end

  def target_end(selecting : Bool = false) : Nil
    len = target_active_line.size
    cx = @target_read.move_cx(target_active_cx, len - target_active_cx, len, selecting: selecting)
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
  end

  # Forward-delete the char under the caret on the target/SNI field — a content edit.
  def target_delete : Nil
    if @target_field == :sni
      return if @scx >= @sni.size
      @sni = "#{@sni[0, @scx]}#{@sni[@scx + 1..]}"
    else
      return if @tcx >= @target.size
      @target = "#{@target[0, @tcx]}#{@target[@tcx + 1..]}"
    end
    @dirty = true
  end

  def target_read_move(dc : Int32, selecting : Bool = false) : Nil
    return if target_insert?
    line = target_active_line
    cx = @target_read.move_cx(target_active_cx, dc, line.size, selecting: selecting)
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
  end

  private def target_active_line : String
    @target_field == :sni ? @sni : @target
  end

  private def target_active_cx : Int32
    @target_field == :sni ? @scx : @tcx
  end

  def target_copy_text : String
    @target_read.copy_text(target_active_line, target_active_cx)
  end
end
