require "./screen"
require "./theme"
require "./frame"
require "./overlay"

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
    # commit — see `drawn?`.
    MIN_H = 4

    # The card's heading (`DELETE ISSUE`), NOT the shell's focus badge — that is `title`
    # below, which is the constant "CONFIRM" for every confirmation.
    getter heading : String
    getter message : String

    def initialize(@heading : String, @message : String, *,
                   @confirm_label : String = "confirm", @cancel_label : String = "cancel",
                   @danger : Bool = true)
      @selected = :cancel # safe default
      # "The last frame did not REFUSE to draw me" — not "a frame has run". The shell draws
      # before it reads a key, so this is never stale there; starting it false instead would
      # make every non-rendering driver (the spec harness, ProjectPicker's own ladder) unable
      # to answer a card that is in fact on screen.
      @drawn = true
    end

    # Did the last frame actually put this card on screen? A terminal too short for even
    # `MIN_H` gets no card at all, and the only cue left is the shell's `CONFIRM` focus badge —
    # which names no action, no target and no consequence. ProjectPicker already refuses to ARM
    # a delete it cannot draw ("a delete you cannot read is a delete you cannot have
    # confirmed"); this is the same rule one step later, where a RESIZE after arming can also
    # reach it, and it covers every confirm the Runner raises rather than that one open site.
    def drawn? : Bool
      @drawn
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Confirm
    end

    def title : String
      "CONFIRM"
    end

    def hint : String
      "←/→ choose · y confirm · n/esc cancel · ↵ select"
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

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?, key.n? then :cancel
      when ConfirmDialog.affirmative?(ev)
        # An answer to a question nobody could read is not an answer. `n`/esc stay open to a
        # window this short — cancelling costs a keystroke, committing costs the data.
        @drawn ? :commit : :stay
      when key.left?, key.right?, key.tab?, key.back_tab?
        move
        :stay
      when key.enter? then confirm_selected? && @drawn ? :commit : :cancel
      else                 :stay
      end
    end

    # A click on a button acts; a click outside the card dismisses. A click inside the
    # card but off both buttons keeps it open — a destructive action needs the button.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel unless box.contains?(mx, my)
      case button_at(box, mx, my)
      when :confirm then :commit
      when :cancel  then :cancel
      else               :stay
      end
    end

    # Inert on purpose. The base default routes a wheel notch to `move`, which here FLIPS
    # the lit button — a stray scroll must never re-aim a destructive choice onto it. The
    # pre-seam shell had no wheel arm for :confirm either.
    def handle_wheel(step : Int32) : Nil
    end

    # Toggle between the two buttons (←/→ or Tab). With only two choices the
    # direction is irrelevant — any move flips the selection.
    def move(_dir : Int32 = 1) : Nil
      @selected = @selected == :confirm ? :cancel : :confirm
    end

    def select_confirm : Nil
      @selected = :confirm
    end

    def select_cancel : Nil
      @selected = :cancel
    end

    def confirm_selected? : Bool
      @selected == :confirm
    end

    # Centered card over `area` (the body rect). The card sizes to the widest of
    # message / title / button row.
    def render(screen : Screen, area : Rect) : Nil
      @drawn = false
      box = overlay_box(area)
      return if box.empty?
      @drawn = true
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      fitted_lines(display_lines(area), box).each_with_index do |line, i|
        screen.text(box.x + 3, box.y + 2 + i, line, Theme.text, Theme.panel, width: box.w - 6)
      end
      render_buttons(screen, box)
    end

    # The message rows this box can actually hold, and what goes in them. A card that fits
    # spends `CHROME_H` and draws every line; a shorter one spends the blank above the buttons
    # first and then CLIPS — the tail of the message is folded into the last visible row so
    # `Screen#text` ellipsises it, because "there is more of this sentence" is exactly what the
    # operator has to know before answering. Refusing to draw at all (what this did) left a
    # destructive modal holding every key with nothing on screen naming it.
    private def fitted_lines(lines : Array(String), box : Rect) : Array(String)
      room = {box.h - (CHROME_H - 1), 0}.max
      return lines if lines.size <= room
      return [] of String if room == 0
      lines[0, room - 1] + [lines[(room - 1)..].join(' ')]
    end

    # Inverts render's centering math: the centered card rect for `area`. Pure;
    # IDENTICAL sizing to render (caller guards on area.w/area.h being too small).
    def overlay_box(area : Rect) : Rect
      # Empty when render would decline to draw (same guard as render): a click then
      # falls through dismiss_zone?/!contains? and closes instead of acting on a
      # phantom box (e.g. firing the destructive button on an undrawn modal).
      return Rect.new(area.x, area.y, 0, 0) if area.w < 18 || area.h < MIN_H
      lines = display_lines(area)
      content = {longest(lines), @heading.size + 2, button_row_width}.max
      # The roomy height, capped by what there IS. The card used to demand its full height and
      # draw nothing at all below it — on an 80×12 terminal (body 6 rows) `⇧X Clear history`
      # armed a modal that showed no heading, no count and no warning, and `y` still wiped the
      # project's whole History. It degrades instead; `fitted_lines` spends the shortfall.
      h = {lines.size + CHROME_H, area.h}.min
      w = (content + TEXT_INSET).clamp(16, {area.w - 2, MAX_WIDTH}.min)
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
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
    # `^W` destroys every run ⇧S promoted into the project.
    #
    # Wrapping HERE and not at each call site is the point: a hand-wrapped sentence is correct
    # until someone edits it, and this is the third message to acquire the same bug. `render`
    # and `overlay_box` share this one definition, so the card's height still matches what is
    # drawn into it — the invariant `overlay_box`'s doc already claims.
    private def display_lines(area : Rect) : Array(String)
      width = {area.w - 2, MAX_WIDTH}.min - TEXT_INSET
      lines = [] of String
      @message.split('\n') { |line| wrap_line(line, width, lines) }
      lines
    end

    # Greedy word wrap measured in terminal COLUMNS, not characters, so a CJK message wraps
    # where it is drawn rather than where its character count happens to land.
    private def wrap_line(line : String, width : Int32, into : Array(String)) : Nil
      if width <= 0 || Screen.display_width(line) <= width
        into << line
        return
      end
      current = [] of String
      current_w = 0
      line.split(' ') do |word|
        parts = hard_split(word, width)
        parts.each_with_index do |part, i|
          pw = Screen.display_width(part)
          if current.empty?
            current << part
            current_w = pw
          elsif current_w + 1 + pw <= width
            current << part
            current_w += 1 + pw
          else
            into << current.join(' ')
            current = [part]
            current_w = pw
          end
          # A hard-split chunk fills the line by construction; its remainder starts the next.
          next if i == parts.size - 1
          into << current.join(' ')
          current = [] of String
          current_w = 0
        end
      end
      into << current.join(' ') unless current.empty?
    end

    # One word wider than the whole line, cut at grapheme-cluster starts. Cut rather than
    # clipped: an over-long token is usually a URL, a project name or a payload, and its tail
    # is the half that identifies it. `Screen.column_for` floors to a cluster start, so a wide
    # glyph is never split down the middle; the `{cut, 1}.max` keeps a single glyph wider than
    # the budget from looping forever.
    private def hard_split(word : String, width : Int32) : Array(String)
      return [word] if Screen.display_width(word) <= width
      parts = [] of String
      rest = word
      while Screen.display_width(rest) > width
        cut = {Screen.column_for(rest, width), 1}.max
        parts << rest[0, cut]
        rest = rest[cut..]
      end
      parts << rest unless rest.empty?
      parts
    end

    private def longest(lines : Array(String)) : Int32
      lines.max_of { |l| Screen.display_width(l) }
    end

    private def button_row_width : Int32
      btn_width(@confirm_label) + 4 + btn_width(@cancel_label)
    end

    private def btn_width(label : String) : Int32
      label.size + 2
    end

    private def render_buttons(screen : Screen, box : Rect) : Nil
      confirm_rect, cancel_rect = button_rects(box)
      render_button(screen, confirm_rect.x, confirm_rect.y, @confirm_label, @selected == :confirm, @danger)
      render_button(screen, cancel_rect.x, cancel_rect.y, @cancel_label, @selected == :cancel, false)
    end

    # Inverts render_buttons' x/y placement: the {confirm, cancel} button rects
    # in `box`. Shared by render and button_at so the click target = the drawn
    # button. Each button is " label " wide; a 4-cell gap sits between them.
    def button_rects(box : Rect) : {Rect, Rect}
      x = box.x + (box.w - button_row_width) // 2
      y = box.bottom - 3
      confirm = Rect.new(x, y, btn_width(@confirm_label), 1)
      cancel = Rect.new(confirm.right + 4, y, btn_width(@cancel_label), 1)
      {confirm, cancel}
    end

    # Maps a click to :confirm/:cancel when it lands on that button, else nil
    # (gaps between/around buttons return nil).
    def button_at(box : Rect, mx : Int32, my : Int32) : Symbol?
      confirm_rect, cancel_rect = button_rects(box)
      return :confirm if confirm_rect.contains?(mx, my)
      return :cancel if cancel_rect.contains?(mx, my)
      nil
    end

    # Draws ` label ` at (x, y); selected fills a band (RED for the danger button,
    # accent otherwise), at rest the danger label stays red text. Returns the x
    # just past the button so the next one can be placed.
    private def render_button(screen : Screen, x : Int32, y : Int32, label : String,
                              selected : Bool, danger : Bool) : Int32
      text = " #{label} "
      if selected
        bg = danger ? Theme.red : Theme.accent_bg
        screen.fill(Rect.new(x, y, text.size, 1), bg)
        screen.text(x, y, text, Theme.text_bright, bg, attr: Attribute::Bold)
      else
        screen.text(x, y, text, danger ? Theme.red : Theme.muted, Theme.panel)
      end
      x + text.size
    end
  end
end
