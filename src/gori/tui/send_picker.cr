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
  class SendPicker < PickerOverlay
    getter payload : String

    def initialize(@card_label : String, @payload : String, @destinations : Array(SendMenu::Destination))
    end

    def empty? : Bool
      @destinations.empty?
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
      when key.escape? then return :cancel
      when key.up?     then move(-1)
      when key.down?   then move(1)
      when key.enter?  then return :commit
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt? && (idx = index_for(c))
          set_selected(idx)
          return :commit
        end
      end
      :stay
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil when
    # render would draw nothing (mirrors the w/h guard). Width fits the widest of the
    # rows (label + hint) and the sized title.
    def overlay_box(area : Rect) : Rect?
      # content_w is a max_of over the rows, which raises on an empty list. Unreachable
      # today (both open-sites refuse to open an empty picker), but PickerOverlay#handle_click
      # calls this for EVERY click, so a nil here is the difference between the base's
      # "a click outside dismisses" promise and an exception out of the event loop.
      return nil if @destinations.empty?
      w = {area.w - 4, content_w + 10}.min
      h = {@destinations.size + 2, area.h - 2}.min
      return nil if w < 18 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to the
    # ACTUALLY rendered rows so a click on a height-clamped card's bottom border can't
    # pick a row that was never drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @destinations.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @destinations.size ? ci : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      rows = {box.h - 2, @destinations.size}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @destinations.size
        d = @destinations[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, d.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 6, ry, d.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
        screen.text(box.right - d.hint.size - 2, ry, d.hint, Theme.muted, bg)
      end
    end

    # The card's own heading, with the shared payload's size appended once
    # (e.g. "Send selection to · 128 B").
    private def card_title : String
      "#{@card_label} · #{Fmt.size(@payload.bytesize.to_i64)}"
    end

    # Widest row (label + hint) and the sized title, driving the card width.
    private def content_w : Int32
      rows = @destinations.max_of { |d| d.label.size + d.hint.size + 4 }
      {rows, card_title.size}.max
    end
  end
end
