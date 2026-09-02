require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../store"
require "../store/safe_regexp"
require "../probe/custom_rule"

module Gori::Tui
  # Popup form to add or edit ONE custom Probe match rule (the Rules sub-tab). Same interaction
  # model as ScopeRuleOverlay / FuzzSetOverlay:
  #   ↑/↓ or ↹  move between fields
  #   ←/→        cycle the selected option row (scope/side/region/match/severity)
  #   type       edit the focused text row (title / description / pattern)
  #   ↵          advance a text row (↵ on pattern or Save commits) · esc cancels
  #
  # On the polymorphic Overlay seam (see overlay.cr): the persist — global →
  # settings.json, project → project DB, and the scope-change move between them — is
  # injected as `on_commit` at the open-site (Runner#open_custom_rule_editor), which
  # routes it to ProbeController#apply_custom_rule. An invalid form (missing title/
  # description, or a regex that won't compile) makes that closure return false, which
  # keeps the card up.
  class CustomRuleOverlay < Overlay
    ROW_TITLE   = 0
    ROW_DESC    = 1
    ROW_SCOPE   = 2
    ROW_SIDE    = 3
    ROW_REGION  = 4
    ROW_KIND    = 5
    ROW_SEV     = 6
    ROW_PATTERN = 7
    ROW_SAVE    = 8
    ROW_COUNT   = 9

    SCOPES  = %w[project global]
    SIDES   = %w[request response]
    REGIONS = %w[whole header body]
    # `exec` turns `pattern:` into an ARGV: the region goes to that command on stdin and its
    # exit code is the verdict (#818). It sits last so the two match kinds that have always
    # been here keep their cycler positions.
    KINDS = %w[string regex exec]
    SEVS  = %w[info low medium high critical]

    getter edit_id : String?
    getter edit_scope : String?

    @scope_i : Int32
    @side_i : Int32
    @region_i : Int32
    @kind_i : Int32
    @sev_i : Int32
    @sel : Int32

    def initialize(*, title : String = "", description : String = "", scope : String = "project",
                   side : String = "response", region : String = "body", kind : String = "string",
                   severity : String = "info", pattern : String = "",
                   @edit_id : String? = nil, @edit_scope : String? = nil)
      @fields = {
        title:   TextField.new(title),
        desc:    TextField.new(description),
        pattern: TextField.new(pattern),
      }
      @scope_i = idx(SCOPES, scope)
      @side_i = idx(SIDES, side)
      @region_i = idx(REGIONS, region)
      @kind_i = idx(KINDS, kind)
      @sev_i = idx(SEVS, severity)
      @sel = 0
    end

    def self.adding : CustomRuleOverlay
      new
    end

    def self.editing(rule : Probe::CustomRule) : CustomRuleOverlay
      new(title: rule.title, description: rule.description, scope: rule.scope, side: rule.side,
        region: rule.region, kind: rule.kind, severity: rule.severity.label, pattern: rule.pattern,
        edit_id: rule.id, edit_scope: rule.scope)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    # NOT `title`: that name belongs to the Overlay contract (the focus-badge label). The
    # two are unrelated strings and collapsing them would silently persist every rule
    # under the badge text.
    def rule_title : String
      @fields[:title].value.strip
    end

    def description : String
      @fields[:desc].value.strip
    end

    def pattern : String
      @fields[:pattern].value.strip
    end

    def scope : String
      SCOPES[@scope_i]
    end

    def side : String
      SIDES[@side_i]
    end

    def region : String
      REGIONS[@region_i]
    end

    def kind : String
      KINDS[@kind_i]
    end

    def severity : Store::Severity
      Store::Severity.parse?(SEVS[@sev_i]) || Store::Severity::Info
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    # Every required field is present and, for a regex rule, the pattern compiles (the shared
    # validator the CLI/MCP write paths use too).
    def valid? : Bool
      return false if rule_title.empty? || description.empty?
      Probe::CustomRule.valid_pattern?(pattern, kind)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::ProbeRule
    end

    def title : String
      I18n.ui("CUSTOM RULE")
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      I18n.ui("↑/↓ field · ←/→ options · type title/pattern · ↵ save · esc cancel")
    end

    # Click a field row to select it; a click on Save commits; a click outside the card
    # cancels. Mirrors the ↑/↓ + ↵ keyboard model.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_save_row?
      end
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, ROW_COUNT - 1)
    end

    private def cycler_row?(row : Int32) : Bool
      ROW_SCOPE <= row <= ROW_SEV
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_TITLE   then @fields[:title]
      when ROW_DESC    then @fields[:desc]
      when ROW_PATTERN then @fields[:pattern]
      end
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SCOPE  then @scope_i = (@scope_i + d) % SCOPES.size
      when ROW_SIDE   then @side_i = (@side_i + d) % SIDES.size
      when ROW_REGION then @region_i = (@region_i + d) % REGIONS.size
      when ROW_KIND   then @kind_i = (@kind_i + d) % KINDS.size
      when ROW_SEV    then @sev_i = (@sev_i + d) % SEVS.size
      end
    end

    # :stay | :commit | :cancel
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up? || key.back_tab?
        move(-1)
        return :stay
      elsif key.down? || key.tab?
        move(1)
        return :stay
      end

      if cycler_row?(@sel)
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      else # text row: title / description / pattern
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_PATTERN
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

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, ROW_COUNT)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "custom-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      title = editing? ? "EDIT CUSTOM RULE" : "ADD CUSTOM RULE"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      # No key hint on the bottom border — the shell draws `hint` in the status strip for the
      # open modal (Runner#key_hints). See RewriterRuleOverlay#render for the whole argument.
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when ROW_TITLE then draw_field(screen, box, py, bg, fg, sel, "title:", @fields[:title])
      when ROW_DESC  then draw_field(screen, box, py, bg, fg, sel, "desc:", @fields[:desc])
        # The label follows the KIND, because an operator looking at "pattern:" over a command
        # line has been told the wrong thing about what the field means.
      when ROW_PATTERN then draw_field(screen, box, py, bg, fg, sel, kind == "exec" ? "run:" : "pattern:", @fields[:pattern])
      when ROW_SCOPE   then Frame.option_cycle(screen, x, py, box.right - 2, bg, "scope:", SCOPES, @scope_i, sel)
      when ROW_SIDE    then Frame.option_cycle(screen, x, py, box.right - 2, bg, "side:", SIDES, @side_i, sel)
      when ROW_REGION  then Frame.option_cycle(screen, x, py, box.right - 2, bg, "region:", REGIONS, @region_i, sel)
      when ROW_KIND    then Frame.option_cycle(screen, x, py, box.right - 2, bg, "match:", KINDS, @kind_i, sel)
      when ROW_SEV     then Frame.option_cycle(screen, x, py, box.right - 2, bg, "severity:", SEVS, @sev_i, sel)
      else
        ok = valid?
        label = ok ? "[ Save rule ]" : "[ complete title, description & #{kind == "exec" ? "command" : "pattern"} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
