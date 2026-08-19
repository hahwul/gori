require "../tab_controller"
require "../colormarker_view"
require "../custom_colors_view"
require "../../store"
require "../../settings"
require "../../colormarker"
require "../viewport"

module Gori::Tui
  # The Colormarker tab: two stacked panes. The POLICY list on top manages this project's
  # History row-colour rules (the shared Colormarker engine History's row loop reads live);
  # the CUSTOM COLORS list below manages the global palette of user-defined colours those rules
  # can paint with. Add/edit on either pane opens a modal (ColormarkerRuleOverlay /
  # CustomColorOverlay), wired in the runner like the Rewriter rule editor.
  #
  # Multi-pane like the Rewriter, and for the same reasons: `@focus` names the pane the keyboard
  # points at, the rule verbs' chords are gated on the policy pane being focused (a chord has no
  # `section:` to hide behind), and the colours pane's a/e/d are handled HERE rather than as
  # verbs — the two panes share `Verb::Scope::Colormarker`, and the keymap holds one verb per
  # chord per scope, so a/e/d could not bind twice.
  class ColormarkerController < TabController
    def initialize(host : Host)
      super(host)
      @view = ColormarkerView.new
      @colors_view = CustomColorsView.new
      @sel = 0
      @scroll = 0
      @color_sel = 0
      @color_scroll = 0
      @focus = :rules       # :rules | :colors
      @colors_shown = false # whether the body is tall enough to host the colours pane
      @last_body = Rect.new(0, 0, 0, 0)
    end

    def tab : Symbol
      :colormarker
    end

    def command_scope : Verb::Scope
      Verb::Scope::Colormarker
    end

    # The space menu's CONTEXT section: the pane the keyboard points at. `:rules` shows the
    # policy actions, `:colors` the custom-colour ones — two `section:`s that never render
    # together, so each may reuse a/e/d without `validate_menu_keys!` seeing them twice.
    def command_section : Symbol
      @focus == :colors ? :colors : :rules
    end

    private def engine : Colormarker
      @host.session.colormarker
    end

    private def rule_list : Array(Store::ColorRule)
      engine.rules
    end

    private def custom_colors : Array(Settings::ColormarkerColor)
      Settings.colormarker_colors
    end

    def selected_rule : Store::ColorRule?
      rule_list[@sel]?
    end

    def rule_selected? : Bool
      !selected_rule.nil?
    end

    # The FOCUS half of the rule-verb gate: the policy list is the thing the keyboard points at.
    # Both `rule_selected?` and this are needed, exactly as on the Rewriter — the colours pane
    # sits in the same body and a bare `x`/`s`/⇧J there would otherwise act on the rule behind it.
    def rule_list_focused? : Bool
      @focus == :rules
    end

    def global_rule_selected? : Bool
      selected_rule.try(&.global?) == true
    end

    def selected_color : Settings::ColormarkerColor?
      custom_colors[@color_sel]?
    end

    def color_selected? : Bool
      !selected_color.nil?
    end

    def colors_focused? : Bool
      @focus == :colors
    end

    # Pull external (MCP / CLI / other-instance) rule edits when the tab becomes active.
    def on_enter : Nil
      engine.reload
      @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
      @color_sel = @color_sel.clamp(0, {custom_colors.size - 1, 0}.max)
    end

    def on_external_change : Nil
      engine.reload
    end

    # --- render ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      # multi_pane: true — each pane gilds its own border, the outer shell stays a hairline.
      BodyChrome.framed(screen, rect, BodyChrome.shell_focused(focus, multi_pane: true)) do |inner|
        @last_body = inner
        rules_r, colors_r = @view.pane_rects(inner)
        @colors_shown = !colors_r.empty?
        @focus = :rules unless @colors_shown # can't rest on a pane that is not drawn

        rlist = rule_list
        @sel = @sel.clamp(0, {rlist.size - 1, 0}.max)
        ensure_visible(rules_r, rlist.size)
        @view.render(screen, rules_r, rlist, @sel, @scroll, engine.enabled_count,
          body_focused && @focus == :rules)

        if @colors_shown
          clist = custom_colors
          @color_sel = @color_sel.clamp(0, {clist.size - 1, 0}.max)
          ensure_color_visible(colors_r, clist.size)
          @colors_view.render(screen, colors_r, clist, @color_sel, @color_scroll,
            body_focused && @focus == :colors)
        end
      end
    end

    # Both counts are the arrays the caller hands straight to the matching view — `rule_list`
    # for the POLICY pane, `custom_colors` for the COLOURS pane — so each window and its draw
    # walk the same list by construction. `row_capacity` takes the count because the pane's
    # usable height depends on how many rows it has to place.
    private def ensure_visible(rect : Rect, count : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@sel, @scroll, @view.row_capacity(rect, count), count)
    end

    private def ensure_color_visible(rect : Rect, count : Int32) : Nil
      @color_scroll = Viewport.scroll_to_show(@color_sel, @color_scroll,
        @colors_view.row_capacity(rect, count), count)
    end

    def body_hint(focus : Symbol) : String
      if @focus == :colors
        "↑/↓ select · a add · ↵/e edit · d delete · space cmds · esc tabs"
      else
        "↑/↓ select · a add · ↵/e edit · x on/off · d delete · space cmds · ↹ colours"
      end
    end

    # --- focus ring (Tab/Shift-Tab) ---
    def pane_advance(dir : Int32) : Bool
      order = @colors_shown ? [:rules, :colors] : [:rules]
      idx = order.index(@focus) || 0
      nidx = idx + dir
      return false unless 0 <= nidx < order.size
      @focus = order[nidx]
      true
    end

    def focus_first : Nil
      @focus = :rules
    end

    def focus_last : Nil
      @focus = @colors_shown ? :colors : :rules
    end

    # --- keys ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      @focus == :colors ? handle_colors_key(ev, key) : handle_rules_key(ev, key)
    end

    private def handle_rules_key(ev : Termisu::Event::Key, key) : Bool
      c = ev.char || key.to_char
      case
      when key.escape?         then @host.request_focus(:menu)
      when key.up?, c == 'k'   then rules_up
      when key.down?, c == 'j' then rules_down
      else
        # a/↵/e/d/x/⇧X/s/⇧J/⇧K defer to the central keymap — the rule actions are REBINDABLE and
        # dispatch through the same `available?` gate the menu uses, now focus-aware
        # (`rule_list_focused?`) so `x`/`s` here can never fire while the colours pane is up.
        return false
      end
      true
    end

    private def handle_colors_key(ev : Termisu::Event::Key, key) : Bool
      c = ev.char || key.to_char
      case
      when key.escape?          then @focus = :rules
      when key.up?, c == 'k'    then colors_up
      when key.down?, c == 'j'  then colors_down
      when key.enter?, c == 'e' then customcolor_edit
      when c == 'a'             then customcolor_add
      when c == 'd'             then customcolor_delete
      else
        # Defer everything else to the keymap. A rule chord (x/s/⇧J/…) resolves to a verb whose
        # `available?` is gated on the POLICY pane being focused, so it is a no-op here rather
        # than acting on the list behind this pane — and deferring (not consuming) is what keeps
        # global chords (^R/^P/quit) working while this pane holds focus.
        return false
      end
      true
    end

    # ↑/k at the top of the policy list releases focus back to the tab bar.
    private def rules_up : Nil
      @sel <= 0 ? @host.request_focus(:menu) : move_sel(-1)
    end

    # ↓/j past the last rule (or on an empty list) drops into the colours pane when it is shown.
    private def rules_down : Nil
      n = rule_list.size
      if (n == 0 || @sel >= n - 1) && @colors_shown
        @focus = :colors
      else
        move_sel(1)
      end
    end

    private def colors_up : Nil
      @color_sel <= 0 ? (@focus = :rules) : move_color_sel(-1)
    end

    private def colors_down : Nil
      move_color_sel(1)
    end

    private def move_sel(d : Int32) : Nil
      n = rule_list.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    private def move_color_sel(d : Int32) : Nil
      n = custom_colors.size
      return if n == 0
      @color_sel = (@color_sel + d).clamp(0, n - 1)
    end

    # --- mouse ---
    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = BodyChrome.frame_inner(rect)
      @last_body = inner
      rules_r, colors_r = @view.pane_rects(inner)
      if !colors_r.empty? && colors_r.contains?(mx, my)
        @focus = :colors
        n = custom_colors.size
        if row = @colors_view.gauge_row_at(colors_r, mx, my, n)
          @color_sel = row
        elsif idx = @colors_view.row_at(colors_r, my, @color_scroll, n)
          @color_sel = idx.clamp(0, {n - 1, 0}.max)
        end
        return true
      end
      @focus = :rules
      # The scroll gauge on the card's right hairline, which `row_at` excludes by construction.
      if row = @view.gauge_row_at(rules_r, mx, my, rule_list.size)
        @sel = row
        return true
      end
      if idx = @view.row_at(rules_r, my, @scroll, rule_list.size)
        @sel = idx.clamp(0, {rule_list.size - 1, 0}.max)
      end
      true
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click(rect, mx, my)
      @focus == :colors ? customcolor_edit : colormarker_edit
      true
    end

    # The SELECTION, like every other selection-carrying list in the tree — render's
    # ensure_visible brings the viewport along.
    def handle_wheel(step : Int32) : Bool
      @focus == :colors ? move_color_sel(step) : move_sel(step)
      true
    end

    # --- policy actions (also the ExecContext verbs) ---

    def colormarker_add : Nil
      @host.open_colormarker_rule_editor(nil)
    end

    def colormarker_edit : Nil
      if rule = selected_rule
        @host.open_colormarker_rule_editor(rule)
      else
        @host.status("no colour rule selected")
      end
    end

    def colormarker_delete : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      label = rule.name.empty? ? rule.match_filter : rule.name
      # A global rule is deleted out of EVERY project, and the prompt has to say so — the row
      # differs from a project rule's by one badge, and the confirm is the last place to notice.
      note = rule.global? ? " It is a GLOBAL rule — this removes it from every project." : ""
      @host.confirm("DELETE COLOUR RULE", "Delete “#{label}”?#{note} This can't be undone.",
        confirm_label: "delete", danger: true) do
        ok = engine.remove(rule.id, rule.scope)
        @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
        @host.status(ok ? "colour rule deleted: #{label}" : "colour rule NOT deleted (project busy) — the row colour is unchanged")
      end
    end

    # `x` toggles the rule HERE. For a project rule that is the row itself; for a global one it
    # is this project's override of the library's default, which is why the toast says where the
    # change lands.
    def colormarker_toggle : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      unless engine.toggle(rule.id, rule.scope)
        return @host.status("enable/disable NOT applied (project busy) — the row colour is unchanged")
      end
      state = rule.enabled? ? "disabled" : "enabled"
      @host.status(rule.global? ? "global colour rule #{state} in this project" : "colour rule #{state}")
    end

    # ⇧X: the global DEFAULT — what every project that has not overridden this rule follows.
    def colormarker_toggle_default : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      return @host.status("only a global rule has a default — this one is project-scoped") unless rule.global?
      unless engine.toggle_default(rule.id, rule.scope)
        return @host.status("default NOT changed (settings not writable) — the rule is unchanged")
      end
      after = rule_list.find { |r| r.global? && r.id == rule.id }
      note = after.try(&.overridden?) ? " (this project still overrides it)" : ""
      @host.status("global colour rule default flipped for every project#{note}")
    end

    # Reordering here changes WHICH rule paints a row (first enabled match wins), so the toast
    # says that rather than leaving an operator to infer it from a list that merely shuffled.
    def colormarker_move(dir : Int32) : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      if engine.move(rule.id, dir, rule.scope)
        move_sel(dir)
        @host.status("precedence changed — the first enabled match paints the row")
      elsif !at_scope_edge?(rule, dir)
        # Not an edge, so the reorder was refused by the store / settings write. Say so: a
        # silent no-op here reads exactly like "the rule is already at the top".
        @host.status("precedence NOT changed (project busy or settings not writable)")
      end
    end

    # Whether the rule already sits at the first/last slot of its own scope block, where `move`
    # legitimately answers false without attempting a write.
    private def at_scope_edge?(rule : Store::ColorRule, dir : Int32) : Bool
      scoped = rule_list.select { |r| r.scope == rule.scope }
      i = scoped.index { |r| r.id == rule.id }
      return true unless i
      j = i + (dir < 0 ? -1 : 1)
      j < 0 || j >= scoped.size
    end

    def colormarker_duplicate : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      name = rule.name.empty? ? "" : "#{rule.name} copy"
      unless engine.add(rule.match_filter, rule.color, rule.style, name, scope: rule.scope)
        return @host.status("colour rule NOT duplicated (project busy or settings not writable)")
      end
      @host.status(rule.global? ? "global colour rule duplicated" : "colour rule duplicated")
    end

    # `s`: move the selected rule between the global library and this project.
    def colormarker_scope_toggle : Nil
      rule = selected_rule || return @host.status("no colour rule selected")
      to = rule.global? ? Store::RuleScope::Project : Store::RuleScope::Global
      unless engine.set_scope(rule, to)
        return @host.status("scope NOT changed (project busy or settings not writable) — the rule is unchanged")
      end
      @sel = last_index_of_scope(to)
      @host.status(to.global? ? "colour rule is now GLOBAL — it applies in every project" : "colour rule is now project-scoped")
    end

    def colormarker_reload : Nil
      engine.reload
      @host.status("colour rules reloaded")
    end

    # Commit the rule editor overlay: add a new rule or update the edited one, then re-select it.
    #
    # False KEEPS THE FORM OPEN — `Runner#dispatch_overlay_key` closes the overlay only on a true
    # commit — so a refused write answers false, not merely a status line: the condition, colour
    # and name in the fields are the operator's only copy of what they just typed, and a closed
    # form leaves them retyping it from a one-line toast. Same contract, same reason, as
    # `ProbeController#apply_custom_rule`.
    def apply_color_rule(ov : ColormarkerRuleOverlay) : Bool
      return false unless ov.valid?
      if id = ov.edit_id
        from = ov.edit_scope || Store::RuleScope::Project
        unless engine.update(id, ov.condition, ov.color, ov.style, ov.name, scope: from)
          # Return rather than fall through: `rule_list` still holds the PRE-EDIT row, so the
          # re-home below would move that stale rule to the other scope and succeed, dropping
          # the edit while reporting nothing.
          @host.status("rule NOT saved (project busy or settings not writable) — it is unchanged")
          return false
        end
        if from != ov.scope
          moved = rule_list.find { |r| r.scope == from && r.id == id }
          if moved && !engine.set_scope(moved, ov.scope)
            @host.status("rule saved, but the scope change did not commit — it is still #{from.label}")
          end
        end
      else
        unless engine.add(ov.condition, ov.color, ov.style, ov.name, scope: ov.scope)
          # Report rather than re-select: with nothing added, `last_index_of_scope` would move
          # the highlight onto whatever already sat at the end of that block.
          @host.status("rule NOT added (project busy or settings not writable)")
          return false
        end
        @sel = last_index_of_scope(ov.scope)
      end
      true
    end

    private def last_index_of_scope(scope : Store::RuleScope) : Int32
      idx = rule_list.rindex { |r| r.scope == scope }
      idx || {rule_list.size - 1, 0}.max
    end

    # --- custom-colour actions (colours pane) ---

    def customcolor_add : Nil
      @host.open_colormarker_color_editor(nil)
    end

    def customcolor_edit : Nil
      if c = selected_color
        @host.open_colormarker_color_editor(c)
      else
        @host.status("no custom colour selected")
      end
    end

    def customcolor_delete : Nil
      c = selected_color || return @host.status("no custom colour selected")
      # A colour still named by a rule is NOT cascaded away — those rows fall back to a visible
      # default. The prompt says how many, so the deletion is not a surprise.
      #
      # `engine.rules` is THIS project's merged list (global library + project rules), and the
      # colour being deleted is global, so rules in OTHER projects can name it and are not
      # counted — reaching them would mean opening every project DB from a confirm prompt. The
      # wording says "in this project" rather than implying a total, and the tail is
      # unconditional so a count of zero still does not read as "nothing references this".
      in_use = engine.rules.count { |r| r.color == c.name }
      note = in_use > 0 ? " #{in_use} rule#{in_use == 1 ? "" : "s"} in this project still name it;" : " No rule in this project names it, but"
      note += " rules in other projects may too — those rows fall back to a default colour."
      @host.confirm("DELETE CUSTOM COLOUR", "Delete “#{c.name}”?#{note} This can't be undone.",
        confirm_label: "delete", danger: true) do
        if Settings.delete_colormarker_color(c.name)
          sync_custom_marks
          @color_sel = @color_sel.clamp(0, {custom_colors.size - 1, 0}.max)
          @host.status("custom colour deleted: #{c.name}")
        else
          @host.status("custom colour NOT deleted (settings not writable)")
        end
      end
    end

    # Commit the custom-colour editor. The settings registry is the arbiter of uniqueness and hex
    # validity — a non-nil message means it refused, and the form stays open showing it.
    def apply_custom_color(ov : CustomColorOverlay) : Bool
      err =
        if orig = ov.original_name
          Settings.update_colormarker_color(orig, ov.name, ov.hex)
        else
          Settings.add_colormarker_color(ov.name, ov.hex)
        end
      if err
        @host.status(err)
        return false
      end
      sync_custom_marks
      if idx = custom_colors.index { |c| c.name == ov.name.strip.downcase }
        @focus = :colors if @colors_shown
        @color_sel = idx
      end
      true
    end

    # Re-prime the render-side custom-mark map and bump the Colormarker revision so History
    # repaints — a custom-colour edit changes no rule, so `Colormarker#reload` is what carries
    # the change (its refresh compares the registry too).
    private def sync_custom_marks : Nil
      Theme.set_custom_marks(Settings.colormarker_color_map)
      engine.reload
    end
  end
end
