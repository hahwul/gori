require "termisu"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./layout"
require "./mascot"
require "./notifications"
require "./companion"
require "../settings"

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
    TABS = %w[Project Target History Intercept Repeater Fuzzer Help]

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
    HEADER_ROWS  =  2 # brand + progress rail
    FOOTER_ROWS  =  2 # hint + Prev/Next buttons

    # Rows the mock wants: the tab bar, the keyhint row under it, and panes tall enough to
    # show every FLOW_ROWS row. `render_shell` refuses to draw at all below 5 (its panes are
    # clamped to 3 rows and would spill past the rect), and `lesson_split` hands it these
    # rows BEFORE the prose so it can never fall through that floor.
    SHELL_ROWS = 7

    # Columns Miss Ring's stand claims at the right edge, when she is on: the sprite, the
    # GUTTER Companion.place already keeps clear of it, and ONE more for the plate strip
    # Companion.draw paints at `rect.x - 1`.
    #
    # The card is NARROWED by this rather than the sprite being dropped when it doesn't
    # fit beside a full-width card — which is what the project picker does, and copying
    # that rule here would have been wrong. The picker's card is 50 columns, so 80 seats
    # her beside it; the tour's is up to 78, so the same rule would not seat her until
    # ~102 columns — absent on exactly the 80-column terminals the new users this tour
    # exists for are most likely to be running. CARD_W is a CAP, not a requirement
    # (step_card already floors the card at 40), so reserving her band before centring
    # costs a few columns of mock and seats her from 80.
    #
    # Only when she is ON. A default install (Companion off) must render the tour exactly as it
    # did before she existed — see #companion_band.
    COMPANION_BAND = Companion::GUTTER + Mascot::W + 1

    # Fake palette rows used by the palette lesson + practice overlay: sigil, label, and the
    # fake tab index the row switches to (nil = the row only closes the palette). The action
    # rides its own slot so the label is free to be reworded or translated without the
    # practice step's "Go to …" quietly turning into a no-op.
    PALETTE_ROWS = [
      {"»", "Go to Repeater", 4},
      {"≡", "Settings: Theme", nil},
      {"×", "Quit gori", nil},
      {"→", "Go to History", 2},
      {"?", "Open Help", 6},
    ]

    # Fake space-menu rows (mnemonic key + label).
    SPACE_ROWS = [{'o', "Open"}, {'r', "Repeater"}, {'y', "Copy"}, {'/', "Filter"}]

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
      # Held as the base Backend: TermisuBackend is generic over the terminal type.
      @backend = TermisuBackend.new(@term).as(Backend)
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
      # esc at the top level arms the leave-the-tour prompt; a second esc leaves. See
      # #handle_escape for why one press is not enough.
      @esc_armed = false

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

      # Miss Ring (settings:companion), the same widget the session and the picker run — off by
      # default, and the same zero-cost no-op while off. Like the picker she has no
      # notification ring here (the tour opens no project), so everything she says beyond
      # her hello is handed to her directly via Companion#say.
      #
      # SHE REACTS; THE CARD TEACHES. Every lesson's explanation stays in the card where
      # it already is, and she only ever confirms a move the user just made. That is what
      # keeps her honest against Companion#say's `companion_notices?` gate: a reader who turned her
      # speech off gets a tour missing some encouragement, never a tour missing the
      # lesson. Teaching content may not live in a bubble.
      @companion = Companion.new(Notifications.new)
      @companion_said = Set(Symbol).new # goals she has already reacted to (rising edge, once each)
    end

    # Run the tour to completion (Done + Next/Finish) or until the user leaves
    # (esc). Returns when done; the caller continues after.
    def run : Nil
      @running = true
      loop do
        tick_companion
        render
        # Own event loop — fold ⌥P onto ^P so the "try the palette" goal below can be
        # completed with whichever modifier the user configured.
        case ev = Keybind.dealias_event(@term.poll_event(50))
        when Termisu::Event::Resize then (@backend.resize(ev.width, ev.height); @resized = true)
        when Termisu::Event::Key    then (@companion.wake_on_input; handle_key(ev))
        when Termisu::Event::Mouse  then (@companion.wake_on_input; handle_mouse(ev))
        end
        @tick &+= 1
        break unless @running
      end
    end

    # --- Miss Ring -----------------------------------------------------------

    # No dirty-tracking around the tick (unlike the Runner's): this loop already repaints
    # every poll, so her `changed` verdict has nothing here to gate — the same bargain
    # ProjectPicker#tick_companion makes.
    private def tick_companion : Nil
      companion_watch_goals
      @companion.tick(Time.instant)
    end

    # What she says, per goal. Retagged (^P → ⌥P) at the say site so she names the chord
    # the user actually configured, exactly as the card titles do.
    COMPANION_LINES = [
      {:nav, "that's it — tab bar up top, body below"},
      {:palette, "^P from anywhere, any tab"},
      {:space, "space acts on whatever's selected"},
      {:edit, "INS to type, esc back to READ"},
      {:practice, "all four! you're ready"},
      {:done, "that's the tour — go break something"},
    ]

    # Rising-edge watch over the tour's OWN goal flags, run once per frame.
    #
    # The flags are set at a dozen scattered sites (lesson try-its, practice, the mock's
    # mouse handlers), and threading a reaction through each of them would put her in the
    # middle of code that has nothing to do with her. Watching the flags instead keeps
    # every line she says in one table, and means a goal reached by a route nobody thought
    # about still gets its reaction.
    #
    # ONE AT A TIME, AND ONLY WHILE SHE IS SILENT. Several goals can be reached before she
    # has said anything — a user who jumps straight to Practice via the rail, or a single
    # keystroke on the REQUEST pane that sets @p_edit and completes the practice set at
    # once — and firing them together would let the last line stomp the rest.
    #
    # "One per frame" is NOT enough to pace that, which is what this originally did: the
    # run loop polls on a 50ms timeout, so the next frame is ~50ms away while a :success
    # bubble lives for 3500ms. The queued line would replace the previous one before it
    # could be read. Waiting for the bubble to clear is the only pacing that matches how
    # long she actually speaks for, so the backlog drains one readable line at a time.
    private def companion_watch_goals : Nil
      return unless Settings.companion?
      return if companion_speaking?
      COMPANION_LINES.each do |(goal, line)|
        next unless companion_goal_reached?(goal)
        return if companion_react(goal, Hotkeys.retag(I18n.ring(line)))
      end
    end

    # Whether a bubble is still on screen. Not the text — nothing here paints her line, she
    # says it in her own bubble — only whether the next reaction has to wait its turn.
    private def companion_speaking? : Bool
      !@companion.frame.try(&.bubble).nil?
    end

    private def companion_goal_reached?(goal : Symbol) : Bool
      case goal
      when :nav      then @tried_nav
      when :palette  then @tried_palette
      when :space    then @tried_space
      when :edit     then @tried_edit
      when :practice then practice_done?
      when :done     then @step.done?
      else                false
      end
    end

    # React to a goal the user just completed, ONCE per tour; true when she actually spoke.
    # `goal` is the latch, not the step: the lessons set @tried_* and Practice sets @p_*,
    # and a user who does the same move in both should not be congratulated for it twice.
    #
    # Set#add? IS the latch — the caller must not pre-check membership, or the same fact
    # ends up spelled two ways and a later edit has to prove they agree. Loop-internal:
    # companion_watch_goals owns the Settings.companion? gate. Companion#say is gated on `companion_notices?` for
    # the rest, which is deliberate (see the note on @companion above).
    private def companion_react(goal : Symbol, line : String, level : Symbol = :success) : Bool
      return false unless @companion_said.add?(goal)
      @companion.say(line, Time.instant, level)
      true
    end

    # --- input ---------------------------------------------------------------

    # The character a keystroke carries WHEN IT IS NOT A CHORD, else nil.
    #
    # `Event::Key#char` is `@char || key.to_char`, so ^P arrives carrying 'p' and ⌥L
    # carrying 'l'. Every bare `ev.char == …` guard in this file was firing on the chord:
    # ^L switched a tab in Practice and ticked its "switch" goal, ^O ran the space menu's
    # `o Open` row, and both text-entry sites typed the chord's letter — ^P then ^T in the
    # palette lesson's filter left "pt" in the query box, on the lesson whose whole subject
    # is ^P. The real app guards this at every one of these sites
    # (Runner#handle_palette_key's `c && !ev.ctrl? && !ev.alt?`,
    # Runner#handle_space_menu_key's, TextField#handle_edit_key's); the tour guarded it
    # nowhere. ONE home for the rule, spec-able without a tty, so they cannot drift apart
    # again.
    #
    # The chords the tour DOES bind are matched on `ev.ctrl?` + `ev.key` before this is ever
    # reached (`palette_open_key?`), so nothing that wants a modifier comes through here.
    # `Keybind.dealias` composes: it rebuilds the ⌥P event with `char: nil` and Ctrl set, so
    # `to_char` still yields 'p' and this catches the aliased path too.
    def self.bare_char(ev : Termisu::Event::Key) : Char?
      return nil if ev.ctrl? || ev.alt?
      ev.char
    end

    # …and the text-entry half: what a keystroke should INSERT, or nil.
    #
    # Non-control rather than the printable-ASCII window this replaced (`ord >= 32 && < 127`),
    # matching `TextField#insert`: the tour's INS demo asks the user to "type a username" and
    # then silently dropped every Hangul/CJK/accented character they typed. Enter and
    # Backspace are handled by their own branches ahead of this and carry control chars
    # anyway.
    def self.typed_char(ev : Termisu::Event::Key) : Char?
      return nil unless ch = bare_char(ev)
      ch.control? ? nil : ch
    end

    private def handle_key(ev : Termisu::Event::Key) : Nil
      key = ev.key

      if ev.ctrl_c?
        @running = false
        return
      end

      # Anything but esc disarms the leave-the-tour confirmation (see #handle_escape). Set
      # here rather than per-branch so a key handled deep in an overlay still counts.
      @esc_armed = false unless key.escape?

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
        ch = Tutorial.bare_char(ev)
        if nav_switch_key?(ev) || key.down? || key.enter? || ch == 'j' ||
           ch == '[' || ch == ']'
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
          enter_insert
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
    # While typing in INS or with ANY overlay open (palette filter, or the space
    # menu that owns its own keys), n/b are NOT tour nav — the overlay consumes
    # them (the palette types them; the space menu ignores non-mnemonics) instead
    # of snapping the lesson forward/back. ⇧⇥ still escapes (checked first).
    #
    # Body focus in the mock does NOT suppress them, though it used to "to prevent
    # accidental jumps". Nothing in the mock's body binds n or b — the shell reads arrows,
    # hjkl, ⇥, ↵, i, space, ^P, digits and [ ] — so the suppression protected no gesture and
    # only made two advertised keys dead: `footer_hint` goes on printing "n next · b back" in
    # exactly that state, and on a short terminal, where the mock does not draw at all, one ↓
    # left the user pressing them at a blank card with nothing to explain why. Free keys, and
    # this whole method exists so a lesson can never trap anyone.
    private def tour_nav_key?(ev : Termisu::Event::Key) : Bool
      return true if ev.key.back_tab?
      return false if @edit_insert
      return false unless @overlay == :none
      ch = Tutorial.bare_char(ev) # nil for ^P etc. — leave the chords alone
      ch == 'n' || ch == 'N' || ch == 'b' || ch == 'B'
    end

    private def handle_tour_nav(ev : Termisu::Event::Key) : Nil
      if ev.key.back_tab?
        back
        return
      end
      case Tutorial.bare_char(ev)
      when 'n', 'N' then advance
      when 'b', 'B' then back
      end
    end

    # Reached only with INS closed and no overlay open — `handle_key` dispatches both of those
    # ahead of this, and each owns its own esc (leave INS / close the overlay). This is the
    # rest: pop one level of the mock, or leave the tour.
    private def handle_escape : Nil
      if live_shell? && @p_level == :body
        @p_level = :menu
        @p_up = true
        mark_nav_tried
        return
      end
      # Top level, where esc leaves the tour — but only on a DELIBERATE second press.
      #
      # This tour spends two steps teaching esc as "go back" and Practice names `esc back` as
      # one of its six goals, so the press that arrives here is nearly always someone who
      # meant back and had already run out of levels: one step too far in Practice, or the
      # second half of the double-tap that dismisses an overlay (^P, esc to close, esc). A
      # single press ended the whole tour on the spot, and on the first-run path that is
      # permanent — App offers it only while settings.json is absent (which the wizard has
      # just written), and the Done step it discards is the only screen that names
      # `gori tutorial` as the way back.
      #
      # `footer_hint` announces the armed state, and any other key disarms it (#handle_key,
      # #handle_mouse), so this can't strand anyone in a mode they can't see — which is also
      # why the resize-and-retry screen, the one path that paints no footer, opts out.
      return @running = false if too_small?
      if @esc_armed
        @running = false
      else
        @esc_armed = true
      end
    end

    private def live_shell? : Bool
      @step.practice? || (@step.navigate? && @nav_live)
    end

    # Shared shell keyboard model for Navigate (live) and Practice — closer to the
    # real app: [ / ] switch tabs anywhere, esc back to tabs, ⇥ panes, ↑/↓ list,
    # ↵ opens detail / INS on the request, ^P / space openers.
    private def handle_live_shell_key(ev : Termisu::Event::Key, *, practice : Bool) : Nil
      key = ev.key
      # Bare, never the letter a chord happens to carry — ^L used to switch a tab and tick
      # Practice's "switch" goal. See Tutorial.bare_char.
      bare = Tutorial.bare_char(ev)

      # Global tab cycle (real app: [ / ] from anywhere).
      if bare == '['
        switch_tab(-1)
        return
      end
      if bare == ']'
        switch_tab(1)
        return
      end
      if (ch = bare) && ch >= '1' && ch <= '9'
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
        enter_insert
        @p_edit = true if practice
        return
      end

      # ↵ on FLOWS focuses the REQUEST pane (open the selected flow).
      if @p_pane == 0 && key.enter?
        @p_pane = 1
        return
      end

      if key.down? || bare == 'j'
        @p_flow = {@p_flow + 1, FLOW_ROWS.size - 1}.min if @p_pane == 0
        return
      end
      # ↑ / k: REQUEST always returns to the tab bar. FLOWS moves the list first,
      # and at the top row also returns to tabs (same focus-ring as real History).
      if key.up? || bare == 'k'
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
      if key.left? || bare == 'h'
        @p_pane = 0 if @p_pane == 1
        return
      end
      if key.right? || bare == 'l'
        @p_pane = 1 if @p_pane == 0
        return
      end
    end

    private def focus_tabs : Nil
      @p_level = :menu
      @p_up = true
      mark_nav_tried
    end

    private def practice_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      bare = Tutorial.bare_char(ev)
      if key.left? || bare == 'h'
        switch_tab(-1)
      elsif key.right? || bare == 'l'
        switch_tab(1)
      elsif key.down? || key.enter? || bare == 'j'
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        mark_nav_tried
      end
    end

    private def switch_tab(delta : Int32) : Nil
      @p_tab = (@p_tab + delta) % TABS.size
      mark_switch
    end

    private def mark_switch : Nil
      @p_switch = true
      mark_nav_tried
      # Switching tabs while in the body keeps body focus (real app); stay put.
    end

    # The two lesson try-it flags that more than one lesson can reach, gated to the lessons
    # they belong to.
    #
    # @tried_nav is the Navigate lesson's ✓ (and Miss Ring's :nav line, "that's it — tab bar
    # up top, body below"); @tried_edit is the Edit lesson's. Both were set unconditionally
    # from shared code every lesson runs through — mark_switch, focus_tabs,
    # handle_shell_click, handle_live_shell_key's INS branch — so a click on the EDIT
    # lesson's REQUEST pane ticked NAVIGATE's try-it and had Miss Ring congratulate a move
    # about tab bars on the lesson about typing, and entering INS during the Navigate lesson
    # pre-✓'d Edit before the user reached it. Practice re-teaches both moves, so it counts
    # for either; every other lesson counts for neither.
    private def mark_nav_tried : Nil
      @tried_nav = true if @step.navigate? || @step.practice?
    end

    private def mark_edit_tried : Nil
      @tried_edit = true if @step.edit? || @step.practice?
    end

    # The three doors into the mock's INS mode — the Edit lesson's `i`/↵, the shared shell's
    # `i`/↵ on the REQUEST pane, and a click on the Edit lesson's pane — spelled the same
    # three lines each. One home, so they cannot disagree about the try-it flag the way they
    # already did about the field.
    private def enter_insert : Nil
      @edit_insert = true
      @edit_typed = ""
      mark_edit_tried
    end

    private def handle_edit_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.escape?
        @edit_insert = false
        mark_edit_tried
        return
      end
      if key.enter?
        # ↵ leaves INS (like leaving insert in many editors); Next advances the tour.
        @edit_insert = false
        mark_edit_tried
        return
      end
      if key.backspace?
        @edit_typed = @edit_typed[0...-1] unless @edit_typed.empty?
        return
      end
      if (ch = Tutorial.typed_char(ev)) && @edit_typed.size < 16
        @edit_typed += ch
        mark_edit_tried
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
        # ONE `rows.size` for both arrows. The ↑ arm used to take the modulo BEFORE its
        # empty-list guard — `(@pal_sel - 1) % 0` — so typing a character that matches no
        # PALETTE_ROWS label and then pressing ↑ killed the tour with an unhandled
        # DivisionByZeroError, while the ↓ arm three lines below had always computed `n`
        # first. `render_fake_palette` already paints "(no matches)" and `footer_hint`
        # advertises ↑/↓ in exactly that state, so the empty list was expected everywhere
        # except on that one line. Hoisted rather than re-guarded so the two cannot drift
        # apart again. (Crystal's `%` is floored, so -1 wraps to the last row.)
        n = filtered_palette.size
        # ARROWS ONLY, and everything else types — the rule Runner#handle_palette_key has.
        # j/k used to move the selection here, in a field the lesson's own key line calls
        # "type to fuzzy-filter": two letters the real palette accepts were the two this
        # mock refused, teaching a model gori does not have. (The space menu below is the
        # surface that DOES fall back to j/k, and it keeps it.)
        if key.up?
          @pal_sel = Tutorial.wrap_sel(@pal_sel, -1, n)
        elsif key.down?
          @pal_sel = Tutorial.wrap_sel(@pal_sel, +1, n)
        elsif key.backspace?
          @pal_query = @pal_query[0...-1] unless @pal_query.empty?
          @pal_sel = 0
        elsif (ch = Tutorial.typed_char(ev)) && @pal_query.size < 20
          @pal_query += ch
          @pal_sel = 0
        end
      when :space
        # Mnemonic FIRST, then the j/k fallback — the helix-leader order
        # Runner#handle_space_menu_key spells out. No SPACE_ROWS key is j or k today, so
        # this changes nothing now and cannot go wrong the day one is.
        bare = Tutorial.bare_char(ev)
        if bare && SPACE_ROWS.any? { |(k, _)| k == bare }
          close_overlay # mnemonic runs the row
        elsif key.up? || bare == 'k'
          @space_sel = (@space_sel - 1) % SPACE_ROWS.size
        elsif key.down? || bare == 'j'
          @space_sel = (@space_sel + 1) % SPACE_ROWS.size
        end
      end
    end

    private def filtered_palette : Array({String, String, Int32?})
      q = @pal_query.downcase
      return PALETTE_ROWS if q.empty?
      PALETTE_ROWS.select { |(_, label, _)| label.downcase.includes?(q) }
    end

    private def run_overlay_selection : Nil
      if @overlay == :palette
        rows = filtered_palette
        if row = rows[@pal_sel]?
          # Mirror a couple of real "Go to …" actions so the palette feels alive.
          if tab = row[2]
            @p_tab = tab
            mark_switch
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

    # The three below read a BARE character (Tutorial.bare_char), never the letter a chord
    # carries — ⌥I is not "press i", and ^Space is not the action menu.
    private def nav_switch_key?(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return true if key.left? || key.right?
      ch = Tutorial.bare_char(ev)
      ch == 'h' || ch == 'l' || ch == '[' || ch == ']'
    end

    private def palette_open_key?(ev : Termisu::Event::Key) : Bool
      ev.ctrl? && ev.key.lower_p?
    end

    private def space_open_key?(ev : Termisu::Event::Key) : Bool
      Tutorial.bare_char(ev) == ' '
    end

    private def edit_enter_key?(ev : Termisu::Event::Key) : Bool
      ch = Tutorial.bare_char(ev)
      ch == 'i' || ch == 'I'
    end

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? && !ev.wheel?
      @esc_armed = false          # a click is intent to stay (see #handle_escape)
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
        # Click a row → select + run (same as ↵). Bounded by the rows actually PAINTED and
        # offset by the same scroll window `render_fake_palette` used, not by `rows.size`:
        # the two disagreed, so a click on the overlay's bottom border ran a command the user
        # could not see.
        rows = filtered_palette
        vis = Tutorial.palette_rows_visible(@palette_rect)
        top = Tutorial.palette_scroll(@pal_sel.clamp(0, {rows.size - 1, 0}.max), rows.size, vis)
        row = my - (@palette_rect.y + 3)
        if row >= 0 && row < {vis, rows.size - top}.min
          @pal_sel = top + row
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

      # The Edit lesson draws ONLY the REQUEST pane, and its whole ask is "press i". A click
      # on it used to fall through to the body-focus branch below — which `render_edit`
      # ignores entirely, since it always draws that pane focused and reads @edit_insert for
      # the mode — so the pointer did nothing at all, while still ticking the NAVIGATE
      # lesson's try-it on the way past. Clicking into a field to type in it is what the
      # pointer means here.
      if @step.edit?
        enter_insert if @request_rect.contains?(mx, my) && !@edit_insert
        return
      end

      @tab_hits.each do |(rect, idx)|
        if rect.contains?(mx, my)
          @p_tab = idx
          mark_switch
          @p_level = :menu # clicking a tab focuses the bar (real app)
          return
        end
      end

      # Pane clicks only where the mock RENDERS focus: Navigate (made live just above) and
      # Practice. The Palette and SpaceMenu lessons hand `render_shell` a fixed focus so
      # their panes have nothing to move — moving @p_level/@p_pane there changed nothing on
      # screen, and the @p_flow it also moved left the REQUEST pane showing a flow the FLOWS
      # pane was not marking as selected.
      return unless live_shell?

      if @flows_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        mark_nav_tried
        # Row hit: interior starts at y+1.
        row = my - (@flows_rect.y + 1)
        @p_flow = row.clamp(0, FLOW_ROWS.size - 1) if row >= 0
        return
      end

      if @request_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 1
        @p_enter = true
        mark_nav_tried
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

      # Derived ONCE and reused below. step_card now runs the whole placement decision
      # (companion_band → companion_place → Companion.place, plus a nested step_card), and this loop repaints
      # on every 50ms poll — calling it for the guard and again for the card doubled that
      # work ~20x/second to answer a question whose inputs had not changed.
      box = step_card(w, h)
      if too_small?(w, h)
        screen.text(0, 0, "terminal too small for tutorial — min 40x16, resize & retry (esc to leave)", Theme.red)
        @term.hide_cursor
        flush
        return
      end

      render_header(screen, w)
      render_progress_rail(screen, w)
      Frame.card(screen, box, Hotkeys.retag(card_title), border: Theme.border_focus)
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
      render_companion(screen, w, h)

      @term.hide_cursor
      flush
    end

    # She paints LAST, over the card — anything she is allowed to occupy she occupies
    # opaquely, so drawing her earlier would let a mock's pane border cut through her.
    # step_card has already held her band back, so the sprite lands on bare background;
    # only the BUBBLE floats over the card, for the few seconds she is talking, exactly as
    # it does over the picker's card and a tab body in the session.
    private def render_companion(screen : Screen, w : Int32, h : Int32) : Nil
      return unless Settings.companion?
      # companion_draw_stage, NOT companion_stage: the bare stage seats her at every size Companion.place
      # accepts, which includes the 40..51-column band companion_place stands her down in. That
      # bug painted her over the mock tab bar at exactly those sizes.
      return unless stage = Tutorial.companion_draw_stage(w, h)
      return unless frame = @companion.frame
      Companion.draw(screen, stage, frame)
    end

    private def flush : Nil
      @backend.flush(sync: @resized)
      @resized = false
    end

    # Whether `render` will paint the resize-and-retry line instead of the tour.
    #
    # Shared with `handle_escape`, which must not arm its leave-the-tour confirmation on that
    # screen: `footer_hint` is what announces the armed state and this path returns before
    # `render_footer`, so a first esc there would change nothing a user could see while the
    # red line goes on advertising "esc to leave". Nothing on that screen is a lesson worth
    # protecting from an accidental press, so esc simply leaves.
    private def too_small?(w : Int32, h : Int32) : Bool
      !(Layout.usable?(w, h) && Tutorial.step_card(w, h, companion_band(w, h)).h >= MIN_CARD_H)
    end

    private def too_small? : Bool
      w, h = @backend.size
      too_small?(w, h)
    end

    # Card sits between the 2-row header and the 2-row footer, centred in whatever width
    # Miss Ring's stand leaves it (COMPANION_BAND, or the full width while she is off).
    private def step_card(w : Int32, h : Int32) : Rect
      Tutorial.step_card(w, h, companion_band(w, h))
    end

    # The placement rules themselves, free of Settings and of any Tutorial instance so a
    # spec can sweep them over terminal sizes — the one thing about her here that geometry
    # can get wrong. `band` is threaded through rather than read from Settings for the same
    # reason: the card's width and her stand are two halves of one decision, and a spec has
    # to be able to check they agree.
    def self.step_card(w : Int32, h : Int32, band : Int32 = 0) : Rect
      avail_w = {w - band, 40}.max
      cw = { {avail_w - 4, CARD_W}.min, 40 }.max
      avail = {h - HEADER_ROWS - FOOTER_ROWS, 3}.max
      ch = {CONTENT_ROWS + 3, avail}.min
      cx = {(avail_w - cw) // 2, 0}.max
      cy = HEADER_ROWS + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    # Her stage is the canvas down to the row above the footer, so Companion.place's own
    # BOTTOM_MARGIN keeps her plate clear of both footer rows with a row to spare.
    def self.companion_stage(w : Int32, h : Int32) : Rect
      Rect.new(0, 0, w, h - FOOTER_ROWS)
    end

    # Her stand, or nil when the terminal cannot seat her CLEAR OF THE CARD.
    #
    # Reserving her band is not enough on its own: step_card floors the card at 40 columns
    # (a narrower one can't hold a legible mock), so below ~52 columns the floor wins and
    # the card grows back over her stand. Layout.usable? admits terminals from 40 columns,
    # so that range is reachable — and the failure would be a mascot painted on top of the
    # tab-bar mock, not a missing one. She stands down instead, and #companion_band then returns
    # 0 so the card takes the full width it would have had if she were off.
    # Move a wrapping selection by `delta` over `n` rows, and 0 when there are none.
    #
    # A class method rather than two inline expressions because the two arrows had already
    # drifted: ↑ took `(@pal_sel - 1) % filtered_palette.size` BEFORE its empty-list guard, so
    # filtering the tour's fake palette down to no matches and pressing ↑ (or `k`) killed the
    # process with an unhandled DivisionByZeroError — on the first-run path that is after
    # `SetupWizard#finish` has written settings.json, so the tour never auto-launched again.
    # ↓ three lines below had always computed the size first. `render_fake_palette` clamps for
    # an empty list and paints "(no matches)", and `footer_hint` advertises ↑/↓ in exactly that
    # state, so the empty list was expected everywhere but that one line. One home, spec-able
    # without a tty. (Crystal's `%` is floored, so -1 wraps to the last row.)
    def self.wrap_sel(sel : Int32, delta : Int32, n : Int32) : Int32
      return 0 if n <= 0
      (sel + delta) % n
    end

    # Rows `render_fake_palette` can actually paint in `rect`: its interior between the query
    # divider (rect.y + 2) and the bottom border.
    #
    # ONE home for the draw loop, the scroll window and the click hit-test, which had drifted
    # apart. `draw_palette_overlay` capped the overlay at 8 rows — four short of what five
    # PALETTE_ROWS need — and there was no scrolling, so "Open Help" could not be drawn at any
    # terminal size while ↑/↓ still selected it: the ▎ marker simply vanished off the bottom
    # and ↵ ran a command that had never been on screen. The click path was worse, bounding
    # the row by `rows.size` instead of by what was painted, so a click on the card's own
    # bottom border ran an undrawn row. In the one lesson whose subject is "↑/↓ move · ↵ run".
    def self.palette_rows_visible(rect : Rect) : Int32
      {rect.h - 4, 0}.max
    end

    # First row of the scroll window that keeps `sel` on screen.
    #
    # Stateless, so the selection rides the window's BOTTOM edge once the list is scrolled at
    # all: moving up one row scrolls the list up with it rather than leaving it parked. A
    # sticky window (keep the previous top unless `sel` would fall outside it) would move less,
    # but it needs the previous top carried across frames, and this is a five-row fake palette
    # in a tutorial — the thing worth guaranteeing here is that draw, click and ↑/↓ agree on
    # one window, which they can only do if any of them can recompute it.
    def self.palette_scroll(sel : Int32, n : Int32, visible : Int32) : Int32
      return 0 if visible <= 0 || n <= visible
      { {sel - visible + 1, 0}.max, n - visible }.min
    end

    def self.companion_place(w : Int32, h : Int32) : Rect?
      return nil unless rect = Companion.place(companion_stage(w, h))
      # Her plate claims a column left of the sprite (Companion.draw), so that — not rect.x — is
      # the edge the card has to clear. COMPANION_BAND, not #companion_band: the card measured here is
      # the one she would get if she stands, which is exactly what this decides.
      return nil if rect.x - 1 < step_card(w, h, COMPANION_BAND).right
      rect
    end

    # Columns to hold back from the card. Not circular with step_card: companion_place measures
    # against a card sized by the CONSTANT band, never by this.
    def self.companion_band(w : Int32, h : Int32) : Int32
      companion_place(w, h) ? COMPANION_BAND : 0
    end

    # The stage to hand Companion.draw, or nil when she must not be drawn at all.
    #
    # ONE function, so the render path cannot drift from the placement rule. Companion.draw
    # re-derives Companion.place from whatever rect it is handed and knows nothing about the
    # card, so handing it the bare stage seats her at every size Companion.place accepts —
    # including the 40..51-column band companion_place deliberately rejects. Routing the render
    # through this makes "may she be drawn" and "where does she stand" the same answer,
    # and gives the spec something it can assert without a Screen.
    def self.companion_draw_stage(w : Int32, h : Int32) : Rect?
      return nil unless companion_place(w, h)
      companion_stage(w, h)
    end

    # …and the live gate. Off by default, so a default install gets the full-width card.
    private def companion_band(w : Int32, h : Int32) : Int32
      Settings.companion? ? Tutorial.companion_band(w, h) : 0
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
          @rail_hits << {Rect.new(cx, y, unit, 1), i}
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
      when Step::Welcome then " Start "
      when Step::Done    then " Finish "
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
      screen.text({(w - Screen.draw_width(hint)) // 2, 0}.max, hy, hint, Theme.muted, Theme.bg)

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
      # The armed esc outranks every lesson's hint: it is the only state in the tour where
      # the next keystroke can end it, and it lasts exactly until the next key or click.
      # The three hints that name the exit spell it "esc esc" for the same reason — a footer
      # promising what one press does when it takes two is the defect this whole change is
      # about, just pointed the other way.
      return "esc again to leave the tour · any other key stays" if @esc_armed
      case @step
      when Step::Welcome
        "↵/n start · click Start · esc esc leave"
      when Step::Done
        "↵/n finish · click Finish · esc esc leave"
      when Step::Practice
        if @overlay != :none
          # NOT `tour`: `tour_nav_key?` hands n/b to an open overlay (the palette types
          # them, the space menu ignores them), so printing "n next · b back" here named two
          # keys that do nothing — the same defect as the esc note above, pointed the other
          # way. The Palette lesson's own overlay hint already used the "then" form; these
          # two were the branches that didn't.
          "↑/↓ · ↵ run · esc close · then n/Next"
        elsif @edit_insert
          "type · esc → READ · then n/Next"
        elsif practice_done?
          "✓ done — ↵/n/Next · or keep exploring"
        else
          "roam the mock · #{tour} / Skip anytime"
        end
      when Step::Navigate
        if @edit_insert
          # Reachable here, not just on Edit/Practice — see the note in `render_navigate`.
          "type · esc → READ · then n/Next"
        elsif @nav_live
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
          Hotkeys.retag("try ^P · #{tour} to skip")
        end
      when Step::SpaceMenu
        if @overlay == :space
          "↑/↓ · letter · ↵ · esc close · then n/Next" # n/b belong to the menu here — see Practice
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
        "#{tour} · click Prev/Next · esc esc leave"
      end
    end

    # --- lessons -------------------------------------------------------------

    # Split a lesson's interior between its prose and its mock.
    #
    # THE MOCK IS THE LESSON, so it claims SHELL_ROWS off the bottom first and the prose
    # gives way — the muted key-hint rows restate what `footer_hint` already says, while a
    # lesson whose mock did not draw teaches nothing. The old fixed walk did the opposite,
    # and the card MIN_CARD_H admits is three rows shorter than CONTENT_ROWS asks for: at a
    # 12-row card (an 80x16 terminal — the size the "too small" message NAMES as the
    # minimum) it left the shell 4 rows, one under `render_shell`'s floor, so Navigate and
    # Practice painted an EMPTY card under "roam the mock" and "Try: switch a tab, enter
    # body". At 13 and 14 rows the FLOWS pane showed 1 and 2 of its 3 rows, teaching "↓ list"
    # over a list that could not move.
    #
    # Returns {rows of `detail` the prose may keep, the row the mock starts on}. `fixed` is
    # prose rows the lesson always draws (headline, try line, goal chips); `pad` is rows it
    # keeps BELOW the mock.
    # Class methods, like step_card and wrap_sel, so a spec can sweep them over card heights
    # without a tty — this is geometry, and the way it breaks is silently, at one end of a
    # size range nobody renders by hand.
    def self.lesson_split(box : Rect, fixed : Int32, detail : Int32, pad : Int32 = 0) : {Int32, Int32}
      floor = box.bottom - 1 - pad
      keep = { {floor - SHELL_ROWS - prose_top(box) - fixed, 0}.max, detail }.min
      y = prose_top(box) + fixed + keep
      y += 1 if y + 1 + SHELL_ROWS <= floor # blank spacer, only when the mock keeps its rows
      {keep, y}
    end

    # Blank spacer rows a lesson can still afford, given the `content` rows it always draws.
    #
    # The prose lessons (Welcome / Done) call this for their own spacing — what they overran
    # was the card's bottom border, which their eleventh row painted straight over
    # ("╰─Re-run this tour anytime: gori tutorial──╯" at 80x16). Practice calls it for the
    # status row UNDER its mock, passing `fixed + SHELL_ROWS` as content: same question, since
    # that row is spacing the mock's list rows outrank.
    def self.prose_gaps(box : Rect, content : Int32, want : Int32) : Int32
      { {box.bottom - 1 - prose_top(box) - content, 0}.max, want }.min
    end

    # First interior row a lesson writes on — one blank under the card's top border. ONE home
    # for it: both helpers above measure from here, and they disagreeing is how the card grew
    # a row past its own frame the last time.
    def self.prose_top(box : Rect) : Int32
      box.y + 2
    end

    private def render_welcome(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      moves = [
        "1.  tabs & panes     ←/→  ·  ↓  ·  esc  ·  ⇥",
        Hotkeys.retag("2.  command palette  ^P   — jump to any action"),
        "3.  action menu      space — commands for this pane",
        "4.  edit mode        READ / INS — browse, then type",
      ]
      gaps = Tutorial.prose_gaps(box, moves.size + 4, 2)
      screen.text(ix, y, "Welcome to gori — a keyboard-driven HTTP/HTTPS proxy.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      y += 1 if gaps > 0
      screen.text(ix, y, "You'll learn the four moves you'll use every session:", Theme.text, Theme.panel, width: iw)
      y += 1
      moves.each do |ln|
        screen.text(ix + 2, y, ln, Theme.text, Theme.panel, width: {iw - 2, 1}.max)
        y += 1
      end
      y += 1 if gaps > 1
      screen.text(ix, y, "Each step demos a move, then lets you try it on a live mock.", Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "Tour nav: n next · b back · click Prev/Next · click the step rail.", Theme.muted, Theme.panel, width: iw)
    end

    private def render_navigate(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      detail = [
        "←/→ on the bar · [ / ] from anywhere · 1-9 jump",
        "↓ or ↵ into the body · ↑ back to tabs · ↓ list · esc · ⇥ panes",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, "Every screen is a tab; most tabs split into panes.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: switch a tab, enter body, ↑ back to tabs.", @tried_nav)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      if @nav_live
        # INS included, because the SHARED shell handler can enter it here: ↵ or i on the
        # REQUEST pane sets @edit_insert on this lesson exactly as it does on Practice. This
        # used to draw `insert: false, typed: ""` regardless, so the user landed in an
        # invisible INS mode — the badge still read READ, nothing showed what they typed,
        # and `handle_key` routes every key to `handle_edit_key` while it is on, so n and b
        # went dead with nothing on screen to explain why. The one thing `tour_nav_key?`
        # exists to prevent.
        render_shell(screen, shell, @p_tab, @p_level == :body, @p_pane, "",
          flow: @p_flow, insert: @edit_insert, typed: @edit_typed)
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
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: 1)
      screen.text(ix, y, "Jump to any action without hunting tabs or memorizing chords.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      if keep > 0
        screen.text(ix, y, Hotkeys.retag("^P opens it · type to fuzzy-filter · ↑/↓ move · ↵ run · esc close"),
          Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, Hotkeys.retag("Try: press ^P, filter, ↵ to run a command."), @tried_palette)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      render_shell(screen, shell, @p_tab, false, 0, "", flow: 0)
      # Demo auto-overlay only until the user has tried — after they close it,
      # leave a clean shell so it doesn't look like the palette is still open.
      if @overlay == :palette
        draw_palette_overlay(screen, shell, live: true)
      elsif !@tried_palette
        draw_palette_overlay(screen, shell, live: false)
      end
    end

    private def render_spacemenu(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: 1)
      screen.text(ix, y, "space opens actions for whatever area has focus.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      if keep > 0
        screen.text(ix, y, "each row has a mnemonic key — press it to run · ↑/↓ move · esc dismiss",
          Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: press space, move with ↑/↓, run with a letter or ↵.", @tried_space)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      # @p_tab, not a hardcoded 0: `render_tab_bar` registers a hit rect for every chip it
      # draws, so a click on one was already moving @p_tab — this lesson was the only one
      # that then ignored it, leaving the chips looking clickable and behaving dead.
      render_shell(screen, shell, @p_tab, true, 0, "", flow: 0)
      if @overlay == :space
        draw_space_overlay(screen, shell, live: true)
      elsif !@tried_space
        draw_space_overlay(screen, shell, live: false)
      end
    end

    private def render_edit(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: 1)
      screen.text(ix, y, "Editors open in READ — navigate, select, copy, open the menu.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      if keep > 0
        screen.text(ix, y, "press i or ↵ to enter INS and type · esc returns to READ (safe by default)",
          Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: press i, type a username, esc back to READ.", @tried_edit)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
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
      render_request_pane(screen, pane, true, insert: insert, typed: typed, flow: 0)

      kh = insert ? "INS · type · esc → READ" : "READ · i or ↵ → INS"
      screen.text(shell.x + {(shell.w - Screen.draw_width(kh)) // 2, 0}.max, shell.bottom - 1, kh, Theme.muted, Theme.bg)
    end

    private def render_practice(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      goals = [
        {"switch", @p_switch}, {"enter", @p_enter}, {"esc back", @p_up},
        {Hotkeys.retag("^P"), @p_palette}, {"space", @p_space}, {"i INS", @p_edit},
      ]
      # Practice carries two rows of prose the other lessons don't — the six goal chips — and
      # at the shortest card that costs the mock a FLOWS row, on the one step whose key line
      # teaches "↓ list". So the chips fold onto one row when they fit there, and the status
      # row under the mock (which restates those same chips, and `footer_hint` under it) is
      # what goes next. Both are spacing around the mock; the mock is the lesson.
      one_row = goals.sum { |(label, _)| label.size + 4 } - 2 <= iw
      fixed = one_row ? 2 : 3
      pad = Tutorial.prose_gaps(box, fixed + SHELL_ROWS, 1)
      _, sy = Tutorial.lesson_split(box, fixed: fixed, detail: 0, pad: pad)

      screen.text(ix, y, "Your turn — complete each move once (or Skip anytime).", Theme.text_bright, Theme.panel, width: iw)
      y += 1

      per_row = one_row ? goals.size : 3
      goals.each_slice(per_row) do |slice|
        gx = ix
        slice.each { |(label, done)| gx = draw_goal(screen, gx, y, label, done) + 2 }
        y += 1
      end

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - pad - sy, 3}.max)
      render_shell(screen, shell, @p_tab, @p_level == :body, @p_pane, "",
        flow: @p_flow, insert: @edit_insert, typed: @edit_typed)

      case @overlay
      when :palette then draw_palette_overlay(screen, shell, live: true)
      when :space   then draw_space_overlay(screen, shell, live: true)
      end

      return if pad == 0
      msg = if practice_done?
              "✓ Nicely done — click Next or press ↵."
            elsif @overlay != :none
              "Overlay open — ↵ runs, esc closes, click outside dismisses."
            elsif @edit_insert
              "INS mode — type, then esc back to READ."
            else
              Hotkeys.retag("←/→ tabs · ↓ body · ↑ tabs · ↓ list · ⇥ panes · esc · ^P · space · i")
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
      steps = [
        {"1.", "run  gori  — start the TUI (proxy on your bind address)"},
        {"2.", "browse via Project, or point a client at the proxy"},
        {"3.", "History — pick a captured flow"},
        {"4.", "^R — send it to Repeater · edit (i) · send again"},
        {"5.", "Help tab — full cheat-sheet anytime"},
      ]
      gaps = Tutorial.prose_gaps(box, steps.size + 3, 2)
      screen.text(ix, y, "That's the tour — here's a first real session:", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      y += 1 if gaps > 0
      steps.each do |(num, desc)|
        screen.text(ix, y, num, Theme.accent, Theme.panel, width: 3)
        screen.text(ix + 3, y, desc, Theme.text, Theme.panel, width: {iw - 3, 1}.max)
        y += 1
      end
      y += 1 if gaps > 1
      screen.text(ix, y, Hotkeys.retag("Cheat-sheet:  ^P palette · space menu · i/↵ INS · esc READ/back"), Theme.muted, Theme.panel, width: iw)
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
      # The focus badge is painted AFTER the tab bar and would overwrite whatever chip
      # happens to reach its columns, so reserve them first — otherwise the last tab that
      # still fits gets sheared mid-word and reads as "Fuzzer" rendering as "F TABS".
      # Only visible once the shell is narrow enough for the chips to reach that far,
      # which is why Miss Ring's band (which narrows the card) is what surfaced it.
      scol = in_body ? Theme.focus_gold : Theme.accent
      slabel = " #{in_body ? "BODY" : "TABS"} "
      sx = rect.right - slabel.size
      # ONE condition for both the reservation and the paint. Reserving columns the badge
      # then declines to use (sx <= rect.x, on a shell too narrow to hold it) would spend
      # the whole row on a chip that never appears.
      badge = sx > rect.x
      bar_w = badge ? {rect.w - slabel.size - 1, 1}.max : rect.w
      render_tab_bar(screen, rect.x, rect.y, bar_w, active, !in_body)
      screen.text(sx, rect.y, slabel, Theme.ink_on(scol), scol, attr: Attribute::Bold) if badge

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
      render_request_pane(screen, req, in_body && pane == 1, insert: insert, typed: typed, flow: flow)

      unless keyhint.empty?
        kh = " #{keyhint} "
        screen.text(rect.x + {(rect.w - Screen.draw_width(kh)) // 2, 0}.max, rect.y + 1, kh,
          Theme.ink_on(Theme.accent), Theme.accent, attr: Attribute::Bold)
      end
    end

    private def render_tab_bar(screen : Screen, x : Int32, y : Int32, w : Int32,
                               active : Int32, focused : Bool) : Nil
      @tab_hits = [] of {Rect, Int32}
      cx = x
      TABS.each_with_index do |name, i|
        label = " #{name} "
        lw = Screen.draw_width(label)
        break if cx + lw > x + w
        @tab_hits << {Rect.new(cx, y, lw, 1), i}
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
                                    insert : Bool, typed : String, flow : Int32) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "REQUEST", border: Frame.pane_border(focused))
      badge_min = rect.x + 10
      Frame.mode_badge(screen, rect.right - 1, rect.y, badge_min, insert)

      ix = rect.x + 2
      iw = {rect.w - 4, 1}.max
      yy = rect.y + 1
      # Reflect the selected flow path so the two panes feel linked. The INDEX RENDER_SHELL
      # WAS HANDED, not @p_flow — its sibling `render_flows_pane` marks the row from the
      # parameter, and reading the field here meant the two panes could name different flows
      # on any lesson that draws the shell with a fixed one.
      path = FLOW_ROWS[flow]?.try(&.[1]) || "/login"
      ["GET #{path} HTTP/1.1", "Host: example.com", "Accept: */*"].each do |ln|
        break if yy >= rect.bottom - 1
        screen.text(ix, yy, ln, Theme.text, Theme.panel, width: iw)
        yy += 1
      end
      if yy < rect.bottom - 1
        user = typed
        if insert
          px = screen.text(ix, yy, "username=#{user}", Theme.text_bright, Theme.panel, width: iw)
          screen.cell({px, rect.right - 2}.min, yy, ' ', Theme.bg, Theme.accent)
        elsif focused || !typed.empty? || @tried_edit
          screen.text(ix, yy, "username=#{user}", Theme.text, Theme.panel, width: iw)
        else
          screen.text(ix, yy, "username=alice", Theme.muted, Theme.panel, width: iw)
        end
      end
    end

    private def draw_palette_overlay(screen : Screen, shell : Rect, *, live : Bool) : Nil
      pw = { {shell.w - 8, 36}.min, 24 }.max
      # Tall enough for every row when the shell can spare it: border + query + divider +
      # rows + border. The old cap of 8 was fixed at four rows short of PALETTE_ROWS, so the
      # fifth was unreachable even on a 200-row terminal — see `palette_rows_visible`.
      ph = { {shell.h - 1, PALETTE_ROWS.size + 4}.min, 6 }.max
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
        # COLUMNS, not characters: the query accepts CJK/Hangul now (Tutorial.typed_char),
        # and each of those is two columns wide — counting them as one parked the caret
        # inside the text it is supposed to follow.
        caret_x = qx + {Screen.draw_width(q), qw - 1}.min
        screen.cell(caret_x, rect.y + 1, ' ', Theme.bg, Theme.accent) if caret_x < rect.right - 1
      end
      Frame.tee_divider(screen, rect, rect.y + 2)

      rows = live ? filtered_palette : PALETTE_ROWS
      sel = if live
              rows.empty? ? 0 : @pal_sel.clamp(0, rows.size - 1)
            else
              (@tick // 10) % PALETTE_ROWS.size
            end
      vis = Tutorial.palette_rows_visible(rect)
      top = Tutorial.palette_scroll(sel, rows.size, vis)
      yy = rect.y + 3
      rows[top, vis].each_with_index do |(sig, label), i|
        s = top + i == sel
        bg = s ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, s ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 3, yy, sig, Theme.muted, bg)
        screen.text(rect.x + 5, yy, label, s ? Theme.text_bright : Theme.text, bg,
          width: {rect.right - 1 - (rect.x + 5), 1}.max)
        yy += 1
      end
      # A scrolled list says so, on the border row it is covering — otherwise a window showing
      # 2 of 5 reads as a palette with only 2 commands in it. Rows BELOW the window, not rows
      # hidden in total: it is painted at the bottom edge, so it can only be read as "more
      # that way", and it went on claiming "+3" with the user parked on the last row.
      below = rows.size - top - vis
      if vis > 0 && below > 0
        more = "+#{below}"
        screen.text({rect.right - 1 - more.size, rect.x + 1}.max, rect.bottom - 1, more, Theme.muted, Theme.panel)
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
