require "./screen"
require "./theme"
require "./frame"
require "./text_field"

module Gori::Tui
  # A flat snapshot of the Fuzzer's advanced knobs, moved between FuzzerView (which
  # keeps them as @s_* string buffers + @config/@matcher) and FuzzAdvancedOverlay
  # (which edits them). Text fields carry "" for blank; regexes are kept as source
  # strings (compiled by the view's commit_buffers at build/persist time, unchanged).
  record AdvancedSnapshot,
    conc : String, rate : String, timeout : String, retries : String,
    follow : Bool, calibrate : Bool,
    m_status : String, m_size : String, m_words : String, m_regex : String,
    f_status : String, f_size : String, f_words : String, f_regex : String

  # The full-area popup for the Fuzzer's advanced run settings. Every engine / match
  # / filter knob gets its OWN labeled row (no more horizontal fields walked by ↑/↓,
  # no more ←/→-cycle-vs-caret overload): ↑/↓/⇥ move rows, ←/→ moves the caret on a
  # text row or flips a toggle row, esc applies + closes. Modeled on the same row
  # idiom as MineConfigOverlay/FuzzSetOverlay.
  class FuzzAdvancedOverlay
    # {field key, label, kind(:text|:toggle)} in display order.
    ROWS = [
      {:conc, "Concurrency", :text},
      {:rate, "Rate (rps)", :text},
      {:timeout, "Timeout (s)", :text},
      {:retries, "Retries", :text},
      {:follow, "Follow redirects", :toggle},
      {:calibrate, "Auto-calibrate", :toggle},
      {:m_status, "Match status", :text},
      {:m_size, "Match size", :text},
      {:m_words, "Match words", :text},
      {:m_regex, "Match regex", :text},
      {:f_status, "Filter status", :text},
      {:f_size, "Filter size", :text},
      {:f_words, "Filter words", :text},
      {:f_regex, "Filter regex", :text},
    ]
    LABEL_W = 18 # value column offset (widest label "Follow redirects" + padding)

    def initialize(snap : AdvancedSnapshot)
      @sel = 0
      @scroll = 0
      @follow = snap.follow
      @calibrate = snap.calibrate
      @fields = {
        :conc     => TextField.new(snap.conc),
        :rate     => TextField.new(snap.rate),
        :timeout  => TextField.new(snap.timeout),
        :retries  => TextField.new(snap.retries),
        :m_status => TextField.new(snap.m_status),
        :m_size   => TextField.new(snap.m_size),
        :m_words  => TextField.new(snap.m_words),
        :m_regex  => TextField.new(snap.m_regex),
        :f_status => TextField.new(snap.f_status),
        :f_size   => TextField.new(snap.f_size),
        :f_words  => TextField.new(snap.f_words),
        :f_regex  => TextField.new(snap.f_regex),
      }
    end

    private def current : {Symbol, String, Symbol}
      ROWS[@sel]
    end

    # --- input --------------------------------------------------------------
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :apply if key.escape?
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
        return :apply if @sel == ROWS.size - 1
        @sel += 1
      else
        @fields[current[0]].handle_edit_key(ev)
      end
      :stay
    end

    private def toggle_current : Nil
      case current[0]
      when :follow    then @follow = !@follow
      when :calibrate then @calibrate = !@calibrate
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
        follow: @follow, calibrate: @calibrate,
        m_status: @fields[:m_status].value, m_size: @fields[:m_size].value,
        m_words: @fields[:m_words].value, m_regex: @fields[:m_regex].value,
        f_status: @fields[:f_status].value, f_size: @fields[:f_size].value,
        f_words: @fields[:f_words].value, f_regex: @fields[:f_regex].value)
    end

    # --- rendering ----------------------------------------------------------
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 56}.min
      h = {area.h - 4, ROWS.size + 4}.min
      return nil if w < 30 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "advanced editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "ADVANCED", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      visible = {(box.bottom - 2) - top, 1}.max # last interior row reserved for the hint
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
        on = key == :follow ? @follow : @calibrate
        screen.text(vx, y, on ? "‹ on ›" : "‹ off ›", foc ? Theme.text_bright : Theme.text, bg)
      else
        vw = {box.right - 2 - vx, 1}.max
        @fields[key].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      end
    end

    def handle_click(box : Rect, mx : Int32, my : Int32) : Bool
      return false unless box.contains?(mx, my)
      i = my - (box.y + 1)
      ri = @scroll + i
      @sel = ri if 0 <= i && 0 <= ri < ROWS.size
      true
    end
  end
end
