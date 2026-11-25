# The TARGET card's two single-line fields — the target URL and the optional TLS SNI override —
# shared by RepeaterView and FuzzerView: editing them, moving between them, READ-mode motion,
# copy, the card's height rule and the row painter. An includer holds `@target`/`@tcx`,
# `@sni`/`@scx`, `@target_field`, `@target_mode`, `@target_read`, `@focus` and `@dirty`, and
# answers `target_insert?`.
module Gori::Tui::TargetField
  TARGET_PREFIX = "›"
  SNI_PREFIX    = "SNI ›"
  # The first character each row was drawn from on the last frame (see `target_window`): 0 for
  # a row that was not the active field. A click is rebased by what was on screen, not by a
  # window recomputed after the press — `TextField#click_to_cursor` says why.
  @url_drawn_start = 0
  @sni_drawn_start = 0
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
      enter_target_insert!
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
    # mirroring edit_move/goto_request_line and the hex editor's arrows.
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

  # A `LineEdit` key (^A/^E/^U/^W, word motion, Home/End/Delete) on the active field, so the
  # field takes the shell's line keys ahead of the tab's chords like every other bar (#1379).
  def target_line_edit(action : Symbol) : Nil
    text, cx = LineEdit.apply(action, target_active_line, target_active_cx)
    @dirty = true if text != target_active_line
    if @target_field == :sni
      @sni, @scx = text, cx
    else
      @target, @tcx = text, cx
    end
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

  # The TARGET card grows to a second content row (4 high vs 3) whenever an SNI
  # override is set OR is being edited — so the override is always visible, and the
  # input row only appears once you reach for it (^S).
  private def sni_active? : Bool
    !@sni.strip.empty? || (editing_sni? && @focus == :target)
  end

  private def target_card_h : Int32
    sni_active? ? 4 : 3
  end

  private def field_base(rect : Rect, prefix : String) : Int32
    rect.x + 2 + prefix.size + 1
  end

  # A press picks the URL or SNI row. A drag keeps the active field and its anchor.
  def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
    return unless @loaded
    @target_field = (sni_active? && my == rect.y + 2) ? :sni : :url unless selecting
    sni = @target_field == :sni
    base = field_base(rect, sni ? SNI_PREFIX : TARGET_PREFIX)
    row = rect.y + (sni ? 2 : 1)
    start = sni ? @sni_drawn_start : @url_drawn_start
    lead = start > 0 ? 1 : 0 # the leading `…` column `draw_target_row` drew
    width = my == row ? {rect.right - base - 1 - lead, 1}.max : 0
    cx = @target_read.click_to_cursor(target_active_line, target_active_cx, mx - base - lead, width, selecting,
      start: start)
    sni ? (@scx = cx) : (@tcx = cx)
  end

  def target_select_word : Bool
    return false unless @loaded && !target_insert?
    return false unless cx = @target_read.select_word_at_press(target_active_line)
    @target_field == :sni ? (@scx = cx) : (@tcx = cx)
    true
  end

  # The active row's horizontal window: its first visible CHARACTER, from `Screen.input_window`,
  # the scheme every `TextField` scrolls by. The row drew from column 0 whatever the caret
  # did, so typing past the field's width (a long query string) went on blind behind a
  # trailing `…`, caret and all. `prev` is the start this row drew last frame: the window holds
  # still while the caret stays inside it, so a drag across a scrolled row selects what the
  # pointer swept instead of chasing a window that re-centred on every event.
  #
  # Unlike `input_line`, this row marks what it hides: a leading `…` once the start is scrolled
  # off, and the trailing one `Highlight.draw` puts on a value that runs past the field. Each
  # takes a column, so the caret is windowed into what the marks leave and never sits under
  # one. A narrower window only moves `start` right, so the marks only ever get added, and the
  # loop settles by its third pass.
  #
  # The caret is given its glyph's whole width, not one cell: the character under it can be a
  # CJK glyph or a zero-width char drawn as its six-column `⟨ZWSP⟩` badge, and a window that
  # reserved one cell parked that badge across the trailing `…` and the card border. The
  # extra columns ride in as `input_window`'s preedit, which it measures and never draws.
  private def target_window(value : String, cx : Int32, w : Int32, prev : Int32) : Int32
    return 0 if w < 3 # no room for a mark and a caret: draw from the start, as before
    caret_cols = cx < value.size ? Screen.grapheme_cols(value[cx].to_s) : 1
    pad = " " * (caret_cols - 1)
    lead = trail = 0
    start = 0
    3.times do
      start = Screen.input_window(value, cx, pad, w - lead - trail, prev)
      l = start > 0 ? 1 : 0
      t = target_tail_cut?(value, start, w - l) ? 1 : 0
      break if l <= lead && t <= trail
      lead, trail = {lead, l}.max, {trail, t}.max
    end
    start
  end

  # Does `value` from `start` run past `width` columns — the test `Highlight.draw` makes before
  # it spends the last column on a trailing `…`? Bounded, as that one is.
  private def target_tail_cut?(value : String, start : Int32, width : Int32) : Bool
    Screen.draw_width_upto(value[start..], width + 1) > width
  end

  # One single-line field row of the TARGET card: a marker prefix, then the value,
  # with the block caret + terminal cursor when this row is the active field.
  #
  # The active row is windowed around its caret (`target_window`). A leading `…` stands in
  # front of a scrolled-off start, the text starts one column later, and every measure below
  # (env colouring, band, caret) is taken on the same window, so they stay over the glyphs
  # they name. `target_click_to_cursor` inverts it with the start this frame records.
  private def draw_target_row(screen : Screen, rect : Rect, row : Int32, prefix : String, value : String,
                              cx : Int32, active : Bool, insert : Bool) : Nil
    screen.text(rect.x + 2, row, prefix, active ? Theme.accent : Theme.muted)
    base = field_base(rect, prefix)
    w = {rect.right - base - 1, 1}.max
    sni = prefix == SNI_PREFIX
    start = active ? target_window(value, cx, w, sni ? @sni_drawn_start : @url_drawn_start) : 0
    sni ? (@sni_drawn_start = start) : (@url_drawn_start = start)
    lead = start > 0 ? 1 : 0
    tx = base + lead # where the visible text starts
    tw = w - lead    # and how wide it may run, its trailing `…` included
    screen.cell(base, row, '…', Theme.muted, Theme.bg) if lead > 0
    line = Highlight.env_line(value, Theme.text_bright)
    # Coloured on the WHOLE value, then cut: a `$TOKEN` straddling the window's left edge keeps
    # the colour its full name earned instead of being re-read from its visible tail.
    line = Highlight.slice_left(line, Screen.draw_width(value[0, start])) if start > 0
    Highlight.draw(screen, tx, row, line, width: tw)
    return unless active
    # AFTER the value, and before the caret below. `Highlight.draw` writes its own `bg`
    # into every cell it touches, so a band painted first was applied and erased on the
    # same frame: ⇧←/→ on this row selected, `y` copied the right slice, and the operator
    # saw nothing. The caret still goes last, because when the selection grows LEFTWARD
    # the caret cell is inside the span and the band would otherwise erase it.
    paint_target_band(screen, tx, row, tw, value, start, cx) unless insert
    paint_target_caret(screen, tx, row, tw, value, start, cx, insert)
  end

  # The block caret + terminal cursor on the windowed text that starts at `tx`.
  #
  # column_width — the measure the selection tint already uses on this same value in this
  # same render, and the exact inverse of the Screen.column_for that target_click_to_cursor
  # uses to turn a click back into `cx`. display_width scored a zero-width char as 0, so the
  # three disagreed: the tint covered one span, the caret sat a column left of its glyph, and
  # a click landed a character off. A URL carrying U+200B is ordinary traffic for this tool
  # (it is a stock filter-bypass payload), so this is reachable, not theoretical.
  #
  # The caret's own glyph stays inside the text's columns (`target_window` sized the window
  # for it). On a row too narrow to hold it anyway, a space, as `Screen#input_line` draws.
  private def paint_target_caret(screen : Screen, tx : Int32, row : Int32, tw : Int32, value : String,
                                 start : Int32, cx : Int32, insert : Bool) : Nil
    cursor_x = tx + Screen.draw_width(value[start, {cx - start, 0}.max])
    limit = tx + tw - (target_tail_cut?(value, start, tw) ? 1 : 0)
    return unless cursor_x < limit
    ch = cx < value.size ? value[cx] : ' '
    ch = ' ' if cursor_x + Screen.grapheme_cols(ch.to_s) > limit
    screen.cell(cursor_x, row, ch, Theme.bg, insert ? Theme.accent : Theme.accent_bg)
    screen.cursor(cursor_x, row)
  end

  # The READ selection band over the windowed text that starts at `tx`, `tw` columns wide.
  #
  # Clipped to the text's own columns: the band used to run on to the screen's edge, over
  # the trailing `…` and the card's border, so a selected long URL read as if it ended
  # there. It stops short of the trailing `…` the same way the text does.
  private def paint_target_band(screen : Screen, tx : Int32, row : Int32, tw : Int32, value : String,
                                start : Int32, cx : Int32) : Nil
    return unless span = @target_read.selection_span(cx)
    shown = value[start..]
    bw = target_tail_cut?(value, start, tw) ? tw - 1 : tw
    screen.char_span_bg(tx, row, shown, (span[0] - start).clamp(0, shown.size),
      (span[1] - start).clamp(0, shown.size), Theme.accent_bg, width: bw)
  end

  # Pointer moved with the button held over the target card — extend from the press.
  #
  # READ mode only, because that is the only mode whose band `draw_target_row` paints
  # (`active && !insert`). Extending in INSERT would plant an anchor nothing draws and
  # `target_copy_text` would then hand back a slice the operator never saw selected — a
  # silent selection is worse than none. The INSERT half of this field has no selection at
  # all yet; when it grows one, this guard is what lifts.
  def target_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
    return if target_insert?
    target_click_to_cursor(rect, mx, my, selecting: true)
  end
end

# The Repeater's half: the module above, plus the per-send TLS fingerprint. Reopens
# Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  include TargetField

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

  # `␣Pt`: advance to the next fingerprint. Cycles nil → chrome → firefox → safari → curl → nil,
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
