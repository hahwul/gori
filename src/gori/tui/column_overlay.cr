require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store"
require "../display_columns"

module Gori::Tui
  # Popup form to add or edit ONE History column (#819). Same interaction model as
  # `ExtractRuleOverlay`, deliberately: a column IS an extract descriptor, and an operator who
  # learned the binding form should not have to learn a second one for the same five kinds.
  #
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the side / the descriptor kind
  #   type        edit the focused text row (label / selector / range / width)
  #   ↵           advance a text row (↵ on the last one or Save commits) · esc cancels
  #
  # The two rows `ExtractRuleOverlay` does not have are the two axes a DISPLAYED value needs and
  # a bound one does not: `from:` (request or response — the value an operator wants in the list
  # is as often the one their client sent) and `width:`.
  #
  # Store-free like its siblings. The live preview band is INJECTED at the open-site
  # (`on_preview`), because "what does this pull out of the flow under the cursor" is a question
  # only the History list can answer — the card holds no store and no selection.
  class ColumnOverlay < FormOverlay
    ROW_LABEL    = 0
    ROW_SIDE     = 1
    ROW_KIND     = 2
    ROW_SELECTOR = 3
    # `position` only: the half-open byte range over the decoded body, as `start:end`.
    ROW_RANGE = 4
    ROW_WIDTH = 5
    ROW_SAVE  = 6
    ROW_COUNT = 7

    KINDS = Gori::ExtractKind.values
    SIDES = Gori::MessageSide.values

    getter edit_id : Int64?

    # Returns what this descriptor extracts from the flow under the History cursor, or nil when
    # there is nothing to preview. Injected — see the class note.
    property on_preview : Proc(ColumnOverlay, String?)?

    @kind_i : Int32
    @side_i : Int32
    @preview : String = ""
    # Last previewed descriptor; gates the re-extract to real changes so typing stays responsive.
    @preview_sig : String = ""

    def initialize(*, label : String = "", side : Gori::MessageSide = Gori::MessageSide::Response,
                   kind : Gori::ExtractKind = Gori::ExtractKind::Header, selector : String = "",
                   pos_start : Int32 = 0, pos_end : Int32 = 0, width : Int32 = 0,
                   @edit_id : Int64? = nil)
      @fields = {
        label:    TextField.new(label),
        selector: TextField.new(selector),
        range:    TextField.new(pos_end > 0 ? "#{pos_start}:#{pos_end}" : ""),
        width:    TextField.new(width > 0 ? width.to_s : ""),
      }
      @kind_i = KINDS.index(kind) || 0
      @side_i = SIDES.index(side) || 0
    end

    def self.adding : ColumnOverlay
      new
    end

    def self.editing(col : Store::DisplayColumn) : ColumnOverlay
      new(label: col.label, side: col.side, kind: col.kind, selector: col.selector,
        pos_start: col.pos_start, pos_end: col.pos_end, width: col.width, edit_id: col.id)
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def label : String
      @fields[:label].value.strip
    end

    def selector : String
      @fields[:selector].value.strip
    end

    def kind : Gori::ExtractKind
      KINDS[@kind_i]
    end

    def side : Gori::MessageSide
      SIDES[@side_i]
    end

    def position? : Bool
      kind.position?
    end

    def pos_start : Int32
      parse_range[0]
    end

    def pos_end : Int32
      parse_range[1]
    end

    # 0 = auto. A width outside the renderer's bounds is CLAMPED rather than refused: it is a
    # display preference with an obvious nearest legal answer, unlike a selector, where guessing
    # would change which value the column shows.
    def width : Int32
      raw = @fields[:width].value.strip
      return 0 if raw.empty?
      n = raw.to_i32?
      return 0 unless n && n > 0
      n.clamp(Gori::DisplayColumns::MIN_WIDTH, Gori::DisplayColumns::MAX_WIDTH)
    end

    private def parse_range : {Int32, Int32}
      raw = @fields[:range].value.strip
      a, _, b = raw.partition(':')
      {a.to_i32? || 0, b.to_i32? || 0}
    end

    # A descriptor row the CURRENT kind has no meaning for is skipped by ↑/↓, so the caret never
    # parks on a field that does nothing — the same rule `ExtractRuleOverlay` applies.
    private def skip_row?(row : Int32) : Bool
      position? ? row == ROW_SELECTOR : row == ROW_RANGE
    end

    def valid? : Bool
      invalid_reason.nil?
    end

    # Read from `DisplayColumns.invalid_reason`, which `gori run` and MCP also refuse by, so the
    # three surfaces cannot word — or decide — the same refusal differently.
    def invalid_reason : String?
      Gori::DisplayColumns.invalid_reason(label, kind, selector, pos_start, pos_end)
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SIDE then @side_i = (@side_i + d) % SIDES.size
      when ROW_KIND
        @kind_i = (@kind_i + d) % KINDS.size
        # The kind decides which of selector/range is live; if the caret is now on the dead one,
        # walk it forward rather than leaving it parked there.
        move(1) if skip_row?(@sel)
      end
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_LABEL    then @fields[:label]
      when ROW_SELECTOR then @fields[:selector]
      when ROW_RANGE    then @fields[:range]
      when ROW_WIDTH    then @fields[:width]
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Column
    end

    def title : String
      "HISTORY COLUMN"
    end

    def text_fields : Array(TextField)
      @fields.values.to_a
    end

    def hint : String
      "↑/↓ field · ←/→ options · type label/selector · ↵ save · esc back"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      out = dispatch_key(ev)
      refresh_preview if out == :stay
      out
    end

    private def dispatch_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if field_nav?(ev)

      if @sel == ROW_SIDE || @sel == ROW_KIND
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_WIDTH
          move(1)
        elsif field
          field.handle_edit_key(ev)
        end
        :stay
      end
    end

    def set_preedit(text : String) : Nil
      text_field_for(@sel).try(&.set_preedit(text))
    end

    # Re-extract only when the DESCRIPTOR changed. Typing in the selector SHOULD re-run it — a
    # preview that did not follow the characters being typed is not a preview — so what this gate
    # buys is the label and the width fields, which move no value and are where the operator
    # spends most of their keystrokes. The body read the re-extract costs is capped
    # (`DisplayColumns::BODY_CAP`, decode included), the same ceiling the row loop pays.
    private def refresh_preview : Nil
      sig = "#{side.label} #{kind.label} #{selector} #{pos_start}:#{pos_end}"
      return if sig == @preview_sig
      @preview_sig = sig
      @preview = valid? ? (@on_preview.try(&.call(self)) || "") : ""
    end

    def row_count : Int32
      ROW_COUNT
    end

    def preview? : Bool
      true
    end

    def card_title : String
      editing? ? "EDIT COLUMN" : "ADD COLUMN"
    end

    def too_small_what : String
      "column form needs a larger window"
    end

    private def draw_tail(screen : Screen, box : Rect, first : Int32) : Nil
      # The band answers the one question a descriptor form cannot answer on its own: what this
      # pulls out of the flow the operator is looking at. Empty — not "no match" — while the
      # descriptor is still incomplete, since a refusal is already on the Save row.
      pv_y = box.bottom - 2
      return unless pv_y > first
      band = @preview.empty? ? "" : "▶ #{@preview}"
      return if band.empty?
      screen.fill(Rect.new(box.x + 1, pv_y, box.w - 2, 1), Theme.panel)
      screen.text(box.x + 2, pv_y, band, Theme.muted, Theme.panel, width: box.w - 4)
    end

    def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                      x : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      case i
      # `label:` and not `header:`: the SELECTOR row two lines down is already spelled `header:`
      # when the kind is Header, and two rows under one word is a form that cannot be read.
      when ROW_LABEL then draw_field(screen, box, py, bg, fg, sel, "label:", @fields[:label])
      when ROW_SIDE  then Frame.option_cycle(screen, x, py, box.right - 2, bg, "from:", SIDES.map(&.label), @side_i, sel)
      when ROW_KIND  then Frame.option_cycle(screen, x, py, box.right - 2, bg, "kind:", KINDS.map(&.label), @kind_i, sel)
      when ROW_SELECTOR
        draw_field(screen, box, py, bg, fg, sel, selector_label, @fields[:selector]) unless position?
      when ROW_RANGE
        draw_field(screen, box, py, bg, fg, sel, "range:", @fields[:range]) if position?
      when ROW_WIDTH then draw_field(screen, box, py, bg, fg, sel, "width:", @fields[:width])
      else
        reason = invalid_reason
        label = reason ? "[ #{reason} ]" : "[ Save column ]"
        screen.text(x, py, label, reason ? Theme.muted : Theme.accent, bg, Attribute::Bold)
      end
    end

    private def selector_label : String
      case kind
      in Gori::ExtractKind::Cookie   then "cookie:"
      in Gori::ExtractKind::Header   then "header:"
      in Gori::ExtractKind::Regex    then "regex:"
      in Gori::ExtractKind::JsonPath then "path:"
      in Gori::ExtractKind::Position then "range:"
      end
    end
  end
end
