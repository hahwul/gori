require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store/models"

module Gori::Tui
  # The options of a short-circuit rule's answer (#1237), opened from the Rewriter rule form's
  # `options:` row: the map-local prefix and fall-through, a hang's bound, and the delay every
  # source takes. Only the rows the form's current `source:` reads are shown.
  #
  # A SUB-EDITOR like `RewriterStubOverlay`, with the same seam: the rule form is still
  # underneath, so there is nothing to cancel into — esc and click-away both commit, and the
  # injected closure writes the options back onto the form and re-opens it. A number that does
  # not parse is kept as an out-of-range value on purpose, so the form's Save row says what is
  # wrong (`RuleStub.respond_error`) instead of this card silently dropping the keystrokes.
  class RewriterRespondOverlay < Overlay
    ROW_STRIP       = 0
    ROW_FALLTHROUGH = 1
    ROW_HANG        = 2
    ROW_DELAY       = 3

    getter respond : Store::RespondKind
    getter fault : Store::FaultKind?
    @sel : Int32

    def initialize(@respond : Store::RespondKind, @fault : Store::FaultKind?, args : Store::RespondArgs)
      @strip = TextField.new(args.strip_prefix)
      @fallthrough = args.fallthrough?
      @hang = TextField.new(args.hang_ms.to_s)
      @delay = TextField.new(args.delay_ms.to_s)
      @sel = rows.first
    end

    # The rows the source reads, in draw order.
    def rows : Array(Int32)
      if @respond.dir?
        [ROW_STRIP, ROW_FALLTHROUGH, ROW_DELAY]
      elsif @fault == Store::FaultKind::Hang
        [ROW_HANG, ROW_DELAY]
      else
        [ROW_DELAY]
      end
    end

    # The options as edited. Fields the source does not read keep their defaults, so a rule
    # never stores a setting it ignores.
    def args : Store::RespondArgs
      dir = @respond.dir?
      hang = @fault == Store::FaultKind::Hang
      Store::RespondArgs.new(
        dir ? @strip.value.strip : "",
        dir && @fallthrough,
        @fault,
        ms(@delay, 0),
        hang ? ms(@hang, Store::RespondArgs::DEFAULT_HANG_MS) : Store::RespondArgs::DEFAULT_HANG_MS)
    end

    # Blank is the default; anything else that is not a number is -1, which the form's
    # validator reports as out of range rather than this card guessing what was meant.
    private def ms(field : TextField, blank : Int32) : Int32
      s = field.value.strip
      return blank if s.empty?
      s.to_i? || -1
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::RewriterRespond
    end

    def title : String
      "ANSWER OPTIONS"
    end

    def hint : String
      "↑/↓ field · type a value · space toggles · esc saves & closes"
    end

    def text_fields : Array(TextField)
      [@strip, @hang, @delay]
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :commit if key.escape?
      return :stay if step(key)
      list = rows
      i = list.index(@sel) || 0
      if @sel == ROW_FALLTHROUGH
        @fallthrough = !@fallthrough if key.space? || key.enter?
      elsif key.enter?
        return :commit if i == list.size - 1
        @sel = list[i + 1]
      elsif field = field_for(@sel)
        field.handle_edit_key(ev)
      end
      :stay
    end

    # ↑/↓ (and ⇧↹/↹) between the shown rows; true when the key was one of them.
    private def step(key : Termisu::Input::Key) : Bool
      delta = (key.up? || key.back_tab?) ? -1 : ((key.down? || key.tab?) ? 1 : 0)
      return false if delta.zero?
      list = rows
      i = list.index(@sel) || 0
      @sel = list[(i + delta).clamp(0, list.size - 1)]
      true
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :commit if box.nil? || !box.contains?(mx, my)
      i = my - (box.y + 2)
      list = rows
      if 0 <= i < list.size
        @sel = list[i]
        @fallthrough = !@fallthrough if @sel == ROW_FALLTHROUGH
      end
      click_text_field(mx, my)
      :stay
    end

    def set_preedit(text : String) : Nil
      field_for(@sel).try(&.set_preedit(text))
    end

    private def field_for(row : Int32) : TextField?
      case row
      when ROW_STRIP then @strip
      when ROW_HANG  then @hang
      when ROW_DELAY then @delay
      end
    end

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, rows.size + 1)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "answer options need a larger window", closing: "esc saves & closes")
        return
      end
      Frame.card(screen, box, "ANSWER OPTIONS", border: Theme.border_focus)
      first = box.y + 2
      rows.each_with_index do |row, i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, row, py)
      end
      note_y = first + rows.size
      if note_y < box.bottom - 1
        screen.text(box.x + 3, note_y, note, Theme.muted, Theme.panel, width: box.w - 6)
      end
    end

    # What the one setting that is not obvious from its label does.
    private def note : String
      if @respond.dir?
        "a MISSING file may reach the origin; a refused path never does"
      elsif @fault == Store::FaultKind::Hang
        "holds until the client leaves or the bound passes (max #{Store::RespondArgs::MAX_WAIT_MS} ms)"
      else
        "the delay is waited out before any answer (max #{Store::RespondArgs::MAX_WAIT_MS} ms)"
      end
    end

    private def draw_row(screen : Screen, box : Rect, row : Int32, py : Int32) : Nil
      sel = row == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      fg = sel ? Theme.text_bright : Theme.text
      case row
      when ROW_STRIP then draw_field(screen, box, py, bg, fg, sel, "strip prefix:", @strip)
      when ROW_HANG  then draw_field(screen, box, py, bg, fg, sel, "hang ms:", @hang)
      when ROW_DELAY then draw_field(screen, box, py, bg, fg, sel, "delay ms:", @delay)
      else
        x = box.x + 3
        screen.text(x, py, @fallthrough ? "[x]" : "[ ]", @fallthrough ? Theme.green : Theme.muted, bg)
        screen.text(x + 4, py, "fall through to the origin if the file is missing", fg, bg, width: box.w - 9)
      end
    end
  end
end
