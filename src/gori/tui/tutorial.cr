require "termisu"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./layout"

module Gori::Tui
  # A guided, standalone tour of gori's TUI, shown right after the setup wizard
  # (when the user opts in) and re-runnable via `gori tutorial`. It is NOT wired
  # into the live Runner: like SetupWizard it owns its own full-screen run loop,
  # so it fully captures input and can't disturb any real session.
  #
  # It teaches the four moves a new user reaches for most — moving between
  # tabs/panes, the command palette (^P), the action menu (space), and edit mode
  # (READ/INS) — each on a harmless MOCK of the real UI (nothing here is real),
  # drawn with the same Screen/Frame/Theme primitives the app uses.
  #
  # Flow: short explanation + looping demo on each lesson, with a soft "try it"
  # goal so users press the real key at least once; then a hands-on Practice
  # sandbox that encourages all four moves; finally a "first session" checklist.
  # Progression is never blocked — clickable Prev/Next buttons always work.
  class Tutorial
    # The mock tab bar; mirrors the real top-level tabs the user will see.
    TABS = %w[History Replay Fuzzer Project Help]

    # Short labels for the progress rail (keep narrow so 7 chips fit).
    STEP_RAIL = [
      {"intro", Step::Welcome},
      {"nav", Step::Navigate},
      {"palette", Step::Palette},
      {"menu", Step::SpaceMenu},
      {"edit", Step::Edit},
      {"try", Step::Practice},
      {"done", Step::Done},
    ]

    # Interior content rows the tallest lesson wants (explanation + gap + the mock
    # shell). The card is sized to this when the terminal allows and degrades
    # gracefully below it (every mock draw guards on its rect).
    CONTENT_ROWS = 15
    MIN_CARD_H   = 12 # below this the card can't hold a legible mock → "too small"
    CARD_W       = 78
    HEADER_ROWS  = 2  # brand + progress rail
    FOOTER_ROWS  = 2  # hint + Prev/Next buttons

    # Fake palette rows used by the palette lesson + practice overlay.
    PALETTE_ROWS = [
      {"»", "Go to Replay"},
      {"≡", "Settings: Theme"},
      {"×", "Quit gori"},
      {"→", "Go to History"},
      {"?", "Open Help"},
    ]

    # Fake space-menu rows (mnemonic key + label).
    SPACE_ROWS = [{'o', "Open"}, {'r', "Replay"}, {'y', "Copy"}, {'/', "Filter"}]

    FLOW_ROWS = [{"GET ", "/api/users", 200}, {"POST", "/login", 401}, {"GET ", "/admin", 500}]

    enum Step
      Welcome
      Navigate
      Palette
      SpaceMenu
      Edit
      Practice # hands-on sandbox: the user drives the mock
      Done
    end

    def initialize(@term : Termisu)
      @backend = TermisuBackend.new(@term)
      @step = Step::Welcome
      @tick = 0        # loop counter driving the demo animations (advances ~20/s)
      @resized = false # forces a full repaint after a resize
      @running = false

      # Soft per-lesson try-it flags (encouraged, not blocking — Next always works).
      @tried_nav = false
      @tried_palette = false
      @tried_space = false
      @tried_edit = false

      # Shared live mock state (Navigate takeover + Practice sandbox).
      @p_level = :menu # :menu (tab bar) | :body
      @p_tab = 0
      @p_pane = 0       # 0 = FLOWS, 1 = REQUEST
      @p_flow = 0       # selected row in FLOWS
      @p_switch = false # switched tabs
      @p_enter = false  # entered a tab's body
      @p_up = false     # returned to the tab bar with esc

      # Practice-only goals for palette / space / edit (lessons use @tried_*).
      @p_palette = false
      @p_space = false
      @p_edit = false

      # Overlay / edit sandbox driven by the user (lessons + practice).
      @overlay = :none # :none | :palette | :space
      @pal_sel = 0
      @pal_query = "" # live filter string (palette lesson + practice)
      @space_sel = 0
      @edit_insert = false
      @edit_typed = ""
      # Once the user touches keys on Navigate, stop the auto-demo and hand over.
      @nav_live = false

      # Hit-test rects rebuilt every frame for mouse (0-based screen coords).
      @prev_btn = Rect.new(0, 0, 0, 0)
      @next_btn = Rect.new(0, 0, 0, 0)
      @shell_rect = Rect.new(0, 0, 0, 0)
      @tab_hits = [] of {Rect, Int32}  # mock tab chip → index
      @rail_hits = [] of {Rect, Int32} # progress-rail chip → step value
      @flows_rect = Rect.new(0, 0, 0, 0)
      @request_rect = Rect.new(0, 0, 0, 0)
      @palette_rect = Rect.new(0, 0, 0, 0)
      @space_rect = Rect.new(0, 0, 0, 0)
    end

    # Run the tour to completion (Done + Next/Finish) or until the user leaves
    # (esc). Returns when done; the caller continues after.
    def run : Nil
      @running = true
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize then @resized = true
        when Termisu::Event::Key    then handle_key(ev)
        when Termisu::Event::Mouse  then handle_mouse(ev)
        end
        @tick &+= 1
        break unless @running
      end
    end

    # --- input ---------------------------------------------------------------

    private def handle_key(ev : Termisu::Event::Key) : Nil
      key = ev.key

      if ev.ctrl_c?
        @running = false
        return
      end

      # Tour navigation is independent of the mock — available so the user can
      # never get stuck (n/b, ⇧⇥). Letter keys are suppressed while typing.
      if tour_nav_key?(ev)
        handle_tour_nav(ev)
        return
      end

      # Overlay owns keys while open (esc/↵ close; ↑↓ move; type filters palette).
      return handle_overlay_key(ev) unless @overlay == :none

      # INS owns printables + esc (leave READ). Tour nav already handled above.
      if @edit_insert
        return handle_edit_key(ev)
      end

      # Esc: pop one level when the mock is live; leave the tour at the top.
      if key.escape?
        return handle_escape
      end

      # Practice / Navigate live: shell keys first. When practice goals are done,
      # ↵ matches the Next button so the keyboard path isn't a dead end.
      if @step.practice?
        if practice_done? && key.enter?
          advance
          return
        end
        handle_live_shell_key(ev, practice: true)
        return
      end
      if @step.navigate? && @nav_live
        handle_live_shell_key(ev, practice: false)
        return
      end

      # Soft try-it on passive lessons (before Next advances).
      case @step
      when Step::Navigate
        if nav_switch_key?(ev) || key.down? || key.enter? || ev.char == 'j' ||
           ev.char == '[' || ev.char == ']'
          start_nav_live
          handle_live_shell_key(ev, practice: false)
          return
        end
      when Step::Palette
        if palette_open_key?(ev)
          open_palette
          @tried_palette = true
          return
        end
      when Step::SpaceMenu
        if space_open_key?(ev)
          open_space
          @tried_space = true
          return
        end
      when Step::Edit
        if edit_enter_key?(ev) || key.enter?
          @edit_insert = true
          @edit_typed = ""
          @tried_edit = true
          return
        end
      end

      # Enter advances when the mock is not capturing it (welcome / done / skip).
      advance if key.enter?
    end

    # Keys that move the tutorial itself (not the mock UI). Checked first so
    # lessons can never trap the user. Uses letter keys every keyboard has:
    #   n = next · b = back · ⇧⇥ = back
    # (⇥ alone stays free for pane cycle in the mock.)
    # While typing in INS or the palette filter, n/b are normal characters.
    private def tour_nav_key?(ev : Termisu::Event::Key) : Bool
      return true if ev.key.back_tab?
      return false if @edit_insert
      return false if @overlay == :palette
      return false if ev.ctrl? || ev.alt? # leave ^P etc. alone
      ch = ev.char
      ch == 'n' || ch == 'N' || ch == 'b' || ch == 'B'
    end

    private def handle_tour_nav(ev : Termisu::Event::Key) : Nil
      if ev.key.back_tab?
        back
        return
      end
      case ev.char
      when 'n', 'N' then advance
      when 'b', 'B' then back
      end
    end

    private def handle_escape : Nil
      if @edit_insert
        @edit_insert = false
        @tried_edit = true
        return
      end
      if live_shell? && @p_level == :body
        @p_level = :menu
        @p_up = true
        @tried_nav = true if @step.navigate?
        return
      end
      @running = false
    end

    private def live_shell? : Bool
      @step.practice? || (@step.navigate? && @nav_live)
    end

    # Shared shell keyboard model for Navigate (live) and Practice — closer to the
    # real app: [ / ] switch tabs anywhere, esc back to tabs, ⇥ panes, ↑/↓ list,
    # ↵ opens detail / INS on the request, ^P / space openers.
    private def handle_live_shell_key(ev : Termisu::Event::Key, *, practice : Bool) : Nil
      key = ev.key

      # Global tab cycle (real app: [ / ] from anywhere).
      if ev.char == '['
        switch_tab(-1)
        return
      end
      if ev.char == ']'
        switch_tab(1)
        return
      end
      if (ch = ev.char) && ch >= '1' && ch <= '9'
        idx = ch.ord - '1'.ord
        if idx < TABS.size
          @p_tab = idx
          mark_switch
        end
        return
      end

      if palette_open_key?(ev)
        open_palette
        @p_palette = true if practice
        return
      end
      if space_open_key?(ev)
        open_space
        @p_space = true if practice
        return
      end

      if @p_level == :menu
        practice_menu_key(ev)
        return
      end

      # --- body --------------------------------------------------------------
      if key.tab?
        @p_pane = @p_pane == 0 ? 1 : 0
        return
      end

      # INS only on the REQUEST pane (matches real editors).
      if @p_pane == 1 && (edit_enter_key?(ev) || key.enter?)
        @edit_insert = true
        @edit_typed = ""
        @p_edit = true if practice
        @tried_edit = true
        return
      end

      # ↵ on FLOWS focuses the REQUEST pane (open the selected flow).
      if @p_pane == 0 && key.enter?
        @p_pane = 1
        return
      end

      if key.down? || ev.char == 'j'
        @p_flow = {@p_flow + 1, FLOW_ROWS.size - 1}.min if @p_pane == 0
        return
      end
      # ↑ / k: REQUEST always returns to the tab bar. FLOWS moves the list first,
      # and at the top row also returns to tabs (same focus-ring as real History).
      if key.up? || ev.char == 'k'
        if @p_pane == 1
          focus_tabs
        elsif @p_pane == 0
          if @p_flow > 0
            @p_flow -= 1
          else
            focus_tabs
          end
        end
        return
      end
      if key.left? || ev.char == 'h'
        @p_pane = 0 if @p_pane == 1
        return
      end
      if key.right? || ev.char == 'l'
        @p_pane = 1 if @p_pane == 0
        return
      end
    end

    private def focus_tabs : Nil
      @p_level = :menu
      @p_up = true
      @tried_nav = true
    end

    private def practice_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.left? || ev.char == 'h'
        switch_tab(-1)
      elsif key.right? || ev.char == 'l'
        switch_tab(1)
      elsif key.down? || key.enter? || ev.char == 'j'
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        @tried_nav = true
      end
    end

    private def switch_tab(delta : Int32) : Nil
      @p_tab = (@p_tab + delta) % TABS.size
      mark_switch
    end

    private def mark_switch : Nil
      @p_switch = true
      @tried_nav = true
      # Switching tabs while in the body keeps body focus (real app); stay put.
    end

    private def handle_edit_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.escape?
        @edit_insert = false
        @tried_edit = true
        return
      end
      if key.enter?
        # ↵ leaves INS (like leaving insert in many editors); Next advances the tour.
        @edit_insert = false
        @tried_edit = true
        return
      end
      if key.backspace?
        @edit_typed = @edit_typed[0...-1] unless @edit_typed.empty?
        return
      end
      ch = ev.char
      if ch && ch.ord >= 32 && ch.ord < 127 && @edit_typed.size < 16
        @edit_typed += ch
        @tried_edit = true
      end
    end

    private def handle_overlay_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl_c?
        @running = false
        return
      end
      if key.escape?
        close_overlay
        return
      end
      if key.enter?
        run_overlay_selection
        return
      end

      case @overlay
      when :palette
        if key.up? || ev.char == 'k'
          @pal_sel = (@pal_sel - 1) % filtered_palette.size
          @pal_sel = 0 if filtered_palette.empty?
        elsif key.down? || ev.char == 'j'
          n = filtered_palette.size
          @pal_sel = n == 0 ? 0 : (@pal_sel + 1) % n
        elsif key.backspace?
          @pal_query = @pal_query[0...-1] unless @pal_query.empty?
          @pal_sel = 0
        elsif (ch = ev.char) && ch.ord >= 32 && ch.ord < 127 && @pal_query.size < 20
          @pal_query += ch
          @pal_sel = 0
        end
      when :space
        if key.up? || ev.char == 'k'
          @space_sel = (@space_sel - 1) % SPACE_ROWS.size
        elsif key.down? || ev.char == 'j'
          @space_sel = (@space_sel + 1) % SPACE_ROWS.size
        elsif (ch = ev.char) && SPACE_ROWS.any? { |(k, _)| k == ch }
          close_overlay # mnemonic runs the row
        end
      end
    end

    private def filtered_palette : Array({String, String})
      q = @pal_query.downcase
      return PALETTE_ROWS if q.empty?
      PALETTE_ROWS.select { |(_, label)| label.downcase.includes?(q) }
    end

    private def run_overlay_selection : Nil
      if @overlay == :palette
        rows = filtered_palette
        if (row = rows[@pal_sel]?)
          # Mirror a couple of real "Go to …" actions so the palette feels alive.
          case row[1]
          when "Go to Replay"  then @p_tab = 1; mark_switch
          when "Go to History" then @p_tab = 0; mark_switch
          when "Open Help"     then @p_tab = 4; mark_switch
          end
        end
      end
      close_overlay
    end

    private def practice_done? : Bool
      @p_switch && @p_enter && @p_up && @p_palette && @p_space && @p_edit
    end

    private def reset_practice : Nil
      @p_level = :menu
      @p_tab = 0
      @p_pane = 0
      @p_flow = 0
      @p_switch = false
      @p_enter = false
      @p_up = false
      @p_palette = false
      @p_space = false
      @p_edit = false
      @overlay = :none
      @pal_sel = 0
      @pal_query = ""
      @space_sel = 0
      @edit_insert = false
      @edit_typed = ""
      @nav_live = false
    end

    private def reset_lesson_try : Nil
      @overlay = :none
      @pal_sel = 0
      @pal_query = ""
      @space_sel = 0
      @edit_insert = false
      @edit_typed = ""
      @nav_live = false
      @p_level = :menu
      @p_tab = 0
      @p_pane = 0
      @p_flow = 0
    end

    private def start_nav_live : Nil
      return if @nav_live
      @nav_live = true
      @p_level = :menu
      @p_tab = 0
      @p_pane = 0
      @p_flow = 0
    end

    private def open_palette : Nil
      @overlay = :palette
      @pal_sel = 0
      @pal_query = ""
      @edit_insert = false
    end

    private def open_space : Nil
      @overlay = :space
      @space_sel = 0
      @edit_insert = false
    end

    private def close_overlay : Nil
      @overlay = :none
      @pal_query = ""
    end

    private def nav_switch_key?(ev : Termisu::Event::Key) : Bool
      key = ev.key
      key.left? || key.right? || ev.char == 'h' || ev.char == 'l' ||
        ev.char == '[' || ev.char == ']'
    end

    private def palette_open_key?(ev : Termisu::Event::Key) : Bool
      (ev.ctrl? && ev.key.lower_p?) || (ev.char == 'p' && !ev.ctrl? && !ev.alt?)
    end

    private def space_open_key?(ev : Termisu::Event::Key) : Bool
      ev.key.space? || ev.char == ' '
    end

    private def edit_enter_key?(ev : Termisu::Event::Key) : Bool
      ev.char == 'i' || ev.char == 'I'
    end

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? && !ev.wheel?
      mx, my = ev.x - 1, ev.y - 1 # termisu mouse coords are 1-based

      # Footer buttons always win (never stuck — Skip/Next/Finish/Prev).
      if @next_btn.contains?(mx, my)
        advance
        return
      end
      if @prev_btn.contains?(mx, my) && prev_enabled?
        back
        return
      end

      # Progress rail: click any step chip to jump there (tour navigation).
      @rail_hits.each do |(rect, step_val)|
        if rect.contains?(mx, my)
          jump_to(Step.new(step_val))
          return
        end
      end

      # Overlay click: inside keeps focus; outside dismisses (real popup UX).
      unless @overlay == :none
        rect = @overlay == :palette ? @palette_rect : @space_rect
        if rect.contains?(mx, my)
          handle_overlay_click(mx, my)
        else
          close_overlay
        end
        return
      end

      # Mock shell clicks (Navigate live + Practice + lesson demos with shell).
      return unless shell_clickable?
      handle_shell_click(mx, my)
    end

    private def shell_clickable? : Bool
      @step.practice? || @step.navigate? || @step.palette? || @step.space_menu? || @step.edit?
    end

    private def handle_overlay_click(mx : Int32, my : Int32) : Nil
      case @overlay
      when :palette
        # Click a row → select + run (same as ↵).
        row = my - (@palette_rect.y + 3)
        rows = filtered_palette
        if row >= 0 && row < rows.size
          @pal_sel = row
          run_overlay_selection
        end
      when :space
        row = my - (@space_rect.y + 1)
        if row >= 0 && row < SPACE_ROWS.size
          @space_sel = row
          close_overlay
        end
      end
    end

    private def handle_shell_click(mx : Int32, my : Int32) : Nil
      # Ensure live takeover when interacting with the Navigate demo.
      start_nav_live if @step.navigate?

      @tab_hits.each do |(rect, idx)|
        if rect.contains?(mx, my)
          @p_tab = idx
          mark_switch
          @p_level = :menu # clicking a tab focuses the bar (real app)
          return
        end
      end

      if @flows_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        @tried_nav = true
        # Row hit: interior starts at y+1.
        row = my - (@flows_rect.y + 1)
        @p_flow = row.clamp(0, FLOW_ROWS.size - 1) if row >= 0
        return
      end

      if @request_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 1
        @p_enter = true
        @tried_nav = true
        return
      end
    end

    private def prev_enabled? : Bool
      !@step.welcome?
    end

    private def advance : Nil
      if @step.done?
        @running = false
      else
        jump_to(Step.new(@step.value + 1))
      end
    end

    private def back : Nil
      return if @step.welcome?
      jump_to(Step.new(@step.value - 1))
    end

    # Jump to an arbitrary lesson (progress-rail click or sequential next/prev).
    private def jump_to(step : Step) : Nil
      return if step == @step
      @step = step
      @tick = 0
      if @step.practice?
        reset_practice
      else
        reset_lesson_try
      end
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      # Clear hit targets each frame (rebuilt by render helpers).
      @prev_btn = Rect.new(0, 0, 0, 0)
      @next_btn = Rect.new(0, 0, 0, 0)
      @shell_rect = Rect.new(0, 0, 0, 0)
      @tab_hits = [] of {Rect, Int32}
      @rail_hits = [] of {Rect, Int32}
      @flows_rect = Rect.new(0, 0, 0, 0)
      @request_rect = Rect.new(0, 0, 0, 0)
      @palette_rect = Rect.new(0, 0, 0, 0)
      @space_rect = Rect.new(0, 0, 0, 0)

      unless Layout.usable?(w, h) && step_card(w, h).h >= MIN_CARD_H
        screen.text(0, 0, "terminal too small for the tutorial — resize and retry", Theme.red)
        @term.hide_cursor
        flush
        return
      end

      render_header(screen, w)
      render_progress_rail(screen, w)
      box = step_card(w, h)
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      case @step
      when Step::Welcome   then render_welcome(screen, box)
      when Step::Navigate  then render_navigate(screen, box)
      when Step::Palette   then render_palette(screen, box)
      when Step::SpaceMenu then render_spacemenu(screen, box)
      when Step::Edit      then render_edit(screen, box)
      when Step::Practice  then render_practice(screen, box)
      when Step::Done      then render_done(screen, box)
      end
      render_footer(screen, w, h)

      @term.hide_cursor
      flush
    end

    private def flush : Nil
      if @resized
        @term.sync
        @resized = false
      else
        @term.render
      end
    end

    # Card sits between the 2-row header and the 2-row footer.
    private def step_card(w : Int32, h : Int32) : Rect
      cw = { {w - 4, CARD_W}.min, 40 }.max
      avail = {h - HEADER_ROWS - FOOTER_ROWS, 3}.max
      ch = {CONTENT_ROWS + 3, avail}.min
      cx = {(w - cw) // 2, 0}.max
      cy = HEADER_ROWS + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    private def render_header(screen : Screen, w : Int32) : Nil
      x = screen.text(2, 0, "gori", Theme.text_bright, Theme.bg, attr: Attribute::Bold)
      screen.text(x + 1, 0, "· tutorial", Theme.muted, Theme.bg)
      prog = "#{@step.value + 1}/#{Step.values.size}"
      screen.text({w - prog.size - 2, 0}.max, 0, prog, Theme.muted, Theme.bg)
    end

    # Visual "where am I" rail under the brand line. Each chip is clickable
    # (jump_to) so the tour itself can be browsed without finishing every try-it.
    private def render_progress_rail(screen : Screen, w : Int32) : Nil
      y = 1
      cur = @step.value
      @rail_hits = [] of {Rect, Int32}
      # Prefer labelled chips when the terminal is wide enough; else plain dots.
      labels = STEP_RAIL.map { |(lab, _)| lab }
      labelled_w = labels.sum { |l| l.size + 4 } + (labels.size - 1) * 1
      if labelled_w + 4 <= w
        cx = {(w - labelled_w) // 2, 2}.max
        STEP_RAIL.each_with_index do |(lab, st), i|
          done = i < cur
          here = i == cur
          mark = here ? "●" : (done ? "✓" : "○")
          col = here ? Theme.accent : (done ? Theme.green : Theme.muted)
          bg = here ? Theme.accent_bg : Theme.bg
          chip = " #{mark} #{lab} "
          hit = Rect.new(cx, y, chip.size, 1)
          @rail_hits << {hit, st.value}
          screen.fill(hit, bg) if here
          screen.text(cx, y, chip, here ? Theme.text_bright : col, bg,
            attr: here ? Attribute::Bold : Attribute::None)
          cx += chip.size
          if i < STEP_RAIL.size - 1
            screen.text(cx, y, "─", Theme.muted, Theme.bg)
            cx += 1
          end
        end
      else
        # Compact dots: ● ● ● ○ ○ ○ ○ — each cell is still a jump target.
        unit = 2
        total_w = Step.values.size * unit - 1
        cx = {(w - total_w) // 2, 2}.max
        Step.values.size.times do |i|
          done = i < cur
          here = i == cur
          ch = here ? '●' : (done ? '●' : '○')
          col = here ? Theme.accent : (done ? Theme.green : Theme.muted)
          @rail_hits << {Rect.new(cx, y, 1, 1), i}
          screen.cell(cx, y, ch, col, Theme.bg)
          cx += unit
        end
      end
    end

    private def card_title : String
      case @step
      when Step::Welcome   then "WELCOME"
      when Step::Navigate  then "MOVE AROUND · tabs & panes"
      when Step::Palette   then "COMMAND PALETTE · ^P"
      when Step::SpaceMenu then "ACTION MENU · space"
      when Step::Edit      then "EDIT MODE · READ / INS"
      when Step::Practice  then "TRY IT · all four moves"
      else                      "YOU'RE READY"
      end
    end

    private def next_btn_label : String
      case @step
      when Step::Welcome              then " Start "
      when Step::Done                 then " Finish "
      when Step::Practice
        practice_done? ? " Next " : " Skip "
      else " Next "
      end
    end

    private def prev_btn_label : String
      " Prev "
    end

    private def render_footer(screen : Screen, w : Int32, h : Int32) : Nil
      hint = footer_hint
      hy = h - 2
      screen.text({(w - hint.size) // 2, 0}.max, hy, hint, Theme.muted, Theme.bg)

      by = h - 1
      prev_l = prev_btn_label
      next_l = next_btn_label
      # " ← Prev " / " Next → " with arrow affordances
      prev_text = " ←#{prev_l}"
      next_text = "#{next_l}→ "
      pad = 2
      @prev_btn = Rect.new(pad, by, prev_text.size, 1)
      @next_btn = Rect.new({w - pad - next_text.size, 0}.max, by, next_text.size, 1)

      if prev_enabled?
        draw_btn(screen, @prev_btn, prev_text, primary: false)
      else
        screen.text(@prev_btn.x, by, prev_text, Theme.muted, Theme.bg)
      end
      draw_btn(screen, @next_btn, next_text, primary: true)
    end

    private def draw_btn(screen : Screen, rect : Rect, text : String, *, primary : Bool) : Nil
      if primary
        screen.fill(rect, Theme.accent_bg)
        screen.text(rect.x, rect.y, text, Theme.text_bright, Theme.accent_bg, attr: Attribute::Bold)
      else
        screen.fill(rect, Theme.elevated)
        screen.text(rect.x, rect.y, text, Theme.text, Theme.elevated)
      end
    end

    # Contextual mock hint; tour nav (n/b · Prev/Next · rail click) is separate.
    private def footer_hint : String
      tour = "n next · b back"
      case @step
      when Step::Welcome
        "↵/n start · click Start · esc leave"
      when Step::Done
        "↵/n finish · click Finish · esc leave"
      when Step::Practice
        if @overlay != :none
          "↑/↓ · ↵ run · esc close · #{tour}"
        elsif @edit_insert
          "type · esc → READ · then n/Next"
        elsif practice_done?
          "✓ done — ↵/n/Next · or keep exploring"
        else
          "roam the mock · #{tour} / Skip anytime"
        end
      when Step::Navigate
        if @nav_live
          "←/→ tabs · ↓ body · ↑ tabs · ⇥ panes · #{tour}"
        elsif @tried_nav
          "✓ #{tour} · or keep exploring"
        else
          "try ←/→ then ↓ · #{tour} to skip"
        end
      when Step::Palette
        if @overlay == :palette
          "type · ↑/↓ · ↵ run · esc close"
        elsif @tried_palette
          "✓ #{tour}"
        else
          "try ^P (or p) · #{tour} to skip"
        end
      when Step::SpaceMenu
        if @overlay == :space
          "↑/↓ · letter · ↵ · esc · #{tour}"
        elsif @tried_space
          "✓ #{tour}"
        else
          "try space · #{tour} to skip"
        end
      when Step::Edit
        if @edit_insert
          "type · esc/↵ → READ · then n/Next"
        elsif @tried_edit
          "✓ #{tour}"
        else
          "try i · #{tour} to skip"
        end
      else
        "#{tour} · click Prev/Next · esc leave"
      end
    end

    # --- lessons -------------------------------------------------------------

    private def render_welcome(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Welcome to gori — a keyboard-driven HTTP/HTTPS proxy.", Theme.text_bright, Theme.panel, width: iw)
      y += 2
      screen.text(ix, y, "You'll learn the four moves you'll use every session:", Theme.text, Theme.panel, width: iw)
      y += 1
      [
        "1.  tabs & panes     ←/→  ·  ↓  ·  esc  ·  ⇥",
        "2.  command palette  ^P   — jump to any action",
        "3.  action menu      space — commands for this pane",
        "4.  edit mode        READ / INS — browse, then type",
      ].each do |ln|
        screen.text(ix + 2, y, ln, Theme.text, Theme.panel, width: {iw - 2, 1}.max)
        y += 1
      end
      y += 1
      screen.text(ix, y, "Each step demos a move, then lets you try it on a live mock.", Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "Tour nav: n next · b back · click Prev/Next · click the step rail.", Theme.muted, Theme.panel, width: iw)
    end

    private def render_navigate(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Every screen is a tab; most tabs split into panes.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "←/→ on the bar · [ / ] from anywhere · 1-9 jump",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "↓ or ↵ into the body · ↑ back to tabs · ↓ list · esc · ⇥ panes",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      draw_try_line(screen, ix, y, iw, "Try: switch a tab, enter body, ↑ back to tabs.", @tried_nav)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      if @nav_live
        render_shell(screen, shell, @p_tab, @p_level == :body, @p_pane, "",
          flow: @p_flow, insert: false, typed: "")
      else
        phase = (@tick // 12) % 5
        active = phase == 0 ? 0 : 1
        in_body = phase == 2 || phase == 3
        pane = phase == 3 ? 1 : 0
        keyhint = ["", "→", "↓", "⇥", "esc"][phase]
        render_shell(screen, shell, active, in_body, pane, keyhint, flow: 0)
      end
    end

    private def render_palette(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Jump to any action without hunting tabs or memorizing chords.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "^P opens it · type to fuzzy-filter · ↑/↓ move · ↵ run · esc close",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      draw_try_line(screen, ix, y, iw, "Try: press ^P (or p), filter, ↵ to run a command.", @tried_palette)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      render_shell(screen, shell, @p_tab, false, 0, "", flow: 0)
      if @overlay == :palette
        draw_palette_overlay(screen, shell, live: true)
      else
        draw_palette_overlay(screen, shell, live: false)
      end
    end

    private def render_spacemenu(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "space opens actions for whatever area has focus.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "each row has a mnemonic key — press it to run · ↑/↓ move · esc dismiss",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      draw_try_line(screen, ix, y, iw, "Try: press space, move with ↑/↓, run with a letter or ↵.", @tried_space)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      render_shell(screen, shell, 0, true, 0, "", flow: 0)
      if @overlay == :space
        draw_space_overlay(screen, shell, live: true)
      else
        draw_space_overlay(screen, shell, live: false)
      end
    end

    private def render_edit(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Editors open in READ — navigate, select, copy, open the menu.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "press i or ↵ to enter INS and type · esc returns to READ (safe by default)",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      draw_try_line(screen, ix, y, iw, "Try: press i, type a username, esc back to READ.", @tried_edit)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      screen.fill(shell, Theme.bg)

      if @edit_insert || @tried_edit
        insert = @edit_insert
        typed = @edit_typed
      else
        phase = (@tick // 10) % 6
        insert = 1 <= phase <= 4
        typed_full = "alice"
        typed = insert ? typed_full[0, {phase, typed_full.size}.min] : ""
      end

      pw = { {shell.w - 4, 48}.min, 24 }.max
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      pane = Rect.new(px, shell.y, pw, {shell.h - 1, 3}.max)
      @request_rect = pane
      render_request_pane(screen, pane, true, insert: insert, typed: typed)

      kh = insert ? "INS · type · esc → READ" : "READ · i or ↵ → INS"
      screen.text(shell.x + {(shell.w - kh.size) // 2, 0}.max, shell.bottom - 1, kh, Theme.muted, Theme.bg)
    end

    private def render_practice(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Your turn — complete each move once (or Skip anytime).", Theme.text_bright, Theme.panel, width: iw)
      y += 1

      gx = draw_goal(screen, ix, y, "switch", @p_switch)
      gx = draw_goal(screen, gx + 2, y, "enter", @p_enter)
      draw_goal(screen, gx + 2, y, "esc back", @p_up)
      y += 1
      gx = draw_goal(screen, ix, y, "^P", @p_palette)
      gx = draw_goal(screen, gx + 2, y, "space", @p_space)
      draw_goal(screen, gx + 2, y, "i INS", @p_edit)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 2 - y, 3}.max)
      render_shell(screen, shell, @p_tab, @p_level == :body, @p_pane, "",
        flow: @p_flow, insert: @edit_insert, typed: @edit_typed)

      case @overlay
      when :palette then draw_palette_overlay(screen, shell, live: true)
      when :space   then draw_space_overlay(screen, shell, live: true)
      end

      msg = if practice_done?
              "✓ Nicely done — click Next or press ↵."
            elsif @overlay != :none
              "Overlay open — ↵ runs, esc closes, click outside dismisses."
            elsif @edit_insert
              "INS mode — type, then esc back to READ."
            else
              "←/→ tabs · ↓ body · ↑/↓ list · ⇥ panes · esc · ^P · space · i"
            end
      screen.text(ix, box.bottom - 2, msg, practice_done? ? Theme.green : Theme.muted, Theme.panel, width: iw)
    end

    private def draw_try_line(screen : Screen, x : Int32, y : Int32, w : Int32, text : String, done : Bool) : Nil
      col = done ? Theme.green : Theme.accent
      mark = done ? "✓" : "○"
      screen.text(x, y, "#{mark}  #{text}", col, Theme.panel, width: w)
    end

    private def draw_goal(screen : Screen, x : Int32, y : Int32, label : String, done : Bool) : Int32
      col = done ? Theme.green : Theme.muted
      screen.cell(x, y, done ? '✓' : '○', col, Theme.panel)
      screen.text(x + 2, y, label, done ? Theme.text : Theme.muted, Theme.panel)
      x + 2 + label.size
    end

    private def render_done(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "That's the tour — here's a first real session:", Theme.text_bright, Theme.panel, width: iw)
      y += 2
      [
        {"1.", "run  gori  — start the TUI (proxy on your bind address)"},
        {"2.", "browse via Project, or point a client at the proxy"},
        {"3.", "History — pick a captured flow"},
        {"4.", "^R — send it to Replay · edit (i) · send again"},
        {"5.", "Help tab — full cheat-sheet anytime"},
      ].each do |(num, desc)|
        screen.text(ix, y, num, Theme.accent, Theme.panel, width: 3)
        screen.text(ix + 3, y, desc, Theme.text, Theme.panel, width: {iw - 3, 1}.max)
        y += 1
      end
      y += 1
      screen.text(ix, y, "Cheat-sheet:  ^P palette · space menu · i/↵ INS · esc READ/back", Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "Re-run this tour anytime:  gori tutorial", Theme.muted, Theme.panel, width: iw)
    end

    # --- mock UI -------------------------------------------------------------

    private def render_shell(screen : Screen, rect : Rect, active : Int32, in_body : Bool,
                             pane : Int32, keyhint : String, *, flow : Int32 = 0,
                             insert : Bool = false, typed : String = "") : Nil
      return if rect.h < 5
      @shell_rect = rect
      screen.fill(rect, Theme.bg)
      render_tab_bar(screen, rect.x, rect.y, rect.w, active, !in_body)

      scol = in_body ? Theme.focus_gold : Theme.accent
      slabel = " #{in_body ? "BODY" : "TABS"} "
      sx = rect.right - slabel.size
      screen.text(sx, rect.y, slabel, Theme.ink_on(scol), scol, attr: Attribute::Bold) if sx > rect.x

      py = rect.y + 2
      ph = {rect.bottom - py, 3}.max
      gap = 2
      lw = {(rect.w - gap) // 2, 1}.max
      rw = {rect.w - gap - lw, 1}.max
      flows = Rect.new(rect.x, py, lw, ph)
      req = Rect.new(rect.x + lw + gap, py, rw, ph)
      @flows_rect = flows
      @request_rect = req
      render_flows_pane(screen, flows, in_body && pane == 0, flow)
      render_request_pane(screen, req, in_body && pane == 1, insert: insert, typed: typed)

      unless keyhint.empty?
        kh = " #{keyhint} "
        screen.text(rect.x + {(rect.w - kh.size) // 2, 0}.max, rect.y + 1, kh,
          Theme.ink_on(Theme.accent), Theme.accent, attr: Attribute::Bold)
      end
    end

    private def render_tab_bar(screen : Screen, x : Int32, y : Int32, w : Int32,
                               active : Int32, focused : Bool) : Nil
      @tab_hits = [] of {Rect, Int32}
      cx = x
      TABS.each_with_index do |name, i|
        label = " #{name} "
        break if cx + label.size > x + w
        @tab_hits << {Rect.new(cx, y, label.size, 1), i}
        if i == active
          bg = focused ? Theme.focus_gold : Theme.accent_bg
          fg = focused ? Theme.ink_on(Theme.focus_gold) : Theme.text_bright
          screen.text(cx, y, label, fg, bg, attr: Attribute::Bold)
        else
          screen.text(cx, y, label, Theme.muted, Theme.bg)
        end
        cx += label.size + 1
      end
    end

    private def render_flows_pane(screen : Screen, rect : Rect, focused : Bool, flow : Int32) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "FLOWS", border: Frame.pane_border(focused))
      yy = rect.y + 1
      FLOW_ROWS.each_with_index do |(method, path, status), i|
        break if yy >= rect.bottom - 1
        sel = focused && i == flow
        bg = sel ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, sel ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 3, yy, method, Theme.method_color(method.strip), bg)
        px = rect.x + 8
        pw = {rect.right - 1 - 4 - px, 1}.max
        screen.text(px, yy, path, sel ? Theme.text_bright : Theme.text, bg, width: pw)
        sts = status.to_s
        screen.text(rect.right - 1 - sts.size, yy, sts, Theme.status_color(status), bg)
        yy += 1
      end
    end

    private def render_request_pane(screen : Screen, rect : Rect, focused : Bool, *,
                                    insert : Bool, typed : String) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "REQUEST", border: Frame.pane_border(focused))
      badge_min = rect.x + 10
      if insert
        Frame.toggle_badge(screen, rect.right - 1, rect.y, badge_min, "i", "INS", true)
      else
        lbl = " NOR "
        bx = rect.right - 1 - lbl.size
        screen.text(bx, rect.y, lbl, Theme.muted, Theme.bg) if bx >= badge_min
      end

      ix = rect.x + 2
      iw = {rect.w - 4, 1}.max
      yy = rect.y + 1
      # Reflect the selected flow path so the two panes feel linked.
      path = FLOW_ROWS[@p_flow]?.try(&.[1]) || "/login"
      ["GET #{path} HTTP/1.1", "Host: example.com", "Accept: */*"].each do |ln|
        break if yy >= rect.bottom - 1
        screen.text(ix, yy, ln, Theme.text, Theme.panel, width: iw)
        yy += 1
      end
      if insert && yy < rect.bottom - 1
        px = screen.text(ix, yy, "username=#{typed}", Theme.text_bright, Theme.panel, width: iw)
        screen.cell({px, rect.right - 2}.min, yy, ' ', Theme.bg, Theme.accent)
      elsif focused && !insert && yy < rect.bottom - 1
        screen.text(ix, yy, "username=alice", Theme.muted, Theme.panel, width: iw)
      end
    end

    private def draw_palette_overlay(screen : Screen, shell : Rect, *, live : Bool) : Nil
      pw = { {shell.w - 8, 36}.min, 24 }.max
      ph = { {shell.h - 1, 8}.min, 6 }.max
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      py = shell.y + {(shell.h - ph) // 2, 0}.max
      rect = Rect.new(px, py, pw, ph)
      @palette_rect = rect if live
      render_fake_palette(screen, rect, live: live)
    end

    private def draw_space_overlay(screen : Screen, shell : Rect, *, live : Bool) : Nil
      mw = 16
      mh = SPACE_ROWS.size + 2
      mx = shell.right - mw - 1
      my = {shell.bottom - mh, shell.y}.max
      return unless mx > shell.x
      rect = Rect.new(mx, my, mw, mh)
      @space_rect = rect if live
      render_fake_space_menu(screen, rect, SPACE_ROWS, live: live)
    end

    private def render_fake_palette(screen : Screen, rect : Rect, *, live : Bool) : Nil
      return if rect.w < 12 || rect.h < 4
      Frame.card(screen, rect, "COMMANDS", border: Theme.border_focus)
      screen.text(rect.x + 2, rect.y + 1, "›", Theme.accent, Theme.panel)
      q = live ? @pal_query : ""
      qx = rect.x + 4
      qw = {rect.right - 2 - qx, 1}.max
      if q.empty?
        screen.cell(qx, rect.y + 1, ' ', Theme.bg, Theme.accent)
      else
        screen.text(qx, rect.y + 1, q, Theme.text_bright, Theme.panel, width: qw)
        caret_x = qx + {q.size, qw - 1}.min
        screen.cell(caret_x, rect.y + 1, ' ', Theme.bg, Theme.accent) if caret_x < rect.right - 1
      end
      Frame.tee_divider(screen, rect, rect.y + 2)

      rows = live ? filtered_palette : PALETTE_ROWS
      sel = if live
              rows.empty? ? 0 : @pal_sel.clamp(0, rows.size - 1)
            else
              (@tick // 10) % PALETTE_ROWS.size
            end
      yy = rect.y + 3
      rows.each_with_index do |(sig, label), i|
        break if yy >= rect.bottom - 1
        s = i == sel
        bg = s ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, s ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 3, yy, sig, Theme.muted, bg)
        screen.text(rect.x + 5, yy, label, s ? Theme.text_bright : Theme.text, bg,
          width: {rect.right - 1 - (rect.x + 5), 1}.max)
        yy += 1
      end
      if live && rows.empty? && yy < rect.bottom - 1
        screen.text(rect.x + 3, yy, "(no matches)", Theme.muted, Theme.panel)
      end
    end

    private def render_fake_space_menu(screen : Screen, rect : Rect,
                                       rows : Array({Char, String}), *, live : Bool) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "SPACE", border: Theme.border_focus)
      sel = live ? @space_sel : (@tick // 10) % rows.size
      yy = rect.y + 1
      rows.each_with_index do |(key, label), i|
        break if yy >= rect.bottom - 1
        s = i == sel
        bg = s ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, s ? '▎' : ' ', Theme.accent, bg)
        screen.cell(rect.x + 3, yy, key, Theme.accent, bg, attr: Attribute::Bold)
        screen.text(rect.x + 5, yy, label, s ? Theme.text_bright : Theme.text, bg,
          width: {rect.right - 1 - (rect.x + 5), 1}.max)
        yy += 1
      end
    end
  end
end
