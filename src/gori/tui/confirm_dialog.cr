require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./note_detail_overlay"
require "./viewport"

module Gori::Tui
  # A centered yes/no confirmation modal for destructive actions — deleting a
  # project, closing a Repeater/Notes sub-tab. Selection defaults to Cancel — the safe
  # choice — so a reflexive ↵ never destroys anything; the operator must move to (or
  # press `y` for) the danger button on purpose.
  #
  # The archetype the Overlay seam was modelled on: WHAT a confirmation does is injected
  # as the `on_commit` closure at the open-site (Runner#confirm), so the dialog itself
  # only knows which button is lit. `on_close` (Overlay) carries the other half the Runner
  # used to hold in `@confirm_return`: a confirm raised from inside another modal lands
  # back in it, on cancel and on accept alike.
  #
  # ALSO used outside the Runner, by ProjectPicker, which drives it as a plain state +
  # rendering object through its own `:confirm` mode and ignores the Overlay hooks.
  class ConfirmDialog < Overlay
    # The card's own ceiling, and the inset `render` leaves on either side of a message line
    # (3 columns each). Named because `display_lines` has to know the drawable width BEFORE
    # `overlay_box` can size the card to it.
    MAX_WIDTH  = 60
    TEXT_INSET =  6

    # Rows the card spends on itself around the message: the two borders, a blank under the
    # heading, a blank over the buttons, the button row, and a blank under it.
    CHROME_H = 6

    # …and the fewest it can be drawn in at all: the top border (which carries the heading),
    # the button row at `bottom - 3`, and the bottom border. Under this there is nowhere to put
    # the buttons that is not a border, so `render` declines and `handle_key` refuses to
    # commit — see `@drawn`.
    MIN_H = 4

    # The card's heading (`DELETE ISSUE`), NOT the shell's focus badge — that is `title`
    # below, which is the constant "CONFIRM" for every confirmation.
    getter heading : String
    getter message : String

    # `alt_label` adds a THIRD button between the two, pressed with `c`: the hidden-marks
    # card (`HistoryController#hidden_marks_card?`) answers "the marks" with `y` and "only
    # the cursor row" with it. nil, the default, is the two-button card every other confirm
    # draws, byte for byte.
    getter alt_label : String?

    def initialize(@heading : String, @message : String, *,
                   @confirm_label : String = "confirm", @cancel_label : String = "cancel",
                   @danger : Bool = true, @alt_label : String? = nil)
      # The safe default for a DANGER card is the cancel button — ↵ under "DELETE 40 FLOWS?"
      # must not delete. A card that asks something recoverable ("open in Repeater?", "run
      # the fuzz?", "save the results?") lights its own verb instead: eleven such cards said
      # `open`/`run`/`save` on the button and answered ↵ with "no", so the hand that had
      # learnt ↵ = go had to learn `y` for these alone.
      @selected = @danger ? :cancel : :confirm
      # Did the last frame actually put this card on screen? A terminal too short for even
      # `MIN_H` gets no card at all, and the only cue left is the shell's `CONFIRM` focus badge
      # — which names no action, no target and no consequence. ProjectPicker already refuses
      # to ARM a delete it cannot draw ("a delete you cannot read is a delete you cannot have
      # confirmed"); this is the same rule one step later, where a RESIZE after arming can also
      # reach it, and it covers every confirm the Runner raises rather than that one open site.
      #
      # "The last frame did not REFUSE to draw me" — not "a frame has run". The shell draws
      # before it reads a key, so this is never stale there; starting it false instead would
      # make every non-rendering driver (the spec harness, ProjectPicker's own ladder) unable
      # to answer a card that is in fact on screen.
      @drawn = true
      @scroll = 0
      @scroll_max = 0
      @message_room = 1
      @can_confirm = true
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Confirm
    end

    def title : String
      "CONFIRM"
    end

    # Spelled from the buttons, so what ↵ will do is readable before it is pressed, and `y`
    # names the verb it stands for rather than a generic "confirm" the button never says.
    def hint : String
      lit = case @selected
            when :confirm then @confirm_label
            when :alt     then @alt_label || @cancel_label
            else               @cancel_label
            end
      return "make window taller to read · n/esc cancel" if @message_room == 0
      scroll = @scroll_max > 0 ? "↑/↓ scroll · " : ""
      return "#{scroll}read to the end · n/esc cancel" unless @can_confirm
      alt = (a = @alt_label) ? " · #{ALT_KEY} #{a}" : ""
      "#{scroll}←/→ choose · ↵ #{lit} · #{CONFIRM_KEY} #{@confirm_label}#{alt} · #{CANCEL_KEY}/esc #{@cancel_label}"
    end

    # ←/→ or Tab move between the buttons; `y` confirms, `n`/esc cancels, ↵ acts on the
    # selection (which defaults to cancel). EVERY other key is swallowed so nothing leaks
    # to the view behind the card.
    #
    # `y` is guarded on ctrl/alt because `key.y?` is termisu's CASE-INSENSITIVE macro: it
    # compares the key enum alone and knows nothing about modifiers, so an unguarded branch
    # reads every `^Y` as the destructive answer to a card whose hint only ever advertises a
    # bare `y`. `^Y` is a live chord — it is now COPY in every text box, which makes this guard
    # load-bearing on a hotter path than before: the marker-removal confirm pops up inside the
    # request editor, exactly where an operator reaches for `^Y` to copy. (It was
    # repeater.attach-chain when this guard was written; that verb has since moved to `^Q`, and
    # the guard outlived the specific chord because the RULE is about modifiers, not about which
    # verb owns them.) Shift is deliberately NOT guarded — `key.y?` matches
    # UpperY on purpose, and a shifted/caps-locked `Y` is the advertised mnemonic. `n`/esc
    # stay unguarded too: a modified key that CANCELS costs one keystroke, one that COMMITS
    # destroys data, so the strictness is spent only where the harm is.
    #
    # Extracted as a class method because ProjectPicker drives this card as a plain state
    # object through its own key ladder (`handle_confirm`) and never reaches `handle_key` —
    # so the rule lived in two places and only one of them got the guard, leaving `^Y` wired
    # to `rm_rf` on a project. One predicate, both call sites: the next answer key that needs
    # a rule cannot land in one ladder and miss the other.
    def self.affirmative?(ev : Termisu::Event::Key) : Bool
      ev.key.y? && !ev.ctrl? && !ev.alt?
    end

    # The third button's key, guarded on ctrl/alt for the reason `affirmative?` is — and here
    # the chord it must not read is `^C`, which a modal card receives instead of the quit
    # handler (`Runner.quit_chord_claimed?`). An operator reaching for quit over the card must
    # not be told they chose the cursor row.
    def alt_pressed?(ev : Termisu::Event::Key) : Bool
      !@alt_label.nil? && ev.key.c? && !ev.ctrl? && !ev.alt?
    end

    # A pasted `y` is not an answer, and a pasted esc/`n` is not a refusal either: the card
    # ignores the whole paste and waits for a key that was pressed at it.
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      false
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?, key.n? then :cancel
      when ConfirmDialog.affirmative?(ev)
        # An answer to a question nobody could read is not an answer. `n`/esc stay open to a
        # window this short — cancelling costs a keystroke, committing costs the data.
        answer(:confirm)
      when alt_pressed?(ev)
        answer(:alt)
      when key.up?
        handle_wheel(-1)
        :stay
      when key.down?
        handle_wheel(1)
        :stay
      when key.left?, key.back_tab?
        move(-1)
        :stay
      when key.right?, key.tab?
        move(1)
        :stay
      when key.enter?
        return :cancel if @selected == :cancel || !@drawn
        @can_confirm ? :commit : :stay
      else :stay
      end
    end

    # A key or click that names its button commits THAT button, whatever is lit: the
    # selection is set first, so `alt_selected?` read by the commit closure says which answer
    # was given. Refused (stay) on a card that is not drawn or not read to the end.
    private def answer(button : Symbol) : Symbol
      return :stay unless @drawn && @can_confirm
      @selected = button
      :commit
    end

    # A click on a button acts; a click outside the card dismisses. A click inside the
    # card but off both buttons keeps it open — a destructive action needs the button.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel unless box.contains?(mx, my)
      case button_at(box, mx, my)
      when :confirm then answer(:confirm)
      when :alt     then answer(:alt)
      when :cancel  then :cancel
      else               :stay
      end
    end

    # The wheel scrolls disclosure, never the selected destructive button.
    def handle_wheel(step : Int32) : Nil
      @scroll = (@scroll + step).clamp(0, @scroll_max)
    end

    # Step between the buttons (←/→ or Tab). With only two choices the direction is
    # irrelevant — any move flips the selection; with the third button it walks
    # confirm → alt → cancel in drawn order, wrapping.
    def move(dir : Int32 = 1) : Nil
      order = @alt_label ? [:confirm, :alt, :cancel] : [:confirm, :cancel]
      i = order.index(@selected) || 0
      @selected = order[(i + (dir < 0 ? -1 : 1)) % order.size]
    end

    def confirm_selected? : Bool
      @selected == :confirm
    end

    # The third button is lit — read by the commit closure after a `c`, a click on it, or ↵
    # over it (see `answer`).
    def alt_selected? : Bool
      @selected == :alt
    end

    # Whether every wrapped message line can be read in `area` without the compact-card
    # fallback folding the tail into an ellipsized row. A few decisions (project archives,
    # for example) must show their full disclosure before the operator can continue.
    def message_fits?(area : Rect) : Bool
      box = overlay_box(area)
      return false if box.empty?
      display_lines(area).size <= message_room(box)
    end

    # Centered card over `area` (the body rect). The card sizes to the widest of
    # message / title / button row.
    def render(screen : Screen, area : Rect) : Nil
      @drawn = false
      @can_confirm = false
      @message_room = 0
      box = overlay_box(area)
      return if box.empty?
      @drawn = true
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      lines = display_lines(area)
      @message_room = message_room(box)
      @scroll_max = {lines.size - @message_room, 0}.max
      @scroll = Viewport.clamp_scroll(@scroll, @message_room, lines.size)
      @can_confirm = @message_room > 0 && @scroll == @scroll_max
      lines.skip(@scroll).first(@message_room).each_with_index do |line, i|
        screen.text(box.x + 3, box.y + 2 + i, line, Theme.text, Theme.panel, width: box.w - 6)
      end
      render_buttons(screen, box)
    end

    # Inverts render's centering math: the centered card rect for `area`. Pure;
    # IDENTICAL sizing to render (caller guards on area.w/area.h being too small).
    def overlay_box(area : Rect) : Rect
      # Empty when render would decline to draw (same guard as render): a click then
      # falls through dismiss_zone?/!contains? and closes instead of acting on a
      # phantom box (e.g. firing the destructive button on an undrawn modal).
      return Rect.new(area.x, area.y, 0, 0) if area.w < 18
      w_max = {area.w - 2, MAX_WIDTH}.min
      extra = extra_button_rows(w_max)
      return Rect.new(area.x, area.y, 0, 0) if area.h < MIN_H + extra
      lines = display_lines(area)
      content = {longest(lines), Screen.draw_width(@heading) + 2, button_row_width(buttons)}.max
      # The roomy height, capped by what there IS. The card used to demand its full height and
      # draw nothing at all below it — on an 80×12 terminal (body 6 rows) `⇧X Clear history`
      # armed a modal that showed no heading, no count and no warning, and `y` still wiped the
      # project's whole History. Short cards scroll the disclosure instead.
      h = {lines.size + CHROME_H + extra, area.h}.min
      w = (content + TEXT_INSET).clamp(16, w_max)
      area.center(w, h)
    end

    # The message as it will actually be DRAWN: split on '\n', then WRAPPED to the widest
    # line this card can hold.
    #
    # `render` used to hand each `\n`-delimited line straight to `Screen#text`, which CLIPS at
    # `box.w - 6` and appends '…'. The card caps at 60 columns, so any message line past 54
    # lost its tail — and a confirmation's tail is where the consequence lives. All three of
    # #897's two-line messages ran past it, and each lost exactly the clause that said what
    # would happen: `CLOSE FUZZER` drew "Its template/config, private temporary spool, and
    # eve…" and dropped "ry saved run are deleted." — the only warning an operator gets that
    # `^W` destroys every run ⇧E promoted into the project.
    #
    # Wrapping HERE and not at each call site is the point: a hand-wrapped sentence is correct
    # until someone edits it, and this is the third message to acquire the same bug. `render`
    # and `overlay_box` share this one definition, so the card's height still matches what is
    # drawn into it — the invariant `overlay_box`'s doc already claims.
    private def display_lines(area : Rect) : Array(String)
      NoteDetailOverlay.wrap_text(@message, {area.w - 2, MAX_WIDTH}.min - TEXT_INSET)
    end

    private def longest(lines : Array(String)) : Int32
      lines.max_of { |l| Screen.display_width(l) }
    end

    # The keys that press the buttons — the same two `handle_key` answers to and `hint` names.
    CONFIRM_KEY = 'y'
    CANCEL_KEY  = 'n'
    ALT_KEY     = 'c'

    # A button wears its accelerator: `[y] open`, `[n] stay`. The two words alone were not the
    # keys that press them — an operator reading `open` / `stay` reaches for `o` and `s`, and
    # both do nothing — and on the one card raised UNDER a fresh toast (ISSUE CREATED) the hint
    # line that would have said so was not on screen for the frame the decision is made on.
    def self.button_text(label : String, key : Char) : String
      "[#{key}] #{label}"
    end

    BUTTON_GAP = 4

    private def buttons : Array({Symbol, String})
      labels = [{:confirm, ConfirmDialog.button_text(@confirm_label, CONFIRM_KEY)}]
      if alt = @alt_label
        labels << {:alt, ConfirmDialog.button_text(alt, ALT_KEY)}
      end
      labels << {:cancel, ConfirmDialog.button_text(@cancel_label, CANCEL_KEY)}
    end

    private def button_row_width(labels : Array({Symbol, String})) : Int32
      labels.sum { |(_, text)| btn_width(text) } + BUTTON_GAP * (labels.size - 1)
    end

    private def btn_width(label : String) : Int32
      Screen.draw_width(label) + 2
    end

    # Keep the full choice labels on narrow terminals by giving each its own row.
    # The message loses only the rows the buttons need and stays scrollable.
    private def extra_button_rows(width : Int32, labels = buttons) : Int32
      button_row_width(labels) > width - 2 ? labels.size - 1 : 0
    end

    private def message_room(box : Rect) : Int32
      {box.h - (CHROME_H - 1) - extra_button_rows(box.w), 0}.max
    end

    # Rendering and hit testing share the same bounded button rectangles.
    private def button_layout(box : Rect) : Array({Symbol, String, Rect})
      return [] of {Symbol, String, Rect} if box.empty?
      labels = buttons
      extra = extra_button_rows(box.w, labels)
      y = box.bottom - 3 - extra
      x = box.x + (box.w - button_row_width(labels)) // 2
      labels.map do |(action, text)|
        width = {btn_width(text), box.w - 2}.min
        if extra > 0
          rect = Rect.new(box.x + (box.w - width) // 2, y, width, 1)
          y += 1
        else
          rect = Rect.new(x, y, width, 1)
          x += width + BUTTON_GAP
        end
        {action, text, rect}
      end
    end

    def button_rects(box : Rect) : {Rect, Rect}
      layout = button_layout(box)
      empty = Rect.new(box.x, box.y, 0, 0)
      {layout.first?.try(&.[2]) || empty, layout.last?.try(&.[2]) || empty}
    end

    def alt_rect(box : Rect) : Rect?
      button_layout(box).find { |(action, _, _)| action == :alt }.try(&.[2])
    end

    def button_at(box : Rect, mx : Int32, my : Int32) : Symbol?
      button_layout(box).find { |(_, _, rect)| rect.contains?(mx, my) }.try(&.[0])
    end

    private def render_buttons(screen : Screen, box : Rect) : Nil
      button_layout(box).each do |(action, label, rect)|
        render_button(screen, rect, label, @selected == action, @danger && action == :confirm)
      end
    end

    private def render_button(screen : Screen, rect : Rect, label : String,
                              selected : Bool, danger : Bool) : Nil
      text = " #{label} "
      if selected
        bg = danger ? Theme.red : Theme.accent_bg
        screen.fill(rect, bg)
        screen.text(rect.x, rect.y, text, Theme.text_bright, bg, attr: Attribute::Bold, width: rect.w)
      else
        screen.text(rect.x, rect.y, text, danger ? Theme.red : Theme.muted, Theme.panel, width: rect.w)
      end
    end
  end
end
