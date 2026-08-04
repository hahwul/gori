require "../tab_controller"
require "../rewriter_view"
require "../text_area"
require "../read_pane"
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
      # `rules` writes a value, `extract` reads one, `bindings` says whether the read worked.
      # One workflow, one body, three sub-tabs — see RewriterView::SUBS.
      @sub = :rules
      @sub_sel = 0
      @sub_scroll = 0
      @focus = :list # :list | :preview_in | :preview_out
      # The sample is per PROJECT (the rules it previews already are): an operator pastes a
      # real captured request in here, so it must not follow them into the next project.
      # Absent from the store = never edited here → the demo default.
      sample = @host.session.store.setting(Store::REWRITER_SAMPLE_KEY) || DEFAULT_SAMPLE
      @preview_input = TextArea.new(sample)
      @saved_sample = @preview_input.text # what the store holds, in the form `commit` compares
      # The transformed sample: caret, selection, both scroll axes and its whole draw. No gutter
      # — these rows are a rewritten MESSAGE, and the sample's own line numbers would only
      # invite the reader to map them onto the input pane, which a head/body rewrite can shift.
      @out = ReadPane.new
      @last_body = Rect.new(0, 0, 0, 0) # last content rect — click/wheel geometry
    end

    def tab : Symbol
      :rewriter
    end

    def command_scope : Verb::Scope
      Verb::Scope::Rewriter
    end

    # The focus area the space menu shows alongside COMMON. `:preview` while either preview pane
    # holds focus, `:rules` otherwise — so the rule actions are offered where a rule is selected
    # and the read actions where there is text to select, and neither view repeats a letter.
    def command_section : Symbol
      @sub == :rules && (@focus == :preview_in || @focus == :preview_out) ? :preview : :rules
    end

    def body_badge : Symbol
      @focus == :preview_in ? :editor : :body
    end

    private def rules_engine : Rules
      @host.session.rules
    end

    private def bindings : Bindings
      @host.session.bindings
    end

    private def rule_list : Array(Store::MatchRule)
      rules_engine.rules
    end

    private def extract_list : Array(Store::ExtractRule)
      bindings.rules
    end

    private def binding_rows : Array(Bindings::Row)
      bindings.rows
    end

    private def sub_count : Int32
      @sub == :extract ? extract_list.size : binding_rows.size
    end

    # Pull external (MCP / other-instance) rule edits when the tab becomes active.
    def on_enter : Nil
      rules_engine.reload
      bindings.reload
      @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
    end

    def on_external_change : Nil
      rules_engine.reload
      bindings.reload
    end

    # Flush an edited preview sample to the project store on leave/quit. Compared against the
    # last value known to be stored rather than tracked with a dirty flag: every edit path
    # funnels through this one TextArea, so the comparison cannot miss a site — and an
    # untouched sample never writes a row. A failed write leaves @saved_sample alone, so the
    # next leave retries.
    def commit : Nil
      text = @preview_input.text
      return if text == @saved_sample
      @saved_sample = text if @host.session.store.set_setting(Store::REWRITER_SAMPLE_KEY, text)
    end

    def selected_rule : Store::MatchRule?
      rule_list[@sel]?
    end

    # Whether the RULES sub-tab is the one on screen. One workflow, three sub-tabs, and only
    # this one renders `rule_list` — so `selected_rule` alone is not "a rule the operator can
    # see", which is what the Rewriter verbs' `available:` predicates have to mean.
    def rules_sub? : Bool
      @sub == :rules
    end

    # --- render ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      BodyChrome.framed(screen, rect, shell) do |inner|
        @last_body = inner
        case @sub
        when :extract  then render_extract(screen, inner, body_focused)
        when :bindings then render_bindings(screen, inner, body_focused)
        else                render_rules(screen, inner, body_focused)
        end
      end
    end

    private def render_rules(screen : Screen, inner : Rect, body_focused : Bool) : Nil
      list = rule_list
      @sel = @sel.clamp(0, {list.size - 1, 0}.max)
      ensure_visible(inner, list.size)
      sync_preview_out
      @view.render(screen, inner, list, @sel, @scroll, rules_engine.enabled_count,
        @focus, body_focused, rules_engine.active?, @preview_input, @out)
    end

    private def render_extract(screen : Screen, inner : Rect, body_focused : Bool) : Nil
      rules = extract_list
      bound = Set(String).new
      binding_rows.each { |r| bound << r.name if r.bound? }
      @sub_sel = @sub_sel.clamp(0, {rules.size - 1, 0}.max)
      ensure_sub_visible(inner, rules.size)
      @view.render_extract(screen, inner, rules, bound, @sub_sel, @sub_scroll, body_focused)
    end

    private def render_bindings(screen : Screen, inner : Rect, body_focused : Bool) : Nil
      rows = binding_rows
      @sub_sel = @sub_sel.clamp(0, {rows.size - 1, 0}.max)
      ensure_sub_visible(inner, rows.size)
      @view.render_bindings(screen, inner, rows, @sub_sel, @sub_scroll, body_focused, Time.utc)
    end

    private def ensure_sub_visible(inner : Rect, count : Int32) : Nil
      lh = @view.sub_row_capacity(inner)
      return if lh <= 0
      if @sub_sel < @sub_scroll
        @sub_scroll = @sub_sel
      elsif @sub_sel >= @sub_scroll + lh
        @sub_scroll = @sub_sel - lh + 1
      end
      @sub_scroll = @sub_scroll.clamp(0, {count - lh, 0}.max)
    end

    # ⇥ / ⇧⇥ cycles the sub-tab strip. Selection and scroll reset because the three lists
    # are unrelated — carrying row 7 from `rules` into a two-row `bindings` list would be a
    # selection the operator never made.
    private def cycle_sub(d : Int32) : Nil
      i = RewriterView::SUBS.index(@sub) || 0
      @sub = RewriterView::SUBS[(i + d) % RewriterView::SUBS.size]
      @sub_sel = 0
      @sub_scroll = 0
      @focus = :list
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

    # Point the OUTPUT pane at the current transform. Recomputed rather than cached, exactly as
    # the old per-frame `preview_output` call was — `transform_message` over one sample is cheap
    # next to a frame, and any cache key would have to track the sample AND every enabled rule.
    # Called from `render_rules` and from each selection/copy delegator, so a verb never reads a
    # pane pointed at a stale transform.
    private def sync_preview_out : Nil
      text = preview_output
      @out.source(text.empty? ? ["(empty)"] : text.split('\n'))
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
      # `[` / `]` switch sub-tabs from ANY focus in the body, including the preview editor:
      # the strip is the body's own navigation and must not be reachable only from the list.
      #
      # NOT ⇥. The shell owns Tab/BackTab for its focus cycle and says so at the gate
      # (`runner.cr`: "wins over the per-tab body editors below — Repeater used to hijack
      # Tab"), so a body binding for it never fires. Driving the built TUI is what showed
      # that: ⇥ moved focus to the tab bar and back, and the sub-tab never changed.
      c = ev.char || ev.key.to_char
      if !ev.ctrl? && !ev.alt? && (c == ']' || c == '[')
        cycle_sub(c == ']' ? 1 : -1)
        return true
      end
      return handle_sub_key(ev) unless @sub == :rules
      case @focus
      when :preview_in  then handle_preview_in_key(ev)
      when :preview_out then handle_preview_out_key(ev)
      else                   handle_list_key(ev)
      end
    end

    # The `extract` and `bindings` sub-tabs share one list model: they are both a flat,
    # unordered list (extraction produces no bytes, so extract rules have no position to
    # reorder), so neither offers ⇧J/⇧K.
    private def handle_sub_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.space? && !ev.ctrl? && !ev.alt? then @host.open_space_menu
      when key.escape?                         then @host.request_focus(:menu)
      when key.up?, c == 'k'
        @sub_sel <= 0 ? @host.request_focus(:menu) : (@sub_sel -= 1)
      when key.down?, c == 'j'
        @sub_sel = (@sub_sel + 1).clamp(0, {sub_count - 1, 0}.max)
      else
        return handle_sub_action_key(key, c)
      end
      true
    end

    private def handle_sub_action_key(key : Termisu::Input::Key, c : Char?) : Bool
      if @sub == :bindings
        return false unless c == 'd'
        binding_clear
        return true
      end
      case
      when key.enter?, c == 'e' then extract_edit
      when c == 'a'             then extract_add
      when c == 'd'             then extract_delete
      when c == 'x'             then extract_toggle
      else                           return false
      end
      true
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
      # ⇧←/→ grow the selection sideways, and they are checked BEFORE the bare ← that leaves for
      # the INPUT pane — inside the `case` below that arm claims EVERY left press, shifted or not,
      # so ⇧← left the pane instead of selecting. (ameba's Lint/DuplicateWhenCondition is what
      # named it: the later `when key.left?` was unreachable.) Same ordering the Comparer's
      # `handle_body_hscroll` and the Repeater use, for the same reason.
      if ev.shift? && (key.left? || key.right?)
        @out.move(0, key.left? ? -1 : 1, selecting: true)
        return true
      end
      case
      when key.escape?, key.left? then @focus = :preview_in
      when key.up?, key.lower_k?
        # At the top the ↑ crosses back to the INPUT editor, as it always did; below it the
        # caret steps, so ⇧↑ can grow a selection the way it does in every other read pane.
        @out.at_top? ? (@focus = :preview_in) : @out.move(-1, 0, selecting: ev.shift?)
      when key.down?, key.lower_j? then @out.move(1, 0, selecting: ev.shift?)
      when key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
      else
        return @out.motion_key(ev) # Home / End / PgUp / PgDn, ⇧ extending
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
      if s = @view.sub_at(inner, mx, my)
        unless s == @sub
          @sub = s
          @sub_sel = 0
          @sub_scroll = 0
          @focus = :list
        end
        return true
      end
      unless @sub == :rules
        if idx = @view.sub_row_at(inner, mx, my, @sub_scroll, sub_count)
          @sub_sel = idx
        end
        return true
      end
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
        body = @view.preview_output_body(inner)
        sync_preview_out
        @out.click(body, mx, my) unless body.empty?
      end
      true
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # The OUTPUT pane only: the rule list selects rows and the INPUT editor is a TextArea the
    # shell already drags through its own arm below.
    def supports_drag? : Bool
      @sub == :rules && (@focus == :preview_in || @focus == :preview_out)
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      inner = BodyChrome.frame_inner(rect)
      case @focus
      when :preview_in
        body = @view.preview_input_body(inner)
        @preview_input.click_to_cursor(body, mx, my, selecting: true) unless body.empty?
      when :preview_out
        body = @view.preview_output_body(inner)
        return if body.empty?
        sync_preview_out
        @out.click(body, mx, my, selecting: true)
      end
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = BodyChrome.frame_inner(rect)
      case @focus
      when :preview_in
        body = @view.preview_input_body(inner)
        body.empty? ? false : @preview_input.select_word_at(body, mx, my)
      when :preview_out
        body = @view.preview_output_body(inner)
        return false if body.empty?
        sync_preview_out
        @out.select_word(body, mx, my)
      else false
      end
    end

    # --- READ-pane delegators (the Rewriter verbs + the Runner's read_* ladders) ---
    def rewriter_selection_active? : Bool
      @sub == :rules && @focus == :preview_out && @out.selection?
    end

    def rewriter_selection_text : String
      return "" unless @sub == :rules && @focus == :preview_out
      sync_preview_out
      @out.copy_text
    end

    def rewriter_select_line : Nil
      return unless @sub == :rules && @focus == :preview_out
      sync_preview_out
      @out.select_line
    end

    def rewriter_clear_selection : Nil
      @out.clear_selection
    end

    # `y`: the selection, or the whole transformed sample when nothing is selected. The pane is
    # the only place the post-rewrite bytes exist — the sample in the store is the INPUT.
    # Same `Clipboard.copy` + status shape every other tab's copy verb uses, so the toast reads
    # the same and the OSC-52 truncation note is not re-derived here.
    def rewriter_copy : Nil
      return unless @sub == :rules && @focus == :preview_out
      sync_preview_out
      sel = @out.selection?
      text = sel ? @out.copy_text : @out.copy_all
      return if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text.bytesize)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end

    # True while the OUTPUT pane is the focused one — the `available:` gate for its read verbs.
    def rewriter_preview_out_focused? : Bool
      @sub == :rules && @focus == :preview_out
    end

    def handle_wheel(step : Int32) : Bool
      unless @sub == :rules
        @sub_sel = (@sub_sel + step).clamp(0, {sub_count - 1, 0}.max)
        return true
      end
      case @focus
      when :preview_in  then @preview_input.scroll_view(step)
      when :preview_out then sync_preview_out; @out.scroll_view(step)
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
        # The store's answer, not an assumption: a rolled-back write left the rule rewriting
        # live traffic while this toasted "rule deleted". Both headless surfaces already
        # refuse to say that (`mcp/tools/rules.cr`, `cli/run/rewriter.cr`).
        ok = rules_engine.remove(rule.id)
        @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
        @host.status(ok ? "rule deleted" : "rule NOT deleted (project busy) — it is still rewriting traffic")
      end
    end

    def rewriter_toggle : Nil
      rule = selected_rule || return @host.status("no rule selected")
      unless rules_engine.toggle(rule.id)
        return @host.status("enable/disable NOT applied (project busy) — the rule is unchanged")
      end
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

    # --- the global rule-preset library (settings.json `rewriter.presets`) ---------------
    # The shell owns the two modals (Runner#open_rule_preset_save / #open_rule_preset_load);
    # these are the halves that touch the rule set.

    # Copy the rule's FIELDS into the library under `name`. A preset is a recipe, so what
    # does NOT travel is as deliberate as what does: no id (it names a row in THIS project's
    # DB), no position (apply order is a property of a list, not of one rule) and no enabled
    # state (see load_rule_preset).
    def save_rule_preset(rule : Store::MatchRule, name : String) : Nil
      if name.empty?
        @host.status("rule name required")
        return
      end
      ok, existing = Settings.save_rewriter_preset(name, rule.target.label, rule.part.label,
        rule.pattern, rule.replacement, rule.op.label, rule.match_kind.label,
        rule.host, rule.body_file)
      unless ok
        @host.status("could not save rule to the library")
        return
      end
      @host.status(existing ? "updated saved rule \"#{name}\"" : "saved rule \"#{name}\" to the library")
    end

    # APPEND the preset as a new rule in this project — never a merge, never a replacement
    # of the current list. One preset is one rule precisely so loading needs no policy: it
    # lands at the end of the apply order, where `u`/`n` can move it, and the rules already
    # there are untouched.
    #
    # It arrives ENABLED, like Duplicate and like the editor's Add, so "load" means the same
    # thing every other way of putting a rule in this list means. That does start rewriting
    # live traffic, which is why the toast names the rule instead of just saying "loaded".
    def load_rule_preset(preset : Settings::RulePreset) : Nil
      r = preset.to_rule
      rules_engine.add(r.target, r.part, r.pattern, r.replacement,
        r.op, r.match_kind, r.name, r.host, r.body_file)
      # `add` refuses an empty pattern silently; the parse layer drops those, so a preset can
      # never carry one — but select the row by COUNT rather than assuming, so a future
      # refusal can't leave the cursor pointing past the end.
      @sel = {rule_list.size - 1, 0}.max
      @host.status("added rule \"#{preset.name}\" from the library")
    end

    # Commit the editor overlay: add a new rule or update the edited one, then re-select it.
    def apply_rewriter_rule(ov : RewriterRuleOverlay) : Bool
      return false unless ov.valid?
      if id = ov.edit_id
        rules_engine.update(id, ov.target, ov.part, ov.pattern, ov.replacement,
          ov.op, ov.match_kind, ov.name, ov.host, ov.body_file)
      else
        rules_engine.add(ov.target, ov.part, ov.pattern, ov.replacement,
          ov.op, ov.match_kind, ov.name, ov.host, ov.body_file)
        @sel = {rule_list.size - 1, 0}.max
      end
      true
    end

    # --- extract sub-tab actions (#501) ---

    def selected_extract_rule : Store::ExtractRule?
      extract_list[@sub_sel]?
    end

    def extract_add : Nil
      @host.open_extract_rule_editor(nil)
    end

    def extract_edit : Nil
      if rule = selected_extract_rule
        @host.open_extract_rule_editor(rule)
      else
        @host.status("no extract rule selected")
      end
    end

    def extract_toggle : Nil
      rule = selected_extract_rule || return @host.status("no extract rule selected")
      unless bindings.toggle(rule.id)
        return @host.status("enable/disable NOT applied (project busy) — the extract rule is unchanged")
      end
      # Disabling the WRITER also un-declares the name, so a rewrite rule naming it goes
      # back to refusing rather than injecting a value nothing is refreshing any more.
      @host.status(rule.enabled? ? "$#{rule.name} extract rule disabled" : "$#{rule.name} extract rule enabled")
    end

    def extract_delete : Nil
      rule = selected_extract_rule || return @host.status("no extract rule selected")
      @host.confirm("Delete extract rule", "Delete “$#{rule.name}”? Its binding is forgotten too.",
        confirm_label: "Delete", danger: true) do
        ok = bindings.remove(rule.id)
        @sub_sel = @sub_sel.clamp(0, {extract_list.size - 1, 0}.max)
        @host.status(ok ? "extract rule deleted" : "extract rule NOT deleted (project busy) — it is still observing responses")
      end
    end

    # Forget one bound value without touching its rule — the next send naming it refuses
    # instead of going out with a stale token, which is the point of having the action.
    def binding_clear : Nil
      row = binding_rows[@sub_sel]? || return @host.status("no binding selected")
      return @host.status("$#{row.name} is not bound") unless row.bound?
      bindings.clear(row.name)
      @host.status("$#{row.name} cleared")
    end

    # Commit the extract-rule editor overlay. Returns false — and says why — when the table
    # refuses the rule (a duplicate name, an uncompilable regex), so the form stays open.
    def apply_extract_rule(ov : ExtractRuleOverlay) : Bool
      # `apply_rewriter_rule`'s guard, which this one was missing: the overlay's own
      # `invalid_reason` catches the local shape (an empty name, a missing selector, a
      # `position` range whose end is not past its start) and the Save row already renders it,
      # but Enter committed anyway — so a rule the form said was incomplete was persisted.
      return false unless ov.valid?
      err =
        if id = ov.edit_id
          bindings.update(id, ov.name, ov.match_filter, ov.kind, ov.selector,
            ov.pos_start, ov.pos_end, ov.host)
        else
          bindings.add(ov.name, ov.match_filter, ov.kind, ov.selector,
            ov.pos_start, ov.pos_end, ov.host)
        end
      if err
        @host.status(err)
        return false
      end
      @sub = :extract
      @sub_sel = {extract_list.index { |r| r.name == ov.name } || 0, 0}.max
      true
    end

    def body_hint(focus : Symbol) : String
      case @sub
      when :extract
        return "[/] sub-tab · ↑/↓ select · a add · ↵/e edit · x on/off · d delete · space cmds · esc tabs"
      when :bindings
        return "[/] sub-tab · ↑/↓ select · d clear · space cmds · esc tabs"
      end
      case @focus
      when :preview_in
        "type sample HTTP · ↑ list · ↓/→ output · esc list"
      when :preview_out
        "↑/↓ move · ⇧arrows select · y copy · x line · space cmds · ← input · esc input"
      else
        "[/] sub-tab · ↑/↓ select · ↓ preview · a add · ↵/e edit · x on/off · d delete · ⇧J/⇧K reorder · esc tabs"
      end
    end
  end
end
