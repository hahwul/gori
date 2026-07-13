require "termisu"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./layout"
require "./tutorial"
require "../settings"

module Gori::Tui
  # The first-run setup wizard: a standalone, full-screen, step-by-step TUI that
  # helps a brand-new user configure gori before the project picker. Auto-launched
  # once (App#run_tui, when settings.json doesn't exist yet) and re-runnable via
  # `gori wizard`. A config-only tool — no Session/proxy/CA — so it just edits the
  # global Settings + live Theme, mirroring ProjectPicker's run-loop/render shape.
  #
  # Steps: NETWORK (bind ip/port) → THEME (list + live preview) → REVIEW (recap + finish).
  #
  # Edits are STAGED in wizard-local fields and committed to Settings only on
  # finish, so "skip" (Esc) is coherent: it reverts the live theme preview to the
  # baseline, leaves Settings untouched, and persists once (materializing
  # settings.json so the wizard never auto-launches again).
  class SetupWizard
    LABEL_W      =  9 # widest bind label ("Bind Port")
    PREVIEW_W    = 30 # theme-preview panel width (two-column theme step)
    PREVIEW_GAP  =  2
    LIST_MIN     = 24 # minimum theme-list width before the preview is dropped
    THEME_VP_MAX = 10 # most theme rows shown at once

    enum Step
      Bind       # bind ip/port
      Appearance # theme (named Appearance to avoid clashing with the Theme module)
      Review     # recap + finish
    end

    def initialize(@term : Termisu)
      @backend = TermisuBackend.new(@term)
      @step = Step::Bind
      # Bind step — staged values prefilled from the live Settings (which already
      # reflect any `gori tui --port` flag).
      @ip = Settings.bind_host
      @port = Settings.bind_port.to_s
      @bind_field = :ip  # :ip | :port
      @cursor = @ip.size # per-field caret (mid-string edit, like SettingsView)
      @preedit = ""      # live IME composition for the focused bind field
      @status = nil.as(String?)
      # Theme step.
      @theme_name = Theme.canonical(Settings.theme)
      @theme_baseline = Theme.active_name # reverted on skip
      @theme_scroll = 0
      @resized = false # forces a full repaint (resize OR a live theme swap)
      @running = false
      # Review step — offer a guided TUI tour after setup. `@launch_tutorial` is set
      # on finish and read by `run` (below) to launch the tour in this same terminal.
      @offer = :tour # :tour | :skip
      @launch_tutorial = false
    end

    # Run the wizard to completion (finish) or skip. Returns when the user is done;
    # the caller (App#run_tui or `gori wizard`) continues afterward.
    def run : Nil
      Theme.load_custom # pick up any user themes dropped under <GORI_HOME>/themes
      @theme_name = Theme.canonical(@theme_name)
      @theme_baseline = Theme.active_name
      @running = true
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          @resized = true # buffer already resized; force a full repaint next frame
        when Termisu::Event::Key
          handle_key(ev)
        when Termisu::Event::Mouse
          handle_mouse(ev)
        when Termisu::Event::Preedit
          @preedit = ev.text # live IME composition; the committed key clears it
        end
        break unless @running
      end
      # Opted into the tour on the Review step → run it now, reusing this terminal
      # (already enhanced-keyboard + mouse enabled). Skip/Esc leaves it false.
      Tutorial.new(@term).run if @launch_tutorial
    end

    # --- input ---------------------------------------------------------------

    private def handle_key(ev : Termisu::Event::Key) : Nil
      @preedit = "" # any committed key ends an in-progress IME composition
      key = ev.key
      if ev.ctrl_c? || key.escape?
        skip # Esc / ^C exits the wizard (revert preview, persist defaults)
        return
      end
      case @step
      when Step::Bind       then handle_bind_key(ev)
      when Step::Appearance then handle_theme_key(ev)
      when Step::Review     then handle_review_key(ev)
      end
    end

    # Bind step: two text fields. ↵/⇥ moves ip→port then validates + advances;
    # ↑/↓ switches field; ←/→ moves the caret; type to edit.
    private def handle_bind_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter? || key.tab?
        @bind_field == :ip ? switch_bind_field(:port) : advance_from_bind
      elsif key.up?
        switch_bind_field(:ip)
      elsif key.down?
        switch_bind_field(:port)
      elsif key.left?
        move_cursor(-1)
      elsif key.right?
        move_cursor(1)
      elsif key.backspace?
        bind_backspace
      elsif c = typed_char(ev)
        bind_insert(c)
      end
    end

    # The printable character a key event carries, or nil for a non-text key (or a
    # ctrl/alt combo, which must not type into a field).
    private def typed_char(ev : Termisu::Event::Key) : Char?
      return nil if ev.ctrl? || ev.alt?
      ev.char || ev.key.to_char
    end

    # Theme step: ↑/↓/←/→ cycle the selection (live-previewed); ↵/⇥ next; ⇧⇥ back.
    private def handle_theme_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter? || key.tab?
        @step = Step::Review
      elsif key.back_tab?
        back_to_bind
      elsif key.up? || key.left?
        cycle_theme(-1)
      elsif key.down? || key.right?
        cycle_theme(1)
      end
    end

    # Review step: ↑/↓ pick the tour offer; ↵ finishes (commit + persist, then
    # launch the tour iff selected); ⇧⇥ back.
    private def handle_review_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter?
        finish
      elsif key.up? || key.down?
        @offer = @offer == :tour ? :skip : :tour
      elsif key.back_tab?
        @step = Step::Appearance
      end
    end

    private def back_to_bind : Nil
      @step = Step::Bind
      @bind_field = :ip
      @cursor = @ip.size
    end

    private def advance_from_bind : Nil
      unless valid_port?(@port)
        @status = "invalid port (0-65535)"
        return
      end
      @status = nil
      @step = Step::Appearance
    end

    private def valid_port?(s : String) : Bool
      p = s.strip.to_i?
      !p.nil? && 0 <= p <= 65535
    end

    private def bind_value : String
      @bind_field == :ip ? @ip : @port
    end

    private def set_bind_value(v : String) : Nil
      @bind_field == :ip ? (@ip = v) : (@port = v)
    end

    private def switch_bind_field(f : Symbol) : Nil
      @bind_field = f
      @cursor = bind_value.size
      @preedit = ""
    end

    private def move_cursor(delta : Int32) : Nil
      @cursor = (@cursor + delta).clamp(0, bind_value.size)
    end

    private def bind_insert(ch : Char) : Nil
      v = bind_value
      c = @cursor.clamp(0, v.size)
      set_bind_value("#{v[0, c]}#{ch}#{v[c..]}")
      @cursor = c + 1
      @status = nil
    end

    private def bind_backspace : Nil
      return if @cursor == 0
      v = bind_value
      c = @cursor.clamp(0, v.size)
      set_bind_value("#{v[0, c - 1]}#{v[c..]}")
      @cursor = c - 1
      @status = nil
    end

    # Live-preview the chosen theme (re-themes the wizard chrome + the picker that
    # follows). A theme swap leaves stale-coloured cells under the diff renderer, so
    # force a full repaint — same reason Runner#preview_theme sets @resized.
    private def cycle_theme(delta : Int32) : Nil
      names = Theme.available
      return if names.empty?
      i = names.index(@theme_name) || 0
      @theme_name = names[(i + delta) % names.size] # Crystal % is floored → -1 wraps
      Theme.apply(@theme_name)
      @resized = true
    end

    # Commit the staged choices and persist. The live palette is already @theme_name.
    private def finish : Nil
      Settings.bind_host = effective_ip
      Settings.bind_port = @port.strip.to_i? || Settings.bind_port
      Settings.theme = @theme_name
      Settings.save
      @launch_tutorial = @offer == :tour # `run` launches the tour after the loop
      @running = false
    end

    # Exit without committing: revert the live theme preview to the baseline, leave
    # Settings untouched, but persist once so settings.json exists (the first-run
    # gate depends on the file, not its contents).
    private def skip : Nil
      Theme.apply(@theme_baseline)
      @resized = true
      Settings.save
      @running = false
    end

    private def effective_ip : String
      ip = @ip.strip
      ip.empty? ? "127.0.0.1" : ip
    end

    # --- mouse ---------------------------------------------------------------

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? || ev.wheel?
      mx, my = ev.x - 1, ev.y - 1 # termisu mouse coords are 1-based
      if ev.wheel?
        if @step.appearance? && (ev.button.wheel_up? || ev.button.wheel_down?)
          cycle_theme(ev.button.wheel_up? ? -1 : 1)
        end
        return
      end
      case @step
      when Step::Appearance then click_theme(mx, my)
      end
    end

    private def click_theme(mx : Int32, my : Int32) : Nil
      w, h = @backend.size
      box = step_card(w, h)
      return unless box.contains?(mx, my)
      names = Theme.available
      return if names.empty?
      vp = {box.h - 6, 1}.max
      row = my - (box.y + 2)
      return unless 0 <= row < vp
      i = @theme_scroll + row
      return unless i < names.size
      @theme_name = names[i]
      Theme.apply(@theme_name)
      @resized = true
    end

    # --- geometry ------------------------------------------------------------

    # The centred step card for `w`×`h`. The THEME step is wider (room for the
    # preview panel beside the list); the rest use a settings-sized card. Height is
    # content + 6 rows of chrome, clamped to the space between the header and the
    # hint. The ONE source of this geometry — render and the mouse hit-tests share it.
    private def step_card(w : Int32, h : Int32) : Rect
      cols = @step.appearance? ? 84 : 64
      inner = {w - 4, cols}.min
      cw = {inner, 34}.max
      avail = {h - 3, 3}.max # rows between the header (y0-1) and the hint (y h-1)
      ch = {content_rows + 6, avail}.min
      cx = {(w - cw) // 2, 0}.max
      cy = 2 + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    # Interior content rows a step draws (below the card's top border + 1 pad row).
    # Must be ACCURATE for the fixed-layout steps: `step_fits?` rejects a terminal too
    # short to hold them, and render_* draw at fixed offsets up to `box.y + 2 + this`.
    private def content_rows : Int32
      case @step
      when Step::Bind   then 8 # heading, gap, ip, port, gap, 2 info lines, status
      when Step::Review then 8 # title, gap, 2 recap rows, gap, offer prompt, 2 offer rows
      # ≥7 so the preview panel (header + 3 status rows) is never clipped, capped so a
      # long theme list scrolls (the list viewport derives from the card height) instead
      # of demanding the whole screen.
      else { {Theme.available.size, 7}.max, THEME_VP_MAX }.min # appearance
      end
    end

    # Whether the current step's card can hold its content at height `h`. The theme
    # step scrolls (its viewport derives from the card height) so it fits any usable
    # size; the fixed-layout steps draw at fixed offsets and need `content_rows` rows
    # below the top border + pad, i.e. a card height of at least `content_rows + 3`.
    private def step_fits?(h : Int32) : Bool
      return true if @step.appearance?
      step_card(@backend.size[0], h).h - 3 >= content_rows
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      # Below the global minimum, or too short for THIS step's card (the fixed-layout
      # steps would otherwise draw their lower rows over the card border / footer).
      unless Layout.usable?(w, h) && step_fits?(h)
        screen.text(0, 0, "terminal too small for the setup wizard — resize and retry", Theme.red)
        @term.hide_cursor
        flush
        return
      end

      render_header(screen, w)
      box = step_card(w, h)
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      case @step
      when Step::Bind       then render_bind(screen, box)
      when Step::Appearance then render_theme(screen, box)
      when Step::Review     then render_review(screen, box)
      end
      render_footer(screen, w, h)

      if pos = screen.desired_cursor
        @term.set_cursor(pos[0], pos[1], visible: true)
      else
        @term.hide_cursor
      end
      flush
    end

    private def flush : Nil
      if @resized
        @term.sync # full repaint after a resize or a live theme swap
        @resized = false
      else
        @term.render
      end
    end

    private def render_header(screen : Screen, w : Int32) : Nil
      x = screen.text(2, 0, "gori", Theme.text_bright, Theme.bg, attr: Attribute::Bold)
      screen.text(x + 1, 0, "· setup wizard", Theme.muted, Theme.bg)
      prog = progress_label
      screen.text({w - prog.size - 2, 0}.max, 0, prog, Theme.muted, Theme.bg)
    end

    private def progress_label : String
      case @step
      when Step::Bind       then "step 1 of 2"
      when Step::Appearance then "step 2 of 2"
      else                       "review"
      end
    end

    private def card_title : String
      case @step
      when Step::Bind       then "NETWORK · global default"
      when Step::Appearance then "THEME · appearance"
      else                       "REVIEW"
      end
    end

    private def render_footer(screen : Screen, w : Int32, h : Int32) : Nil
      hint = case @step
             when Step::Bind       then "↵ next · ↑/↓ field · esc skip"
             when Step::Appearance then "↑/↓ pick theme · ↵ next · ⇧⇥ back · esc skip"
             else                       "↑/↓ choose · ↵ confirm · ⇧⇥ back · esc skip"
             end
      screen.text({(w - hint.size) // 2, 0}.max, h - 1, hint, Theme.muted, Theme.bg)
    end

    private def render_bind(screen : Screen, box : Rect) : Nil
      ix = box.x + 3
      iw = {box.w - 6, 1}.max
      screen.text(ix, box.y + 2, "Global default bind (projects inherit this)", Theme.text, Theme.panel, width: iw)
      fy = box.y + 4
      render_field(screen, box, fy, "Bind IP", @ip, @bind_field == :ip)
      render_field(screen, box, fy + 1, "Bind Port", @port, @bind_field == :port)
      # Two muted lines: this is the *global* layer only. Projects may pin their own
      # bind; -l/-p override settings for one process and are not written to disk.
      # Keep each line ≤ ~56 chars so a 64-col card (iw ≈ 58) never clips mid-word.
      screen.text(ix, fy + 3, "Projects inherit this unless they pin their own bind.", Theme.muted, Theme.panel, width: iw)
      screen.text(ix, fy + 4, "Settings later · Project tab to pin · -l/-p one run.", Theme.muted, Theme.panel, width: iw)
      if st = @status
        screen.text(ix, fy + 5, "• #{st}", Theme.yellow, Theme.panel, width: iw)
      end
    end

    private def render_field(screen : Screen, box : Rect, ry : Int32, label : String, value : String, focused : Bool) : Nil
      bg = focused ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, focused ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, ry, label, focused ? Theme.text_bright : Theme.text, bg)
      vx = box.x + 3 + LABEL_W + 2
      vw = {box.right - vx - 1, 1}.max
      if focused
        # Render via input_line even when empty so the terminal's IME anchors here.
        screen.input_line(vx, ry, value, @cursor, @preedit, Theme.text_bright, bg, width: vw)
      else
        screen.text(vx, ry, value, Theme.text, bg, width: vw)
      end
    end

    # Two columns: a scrollable theme list (left) and a live preview (right). On a
    # narrow card the preview is dropped and the list takes the full width.
    private def render_theme(screen : Screen, box : Rect) : Nil
      names = Theme.available
      return if names.empty?
      sel = names.index(@theme_name) || 0
      vp = {box.h - 6, 1}.max
      list_full = box.w - 2
      two_col = list_full >= LIST_MIN + PREVIEW_GAP + PREVIEW_W
      list_w = two_col ? list_full - PREVIEW_GAP - PREVIEW_W : list_full

      # Scroll-follow: clamp to a valid window, then keep `sel` on screen.
      @theme_scroll = @theme_scroll.clamp(0, {names.size - vp, 0}.max)
      @theme_scroll = sel if sel < @theme_scroll
      @theme_scroll = sel - vp + 1 if sel >= @theme_scroll + vp

      list_top = box.y + 2
      vp.times do |row|
        i = @theme_scroll + row
        break if i >= names.size
        draw_theme_row(screen, box, list_w, names[i], i == sel, list_top + row,
          up: row == 0 && @theme_scroll > 0,
          down: row == vp - 1 && i < names.size - 1)
      end

      if two_col
        px = box.x + 1 + list_w + PREVIEW_GAP
        render_theme_preview(screen, Rect.new(px, list_top, PREVIEW_W, vp), names[sel])
      end
    end

    private def draw_theme_row(screen : Screen, box : Rect, list_w : Int32, name : String,
                               selected : Bool, ry : Int32, *, up : Bool, down : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, list_w, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      mark_x = box.x + list_w # last column of the list area
      swatch_w = 7
      sx = mark_x - 1 - swatch_w
      name_w = {sx - (box.x + 5) - 1, 1}.max
      screen.text(box.x + 5, ry, name, selected ? Theme.text_bright : Theme.text, bg, width: name_w)
      draw_swatch(screen, sx, ry, name)
      if up && down
        screen.cell(mark_x, ry, '↕', Theme.muted, bg)
      elsif up
        screen.cell(mark_x, ry, '▲', Theme.muted, bg)
      elsif down
        screen.cell(mark_x, ry, '▼', Theme.muted, bg)
      end
    end

    # A 7-cell strip in the theme's OWN palette (Theme.palette, not the active one).
    private def draw_swatch(screen : Screen, x : Int32, ry : Int32, name : String) : Nil
      pal = Theme.palette(name)
      return unless pal
      ticks = {pal.accent, pal.green, pal.yellow, pal.red, pal.syn_header}
      screen.cell(x, ry, ' ', pal.bg, pal.bg)
      ticks.each_with_index { |c, i| screen.cell(x + 1 + i, ry, '█', c, pal.bg) }
      screen.cell(x + 6, ry, ' ', pal.bg, pal.bg)
    end

    # A small mock of the History view rendered entirely in `name`'s OWN palette, so
    # the user previews a theme without it being active. Read pal.* (NOT Theme.*).
    private def render_theme_preview(screen : Screen, rect : Rect, name : String) : Nil
      return if rect.w < 6 || rect.h < 3
      pal = Theme.palette(name)
      return unless pal
      Frame.card(screen, rect, "PREVIEW", bg: pal.panel, border: pal.border)
      ix = rect.x + 2
      iw = {rect.w - 4, 1}.max
      screen.text(ix, rect.y + 1, "gori · 127.0.0.1", pal.text_bright, pal.panel, width: iw)
      rows = [{"GET ", "/api/users", "200", pal.green},
              {"POST", "/login", "404", pal.yellow},
              {"GET ", "/admin", "500", pal.red}]
      y = rect.y + 3
      rows.each_with_index do |(method, path, status, col), i|
        break if y >= rect.bottom - 1
        sel = i == 1
        rbg = sel ? pal.accent_bg : pal.panel
        screen.fill(Rect.new(rect.x + 1, y, rect.w - 2, 1), rbg)
        screen.cell(rect.x + 1, y, sel ? '▎' : ' ', pal.accent, rbg)
        screen.text(rect.x + 3, y, method, sel ? pal.text_bright : pal.muted, rbg)
        path_x = rect.x + 8
        path_w = {(rect.right - 1 - 4) - path_x, 1}.max
        screen.text(path_x, y, path, sel ? pal.text_bright : pal.text, rbg, width: path_w)
        screen.text(rect.right - 1 - status.size, y, status, col, rbg)
        y += 1
      end
    end

    private def render_review(screen : Screen, box : Rect) : Nil
      ix = box.x + 3
      y = box.y + 2
      screen.text(ix, y, "You're all set!", Theme.text_bright, Theme.panel, width: {box.w - 6, 1}.max)
      y += 2
      recap(screen, box, ix, y, "Proxy (global)", "#{effective_ip}:#{@port.strip}"); y += 1
      recap(screen, box, ix, y, "Theme", @theme_name); y += 2
      screen.text(ix, y, "New to gori? Take a quick tour of the TUI:", Theme.muted, Theme.panel, width: {box.w - 6, 1}.max)
      y += 1
      render_offer_row(screen, box, y, "Take the guided tour", @offer == :tour); y += 1
      render_offer_row(screen, box, y, "Skip — finish setup", @offer == :skip)
    end

    private def recap(screen : Screen, box : Rect, ix : Int32, y : Int32, key : String, value : String) : Nil
      screen.text(ix, y, key, Theme.muted, Theme.panel)
      vx = ix + 14
      screen.text(vx, y, value, Theme.text_bright, Theme.panel, width: {box.right - vx - 1, 1}.max)
    end

    # A selectable offer row (radio-style), mirroring the theme list's accent band.
    private def render_offer_row(screen : Screen, box : Rect, ry : Int32, label : String, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      screen.text(box.x + 5, ry, label, selected ? Theme.text_bright : Theme.text, bg, width: {box.right - (box.x + 5) - 1, 1}.max)
    end
  end
end
