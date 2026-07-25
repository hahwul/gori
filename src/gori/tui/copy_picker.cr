require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./copy_menu"
require "./picker_overlay"

module Gori::Tui
  # A small centered picker for the "copy as X" action (space → Y): pick which slice
  # of the focused HTTP message to copy — url / headers / body / cookies / curl / raw.
  # Structurally a twin of ChoicePicker, but each row carries the payload `text`
  # outright and shows its byte size rather than a "current" marker — there's no
  # persisted value here, just a one-shot copy. Rows are fronted by a mnemonic key.
  #
  # PROMPT-TIER on the Overlay seam: the clipboard write is the injected `on_commit`
  # (Runner#copy_as_open) like any migrated modal, but the Runner keeps this in its own
  # slot rather than @active_overlay, because the picker must float over the History
  # detail drill-in without collapsing it and must claim keys before the ^G/^F guards.
  class CopyPicker < PickerOverlay
    # DELIBERATELY doubles as `Overlay#title`, the shell's focus badge — the pre-seam
    # `focus_label` read this very field (`@copy_picker.try(&.title)`), so the badge and
    # the card heading have always been one string. Crystal has no `override` keyword, so
    # a field silently satisfying an abstract method is easy to do BY ACCIDENT and wrong
    # most of the time (see SendPicker, whose heading is a sentence, not a region name).
    # Here it is intended; the spec pins both.
    getter title : String

    def initialize(@title : String, @options : Array(CopyMenu::Option))
    end

    def empty? : Bool
      @options.empty?
    end

    def entry_count : Int32
      @options.size
    end

    def selected_option : CopyMenu::Option?
      @options[@selected]?
    end

    # The row whose mnemonic matches `c` (case-insensitive), or nil for a miss.
    def index_for(c : Char) : Int32?
      lc = c.downcase
      @options.index { |o| o.key.downcase == lc }
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::CopyAs
    end

    def hint : String
      "↑/↓ select · ↵ copy · key picks · esc cancel"
    end

    # ↑/↓ move, ↵ or a row mnemonic copies, esc cancels — j/k fall back to vim-style nav
    # only when they aren't themselves a mnemonic, so the reflex keystroke moves the
    # highlight instead of being ignored (mirrors ChoicePicker so the two feel identical).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then return :cancel
      when key.up?     then move(-1)
      when key.down?   then move(1)
      when key.enter?  then return :commit
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          if idx = index_for(c)
            set_selected(idx)
            return :commit
          elsif c == 'j'
            move(1)
          elsif c == 'k'
            move(-1)
          end
        end
      end
      :stay
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil when
    # render would draw nothing (mirrors the w/h guard). Width leaves room for the
    # right-aligned size hint.
    def overlay_box(area : Rect) : Rect?
      # content_w is a max_of over the rows, which raises on an empty list. Unreachable
      # today (both open-sites refuse to open an empty picker), but PickerOverlay#handle_click
      # calls this for EVERY click, so a nil here is the difference between the base's
      # "a click outside dismisses" promise and an exception out of the event loop.
      return nil if @options.empty?
      w = {area.w - 4, content_w + 10}.min
      h = {@options.size + 2, area.h - 2}.min
      return nil if w < 18 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to
    # the ACTUALLY rendered rows so a click on a height-clamped card's bottom border
    # can't pick a row that was never drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @options.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @options.size ? ci : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)
      rows = {box.h - 2, @options.size}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @options.size
        o = @options[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, o.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 6, ry, o.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
        size = Fmt.size(o.text.bytesize.to_i64)
        screen.text(box.right - size.size - 2, ry, size, Theme.muted, bg)
      end
    end

    # Widest row (label + size hint), driving the card width.
    private def content_w : Int32
      @options.max_of { |o| o.label.size + Fmt.size(o.text.bytesize.to_i64).size + 4 }
    end
  end
end
