require "termisu"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./layout"
require "./mascot"
require "./tutorial"
require "./viewport"
require "../settings"

module Gori::Tui
  # The first-run setup wizard: a standalone, full-screen, step-by-step TUI that
  # helps a brand-new user configure gori before the project picker. Auto-launched
  # once (App#run_tui, when settings.json doesn't exist yet) and re-runnable via
  # `gori wizard`. A config-only tool — no Session/proxy/CA — so it just edits the
  # global Settings + live Theme, mirroring ProjectPicker's run-loop/render shape.
  #
  # Steps: NETWORK (bind ip/port) → THEME (list + live preview) → COMPANION (Miss Ring) →
  # REVIEW (recap + finish).
  #
  # Edits are STAGED in wizard-local fields and committed to Settings only on
  # finish, so "skip" (Esc) is coherent: it reverts the live theme preview to the
  # baseline, leaves Settings untouched, and persists once (materializing
  # settings.json so the wizard never auto-launches again).
  class SetupWizard
    # Miss Ring's stand in the COMPANION step's card: the sprite plus a column of plate either
    # side, held off the card's right border.
    COMPANION_PREVIEW_W   = Mascot::W + 2
    COMPANION_PREVIEW_GAP = 2 # min columns between the text column and her plate
    # Narrowest text column the COMPANION step will lay out AROUND her sprite: the width of its
    # opening line ("A mascot in the corner, off unless you want her."), the one sentence
    # that says what the step is asking. Below it she is dropped and the copy takes the
    # card — see `self.companion_preview_x`. Coupled BY HAND to that sentence, exactly the way
    # BIND_ROWS/COMPANION_ROWS/REVIEW_ROWS are coupled to their renderers and just as unchecked:
    # reword the line and this number is what decides whether the reworded one survives.
    COMPANION_TEXT_MIN = 48
    LABEL_W            =  9 # widest bind label ("Bind Port")
    PREVIEW_W          = 30 # theme-preview panel width (two-column theme step)
    PREVIEW_GAP        =  2
    LIST_MIN           = 24 # minimum theme-list width before the preview is dropped
    THEME_VP_MAX       = 10 # most theme rows shown at once

    # Interior content rows each FIXED-LAYOUT step draws, below the card's top border + 1 pad
    # row. Each must match what the matching render_* actually draws at its fixed offsets, and
    # NOTHING CHECKS THAT — the spec pins MIN_H against these numbers, not these numbers against
    # the renderers, because SetupWizard builds its own TermisuBackend and can't be rendered
    # headless. So they are load-bearing by hand: at MIN_H the tallest step has exactly ZERO
    # spare rows (its content ends on `box.bottom - 2`), which means one row added to a render_*
    # without bumping its constant here draws straight over the card's bottom border, and one
    # row added to REVIEW raises the real floor above the "min 40x15" the guard advertises.
    # Count the offsets in the renderer when you touch either.
    # (Appearance isn't here — it scrolls, so its viewport follows the card height rather than
    # demanding one; see `content_rows`.)
    BIND_ROWS      = 8 # heading, gap, ip, port, gap, 2 info lines, status
    COMPANION_ROWS = 7 # heading, gap, 2 offer rows, gap, motion row, info line
    REVIEW_ROWS    = 9 # title, gap, 4 recap rows, gap, 2 offer rows

    # ONE size floor for every step, DERIVED from the tallest rather than hand-counted. It used
    # to be checked per step against each step's own rows, and the steps don't agree — BIND
    # wanted 14 terminal rows, COMPANION 13, REVIEW 15 — so a 14-row terminal drew BIND, THEME and COMPANION
    # and then refused to draw REVIEW, the one step where `finish` lives. Input is handled
    # regardless of that guard, so a blind ↵ still committed; the user simply had no way to know
    # it would. One floor means the wizard refuses at step 1 or not at all.
    #
    # `+ 6`: a card needs `rows + 3` (top border, pad row, content, bottom border) and
    # `card_h` can only reach `h - 3`. See the spec, which pins the derivation in both
    # directions so a new REVIEW row can't quietly raise the real floor past this number.
    MIN_W = 40 # Layout.usable?'s width floor; step_card clamps to 34 columns inside it
    MIN_H = {BIND_ROWS, COMPANION_ROWS, REVIEW_ROWS}.max + 6

    # The failed-save footer once the full one no longer fits — see render_footer.
    SAVE_FAILED_SHORT = "save failed · ↵ retry · esc discard"

    # The card height `step_card` settles on for a terminal of height `h` and a step wanting
    # `rows` of content. Pulled out as a pure class method so the MIN_H invariant above is
    # checkable without standing up a terminal.
    def self.card_h(h : Int32, rows : Int32) : Int32
      {rows + 6, {h - 3, 3}.max}.min
    end

    # The card WIDTH `step_card` settles on for a terminal `w` columns wide and a step
    # wanting `cols`. Pure for the same reason `card_h` is: it's what makes the companion-preview
    # threshold below checkable from a spec that cannot stand up a terminal.
    def self.card_w(w : Int32, cols : Int32) : Int32
      { {w - 4, cols}.min, 34 }.max
    end

    # The column Miss Ring's static preview stands at inside `box`, or nil when the card is
    # too narrow to hold her BESIDE the step's own copy. Same drop `theme_list_w` performs on
    # the theme preview panel, and for the same reason — except that her band is held back out
    # of the text column, so on a narrow card she did not shrink the copy, she shredded it. At
    # the advertised MIN_W the text column came out 19 columns wide and all three lines,
    # including the one sentence that says what the step is asking, rendered as a stub plus an
    # ellipsis. `box.x + 3` is render_companion's `ix`; keep the two in step.
    #
    # What this guarantees is the OPENING LINE, not the whole step: the two supporting lines
    # want 53 and 54 columns, so she reappears (w ≥ 69) a few columns before they stop
    # clipping (w ≥ 75), and across that band widening the terminal costs those two their
    # tails to buy the sprite back. Deliberate — she is the thing the step is asking about,
    # and a step that describes a mascot you cannot see is the worse trade. `theme_list_w`
    # doesn't have this band only because a theme NAME fits either side of its threshold.
    def self.companion_preview_x(box : Rect) : Int32?
      px = box.right - 2 - COMPANION_PREVIEW_W
      px - COMPANION_PREVIEW_GAP - (box.x + 3) >= COMPANION_TEXT_MIN ? px : nil
    end

    enum Step
      Bind       # bind ip/port
      Appearance # theme (named Appearance to avoid clashing with the Theme module)
      Companion  # Miss Ring: on/off + motion (enum members are scoped to Step, so this
      #            does NOT shadow Gori::Tui::Companion — which the wizard never touches anyway)
      Review # recap + finish
    end

    def initialize(@term : Termisu)
      # Held as the base Backend: TermisuBackend is generic over the terminal type.
      @backend = TermisuBackend.new(@term).as(Backend)
      @step = Step::Bind
      # Bind step — staged values prefilled from the PERSISTED global, which is deliberately
      # NOT where a `gori tui -l/-p` override lives (that is `Settings.cli_bind_*`, a
      # process-only layer). Staging the flag here is what used to promote a documented
      # one-run value into the permanent default on finish.
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
      # Companion step — STAGED, like every other choice here, and unlike the theme.
      #
      # The theme previews by mutating the LIVE Theme module and reverting on skip;
      # Settings.theme is untouched until finish. There is no such separation for Miss
      # Ring: `Settings.companion?` IS both the gate Companion#tick reads and the value that gets
      # persisted, and `skip` calls Settings.save (to materialize settings.json) — so
      # previewing her by flipping Settings.companion would persist whatever was live when the
      # user pressed Esc. Hence a STATIC preview drawn straight from the pure Mascot art
      # (render_companion below): no Companion instance, no tick, no gate to bypass, nothing to revert.
      # The wizard doesn't need her to blink; it needs the user to see what they're
      # turning on.
      @companion_enabled = Settings.companion?
      @companion_motion = Settings.companion_motion
      # Review step — offer a guided TUI tour after setup. `@launch_tutorial` is set
      # on finish and read by `run` (below) to launch the tour in this same terminal.
      @offer = :tour # :tour | :skip
      @launch_tutorial = false
      # Review step also stages the command modifier (see Settings.command_modifier): a
      # first-run chance to pick ⌥ before hitting a terminal that eats Ctrl+digit. Kept on
      # ←/→ rather than the ↑/↓ offer ring, so Review needs no focus ring.
      @modifier = Settings.command_modifier
      # Non-nil once a persist attempt has FAILED: drawn in the footer in place of the key
      # hint, and returned by `run` so the caller can put it somewhere that outlives the alt
      # screen. `Settings.save` rescues everything and reports failure as a plain `false`,
      # which both commit paths used to discard — so an unwritable settings.json meant the
      # wizard walked the user through four steps, accepted "finish", and exited 0 having
      # written nothing. Worse on the first-run path, whose auto-launch gate is that file's
      # existence: the wizard then re-opened on every launch with nothing saying why.
      @save_error = nil.as(String?)
    end

    # Run the wizard to completion (finish) or skip. Returns nil, or a one-line reason the
    # settings could not be persisted — reporting that is the caller's job (App#run_tui puts
    # it on the picker, `gori wizard` on STDERR), because this screen is about to be wiped.
    def run : String?
      Theme.load_custom # pick up any user themes dropped under <GORI_HOME>/themes
      @theme_name = Theme.canonical(@theme_name)
      @theme_baseline = Theme.active_name
      @running = true
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          @backend.resize(ev.width, ev.height) # re-fit grids off the event dims (lockstep w/ termisu)
          @resized = true                      # buffer already resized; force a full repaint next frame
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
      # (already in raw mode with enhanced keyboard on). Skip/Esc leaves it false.
      launch_tour if @launch_tutorial
      @save_error
    end

    # Hand this terminal to the guided tour. `gori tutorial` enables the mouse
    # UNCONDITIONALLY — the tour's Prev/Next buttons and its mock clicks are mouse-driven —
    # while both wizard callers gate `enable_mouse` on Settings.mouse. So the same tour had
    # live buttons or dead ones depending on which door the user came through. Borrow the
    # mouse for the tour when the caller left it off, then hand the terminal back exactly as
    # it arrived (the picker and Runner that follow honour Settings.mouse themselves).
    private def launch_tour : Nil
      borrowed = !Settings.mouse
      @term.enable_mouse if borrowed
      begin
        Tutorial.new(@term).run
      ensure
        @term.disable_mouse if borrowed
      end
    end

    # --- input ---------------------------------------------------------------

    private def handle_key(ev : Termisu::Event::Key) : Nil
      @preedit = "" # any committed key ends an in-progress IME composition
      key = ev.key
      if ev.ctrl_c? || key.escape?
        skip # Esc / ^C exits the wizard (revert preview, persist defaults)
        return
      end
      # Below the floor NOTHING but the two keys above is accepted. `fits?` gates rendering, and
      # while it was the only gate the "terminal too small" screen stayed fully navigable: four
      # blind ↵ presses walked Bind → Companion → Review → `finish` and committed a bind/theme/companion the
      # operator never saw a single frame of. A screen that says it cannot draw the choices must
      # not accept them either — resizing brings the wizard back with nothing lost, since every
      # answer is staged in this object.
      return unless fits?(*@backend.size)
      case @step
      when Step::Bind       then handle_bind_key(ev)
      when Step::Appearance then handle_theme_key(ev)
      when Step::Companion  then handle_companion_key(ev)
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
      elsif key.home?
        @cursor = 0
      elsif key.end?
        @cursor = bind_value.size
      elsif key.backspace?
        bind_backspace
      elsif key.delete?
        bind_delete
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
        @step = Step::Companion
      elsif key.back_tab?
        back_to_bind
      elsif key.up? || key.left?
        cycle_theme(-1)
      elsif key.down? || key.right?
        cycle_theme(1)
      end
    end

    # Companion step: ↑/↓ pick the on/off ring; ←/→ flip her motion; ↵/⇥ next; ⇧⇥ back.
    # Same split Review uses (ring on ↑/↓, the secondary choice on ←/→), so this step
    # needs no focus ring either.
    private def handle_companion_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter? || key.tab?
        @step = Step::Review
      elsif key.back_tab?
        @step = Step::Appearance
      elsif key.up? || key.down?
        @companion_enabled = !@companion_enabled
      elsif (key.left? || key.right?) && @companion_enabled
        # Motion is hers; with "No mascot" selected there is nothing to set a motion FOR,
        # and the row is hidden in that state. Accepting the key anyway let a user who
        # declined her still stage a non-default motion, which #finish would then persist —
        # materializing a "companion" section in settings.json for someone who said no. Settings
        # only omits that section while EVERY field is factory-default.
        @companion_motion = @companion_motion == "calm" ? "lively" : "calm"
      end
    end

    # Review step: ↑/↓ pick the tour offer; ←/→ flip the command modifier; ↵ finishes
    # (commit + persist, then launch the tour iff selected); ⇧⇥ back.
    private def handle_review_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter?
        finish
      elsif key.up? || key.down?
        @offer = @offer == :tour ? :skip : :tour
      elsif key.left? || key.right?
        @modifier = @modifier == "alt" ? "ctrl" : "alt"
      elsif key.back_tab?
        @step = Step::Companion
        # The failed-save footer says "↵ retry", and ↵ only retries HERE (elsewhere it
        # advances), so the notice doesn't follow the user off this step. A still-blocked write
        # sets it again on the next ↵, and `skip` reports its own failure independently.
        @save_error = nil
      end
    end

    private def back_to_bind : Nil
      @step = Step::Bind
      @bind_field = :ip
      @cursor = @ip.size
    end

    private def advance_from_bind : Nil
      if Settings.bind_host_error(@ip)
        # Put the caret back on the field the message is about. This is only ever reached from
        # the PORT field — ↵ on the IP field moves focus here first — so "invalid bind IP" was
        # reported with the accent band and the caret both sitting on Bind Port, pointing at a
        # field the user had already been moved off and that was not the one at fault. Typing
        # in the field we land on clears the status (bind_insert), which is the fix the message
        # is asking for.
        switch_bind_field(:ip)
        @status = "invalid bind IP (e.g. 127.0.0.1)"
        return
      end
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

    # Forward-delete (the Del key): drop the character under the caret, caret unmoved.
    # No-op with the caret at end-of-line — complements bind_backspace after caret moves.
    private def bind_delete : Nil
      v = bind_value
      c = @cursor.clamp(0, v.size)
      return if c >= v.size
      set_bind_value("#{v[0, c]}#{v[(c + 1)..]}")
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
    #
    # Every field is snapshotted first so a FAILED write can be rolled back: the wizard has
    # to stay on REVIEW in that case (nowhere else can report it), and while it is there Esc
    # must still mean what it says — "leaves Settings untouched". Without the rollback, a
    # failed finish followed by Esc would have `skip` persist the committed values under the
    # one keystroke that promises not to.
    private def finish : Nil
      prev_host, prev_port = Settings.bind_host, Settings.bind_port
      prev_theme, prev_modifier = Settings.theme, Settings.command_modifier
      prev_companion, prev_motion = Settings.companion?, Settings.companion_motion
      Settings.bind_host = effective_ip
      Settings.bind_port = @port.strip.to_i? || Settings.bind_port
      Settings.theme = @theme_name
      Settings.command_modifier = Settings.normalize_command_modifier(@modifier)
      # Miss Ring — the ONE place the wizard writes her, so Esc can never persist a preview.
      # Motion is written only when she is ON: a user who declined her must not leave a
      # non-default motion behind, which is what keeps a default install's settings.json
      # free of a "companion" section entirely (Settings omits it only while every field is
      # factory-default).
      Settings.companion = @companion_enabled
      Settings.companion_motion = Settings.normalize_companion_motion(@companion_motion) if @companion_enabled
      if Settings.save
        @save_error = nil
        @launch_tutorial = @offer == :tour # `run` launches the tour after the loop
        @running = false
        return
      end
      Settings.bind_host = prev_host
      Settings.bind_port = prev_port
      Settings.theme = prev_theme
      Settings.command_modifier = prev_modifier
      Settings.companion = prev_companion
      Settings.companion_motion = prev_motion
      # Held on REVIEW: the staged choices live on in this object's own fields, so ↵ retries
      # the write once the user has unblocked it (a full disk, a read-only --config path).
      # "esc DISCARD", not "esc leave": Esc runs `skip`, which saves the rolled-back values, so
      # leaving from here throws every answer away. Saying "leave" invited reading it as
      # "dismiss this error" and losing four screens of work to a keystroke that looked inert.
      #
      # This string is FOOTER-ONLY and never reaches a caller: `finish` leaves @running true, so
      # the loop can exit only through a successful finish (which nils it) or `skip` (which
      # overwrites it) — see `run`'s return.
      @save_error = "save failed: could not write #{Settings.path} · ↵ retry · esc discard"
    end

    # Exit without committing: revert the live theme preview to the baseline, leave
    # Settings untouched, but persist once so settings.json exists (the first-run
    # gate depends on the file, not its contents).
    private def skip : Nil
      Theme.apply(@theme_baseline)
      @resized = true
      # Esc means leave, so unlike `finish` a failed write cannot hold the user here — it is
      # reported through `run`'s return instead. It matters even though nothing was staged:
      # the file not appearing is exactly what makes the first-run wizard re-open next launch.
      # Unprefixed: this is the ONE string `run` can return, and each caller frames it for where
      # it lands ("gori: setup wizard: …" on STDERR, "setup wizard: …" on the picker).
      @save_error = Settings.save ? nil : "could not write #{Settings.path}"
      @running = false
    end

    private def effective_ip : String
      ip = @ip.strip
      ip.empty? ? "127.0.0.1" : ip
    end

    # --- mouse ---------------------------------------------------------------

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? || ev.wheel?
      return unless fits?(*@backend.size) # same reason handle_key bails: nothing is on screen to hit
      mx, my = ev.x - 1, ev.y - 1         # termisu mouse coords are 1-based
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
      # The LIST's own columns only. `box.contains?` also covers the live preview panel, the
      # gap beside it and the card's two border columns, and with `mx` otherwise unused a
      # click anywhere on a row silently re-picked the theme sitting at it — including a
      # click on the preview the user had gone there to look at.
      return unless box.x < mx <= box.x + theme_list_w(box)
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

    # The centred step card for `w`×`h`. Only BIND uses the narrow settings-sized card —
    # Appearance needs room for the preview panel beside the list, and Review's Shortcuts
    # row spells out a chord family plus how to change it. Height is content + 6 rows of
    # chrome, clamped to the space between the header and the hint. The ONE source of this
    # geometry — render and the mouse hit-tests share it.
    private def step_card(w : Int32, h : Int32) : Rect
      # Only BIND uses the narrow card. Appearance needs room for the preview panel beside
      # the list, Review's Shortcuts row spells out a chord family, and Companion holds her
      # sprite's band back out of the same interior its copy runs across.
      cols = @step.bind? ? 64 : 84
      cw = SetupWizard.card_w(w, cols)
      avail = {h - 3, 3}.max # rows between the header (y0-1) and the hint (y h-1)
      ch = SetupWizard.card_h(h, content_rows)
      cx = {(w - cw) // 2, 0}.max
      cy = 2 + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    # Columns the theme LIST occupies inside `box`; the rest goes to the preview panel, or
    # back to the list on a card too narrow to hold both. The ONE source of that split —
    # render and the click hit-test share it, so a click can't land on a row the list
    # doesn't own.
    private def theme_list_w(box : Rect) : Int32
      full = box.w - 2
      full >= LIST_MIN + PREVIEW_GAP + PREVIEW_W ? full - PREVIEW_GAP - PREVIEW_W : full
    end

    # Interior content rows a step draws (below the card's top border + 1 pad row).
    # Must be ACCURATE for the fixed-layout steps: MIN_H is derived from the largest of
    # them, and render_* draw at fixed offsets up to `box.y + 2 + this`.
    private def content_rows : Int32
      case @step
      when Step::Bind      then BIND_ROWS
      when Step::Companion then COMPANION_ROWS
      when Step::Review    then REVIEW_ROWS
        # ≥7 so the preview panel (header + 3 status rows) is unclipped whenever the card can
        # actually have the rows it ASKS for, capped so a long theme list scrolls (the list
        # viewport derives from the card height) instead of demanding the whole screen. The
        # floor is a request, not a guarantee: `card_h` clamps to `h - 3`, so at MIN_H the card
        # is 12 rows however many this returns, the list viewport is 6, and the preview's third
        # status row falls to render_theme_preview's own `break`. One mock row, on the shortest
        # terminal the wizard runs on at all — cheaper than the alternative, which is REVIEW
        # (the tallest step, and the only one that can commit) losing terminal sizes to a
        # higher MIN_H.
      else { {Theme.available.size, 7}.max, THEME_VP_MAX }.min # appearance
      end
    end

    # Whether the wizard can draw AT ALL at `w`×`h`. Deliberately step-independent: the
    # fixed-layout steps each need `content_rows` rows below their card's top border + pad
    # (a card height of `content_rows + 3`), and honouring that per step is what let the
    # wizard accept a terminal at BIND and then dead-end at REVIEW. See MIN_H.
    #
    # Also the input gate (handle_key / handle_mouse): a screen that can't draw the choices must
    # not accept them. Width comes entirely from `Layout.usable?` — MIN_W equals its floor, so a
    # separate `w >= MIN_W` conjunct here would never reject anything the first term didn't;
    # MIN_W's job is to be the number in the on-screen message, and the spec pins the two
    # together so the message can't drift from what actually rejects.
    private def fits?(w : Int32, h : Int32) : Bool
      Layout.usable?(w, h) && h >= MIN_H
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      # Below the wizard's floor. Two rows, both inside MIN_W so neither is ellipsized at
      # the narrowest terminal that CAN run it: the size actually needed (a bare "resize and
      # retry" left the user guessing by how much) and the fact that Esc still works — input
      # is live behind this screen, which is the only thing that makes it escapable.
      unless fits?(w, h)
        screen.text(0, 0, "terminal too small for the setup wizard", Theme.red, Theme.bg)
        screen.text(0, 1, "min #{MIN_W}x#{MIN_H} · resize, or esc to skip", Theme.muted, Theme.bg)
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
      when Step::Companion  then render_companion(screen, box)
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
      # Full repaint after a resize or a live theme swap; a diff otherwise. The
      # backend forwards only the cells that changed this frame.
      @backend.flush(sync: @resized)
      @resized = false
    end

    private def render_header(screen : Screen, w : Int32) : Nil
      x = screen.text(2, 0, "gori", Theme.text_bright, Theme.bg, attr: Attribute::Bold)
      screen.text(x + 1, 0, "· setup wizard", Theme.muted, Theme.bg)
      prog = progress_label
      screen.text({w - prog.size - 2, 0}.max, 0, prog, Theme.muted, Theme.bg)
    end

    private def progress_label : String
      case @step
      when Step::Bind       then "step 1 of 3"
      when Step::Appearance then "step 2 of 3"
      when Step::Companion  then "step 3 of 3"
      else                       "review"
      end
    end

    private def card_title : String
      case @step
      when Step::Bind       then "NETWORK · global default"
      when Step::Appearance then "THEME · appearance"
      when Step::Companion  then "COMPANION · Miss Ring"
      else                       "REVIEW"
      end
    end

    private def render_footer(screen : Screen, w : Int32, h : Int32) : Nil
      # A failed write displaces the key hint rather than taking a card row of its own:
      # REVIEW's interior is already exactly `content_rows` tall, so a row there would push
      # MIN_H from 15 to 16 and lock out terminals that can otherwise finish setup.
      if err = @save_error
        # The path is the more useful half when there is room for it; the KEYS are the half
        # that has to survive. `Screen#text` ellipsizes from the RIGHT, and the long form runs
        # ~84 columns for a default `~/.gori` path — more than twice MIN_W — so what it dropped
        # first was precisely the "↵ retry · esc discard" telling the user four screens of
        # answers are still in hand. Keep SAVE_FAILED_SHORT's tail in step with the string
        # `finish` builds; that is the only one that reaches here (`skip`'s never renders,
        # see there).
        err = SAVE_FAILED_SHORT if err.size > w
        screen.text({(w - err.size) // 2, 0}.max, h - 1, err, Theme.red, Theme.bg)
        return
      end
      hints = footer_hints
      hint = hints.find { |s| s.size <= w } || hints.last
      screen.text({(w - hint.size) // 2, 0}.max, h - 1, hint, Theme.muted, Theme.bg)
    end

    # This step's key hints, widest first; `render_footer` takes the first that fits.
    #
    # EVERY entry ends in "esc", because a single string plus right-hand ellipsis meant the
    # exit was the first thing to go: at the advertised MIN_W of 40 the COMPANION hint (53 columns)
    # and the REVIEW one (59) were 13 and 19 over, so the two steps where a user is most
    # likely to want out — REVIEW being the one where `finish` lives — were the two that
    # stopped advertising a way. Same reason the too-small screen spells out esc.
    private def footer_hints : Array(String)
      case @step
      when Step::Bind
        ["↵ next · ↑/↓ field · esc skip", "↵ next · esc skip"]
      when Step::Appearance
        ["↑/↓ pick theme · ↵ next · ⇧⇥ back · esc skip", "↑/↓ theme · ↵ next · esc skip"]
      when Step::Companion
        # ←/→ is only offered while she is on — it does nothing under "No mascot", and the
        # motion row it drives is hidden there too.
        if @companion_enabled
          ["↑/↓ choose · ←/→ motion · ↵ next · ⇧⇥ back · esc skip", "←/→ motion · ↵ next · esc skip"]
        else
          ["↑/↓ choose · ↵ next · ⇧⇥ back · esc skip", "↑/↓ choose · ↵ next · esc skip"]
        end
      else
        ["↑/↓ choose · ←/→ shortcuts · ↵ confirm · ⇧⇥ back · esc skip", "↵ confirm · esc skip"]
      end
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
      list_w = theme_list_w(box)
      two_col = list_w < box.w - 2 # theme_list_w gives the list everything when it can't fit both

      # Scroll-follow over `names`, the list the row loop below walks. (This used to clamp
      # BEFORE following; `Viewport` follows then clamps, which lands on the same offset for
      # every in-range selection — see the ordering example in spec/tui/viewport_spec.cr —
      # and `sel` is always in range here, `names` being non-empty by the guard above.)
      @theme_scroll = Viewport.scroll_to_show(sel, @theme_scroll, vp, names.size)

      list_top = box.y + 2
      vp.times do |row|
        i = @theme_scroll + row
        break if i >= names.size
        draw_theme_row(screen, box, list_w, names[i], i == sel, list_top + row)
      end
      # The shared gauge on the list area's last column — where the per-row ▲/▼/↕ markers used
      # to sit. Same replacement as the Settings theme list, which is a copy of this one.
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, list_top, list_w - 1, vp),
        names.size, @theme_scroll, true, Theme.panel)

      if two_col
        px = box.x + 1 + list_w + PREVIEW_GAP
        render_theme_preview(screen, Rect.new(px, list_top, PREVIEW_W, vp), names[sel])
      end
    end

    private def draw_theme_row(screen : Screen, box : Rect, list_w : Int32, name : String,
                               selected : Bool, ry : Int32) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, list_w, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      # The list area's last column now carries the scroll gauge, so the swatch ends one cell
      # short of it rather than leaving a gap for a per-row marker.
      mark_x = box.x + list_w
      swatch_w = 7
      sx = mark_x - swatch_w
      name_w = {sx - (box.x + 5) - 1, 1}.max
      screen.text(box.x + 5, ry, name, selected ? Theme.text_bright : Theme.text, bg, width: name_w)
      draw_swatch(screen, sx, ry, name)
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

    # Miss Ring: an on/off ring, her motion, and a STATIC sprite of what "on" looks like.
    #
    # The sprite is drawn from Mascot directly — pure art, no Companion, no tick, no
    # Settings.companion? gate (see @companion_enabled). It is the resting :idle frame with no badge
    # and no glint: one honest still of her, rather than an animation the wizard would
    # have to own a clock for.
    private def render_companion(screen : Screen, box : Rect) : Nil
      ix = box.x + 3
      # Hold the sprite's column band back before laying out the text, so a line can never
      # run under her — the same order Tutorial.step_card reserves her band in. But ONLY while
      # she is actually standing there, which is two conditions, not one: she is switched on
      # AND the card is wide enough to hold her beside the copy (self.companion_preview_x). Every
      # consumer of the reservation — the text width here, the accent band below,
      # draw_companion_preview at the end — reads that ONE answer, so the step either lays out
      # around her or takes the card's full interior, never half of each.
      px = @companion_enabled ? SetupWizard.companion_preview_x(box) : nil
      band = px.try { |x| x - COMPANION_PREVIEW_GAP }
      iw = {(band || (box.right - 1)) - ix, 1}.max
      screen.text(ix, box.y + 2, "A mascot in the corner, off unless you want her.",
        Theme.text, Theme.panel, width: iw)
      ry = box.y + 4
      render_offer_row(screen, box, ry, "Show Miss Ring", @companion_enabled, band)
      render_offer_row(screen, box, ry + 1, "No mascot", !@companion_enabled, band)
      # Only while she is on — a motion row under "No mascot" offers a setting for
      # something that isn't there, and its ←/→ hint would advertise a key that (rightly)
      # does nothing in that state.
      screen.text(ix, ry + 3, "Motion   #{companion_motion_recap}", Theme.muted, Theme.panel, width: iw) if @companion_enabled
      # Say the cost out loud: she is the one piece of chrome that repaints while you are
      # at the keyboard, which is why she is opt-in at all.
      screen.text(ix, ry + 4, "She reacts to results, then dozes off after 90s idle.",
        Theme.muted, Theme.panel, width: iw)
      px.try { |x| draw_companion_preview(screen, x, ry) }
    end

    # Her plate is the card's own panel colour, so she sits ON the card rather than in a
    # box of her own — which is how she is actually drawn everywhere else.
    private def draw_companion_preview(screen : Screen, px : Int32, py : Int32) : Nil
      pal = Mascot.palette(:info, Theme.panel)
      frame = Mascot::Frame.new(pose: :idle)
      Mascot::H.times do |i|
        screen.cell(px, py + i, ' ', pal.plate, pal.plate)
        screen.cell(px + 1 + Mascot::W, py + i, ' ', pal.plate, pal.plate)
      end
      Mascot.draw(screen, px + 1, py, frame, pal)
    end

    # Kept short enough to survive the 80-column case: the card is {w - 4, 84}.min, so an
    # 80-column terminal leaves ~59 columns of interior once her band is held back.
    private def companion_motion_recap : String
      if @companion_motion == "calm"
        "calm    (←/→ lively · adds winks and a glint)"
      else
        "lively  (←/→ calm · half the blinks, for SSH)"
      end
    end

    private def render_review(screen : Screen, box : Rect) : Nil
      ix = box.x + 3
      y = box.y + 2
      screen.text(ix, y, "You're all set!", Theme.text_bright, Theme.panel, width: {box.w - 6, 1}.max)
      y += 2
      recap_labels = ["Proxy (global)", "Theme", "Miss Ring", "Shortcuts"]
      vx = ix + recap_labels.max_of(&.size) + 2 # +2 = min visible gap before the value column
      recap(screen, box, ix, vx, y, "Proxy (global)", "#{effective_ip}:#{@port.strip}"); y += 1
      recap(screen, box, ix, vx, y, "Theme", @theme_name); y += 1
      recap(screen, box, ix, vx, y, "Miss Ring", @companion_enabled ? "on · #{@companion_motion}" : "off"); y += 1
      # The only EDITABLE recap row (←/→). Spell out both the chords it moves and the
      # macOS caveat — a user who picks ⌥ without Option-as-Meta would see nothing happen.
      recap(screen, box, ix, vx, y, "Shortcuts", modifier_recap); y += 2
      # No prompt line above the offer: the two rows below say "Take the guided tour" /
      # "Skip — finish setup" in full, so "New to gori? Take a quick tour of the TUI:" was
      # restating them. Dropping it is what keeps the Miss Ring recap row free — adding a
      # fourth recap row otherwise pushed content_rows from 9 to 10, which moved this step's
      # minimum height from 15 rows to 16 and, since REVIEW is the tallest step, MIN_H along
      # with it. That is the worst row to lose: `finish` lives here, so every row added
      # locks another terminal size out of completing setup. Net rows are unchanged.
      render_offer_row(screen, box, y, "Take the guided tour", @offer == :tour); y += 1
      render_offer_row(screen, box, y, "Skip — finish setup", @offer == :skip)
    end

    # The Shortcuts recap value: what's staged, plus how to change it / what it costs.
    private def modifier_recap : String
      if @modifier == "alt"
        "⌥P ⌥N ⌥W ⌥1-9  (←/→ for Ctrl · needs Option-as-Meta)"
      else
        "^P ^N ^W ^1-9  (←/→ to add ⌥ aliases)"
      end
    end

    private def recap(screen : Screen, box : Rect, ix : Int32, vx : Int32, y : Int32, key : String, value : String) : Nil
      screen.text(ix, y, key, Theme.muted, Theme.panel)
      screen.text(vx, y, value, Theme.text_bright, Theme.panel, width: {box.right - vx - 1, 1}.max)
    end

    # A selectable offer row (radio-style), mirroring the theme list's accent band.
    #
    # `band_right` is where the accent band STOPS, defaulting to the card's inner edge.
    # The Companion step passes her sprite's left edge: her plate is the card's panel colour, so
    # a full-width band would run under her and she would read as a panel-coloured hole
    # punched in the selected row rather than as a mascot standing beside it.
    private def render_offer_row(screen : Screen, box : Rect, ry : Int32, label : String,
                                 selected : Bool, band_right : Int32? = nil) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      right = band_right || (box.right - 1)
      screen.fill(Rect.new(box.x + 1, ry, {right - (box.x + 1), 1}.max, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      screen.text(box.x + 5, ry, label, selected ? Theme.text_bright : Theme.text, bg, width: {right - (box.x + 5), 1}.max)
    end
  end
end
