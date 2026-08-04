require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_field"

module Gori::Tui
  # A flat snapshot of the Fuzzer's advanced knobs, moved between FuzzerView (which
  # keeps them as @s_* string buffers + @config/@matcher) and FuzzAdvancedOverlay
  # (which edits them). Text fields carry "" for blank; regexes are kept as source
  # strings (compiled by the view's commit_buffers at build/persist time, unchanged).
  record AdvancedSnapshot,
    conc : String, rate : String, timeout : String, retries : String,
    max_requests : String,
    follow : Bool, calibrate : Bool, keep_alive : Bool, update_cl : Bool,
    m_status : String, m_size : String, m_words : String, m_regex : String,
    f_status : String, f_size : String, f_words : String, f_regex : String

  # The full-area popup for the Fuzzer's advanced run settings. Every engine / match
  # / filter knob gets its OWN labeled row (no more horizontal fields walked by ↑/↓,
  # no more ←/→-cycle-vs-caret overload): ↑/↓/⇥ move rows, ←/→ moves the caret on a
  # text row or flips a toggle row, esc applies + closes. Modeled on the same row
  # idiom as MineConfigOverlay/FuzzSetOverlay, and like them it rides the polymorphic
  # Overlay seam (see overlay.cr) — where "apply" IS :commit, so there is no cancel:
  # esc and click-away both write the snapshot back through the injected closure.
  class FuzzAdvancedOverlay < Overlay
    # {field key, label, kind(:text|:toggle)} in display order.
    ROWS = [
      {:conc, "Concurrency", :text},
      {:rate, "Rate (rps)", :text},
      {:timeout, "Timeout (s)", :text},
      {:retries, "Retries", :text},
      # The TRUE wire count is what this caps (retries + redirect hops each charge it) —
      # `Fuzz::CappedBackend`, the same counter `--max-requests` and MCP's `max_requests`
      # are enforced against. Blank = no cap, which is what every TUI run used to be.
      {:max_requests, "Max requests", :text},
      {:follow, "Follow redirects", :toggle},
      {:calibrate, "Auto-calibrate", :toggle},
      {:keep_alive, "Keep-alive", :toggle},
      # The Repeater's ^L / `--verbatim` and Intercept's `update_content_length:false` by
      # the same name and for the same reason: a CL / CL-TE desync template IS the payload,
      # and recomputing its Content-Length sweeps a different request than the one written.
      # ON is the old (and right) default for an ordinary sweep whose payload changed the
      # body length; OFF sends the header exactly as the template declares it.
      {:update_cl, "Auto Content-Length", :toggle},
      {:m_status, "Match status", :text},
      {:m_size, "Match size", :text},
      {:m_words, "Match words", :text},
      {:m_regex, "Match regex", :text},
      {:f_status, "Filter status", :text},
      {:f_size, "Filter size", :text},
      {:f_words, "Filter words", :text},
      {:f_regex, "Filter regex", :text},
    ]
    LABEL_W = 21 # value column offset (widest label "Auto Content-Length" + padding)

    def initialize(snap : AdvancedSnapshot)
      @sel = 0
      @scroll = 0
      @follow = snap.follow
      @calibrate = snap.calibrate
      @keep_alive = snap.keep_alive
      @update_cl = snap.update_cl
      @fields = {
        :conc         => TextField.new(snap.conc),
        :rate         => TextField.new(snap.rate),
        :timeout      => TextField.new(snap.timeout),
        :retries      => TextField.new(snap.retries),
        :max_requests => TextField.new(snap.max_requests),
        :m_status     => TextField.new(snap.m_status),
        :m_size       => TextField.new(snap.m_size),
        :m_words      => TextField.new(snap.m_words),
        :m_regex      => TextField.new(snap.m_regex),
        :f_status     => TextField.new(snap.f_status),
        :f_size       => TextField.new(snap.f_size),
        :f_words      => TextField.new(snap.f_words),
        :f_regex      => TextField.new(snap.f_regex),
      }
    end

    private def current : {Symbol, String, Symbol}
      ROWS[@sel]
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::FuzzAdvanced
    end

    def title : String
      "ADVANCED"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      "↑/↓/⇥ field · ←/→ edit · ␣ toggle · ↵ next · esc applies & closes"
    end

    # --- input --------------------------------------------------------------
    # PRE-EXISTING (kept as-is by the Overlay migration, which is behaviour-preserving):
    # the `case` value is discarded, so handle_text's commit-on-the-last-row never reaches
    # the shell — ↵ there is a no-op, not an apply. Only esc and a click-away apply. The
    # rendered hint already says "esc applies" and does not promise ↵, so this is a lost
    # convenience rather than a broken advertised key; fixing it is a behaviour change and
    # belongs in its own patch.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :commit if key.escape?
      case
      when key.tab?, key.down?    then @sel = (@sel + 1).clamp(0, ROWS.size - 1)
      when key.back_tab?, key.up? then @sel = (@sel - 1).clamp(0, ROWS.size - 1)
      else
        current[2] == :toggle ? handle_toggle(key) : handle_text(ev)
      end
      :stay
    end

    private def handle_toggle(key : Termisu::Input::Key) : Symbol
      case
      when key.left?, key.right?, key.enter?, key.space? then toggle_current
      end
      :stay
    end

    private def handle_text(ev : Termisu::Event::Key) : Symbol
      if ev.key.enter?
        # handle_key drops this :commit (see the note there), but the early return is still
        # load-bearing: without it @sel would step past the last row and `current` would
        # index ROWS out of range.
        return :commit if @sel == ROWS.size - 1
        @sel += 1
      else
        @fields[current[0]].handle_edit_key(ev)
      end
      :stay
    end

    private def toggle_current : Nil
      case current[0]
      when :follow     then @follow = !@follow
      when :calibrate  then @calibrate = !@calibrate
      when :keep_alive then @keep_alive = !@keep_alive
      when :update_cl  then @update_cl = !@update_cl
      end
    end

    def set_preedit(text : String) : Nil
      row = current
      @fields[row[0]]?.try(&.set_preedit(text)) if row[2] == :text
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROWS.size - 1)
    end

    # --- result -------------------------------------------------------------
    def snapshot : AdvancedSnapshot
      AdvancedSnapshot.new(
        conc: @fields[:conc].value, rate: @fields[:rate].value,
        timeout: @fields[:timeout].value, retries: @fields[:retries].value,
        max_requests: @fields[:max_requests].value,
        follow: @follow, calibrate: @calibrate, keep_alive: @keep_alive,
        update_cl: @update_cl,
        m_status: @fields[:m_status].value, m_size: @fields[:m_size].value,
        m_words: @fields[:m_words].value, m_regex: @fields[:m_regex].value,
        f_status: @fields[:f_status].value, f_size: @fields[:f_size].value,
        f_words: @fields[:f_words].value, f_regex: @fields[:f_regex].value)
    end

    # --- rendering ----------------------------------------------------------
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 60}.min
      h = {area.h - 4, ROWS.size + 4}.min
      return nil if w < 30 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # Rows the card can actually draw. The last two interior lines are spoken for — the hint
    # on box.bottom-2, the border on box.bottom-1 — so the list ends at box.bottom-3. ONE
    # definition, read by both render and handle_click, which is the shape every sibling
    # form uses (NotificationsOverlay, HotkeysOverlay, TabsOverlay …): a hit-test that does
    # not invert its own render selects rows the cursor was never over.
    private def list_capacity(box : Rect) : Int32
      {(box.bottom - 2) - (box.y + 1), 1}.max
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "advanced editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "ADVANCED", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      visible = list_capacity(box)
      @scroll = @sel if @sel < @scroll
      @scroll = @sel - visible + 1 if @sel >= @scroll + visible
      @scroll = @scroll.clamp(0, {ROWS.size - visible, 0}.max)
      vx = box.x + 2 + LABEL_W
      (0...visible).each do |i|
        ri = @scroll + i
        break if ri >= ROWS.size
        render_row(screen, box, ri, top + i, vx)
      end
      screen.text(box.x + 2, box.bottom - 2, "⇥/↑↓ field · ←/→ edit · space toggle · esc applies", Theme.muted, Theme.bg, width: box.w - 4)
    end

    private def render_row(screen : Screen, box : Rect, ri : Int32, y : Int32, vx : Int32) : Nil
      key, label, kind = ROWS[ri]
      foc = ri == @sel
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if foc
      screen.text(box.x + 2, y, label, foc ? Theme.text_bright : Theme.muted, bg)
      if kind == :toggle
        on = case key
             when :follow     then @follow
             when :keep_alive then @keep_alive
             when :update_cl  then @update_cl
             else                  @calibrate
             end
        screen.text(vx, y, on ? "‹ on ›" : "‹ off ›", foc ? Theme.text_bright : Theme.text, bg)
      else
        vw = {box.right - 2 - vx, 1}.max
        @fields[key].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      end
    end

    # Focus the row under a click; a click outside the card APPLIES (esc semantics), the
    # same dismissal the shell used to run through apply_close_fuzz_advanced.
    #
    # The `i < list_capacity` bound is the half that was missing: without it a click on the
    # hint row or the bottom border — both INSIDE the box, neither a drawn row — resolved to
    # @scroll + visible (+1) and focused a field the cursor was nowhere near, after which
    # render scrolled the list to follow. Reachable only when the card clips (production's
    # `layout.body` draws 11 of the 17 rows), which is why the 80x24 specs never saw it.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :commit if box.nil? || !box.contains?(mx, my)
      i = my - (box.y + 1)
      return :stay if i < 0 || i >= list_capacity(box)
      ri = @scroll + i
      @sel = ri if ri < ROWS.size
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end
  end
end
