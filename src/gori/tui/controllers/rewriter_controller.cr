require "../tab_controller"
require "../rewriter_view"
require "../text_area"
require "../../store"
require "../../rules"

module Gori::Tui
  # The Rewriter tab: manage the project's Match & Replace rules (the shared Rules engine
  # the proxy reads live). A global list on top + a Caido-style live preview pair below
  # (editable sample HTTP | transformed by enabled rules). Add/edit opens the
  # RewriterRuleOverlay (modal, wired in the runner like the Probe custom-rule editor).
  class RewriterController < TabController
    # Default sample so a new project can demo head/body/header rules without pasting.
    DEFAULT_SAMPLE = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: gori\r\nCookie: session=REPLACE_ME\r\n\r\nhello world\r\n"

    def initialize(host : Host)
      super(host)
      @view = RewriterView.new
      @sel = 0
      @scroll = 0
      @focus = :list # :list | :preview_in | :preview_out
      @preview_input = TextArea.new(DEFAULT_SAMPLE)
      @out_scroll = 0
      @last_body = Rect.new(0, 0, 0, 0) # last content rect — click/wheel geometry
    end

    def tab : Symbol
      :rewriter
    end

    def command_scope : Verb::Scope
      Verb::Scope::Rewriter
    end

    def body_badge : Symbol
      @focus == :preview_in ? :editor : :body
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
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      BodyChrome.framed(screen, rect, shell) do |inner|
        @last_body = inner
        list = rule_list
        @sel = @sel.clamp(0, {list.size - 1, 0}.max)
        ensure_visible(inner, list.size)
        @view.render(screen, inner, list, @sel, @scroll, rules_engine.enabled_count,
          @focus, body_focused, rules_engine.active?, @preview_input, preview_output, @out_scroll)
      end
    end

    private def ensure_visible(inner : Rect, count : Int32) : Nil
      lh = @view.list_row_capacity(inner, rules_engine.active?)
      return if lh <= 0
      if @sel < @scroll
        @scroll = @sel
      elsif @sel >= @scroll + lh
        @scroll = @sel - lh + 1
      end
      @scroll = @scroll.clamp(0, {count - lh, 0}.max)
    end

    # Enabled rules applied to the sample (request side; host from Host: header).
    private def preview_output : String
      text = @preview_input.text
      host = host_from_sample(text)
      rules_engine.transform_message(text, Store::RuleTarget::Request, host)
    end

    private def host_from_sample(text : String) : String
      text.each_line do |ln|
        # Allow both "Host:" and "host:" (HTTP/2-style lowercasing in samples).
        if ln.size >= 5 && ln[0, 5].downcase == "host:"
          return ln[5..].strip
        end
      end
      ""
    end

    # --- keys ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      case @focus
      when :preview_in  then handle_preview_in_key(ev)
      when :preview_out then handle_preview_out_key(ev)
      else                   handle_list_key(ev)
      end
    end

    private def handle_list_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.space? && !ev.ctrl? && !ev.alt? then @host.open_space_menu
      when key.up?, c == 'k'                   then move_up
      when key.down?, c == 'j'                 then list_down
      when key.escape?                         then @host.request_focus(:menu)
      else                                          return handle_action_key(ev, c)
      end
      true
    end

    # ↓ past the last rule (or empty list) enters the preview input when shown.
    private def list_down : Nil
      n = rule_list.size
      if n == 0 || @sel >= n - 1
        enter_preview_in if preview_available?
      else
        move_sel(1)
      end
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

    private def handle_preview_in_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      ed = @preview_input
      case
      when key.escape?
        @focus = :list
      when key.up?
        ed.at_top? ? (@focus = :list) : ed.move(-1, 0)
      when key.down?
        ed.at_bottom? ? (@focus = :preview_out) : ed.move(1, 0)
      when key.left?
        ed.at_start? ? (@focus = :list) : ed.move(0, -1)
      when key.right?
        ed.move(0, 1)
      when key.enter?
        ed.insert_newline
      when key.backspace?
        ed.backspace
      when key.delete?
        ed.delete
      when key.home?
        ed.home
      when key.end?
        ed.end_of_line
      when ev.ctrl_z?
        ed.undo
      else
        if (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
          ed.insert(c)
          ed.set_preedit("")
        elsif key.space? && !ev.ctrl? && !ev.alt?
          @host.open_space_menu
        else
          return false
        end
      end
      true
    end

    private def handle_preview_out_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.escape?, key.left? then @focus = :preview_in
      when key.up?, key.lower_k?
        if @out_scroll <= 0
          @focus = :preview_in
        else
          @out_scroll = {@out_scroll - 1, 0}.max
        end
      when key.down?, key.lower_j?
        @out_scroll += 1
      when key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
      else
        return false
      end
      true
    end

    private def move_sel(d : Int32) : Nil
      n = rule_list.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    private def preview_available? : Bool
      return false if @last_body.empty?
      @view.preview_shown?(@last_body)
    end

    private def enter_preview_in : Nil
      return unless preview_available?
      @focus = :preview_in
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = BodyChrome.frame_inner(rect)
      @last_body = inner
      case @view.pane_at(inner, mx, my)
      when :list
        @focus = :list
        if idx = @view.row_at(inner, mx, my, @scroll, rule_list.size, rules_engine.active?)
          @sel = idx
        end
      when :preview_in
        @focus = :preview_in
        body = @view.preview_input_body(inner)
        @preview_input.click_to_cursor(body, mx, my) unless body.empty?
      when :preview_out
        @focus = :preview_out
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      case @focus
      when :preview_in  then @preview_input.scroll_view(step)
      when :preview_out then @out_scroll = {@out_scroll + step, 0}.max
      else                   move_sel(step)
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @focus == :preview_in
      @preview_input.set_preedit(text)
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
      case @focus
      when :preview_in
        "type sample HTTP · ↑ list · ↓/→ output · esc list"
      when :preview_out
        "↑/↓ scroll · ← input · esc input"
      else
        "↑/↓ select · ↓ preview · a add · ↵/e edit · x on/off · d delete · ⇧J/⇧K reorder · space cmds · esc tabs"
      end
    end
  end
end
