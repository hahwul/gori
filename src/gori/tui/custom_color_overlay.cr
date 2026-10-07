require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../settings"

module Gori::Tui
  # Popup form to add or edit ONE custom Colormarker colour (a name + a hex). The name is the
  # token a colour rule stores and the picker shows; the hex is the absolute hue the render side
  # resolves it to. Persistence is injected at the open-site (Runner#open_colormarker_color_editor)
  # exactly like the rule overlay, so the form stays settings-free: `on_commit` calls the
  # controller, which is the only place that knows whether the name is a duplicate.
  #
  #   ↑/↓ or ↹   move between fields
  #   type        edit the focused text row (name / hex)
  #   ↵           advance a text row (↵ on Save commits) · esc cancels
  class CustomColorOverlay < FormOverlay
    ROW_NAME  = 0
    ROW_HEX   = 1
    ROW_SAVE  = 2
    ROW_COUNT = 3

    # The name the colour was OPENED at (nil = adding). The commit needs it to update the right
    # row when the name field itself has been renamed.
    getter original_name : String?

    def initialize(*, name : String = "", hex : String = "", @original_name : String? = nil)
      @fields = {
        name: TextField.new(name),
        hex:  TextField.new(hex),
      }
    end

    def self.adding : CustomColorOverlay
      new
    end

    def self.editing(color : Settings::ColormarkerColor) : CustomColorOverlay
      new(name: color.name, hex: color.hex, original_name: color.name)
    end

    def editing? : Bool
      !@original_name.nil?
    end

    def name : String
      @fields[:name].value
    end

    def hex : String
      @fields[:hex].value
    end

    # Local, format-only validity: a normalisable name and hex. Uniqueness is NOT checked here —
    # only the settings registry can answer that, and it does so on commit (a refused save keeps
    # the form open with the reason). This just gates the Save button and the swatch preview.
    def valid? : Bool
      !Settings.normalize_color_name(name).nil? && !Settings.normalize_hex(hex).nil?
    end

    private def invalid_reason : String
      return "name can't be blank or a built-in colour" if Settings.normalize_color_name(name).nil?
      "hex must be #rrggbb"
    end

    def row_count : Int32
      ROW_COUNT
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME then @fields[:name]
      when ROW_HEX  then @fields[:hex]
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ColormarkerColor
    end

    def title : String
      "CUSTOM COLOUR"
    end

    def text_fields : Array(TextField)
      @fields.values.to_a
    end

    def hint : String
      "↑/↓ field · ↵ save · esc cancel"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if field_nav?(ev)

      if @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else
        text_row_key(ev, @sel == ROW_HEX)
      end
    end

    def card_title : String
      editing? ? "EDIT CUSTOM COLOUR" : "ADD CUSTOM COLOUR"
    end

    def too_small_what : String
      "custom-colour form needs a larger window"
    end

    def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                      x : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      case i
      when ROW_NAME then draw_field(screen, box, py, bg, fg, sel, "name:", @fields[:name])
      when ROW_HEX  then draw_hex_row(screen, box, py, bg, fg, sel)
      else
        ok = valid?
        label = ok ? "[ Save colour ]" : "[ #{invalid_reason} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    # The hex row carries a live swatch of the colour it names, drawn against `Theme.bg` (not the
    # row's own selection band, which would tint the preview). An unparseable hex shows a muted
    # cue instead — the same words `valid?` gates on.
    private def draw_hex_row(screen : Screen, box : Rect, py : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      draw_field(screen, box, py, bg, fg, sel, "hex:", @fields[:hex])
      sx = box.right - 12
      return if sx <= box.x + 3
      if norm = Settings.normalize_hex(hex)
        swatch = Color.from_hex(norm)
        screen.cell(sx, py, ' ', swatch, swatch)
        screen.cell(sx + 1, py, ' ', swatch, swatch)
        screen.text(sx + 3, py, "sample", Theme.muted, bg)
      else
        screen.text(sx, py, "no preview", Theme.muted, bg)
      end
    end
  end
end
