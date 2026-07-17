require "../tab_controller"
require "../rewriter_view"
require "../../store"
require "../../rules"

module Gori::Tui
  # The Rewriter tab: manage the project's Match & Replace rules (the shared Rules engine
  # the proxy reads live). A single global list — no sub-tabs. The body is a navigable
  # list; add/edit opens the RewriterRuleOverlay (a modal, wired in the runner like the
  # Probe custom-rule editor). Rules do far more than the old palette overlay: literal or
  # regex replace on head/body, add/set/remove header by name, and an optional host scope.
  class RewriterController < TabController
    def initialize(host : Host)
      super(host)
      @view = RewriterView.new
      @sel = 0
      @scroll = 0
    end

    def tab : Symbol
      :rewriter
    end

    def command_scope : Verb::Scope
      Verb::Scope::Rewriter
    end

    def body_badge : Symbol
      :body
    end

    private def rules_engine : Rules
      @host.session.rules
    end

    private def rule_list : Array(Store::MatchRule)
      rules_engine.rules
    end

    # Pull external (MCP / other-instance) rule edits when the tab becomes active.
    def on_enter : Nil
      rules_engine.reload
      @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
    end

    def on_external_change : Nil
      rules_engine.reload
    end

    def selected_rule : Store::MatchRule?
      rule_list[@sel]?
    end

    # --- render ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      BodyChrome.framed(screen, rect, shell) do |inner|
        list = rule_list
        @sel = @sel.clamp(0, {list.size - 1, 0}.max)
        ensure_visible(inner, list.size)
        @view.render(screen, inner, list, @sel, @scroll, rules_engine.enabled_count, body_focused, rules_engine.active?)
      end
    end

    # Rows visible in the list area (inner minus header, minus the live note row).
    private def list_height(inner : Rect) : Int32
      h = inner.h - RewriterView::HEADER_H
      h -= 1 if rules_engine.active?
      {h, 0}.max
    end

    private def ensure_visible(inner : Rect, count : Int32) : Nil
      lh = list_height(inner)
      return if lh <= 0
      if @sel < @scroll
        @scroll = @sel
      elsif @sel >= @scroll + lh
        @scroll = @sel - lh + 1
      end
      @scroll = @scroll.clamp(0, {count - lh, 0}.max)
    end

    # --- keys ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.space? && !ev.ctrl? && !ev.alt? then @host.open_space_menu
      when key.up?, c == 'k'                   then move_up
      when key.down?, c == 'j'                 then move_sel(1)
      when key.escape?                         then @host.request_focus(:menu)
      else                                          return handle_action_key(ev, c)
      end
      true
    end

    # ↑/k at the top of the list releases focus back to the tab bar (like the Intercept
    # queue); otherwise it moves the selection up.
    private def move_up : Nil
      if @sel <= 0
        @host.request_focus(:menu)
      else
        move_sel(-1)
      end
    end

    # The rule-action keys, split out to keep handle_body_key's branching low.
    private def handle_action_key(ev : Termisu::Event::Key, c : Char?) : Bool
      key = ev.key
      case
      when key.enter?, c == 'e' then rewriter_edit
      when c == 'a'             then rewriter_add
      when c == 'd'             then rewriter_delete
      when c == 'x'             then rewriter_toggle
      when c == 'J'             then rewriter_move(1)
      when c == 'K'             then rewriter_move(-1)
      else                           return false
      end
      true
    end

    private def move_sel(d : Int32) : Nil
      n = rule_list.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = BodyChrome.frame_inner(rect)
      if idx = @view.row_at(inner, mx, my, @scroll, rule_list.size, rules_engine.active?)
        @sel = idx
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      move_sel(step)
      true
    end

    # --- actions (also reached via the Rewriter verbs) ---
    def rewriter_add : Nil
      @host.open_rewriter_rule_editor(nil)
    end

    def rewriter_edit : Nil
      if rule = selected_rule
        @host.open_rewriter_rule_editor(rule)
      else
        @host.status("no rule selected")
      end
    end

    def rewriter_delete : Nil
      rule = selected_rule || return @host.status("no rule selected")
      label = rule.name.empty? ? rule.pattern : rule.name
      @host.confirm("Delete rule", "Delete “#{label}”? This can't be undone.",
        confirm_label: "Delete", danger: true) do
        rules_engine.remove(rule.id)
        @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
        @host.status("rule deleted")
      end
    end

    def rewriter_toggle : Nil
      rule = selected_rule || return @host.status("no rule selected")
      rules_engine.toggle(rule.id)
      @host.status(rule.enabled? ? "rule disabled" : "rule enabled")
    end

    def rewriter_move(dir : Int32) : Nil
      rule = selected_rule || return @host.status("no rule selected")
      rules_engine.move(rule.id, dir)
      move_sel(dir)
    end

    def rewriter_duplicate : Nil
      rule = selected_rule || return @host.status("no rule selected")
      name = rule.name.empty? ? "" : "#{rule.name} copy"
      rules_engine.add(rule.target, rule.part, rule.pattern, rule.replacement,
        rule.op, rule.match_kind, name, rule.host)
      @host.status("rule duplicated")
    end

    def rewriter_reload : Nil
      rules_engine.reload
      @host.status("rules reloaded")
    end

    # Commit the editor overlay: add a new rule or update the edited one, then re-select it.
    def apply_rewriter_rule(ov : RewriterRuleOverlay) : Bool
      return false unless ov.valid?
      if id = ov.edit_id
        rules_engine.update(id, ov.target, ov.part, ov.pattern, ov.replacement,
          ov.op, ov.match_kind, ov.name, ov.host)
      else
        rules_engine.add(ov.target, ov.part, ov.pattern, ov.replacement,
          ov.op, ov.match_kind, ov.name, ov.host)
        @sel = {rule_list.size - 1, 0}.max
      end
      true
    end

    def body_hint(focus : Symbol) : String
      "↑/↓ select · a add · ↵/e edit · x on/off · d delete · ⇧J/⇧K reorder · space cmds · esc tabs"
    end
  end
end
