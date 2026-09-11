require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../retest"

module Gori::Tui
  # The one expected result a retest step carries (#1036): a one-field card that TEACHES the
  # grammar while it is being typed and says, live, whether what is in the field parses.
  #
  # Not `NamePromptOverlay`, which is the shape this started as. That card's chrome is
  # written for a named library entry — its field is labelled `Name`, and its footer states
  # "an existing name is overwritten", which is simply false here. More importantly an
  # assertion is not a name the operator already knows: `json:data.role=admin` is a grammar
  # they are meeting, and the accepted forms have to be IN FRONT OF THEM while they type,
  # not folded into one truncated hint line.
  #
  # The validation is the other half. `Retest::Assertion.parse` already answers "why not" in
  # a sentence; showing it under the field as it is typed means a bad assertion is corrected
  # here rather than discovered as a step that silently asserts nothing.
  class RetestAssertOverlay < Overlay
    LABEL   = "Expect"
    LABEL_W = 9

    getter title : String
    # What this assertion is about — `variant · GET /orders/7` — so the card says which step
    # is being edited without the operator holding it in their head.
    getter subject : String

    def initialize(@title : String, @subject : String, initial : String)
      @field = TextField.new(initial)
    end

    # The typed text. The open-site re-parses it (this card never writes), so the one place
    # that decides what is stored stays the one place that decides what is legal.
    def value : String
      @field.value.strip
    end

    # nil when the field parses — including when it is EMPTY, which is the legitimate "record
    # the outcome, assert nothing" a login or a cleanup step wants.
    def error : String?
      parsed = Retest::Assertion.parse(value)
      parsed.is_a?(String) ? parsed.lines.first.strip : nil
    end

    # How the card reads back what it will store, once it parses — `status 403`, `data.role =
    # admin`. It is the same `describe` the result table's "expected" column prints, so the
    # operator sees the sentence their step will carry before they commit it.
    def preview : String?
      parsed = Retest::Assertion.parse(value)
      return nil if parsed.is_a?(String)
      parsed.none? ? "no assertion — the outcome is recorded and nothing is asserted" : parsed.describe
    end

    # --- Overlay contract (see overlay.cr) -----------------------------------

    def key : OverlayKind
      OverlayKind::RetestAssert
    end

    def text_fields : Array(TextField)
      [@field]
    end

    def hint : String
      "↵ save · esc cancel · empty = record the outcome only"
    end

    # ↵ commits whatever is typed; the open-site refuses an unparseable one and keeps the
    # card up (`on_commit` returning false), which is why the error line here is a warning
    # and not a gate: a field that could not be left would strand an operator who typed a
    # `$` they now want to delete.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      return :cancel if ev.key.escape?
      return :commit if ev.key.enter?
      @field.handle_edit_key(ev)
      :stay
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # --- rendering -----------------------------------------------------------

    # Two chrome rows above the field (title border + subject), the field, one status row,
    # then the FORMS block and the hint.
    def overlay_box(area : Rect) : Rect?
      h = {area.h - 2, Retest::Assertion::FORMS.size + 9}.min
      w = {area.w - 4, 80}.min
      return nil if w < 44 || h < 9
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "the expected-result card needs a larger window")
        return
      end
      Frame.card(screen, box, @title, bg: Theme.bg, border: Theme.border_focus)
      iw = {box.w - 4, 1}.max
      screen.text(box.x + 2, box.y + 1, oneline(@subject), Theme.muted, Theme.bg, width: iw)

      y = box.y + 3
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      screen.text(box.x + 2, y, LABEL, Theme.text_bright, Theme.accent_bg)
      vx = box.x + 2 + LABEL_W
      @field.render(screen, vx, y, {box.right - 2 - vx, 1}.max, true, Theme.text_bright, Theme.accent_bg)

      # Live: the refusal, or what the stored assertion will mean. One row either way, so the
      # FORMS block below never shifts under the operator as they type.
      if err = error
        screen.text(box.x + 2, y + 1, "⚠ #{err}", Theme.red, Theme.bg, width: iw)
      elsif shown = preview
        screen.text(box.x + 2, y + 1, "→ #{shown}", Theme.green, Theme.bg, width: iw)
      end

      Frame.tee_divider(screen, box, y + 2)
      # `bottom - 2`: `Rect#bottom` is one PAST the last row, so `bottom - 1` is the card's own
      # bottom border. The forms stop one row above the hint that sits there.
      hint_row = box.bottom - 2
      Retest::Assertion::FORMS.each_with_index do |form, i|
        row = y + 3 + i
        break if row >= hint_row
        screen.text(box.x + 2, row, form, Theme.muted, Theme.bg, width: iw)
      end
      screen.text(box.x + 2, hint_row, hint, Theme.muted, Theme.bg, width: iw)
    end

    private def oneline(s : String) : String
      s.gsub(/[\r\n\t]+/, " ")
    end
  end
end
