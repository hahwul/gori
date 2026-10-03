require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../scope"

module Gori::Tui
  # Popup form for adding or editing ONE Project SCOPE rule — same interaction
  # model as MineConfigOverlay / FuzzSetOverlay:
  #   ↑/↓  field (kind → type → pattern → Save)
  #   ←/→  cycle kind or type when that row is selected
  #   type into Pattern when focused; ↵ on Save (or last field) commits
  #   esc cancels
  #
  # First modal migrated onto the polymorphic Overlay seam (see overlay.cr): the Runner
  # dispatches key/click/wheel/preedit/render/title/hint to it generically, and the SCOPE
  # apply is injected as `on_commit` at the open-site (Runner#open_scope_rule_editor).
  class ScopeRuleOverlay < FormOverlay
    getter edit_id : Int64?

    def initialize(*, kind : String = "include", match_type : String = "host",
                   pattern : String = "", @edit_id : Int64? = nil)
      @kind_idx = Scope::KINDS.index(kind) || 0
      @type_idx = Scope::TYPES.index(match_type) || 0
      @pattern = TextField.new(pattern) # rows: 0 kind · 1 type · 2 pattern · 3 save
    end

    def self.adding : ScopeRuleOverlay
      new
    end

    def self.editing(id : Int64, kind : String, match_type : String, pattern : String) : ScopeRuleOverlay
      new(kind: kind, match_type: match_type, pattern: pattern, edit_id: id)
    end

    def kind : String
      Scope::KINDS[@kind_idx]
    end

    def match_type : String
      Scope::TYPES[@type_idx]
    end

    def pattern : String
      @pattern.value.strip
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ScopeRule
    end

    def title : String
      "SCOPE RULE"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      [@pattern]
    end

    def hint : String
      "↑/↓ field · ←/→ options · type pattern · ↵ save · esc cancel"
    end

    def row_count : Int32
      4
    end

    private def on_pattern_row? : Bool
      @sel == 2
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      case @sel
      when 0 then @kind_idx = (@kind_idx + d) % Scope::KINDS.size
      when 1 then @type_idx = (@type_idx + d) % Scope::TYPES.size
      end
    end

    # :stay | :commit | :cancel
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if field_nav?(ev)

      case @sel
      when 0, 1 # kind / type cyclers
        if key.left?
          adjust(-1)
        elsif key.right?
          adjust(1)
        elsif key.enter? || key.space?
          move(1)
        else
          type_into_pattern(ev)
        end
        :stay
      when 2 # pattern text field
        return :commit if key.enter?
        @pattern.handle_edit_key(ev)
        :stay
      else # save row
        return :commit if key.enter? || key.space?
        type_into_pattern(ev)
        :stay
      end
    end

    # The footer says "type pattern", and the form opens on `kind`: a printable typed on a
    # non-text row moves focus to the pattern and lands there instead of being dropped.
    private def type_into_pattern(ev : Termisu::Event::Key) : Nil
      return unless (ch = ev.char) && ch.printable? && !ev.ctrl? && !ev.alt?
      @sel = 2
      @pattern.insert(ch)
    end

    def set_preedit(text : String) : Nil
      @pattern.set_preedit(text) if on_pattern_row?
    end

    def card_title : String
      editing? ? "EDIT SCOPE RULE" : "ADD SCOPE RULE"
    end

    def too_small_what : String
      "scope form needs a larger window"
    end

    def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                      x : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      case i
      when 0
        # `kind:` used to print the current value ALONE — so a form whose whole first question
        # is "include or exclude?" never showed that the other answer existed. Both rows are
        # strips now, through the same renderer as every other cycler in gori.
        Frame.option_cycle(screen, x, py, box.right - 2, bg, "kind:", Scope::KINDS, @kind_idx, sel)
      when 1
        Frame.option_cycle(screen, x, py, box.right - 2, bg, "type:", Scope::TYPES, @type_idx, sel)
      when 2
        screen.text(x, py, "pattern:", Theme.muted, bg)
        vx = x + 9
        # Through the FIELD's own `render`, not a hand-rolled paint of its value. Listing
        # `@pattern` in `text_fields` is the opt-in for caret-on-press, drag-select and
        # double-click-word (see `Overlay#text_fields`), and a `TextField` answers a pointer
        # only against the x/y/width its own `render` recorded — so painting it here left this
        # form advertising three gestures that were silent no-ops, `handle_click`'s
        # `click_text_field` call included. It also buys the horizontal window `input_line`
        # carries, which a long regex pattern needs and the clipped `text` call did not have.
        @pattern.render(screen, vx, py, {box.right - 2 - vx, 3}.max, sel, fg, bg)
      else
        ok = !pattern.empty? && Scope.valid?(match_type, pattern)
        label = ok ? "[ Save rule ]" : "[ enter a valid pattern ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold, width: {box.right - 2 - x, 0}.max)
      end
    end
  end
end
