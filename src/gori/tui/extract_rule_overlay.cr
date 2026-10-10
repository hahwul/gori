require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store"
require "../token_extract"

module Gori::Tui
  # The descriptor half two forms share: a `Gori::ExtractKind` cycler and the selector/range
  # pair it switches between. An extract rule binds the value, a History column displays it —
  # the same five kinds, so an operator who learned one form has learned the other.
  abstract class ExtractFormOverlay < FormOverlay
    KINDS = Gori::ExtractKind.values

    @kind_i = 0

    # The selector row; the range row (`position` only) is the one after it.
    abstract def selector_row : Int32

    private abstract def selector_field : TextField
    private abstract def range_field : TextField

    def kind : Gori::ExtractKind
      KINDS[@kind_i]
    end

    def position? : Bool
      kind.position?
    end

    def selector : String
      selector_field.value.strip
    end

    def pos_start : Int32
      parse_range[0]
    end

    def pos_end : Int32
      parse_range[1]
    end

    # The half-open byte range over the decoded body, typed as `start:end`.
    private def parse_range : {Int32, Int32}
      raw = range_field.value.strip
      a, _, b = raw.partition(':')
      {a.to_i32? || 0, b.to_i32? || 0}
    end

    # A descriptor row the CURRENT kind has no meaning for is skipped by ↑/↓, so the caret
    # never parks on a field that does nothing — same rule RewriterRuleOverlay applies to
    # its two body-source rows.
    def skip_row?(row : Int32) : Bool
      position? ? row == selector_row : row == selector_row + 1
    end

    # Cycle the kind. It decides which of selector/range is live; if the caret is now on the
    # dead one, walk it forward rather than leaving it parked there.
    private def cycle_kind(d : Int32) : Nil
      @kind_i = (@kind_i + d) % KINDS.size
      move(1) if skip_row?(@sel)
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

  # Popup form to add or edit ONE extract rule — the READ half of a session binding (#501).
  # Same interaction model as RewriterRuleOverlay, deliberately: the two live one sub-tab
  # apart on the Rewriter body, and an operator who learned one form should not have to
  # learn the other.
  #
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the descriptor kind
  #   type        edit the focused text row (name / when / selector / range / host)
  #   ↵           advance a text row (↵ on the last one or Save commits) · esc cancels
  #
  # Two sections, and the split is the whole model: MATCH says which messages this rule
  # reads (`when:` — an `InterceptFilter` source, the same boolean grammar the conditional
  # intercept bar uses, plus a `host:` glob in `match_rules`' dialect), and EXTRACT says
  # where in one of them the value lives (`Gori::TokenLoc`, the Sequencer's five descriptors).
  #
  # Store-free like its sibling: the duplicate-name / bad-regex refusal is INJECTED at the
  # open-site (`on_validate`), because "is `$SESSION` already written by another rule" is a
  # question only the live binding table can answer.
  class ExtractRuleOverlay < ExtractFormOverlay
    ROW_NAME     = 0
    ROW_WHEN     = 1
    ROW_HOST     = 2
    ROW_KIND     = 3
    ROW_SELECTOR = 4
    # `position` only: the half-open byte range over the decoded body, as `start:end`.
    ROW_RANGE = 5
    ROW_SAVE  = 6
    ROW_COUNT = 7

    getter edit_id : Int64?

    # Returns the refusal for the rule as currently edited, or nil when it may be saved.
    # Injected because it needs the binding table (one name, one writer).
    property on_validate : Proc(ExtractRuleOverlay, String?)?

    def initialize(*, name : String = "", match_filter : String = "", host : String = "",
                   kind : Gori::ExtractKind = Gori::ExtractKind::Cookie, selector : String = "",
                   pos_start : Int32 = 0, pos_end : Int32 = 0, @edit_id : Int64? = nil)
      @fields = {
        name:     TextField.new(name),
        filter:   TextField.new(match_filter),
        host:     TextField.new(host),
        selector: TextField.new(selector),
        range:    TextField.new(pos_end > 0 ? "#{pos_start}:#{pos_end}" : ""),
      }
      @kind_i = KINDS.index(kind) || 0
    end

    def self.adding : ExtractRuleOverlay
      new
    end

    def self.editing(rule : Store::ExtractRule) : ExtractRuleOverlay
      new(name: rule.name, match_filter: rule.match_filter, host: rule.host,
        kind: rule.kind, selector: rule.selector,
        pos_start: rule.pos_start, pos_end: rule.pos_end, edit_id: rule.id)
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    # The SPELLING is stripped so an operator can type the token the way they read it —
    # `$BIND.SESSION`, `BIND.SESSION`, `$SESSION` or `SESSION` all name the same binding. What
    # is stored is the bare name; the namespace is this field's, not the operator's to choose.
    # Nothing else about the name is repaired here — `Bindings#validate` names what is wrong.
    def name : String
      Env.strip_spelling(@fields[:name].value, Env::Namespace::Bind)
    end

    def match_filter : String
      @fields[:filter].value.strip
    end

    def host : String
      @fields[:host].value.strip
    end

    def selector_row : Int32
      ROW_SELECTOR
    end

    private def selector_field : TextField
      @fields[:selector]
    end

    private def range_field : TextField
      @fields[:range]
    end

    def valid? : Bool
      invalid_reason.nil?
    end

    # What is missing, for the Save row's label. Local shape checks first (they need no
    # injection), then the table's own refusal.
    def invalid_reason : String?
      return "enter a binding name" if name.empty?
      # A `when:` condition is an `InterceptFilter` source, and that backend refuses a field it
      # cannot answer by compiling it to a never-match (`UNSUPPORTED_FIELDS`) — for `scope:`,
      # because `Bindings#observe_response` holds no project scope. Said HERE as well as at the
      # table (`Bindings#validate` refuses the same write, so MCP and the CLI refuse too) because
      # this form greys out its Save row from local shape checks, a keystroke before any commit —
      # and read from the ONE sentence there, so the two can never disagree about what is legal.
      if bad = Gori::InterceptFilter.refusal(match_filter)
        return bad
      end
      if position?
        a, b = parse_range
        return "enter a byte range like 0:32" if b <= a
      elsif selector.empty?
        return "enter a #{kind.label} selector"
      end
      @on_validate.try(&.call(self))
    end

    def adjust(d : Int32) : Nil
      cycle_kind(d) if @sel == ROW_KIND
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME     then @fields[:name]
      when ROW_WHEN     then @fields[:filter]
      when ROW_HOST     then @fields[:host]
      when ROW_SELECTOR then @fields[:selector]
      when ROW_RANGE    then @fields[:range]
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ExtractRule
    end

    def title : String
      "EXTRACT RULE"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      "↑/↓ field · ←/→ options · type when/selector · ↵ save · esc cancel"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if field_nav?(ev)

      if @sel == ROW_KIND
        cycler_key(key)
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else
        text_row_key(ev, @sel == ROW_SELECTOR || @sel == ROW_RANGE)
      end
    end

    def row_count : Int32
      ROW_COUNT
    end

    def card_title : String
      editing? ? "EDIT EXTRACT RULE" : "ADD EXTRACT RULE"
    end

    def too_small_what : String
      "extract-rule form needs a larger window"
    end

    def draw_row_body(screen : Screen, box : Rect, i : Int32, py : Int32,
                      x : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      case i
      # The label is the affordance that teaches the syntax, so it prints the LIVE opener
      # (`$BIND.` / `$`) rather than a hardcoded sigil the operator would then have to undo.
      when ROW_NAME then draw_field(screen, box, py, bg, fg, sel, "name: #{Env.input_hint(Env::Namespace::Bind)}", @fields[:name])
      when ROW_WHEN then draw_field(screen, box, py, bg, fg, sel, "when:", @fields[:filter])
      when ROW_HOST then draw_field(screen, box, py, bg, fg, sel, "host:", @fields[:host])
      when ROW_KIND then Frame.option_cycle(screen, x, py, box.right - 2, bg, "from:", KINDS.map(&.label), @kind_i, sel)
      when ROW_SELECTOR
        draw_field(screen, box, py, bg, fg, sel, selector_label, @fields[:selector]) unless position?
      when ROW_RANGE
        draw_field(screen, box, py, bg, fg, sel, "range:", @fields[:range]) if position?
      else
        reason = invalid_reason
        label = reason ? "[ #{reason} ]" : "[ Save rule ]"
        screen.text(x, py, label, reason ? Theme.muted : Theme.accent, bg, Attribute::Bold, width: {box.right - 2 - x, 0}.max)
      end
    end
  end
end
