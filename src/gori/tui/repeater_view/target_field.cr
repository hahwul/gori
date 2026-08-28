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

  # --- per-send TLS fingerprint (#844) --------------------------------------------------
  #
  # The cycle order: no override, then the presets in `Settings::TLS_PRESETS` order. `nil`
  # leads because it is the default and the way back — a tab that has been cycled all the way
  # round is where it started, and there is no separate "clear" key to find.

  # The fingerprint this tab sends with, or nil for the destination's own policy.
  def tls_preset : String?
    @tls_preset
  end

  # Is this tab's fingerprint override actually going to shape a ClientHello? An http:// target
  # has no handshake to shape, so the value sits there inert.
  #
  # Deliberately NOT a silent reset of `@tls_preset` when the target is plaintext — the
  # operator set it, it is persisted, and retargeting back to https:// must bring it back
  # (P4). The chip goes muted instead, which says "set, and doing nothing" rather than
  # discarding the choice or claiming it applies.
  def tls_preset_live? : Bool
    return false if @tls_preset.nil?
    https_target?
  end

  # Is the target field an `https://` URL? A PREFIX test, not `parse_target` — this is called
  # from `render_target` on every drawn frame, and `parse_target` is `Env.expand` plus a
  # `URI.parse`, i.e. an env scan and a URL parse per frame to pick one chip's colour. The
  # chip's LABEL was already kept off that path (see `tls_chip_label`); routing the colour
  # through the full parse put it straight back.
  #
  # The one case the two answers differ on is a target whose scheme comes from a variable
  # (`$BASE/path`), where this says "not https" and the parse would too — `parse_target`
  # prepends `http://` to anything with no `://`, and `$BASE` has none. A target written
  # `$SCHEME://host` is the genuine gap, and it fails SAFE: the chip goes muted, which
  # understates rather than overstates what the handshake will carry.
  private def https_target? : Bool
    t = @target.lstrip
    t.size >= 8 && t[0, 8].compare("https://", case_insensitive: true) == 0
  end

  # `␣T`: advance to the next fingerprint. Cycles nil → chrome → firefox → safari → curl → nil,
  # so every value including "no override" is reachable with one key and nothing has to be
  # typed — which is also why an unknown preset can never originate here.
  def cycle_tls_preset : String?
    names = Settings::TLS_PRESET_NAMES
    current = @tls_preset
    @tls_preset =
      if current.nil?
        names.first?
      else
        idx = names.index(current)
        # A value this build does not know (a row written by another version) cycles to "none"
        # rather than to a neighbour it has no position among.
        idx.nil? ? nil : names[idx + 1]?
      end
    @dirty = true
    @tls_preset
  end
end
