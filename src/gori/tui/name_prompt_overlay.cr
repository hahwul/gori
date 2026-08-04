require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"

module Gori::Tui
  # "Save this under a name" — a centered one-field card, shared by every workbench that
  # keeps a named GLOBAL library: the Decoder's chain specs and the Rewriter's rule presets
  # today (see LibraryPicker for the reading half).
  #
  # It replaces per-tab inline mini-prompts. The Decoder's lived on a single row inside the
  # OUTPUT pane and opened EMPTY, so saving meant retyping a name the operator had already
  # given the sub-tab, and there was no room to say what was about to be written or where.
  # Seeded (`initial`) plus a `subject` line, the card answers both before ↵. Same reasoning
  # ImportOverlay records for moving OFF the status row.
  #
  # A dumb form object on the Overlay seam: the save itself is the injected `on_commit`,
  # which reads `name`. Blank is allowed THROUGH — the open-site owns the "a name is
  # required" message, because only it knows what is being named.
  class NamePromptOverlay < Overlay
    getter title : String
    getter subject : String # one dim line describing what gets saved (a chain spec, a rule summary)
    getter action : String  # the ↵ verb, so the card hint and the shell's bottom row agree

    def initialize(@title : String, @subject : String, initial : String, @action : String = "save")
      @field = TextField.new(initial)
    end

    def name : String
      @field.value.strip
    end

    # --- Overlay contract (see overlay.cr) -----------------------------------
    def key : OverlayKind
      OverlayKind::NamePrompt
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      [@field]
    end

    def hint : String
      "type a name · ↵ #{@action} · esc cancel"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :commit if key.enter?
      @field.handle_edit_key(ev)
      :stay
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 7 # value column offset ("Name" + padding)

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 72}.min
      h = {area.h - 4, 9}.min
      return nil if w < 34 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "name prompt needs a larger window · esc to close",
          Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, bg: Theme.bg, border: Theme.border_focus)
      iw = {box.w - 4, 1}.max
      # What is being saved, collapsed to one row — a chain spec or a rule summary can be
      # long and multi-line, and the card is a naming prompt, not a preview pane.
      screen.text(box.x + 2, box.y + 1, oneline(@subject), Theme.muted, Theme.bg, width: iw)

      y = box.y + 3
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      screen.text(box.x + 2, y, "Name", Theme.text_bright, Theme.accent_bg)
      vx = box.x + 2 + LABEL_W
      @field.render(screen, vx, y, {box.right - 2 - vx, 1}.max, true, Theme.text_bright, Theme.accent_bg)

      # Spelled out rather than left to the shell row alone: overwriting a same-named entry
      # is silent, and this is the only place it is stated before it happens.
      screen.text(box.x + 2, box.bottom - 2,
        "#{hint} · an existing name is overwritten", Theme.muted, Theme.bg, width: iw)
    end

    private def oneline(s : String) : String
      s.gsub(/[\r\n\t]+/, " ")
    end
  end
end
