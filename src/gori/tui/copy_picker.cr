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
  class CopyPicker < PlainPickerOverlay
    # DELIBERATELY doubles as `Overlay#title`, the shell's focus badge — the pre-seam
    # `focus_label` read this very field (`@copy_picker.try(&.title)`), so the badge and
    # the card heading have always been one string. Crystal has no `override` keyword, so
    # a field silently satisfying an abstract method is easy to do BY ACCIDENT and wrong
    # most of the time (see SendPicker, whose heading is a sentence, not a region name).
    # Here it is intended; the spec pins both.
    getter title : String

    def initialize(@title : String, @options : Array(CopyMenu::Option))
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
      when key.escape?  then return :cancel
      when key.up?      then move(-1)
      when key.down?    then move(1)
      when page_key(ev) then nil
      when key.enter?   then return :commit
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

    private def draw_row(screen : Screen, box : Rect, ry : Int32, idx : Int32, active : Bool, bg : Color) : Nil
      o = @options[idx]
      screen.text(box.x + 3, ry, o.key.to_s, Theme.accent, bg, Attribute::Bold)
      screen.text(box.x + 6, ry, o.label, active ? Theme.text_bright : Theme.text, bg, Attribute::Bold)
      size = Fmt.size(o.text.bytesize.to_i64)
      screen.text(box.right - size.size - 2, ry, size, Theme.muted, bg)
    end

    # Widest row (label + size hint) plus its padding, driving the card width. The padding
    # leaves room for the mnemonic column and the right-aligned size hint.
    private def card_w : Int32
      @options.max_of { |o| Screen.draw_width(o.label) + Fmt.size(o.text.bytesize.to_i64).size + 4 } + 10
    end
  end
end
