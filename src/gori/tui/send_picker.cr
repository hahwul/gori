require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./send_menu"
require "./picker_overlay"

module Gori::Tui
  # A small centered picker for the "send selection to X" action (space → S): pick a
  # string-handling destination for the current text selection. Structurally a twin
  # of CopyPicker, but every row shares ONE `@payload` (the selection) and differs
  # only by destination — so rows show the target's `hint` (not a per-row byte size),
  # and the card title carries the payload size once. Rows are fronted by a mnemonic key.
  #
  # PROMPT-TIER on the Overlay seam, exactly like CopyPicker: the send is the injected
  # `on_commit` (Runner#send_to_open), but the Runner keeps it out of @active_overlay so
  # it floats over @overlay instead of replacing it.
  class SendPicker < PlainPickerOverlay
    getter payload : String

    def initialize(@card_label : String, @payload : String, @destinations : Array(SendMenu::Destination))
    end

    def entry_count : Int32
      @destinations.size
    end

    def selected_destination : SendMenu::Destination?
      @destinations[@selected]?
    end

    # The row whose mnemonic matches `c` (case-insensitive), or nil for a miss.
    def index_for(c : Char) : Int32?
      lc = c.downcase
      @destinations.index { |d| d.key.downcase == lc }
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::SendTo
    end

    # The focus badge. Deliberately NOT the card's own label ("Send selection to · 128 B"),
    # which is a sentence, not a region name.
    def title : String
      "SEND TO"
    end

    def hint : String
      "↑/↓ select · ↵ send · key picks · esc cancel"
    end

    # ↑/↓ move, ↵ or a row mnemonic sends, esc cancels. No j/k vim fallback: destination
    # mnemonics now include 'j' (JWT), so a j/k nav fallback both shadowed that mnemonic
    # and was asymmetric (k moved up, j sent). Arrows handle navigation.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?  then return :cancel
      when key.up?      then move(-1)
      when key.down?    then move(1)
      when page_key(ev) then nil
      when key.enter?   then return :commit
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt? && (idx = index_for(c))
          set_selected(idx)
          return :commit
        end
      end
      :stay
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, idx : Int32, active : Bool, bg : Color) : Nil
      d = @destinations[idx]
      screen.text(box.x + 3, ry, d.key.to_s, Theme.accent, bg, Attribute::Bold)
      screen.text(box.x + 6, ry, d.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
      screen.text(box.right - Screen.draw_width(d.hint) - 2, ry, d.hint, Theme.muted, bg)
    end

    # The card's own heading, with the shared payload's size appended once
    # (e.g. "Send selection to · 128 B"). Replaces the base's default (the focus badge,
    # `title`), which here is a region name, not a sentence.
    private def card_title : String
      "#{@card_label} · #{Fmt.size(@payload.bytesize.to_i64)}"
    end

    # Widest of the rows (label + hint) and the sized title, plus its padding, driving the
    # card width.
    private def card_w : Int32
      rows = @destinations.max_of { |d| Screen.draw_width(d.label) + Screen.draw_width(d.hint) + 4 }
      {rows, Screen.draw_width(card_title)}.max + 10
    end
  end
end
