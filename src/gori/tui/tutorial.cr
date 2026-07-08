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
  # drawn with the same Screen/Frame/Theme primitives the app uses. Each lesson
  # is a page with a short explanation plus a gentle looping demo animation; the
  # user just presses ↵ to move on (no key-practice is required).
  class Tutorial
    # The mock tab bar; mirrors the real top-level tabs the user will see.
    TABS = %w[History Replay Fuzzer Project Help]

    # Interior content rows the tallest lesson wants (explanation + gap + the mock
    # shell). The card is sized to this when the terminal allows and degrades
    # gracefully below it (every mock draw guards on its rect).
    CONTENT_ROWS = 14
    MIN_CARD_H   = 12 # below this the card can't hold a legible mock → "too small"
    CARD_W       = 78

    enum Step
      Welcome
      Navigate
      Palette
      SpaceMenu
      Edit
      Practice # hands-on sandbox: the user drives the mock to finish
      Done
    end

    def initialize(@term : Termisu)
      @backend = TermisuBackend.new(@term)
      @step = Step::Welcome
      @tick = 0        # loop counter driving the demo animations (advances ~20/s)
      @resized = false # forces a full repaint after a resize
      @running = false
      # Practice sandbox state — the user's live focus in the mock plus the goals
      # they must complete to unlock finishing (participation, not a passive click).
      @p_level = :menu # :menu (tab bar) | :body
      @p_tab = 0
      @p_pane = 0
      @p_switch = false # switched tabs with ←/→
      @p_enter = false  # entered a tab's body with ↓/↵
      @p_up = false     # returned to the tab bar with ↑
    end

    # Run the tour to completion (Done + ↵) or until the user skips (esc). Returns
    # when done; the caller (SetupWizard#run or `gori tutorial`) continues after.
    def run : Nil
      @running = true
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize then @resized = true
        when Termisu::Event::Key    then handle_key(ev)
        when Termisu::Event::Mouse  then handle_mouse(ev)
        end
        @tick &+= 1 # advance the animation even on an input-less tick (wraps safely)
        break unless @running
      end
    end

    # --- input ---------------------------------------------------------------

    private def handle_key(ev : Termisu::Event::Key) : Nil
      return handle_practice_key(ev) if @step.practice? # the sandbox owns its keys
      key = ev.key
      if ev.ctrl_c? || key.escape?
        @running = false # esc / ^C leaves the tour at any point
        return
      end
      if key.enter? || key.tab? || key.right?
        advance
      elsif key.back_tab? || key.left?
        back
      end
    end

    # The hands-on final step: the user actually roams the mock. Nav keys drive the
    # focus (they don't advance the tour); only after completing the moves does ↵
    # finish. esc pops body→tabs (authentic), and leaves the tour from the tab bar.
    private def handle_practice_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      return practice_escape if ev.ctrl_c? || key.escape?
      return back if key.back_tab?                   # ⇧⇥ → previous lesson
      return advance if practice_done? && key.enter? # ↵ finishes once you've roamed
      @p_level == :menu ? practice_menu_key(ev) : practice_body_key(ev)
    end

    private def practice_escape : Nil
      if @p_level == :body
        @p_level = :menu # esc steps back up a level (and counts as "back to tabs")
        @p_up = true
      else
        @running = false # esc at the top leaves the tour
      end
    end

    # On the tab bar: ←/→ (h/l) switch tabs, ↓/↵ (j) descend into the body.
    private def practice_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.left? || ev.char == 'h'
        @p_tab = (@p_tab - 1) % TABS.size
        @p_switch = true
      elsif key.right? || ev.char == 'l'
        @p_tab = (@p_tab + 1) % TABS.size
        @p_switch = true
      elsif key.down? || key.enter? || ev.char == 'j'
        @p_level = :body
        @p_enter = true
      end
    end

    # In the body: ↑ (k) back up to the tab bar, ⇥ cycle panes (bonus, not required).
    private def practice_body_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.up? || ev.char == 'k'
        @p_level = :menu
        @p_up = true
      elsif key.tab?
        @p_pane = @p_pane == 0 ? 1 : 0
      end
    end

    private def practice_done? : Bool
      @p_switch && @p_enter && @p_up
    end

    private def reset_practice : Nil
      @p_level = :menu
      @p_tab = 0
      @p_pane = 0
      @p_switch = false
      @p_enter = false
      @p_up = false
    end

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      # A click is a friendly "next" — but not in the sandbox, where you must roam.
      advance if ev.press? && !@step.practice?
    end

    private def advance : Nil
      if @step.done?
        @running = false
      else
        @step = Step.new(@step.value + 1)
        @tick = 0                         # restart the new lesson's animation from frame 0
        reset_practice if @step.practice? # fresh sandbox each entry
      end
    end

    private def back : Nil
      return if @step.welcome?
      @step = Step.new(@step.value - 1)
      @tick = 0
      reset_practice if @step.practice?
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      unless Layout.usable?(w, h) && step_card(w, h).h >= MIN_CARD_H
        screen.text(0, 0, "terminal too small for the tutorial — resize and retry", Theme.red)
        @term.hide_cursor
        flush
        return
      end

      render_header(screen, w)
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

      @term.hide_cursor # the tour has no text entry — never show a caret
      flush
    end

    private def flush : Nil
      if @resized
        @term.sync # full repaint after a resize
        @resized = false
      else
        @term.render # diff render — only the animated cells repaint
      end
    end

    # Centred lesson card. Height grows to CONTENT_ROWS when the terminal allows,
    # clamped to the space between the header and the footer. One geometry source.
    private def step_card(w : Int32, h : Int32) : Rect
      cw = { {w - 4, CARD_W}.min, 40 }.max
      avail = {h - 3, 3}.max # rows between the header (row 0) and the footer (row h-1)
      ch = {CONTENT_ROWS + 3, avail}.min
      cx = {(w - cw) // 2, 0}.max
      cy = 2 + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    private def render_header(screen : Screen, w : Int32) : Nil
      x = screen.text(2, 0, "gori", Theme.text_bright, Theme.bg, attr: Attribute::Bold)
      screen.text(x + 1, 0, "· tutorial", Theme.muted, Theme.bg)
      prog = progress_label
      screen.text({w - prog.size - 2, 0}.max, 0, prog, Theme.muted, Theme.bg)
    end

    private def progress_label : String
      case @step
      when Step::Welcome  then "intro"
      when Step::Practice then "try it"
      when Step::Done     then "done"
      else                     "#{@step.value} of 4" # Navigate=1 … Edit=4
      end
    end

    private def card_title : String
      case @step
      when Step::Welcome   then "WELCOME"
      when Step::Navigate  then "MOVE AROUND · tabs & panes"
      when Step::Palette   then "COMMAND PALETTE · ^P"
      when Step::SpaceMenu then "ACTION MENU · space"
      when Step::Edit      then "EDIT MODE · READ / INS"
      when Step::Practice  then "TRY IT · your turn"
      else                      "YOU'RE READY"
      end
    end

    private def render_footer(screen : Screen, w : Int32, h : Int32) : Nil
      hint = case @step
             when Step::Welcome  then "↵ start · esc skip"
             when Step::Done     then "↵ finish"
             when Step::Practice then practice_done? ? "✓ ↵ finish · esc skip" : "arrow keys move · ⇥ panes · esc skip"
             else                     "↵ next · ⇧⇥ back · esc skip"
             end
      screen.text({(w - hint.size) // 2, 0}.max, h - 1, hint, Theme.muted, Theme.bg)
    end

    # --- lessons -------------------------------------------------------------

    private def render_welcome(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Welcome to gori — a keyboard-driven HTTP/HTTPS proxy.", Theme.text_bright, Theme.panel, width: iw)
      y += 2
      screen.text(ix, y, "This quick tour shows the four moves you'll use most:", Theme.text, Theme.panel, width: iw)
      y += 1
      [
        "1.  moving between tabs and panes",
        "2.  the command palette   ^P",
        "3.  the action menu       space",
        "4.  edit mode             READ / INS",
      ].each do |ln|
        screen.text(ix + 2, y, ln, Theme.text, Theme.panel, width: {iw - 2, 1}.max)
        y += 1
      end
      y += 1
      screen.text(ix, y, "Everything here is a harmless sandbox — nothing is real.", Theme.muted, Theme.panel, width: iw)
    end

    private def render_navigate(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "The arrow keys roam everywhere — no Enter needed.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "←/→ switch tab · ↓ into the body · ↑ back to tabs · ⇥ cycle panes · 1-9 jump",
        Theme.muted, Theme.panel, width: iw)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      # A 5-phase loop showing arrows roam both axes: → switch tab, ↓ into the body,
      # ⇥ cycle panes, ↑ back to the tab bar, then repeat.
      phase = (@tick // 12) % 5
      active = phase == 0 ? 0 : 1 # → moved History → Replay
      in_body = phase == 2 || phase == 3
      pane = phase == 3 ? 1 : 0 # ⇥ moved FLOWS → REQUEST
      keyhint = ["", "→", "↓", "⇥", "↑"][phase]
      render_shell(screen, shell, active, in_body, pane, keyhint)
    end

    private def render_palette(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "^P opens the command palette — every app-wide action.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "type to fuzzy-filter · ↑/↓ move · ↵ run · esc close", Theme.muted, Theme.panel, width: iw)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      render_shell(screen, shell, 0, false, 0, "")
      pw = { {shell.w - 8, 36}.min, 24 }.max
      ph = { {shell.h - 1, 7}.min, 6 }.max # 7 = border+query+divider+3 rows+border
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      py = shell.y + {(shell.h - ph) // 2, 0}.max
      render_fake_palette(screen, Rect.new(px, py, pw, ph))
    end

    private def render_spacemenu(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "space opens the action menu for whatever area has focus.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "each row has a mnemonic key — press it to run · ↑/↓ move · esc dismiss",
        Theme.muted, Theme.panel, width: iw)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      render_shell(screen, shell, 0, true, 0, "") # focus in the body so the menu context reads right
      rows = [{'o', "Open"}, {'r', "Replay"}, {'y', "Copy"}, {'/', "Filter"}]
      mw = 16
      mh = rows.size + 2
      mx = shell.right - mw - 1
      my = {shell.bottom - mh, shell.y}.max
      render_fake_space_menu(screen, Rect.new(mx, my, mw, mh), rows) if mx > shell.x
    end

    private def render_edit(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Editors open in READ mode — navigate, select, copy, open the menu.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "press i or ↵ to enter INS and type · esc returns to READ", Theme.muted, Theme.panel, width: iw)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 1 - y, 3}.max)
      screen.fill(shell, Theme.bg)
      # A 6-phase loop: READ, then INS typing "alice", then back to READ.
      phase = (@tick // 10) % 6
      insert = 1 <= phase <= 4
      typed_full = "alice"
      typed = insert ? typed_full[0, {phase, typed_full.size}.min] : ""

      pw = { {shell.w - 4, 48}.min, 24 }.max
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      pane = Rect.new(px, shell.y, pw, {shell.h - 1, 3}.max)
      render_request_pane(screen, pane, true, insert: insert, typed: typed)

      kh = insert ? "i → INS" : "esc → READ"
      screen.text(shell.x + {(shell.w - kh.size) // 2, 0}.max, shell.bottom - 1, kh, Theme.muted, Theme.bg)
    end

    # The hands-on finish: a LIVE mock the user drives with the arrow keys. A small
    # goal checklist lights up as they roam; completing it unlocks ↵ to finish, so
    # they leave the tour by actually navigating (not just clicking through).
    private def render_practice(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "Now you try! Roam this mock with the arrow keys.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      gx = draw_goal(screen, ix, y, "switch tab", @p_switch)
      gx = draw_goal(screen, gx + 3, y, "enter ↓", @p_enter)
      draw_goal(screen, gx + 3, y, "back ↑", @p_up)
      y += 2

      shell = Rect.new(box.x + 2, y, box.w - 4, {box.bottom - 2 - y, 3}.max)
      render_shell(screen, shell, @p_tab, @p_level == :body, @p_pane, "")

      msg = practice_done? ? "✓ Nicely done — press ↵ to finish the tour." : "Try: ←/→ , then ↓ , then ↑."
      screen.text(ix, box.bottom - 2, msg, practice_done? ? Theme.green : Theme.muted, Theme.panel, width: iw)
    end

    # One goal chip (✓/○ + label), returning the x just past it so chips chain.
    private def draw_goal(screen : Screen, x : Int32, y : Int32, label : String, done : Bool) : Int32
      col = done ? Theme.green : Theme.muted
      screen.cell(x, y, done ? '✓' : '○', col, Theme.panel)
      screen.text(x + 2, y, label, done ? Theme.text : Theme.muted, Theme.panel)
    end

    private def render_done(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.text(ix, y, "That's the tour — you're ready to drive gori.", Theme.text_bright, Theme.panel, width: iw)
      y += 2
      [
        {"move", "arrow keys: ←/→ tab · ↓ enter · ↑ back · ⇥ panes"},
        {"palette", "^P — app-wide commands"},
        {"menu", "space — actions for the focused area"},
        {"edit", "i/↵ to type (INS) · esc back to READ"},
      ].each do |(key, desc)|
        screen.text(ix, y, key, Theme.muted, Theme.panel, width: 8)
        screen.text(ix + 9, y, desc, Theme.text, Theme.panel, width: {iw - 9, 1}.max)
        y += 1
      end
      y += 1
      screen.text(ix, y, "Open the Help tab anytime for the full cheat-sheet.", Theme.muted, Theme.panel, width: iw)
    end

    # --- mock UI -------------------------------------------------------------

    # A miniature of the gori shell (tab bar + two panes) drawn into `rect`, on a
    # Theme.bg backdrop so the panel panes read as they do in the real app. When
    # `in_body` is false the tab bar holds focus (gold pill); otherwise the active
    # `pane` (0=FLOWS, 1=REQUEST) does. `keyhint` labels the transition just made.
    private def render_shell(screen : Screen, rect : Rect, active : Int32, in_body : Bool,
                             pane : Int32, keyhint : String) : Nil
      return if rect.h < 5
      screen.fill(rect, Theme.bg)
      render_tab_bar(screen, rect.x, rect.y, rect.w, active, !in_body)

      # focus label, right-aligned on the tab row (TABS on the bar, BODY in a pane)
      scol = in_body ? Theme.focus_gold : Theme.accent
      slabel = " #{in_body ? "BODY" : "TABS"} "
      sx = rect.right - slabel.size
      screen.text(sx, rect.y, slabel, Theme.ink_on(scol), scol, attr: Attribute::Bold) if sx > rect.x

      py = rect.y + 2
      ph = {rect.bottom - py, 3}.max
      gap = 2
      lw = {(rect.w - gap) // 2, 1}.max
      rw = {rect.w - gap - lw, 1}.max
      render_flows_pane(screen, Rect.new(rect.x, py, lw, ph), in_body && pane == 0)
      render_request_pane(screen, Rect.new(rect.x + lw + gap, py, rw, ph),
        in_body && pane == 1, insert: false, typed: "")

      unless keyhint.empty?
        kh = " #{keyhint} "
        screen.text(rect.x + {(rect.w - kh.size) // 2, 0}.max, rect.y + 1, kh,
          Theme.ink_on(Theme.accent), Theme.accent, attr: Attribute::Bold)
      end
    end

    private def render_tab_bar(screen : Screen, x : Int32, y : Int32, w : Int32,
                               active : Int32, focused : Bool) : Nil
      cx = x
      TABS.each_with_index do |name, i|
        label = " #{name} "
        break if cx + label.size > x + w
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

    private def render_flows_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "FLOWS", border: Frame.pane_border(focused))
      rows = [{"GET ", "/api/users", 200}, {"POST", "/login", 401}, {"GET ", "/admin", 500}]
      yy = rect.y + 1
      rows.each_with_index do |(method, path, status), i|
        break if yy >= rect.bottom - 1
        sel = focused && i == 0
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

    # The REQUEST pane, shared by the navigation mock (READ) and the edit lesson
    # (INS + a typed line). The mode badge mirrors the real app: a lit "INS" or a
    # dim " NOR " (the app's badge reads NOR for READ mode).
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
      ["GET /login HTTP/1.1", "Host: example.com", "Accept: */*"].each do |ln|
        break if yy >= rect.bottom - 1
        screen.text(ix, yy, ln, Theme.text, Theme.panel, width: iw)
        yy += 1
      end
      if insert && yy < rect.bottom - 1
        px = screen.text(ix, yy, "username=#{typed}", Theme.text_bright, Theme.panel, width: iw)
        screen.cell({px, rect.right - 2}.min, yy, ' ', Theme.bg, Theme.accent) # block caret
      end
    end

    private def render_fake_palette(screen : Screen, rect : Rect) : Nil
      return if rect.w < 12 || rect.h < 4
      Frame.card(screen, rect, "COMMANDS", border: Theme.border_focus)
      screen.text(rect.x + 2, rect.y + 1, "›", Theme.accent, Theme.panel)
      screen.cell(rect.x + 4, rect.y + 1, ' ', Theme.bg, Theme.accent) # caret in the (empty) query
      Frame.tee_divider(screen, rect, rect.y + 2)
      rows = [{"»", "Go to Replay"}, {"≡", "Settings: Theme"}, {"×", "Quit gori"}]
      sel = (@tick // 10) % rows.size
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
    end

    private def render_fake_space_menu(screen : Screen, rect : Rect,
                                       rows : Array({Char, String})) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "SPACE", border: Theme.border_focus)
      sel = (@tick // 10) % rows.size
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
