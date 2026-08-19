require "../tab_controller"
require "../rewriter_view"
require "../text_area"
require "../read_pane"
require "../../store"
require "../../rules"
require "../viewport"

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
      # Soft wrap, matching the PREVIEW INPUT editor above it: the two panes show the same
      # message before and after a rule, so they have to agree about what a row is.
      @out = ReadPane.new(wrap: true)
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

    # …and the FOCUS half of the same question. `rules_sub?` says the list is on screen;
    # this says it is the thing the keyboard is pointed at. Both are needed now that the
    # rule verbs carry real chords: the preview panes sit in the same body, and `d` there
    # would otherwise delete the rule behind them. The menu was already safe by a different
    # route (`command_section` answers :preview, and the verbs are `section: :rules`) — a
    # chord has no section to hide behind.
    def rule_list_focused? : Bool
      @sub == :rules && @focus == :list
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

    # `count` is whichever sub-tab list the caller is about to hand the view — `extract_list`
    # for EXTRACT, `binding_rows` for BINDINGS — so it is by construction the collection the
    # render walks.
    private def ensure_sub_visible(inner : Rect, count : Int32) : Nil
      @sub_scroll = Viewport.scroll_to_show(@sub_sel, @sub_scroll,
        @view.sub_row_capacity(inner), count)
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

    # `count` is `rule_list.size` — the array `render_rules` hands straight to `@view.render`,
    # so the window and the draw walk the same list by construction.
    private def ensure_visible(inner : Rect, count : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@sel, @scroll,
        @view.list_row_capacity(inner, rules_engine.active?), count)
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
      when c == 'x'
        # The one action still dispatched here, and not an oversight: `rewriter.select-line`
        # binds bare `x` in this same SCOPE for the preview pane, and `Keymap#lookup` is keyed
        # by scope alone — a chord on `rewriter.toggle` would shadow one of the two. The
        # keymap has no focus dimension; this method only runs when the LIST has focus, so it
        # is the disambiguator. (Trade-off: `x` alone is not rebindable here.)
        rewriter_toggle
      else
        # a/↵/e/d/⇧X/s/⇧J/⇧K defer to the central keymap, so the rule actions are
        # REBINDABLE and dispatch through the same `available?` gate the space menu uses —
        # which is now focus-aware (`rewriter_rule_list_focused?`), because a chord has no
        # `section:` to keep it away from the preview panes the way the menu entries do.
        # This list and the Colormarker's were the last two rule lists still hand-rolling
        # their keys while the other four bound real chords.
        return false
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

    # Everything below the three pane-crossing arms is `TextArea#handle_motion_key` — the ONE
    # editor keymap (⇧arrows select, Page keys, ⇧Home/⇧End, ⌥/⌃←→ by word, ⌥⌫). This pane was
    # the last TextArea editor still hand-rolling its own arrows, and the hand-rolled set passed
    # no `selecting:` anywhere: it had the MOUSE half of selection (drag + double-click, below)
    # and none of the keyboard half, while the OUTPUT pane beside it had ⇧arrows all along.
    #
    # A crossing arm claims only a BARE press. ⇧ means a selection is mid-build and leaving
    # would abandon it (the same line Notes and the Project description draw), and ⌥←/⌥↑ are
    # word/buffer motions this pane owns — routing them out would make ⌥← at column 0 jump to
    # the rule list instead of stepping back a word.
    private def handle_preview_in_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      ed = @preview_input
      crossing = !ev.shift? && !ev.ctrl? && !ev.alt?
      case
      when key.escape?
        @focus = :list
      when key.up? && crossing && ed.at_top?
        @focus = :list
      when key.down? && crossing && ed.at_bottom?
        @focus = :preview_out
      when key.left? && crossing && ed.at_start?
        @focus = :list
      when key.enter?
        ed.insert_newline
      when ev.ctrl_z?
        ed.undo
        # Before plain ⌫, which would otherwise swallow the modified form as a one-character
        # delete on a terminal that reports ⌥⌫ as Backspace+Alt.
      when ed.word_delete_key?(ev)
        ed.handle_motion_key(ev)
      when key.backspace?
        ed.backspace
      when key.delete?
        ed.delete
      when ed.handle_motion_key(ev)
        # consumed: a caret motion, with or without a selection riding along
      else
        if (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
          # Space included, deliberately: `Key::Space.to_char` is `' '` and `' '.control?` is
          # false, so this arm claims it and types it. There used to be an `elsif key.space?`
          # below opening the space menu — unreachable behind this branch, and correctly so:
          # the sample is an HTTP message, which cannot be typed without spaces. The footer
          # names no `space cmds` here for the same reason.
          ed.insert(c)
          report_replaced(ed.last_replaced) # a printable over a selection REPLACES it
          ed.set_preedit("")
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
        if row = @view.gauge_row_at(inner, mx, my, sub_count)
          @sub_sel = row
        elsif idx = @view.sub_row_at(inner, mx, my, @sub_scroll, sub_count)
          @sub_sel = idx
        end
        return true
      end
      # The RULES list's scroll gauge rides the card's right hairline, which `row_at` excludes.
      if row = @view.rules_gauge_row_at(inner, mx, my, rule_list.size, rules_engine.active?)
        @focus = :list
        @sel = row
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
    # Two panes, two selection models: `@out` is the read-only transform result, `@preview_input`
    # is the editable sample. The INPUT half used to be absent everywhere here, so a ⇧arrow
    # selection built in that editor could be destroyed by the next printable (TextArea#insert
    # cuts it) but never copied. Same shape as RepeaterView#pane_selection?.
    def rewriter_selection_active? : Bool
      return false unless @sub == :rules
      case @focus
      when :preview_out then @out.selection?
      when :preview_in  then @preview_input.selection?
      else                   false
      end
    end

    def rewriter_selection_text : String
      return "" unless @sub == :rules
      case @focus
      when :preview_in then @preview_input.selection_text || @preview_input.text
      when :preview_out
        sync_preview_out
        @out.copy_text
      else ""
      end
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
      sel, text = rewriter_copy_target
      return if text.nil? # not a preview pane — the verb's gate should have caught it
                # "nothing to copy" rather than a silent return: on the INPUT sample `^Y` is the ONLY
                # copy and the footer names it, so an empty pane swallowing the chord reads as a dead
                # key. Every sibling tab's `do_copy` answers here; this one returned.
      return @host.status("nothing to copy") if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end

    # What `rewriter_copy` would put on the clipboard and whether it is a selection, without
    # writing it — the JWT half of this sweep grew `jwt_copy_text` for the same reason: the
    # decision is worth asserting on its own, and `Clipboard.copy` writes OSC 52 to the tty.
    # `nil` text = a focus that has no copy (the rule list).
    #
    # This is NOT `rewriter_selection_text`, which is the "Send selection to" payload and
    # always narrows to the band; a copy with no band falls back to the whole pane.
    def rewriter_copy_target : {Bool, String?}
      return {false, nil} unless @sub == :rules
      case @focus
      when :preview_in
        # The editable sample. `^Y` is the only way to copy a selection here: in INS a bare `y`
        # is a literal character, and typing it REPLACES the selection.
        sel = @preview_input.selection?
        {sel, sel ? @preview_input.selection_text : @preview_input.text}
      when :preview_out
        sync_preview_out
        sel = @out.selection?
        {sel, sel ? @out.copy_text : @out.copy_all}
      else
        {false, nil}
      end
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
        @host.status("no rewrite rule selected")
      end
    end

    def rewriter_delete : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      label = rule.name.empty? ? rule.pattern : rule.name
      # A global rule is deleted out of EVERY project, and the prompt has to say so — the row
      # looks the same as a project rule's apart from one badge, and the confirm is the last
      # place to notice which of the two is about to go.
      note = rule.global? ? " It is a GLOBAL rule — this removes it from every project." : ""
      @host.confirm("DELETE RULE", "Delete “#{label}”?#{note} This can't be undone.",
        confirm_label: "delete", danger: true) do
        # The store's answer, not an assumption: a rolled-back write left the rule rewriting
        # live traffic while this toasted "rule deleted". Both headless surfaces already
        # refuse to say that (`mcp/tools/rules.cr`, `cli/run/rewriter.cr`).
        ok = rules_engine.remove(rule.id, rule.scope)
        @sel = @sel.clamp(0, {rule_list.size - 1, 0}.max)
        @host.status(ok ? "rule deleted: #{label}" : "rule NOT deleted (project busy) — it is still rewriting traffic")
      end
    end

    # `x` toggles the rule HERE. For a project rule that is the row itself; for a global one it
    # is this project's override of the library's default, which is why the toast says where
    # the change lands — the same keypress means "off in this engagement", not "off everywhere"
    # (that is ⇧X / `rewriter_toggle_default`).
    def rewriter_toggle : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      unless rules_engine.toggle(rule.id, rule.scope)
        return @host.status("enable/disable NOT applied (project busy) — the rule is unchanged")
      end
      state = rule.enabled? ? "disabled" : "enabled"
      @host.status(rule.global? ? "global rule #{state} in this project" : "rule #{state}")
    end

    # ⇧X: the global DEFAULT — what every project that has not overridden this rule follows.
    def rewriter_toggle_default : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      return @host.status("only a global rule has a default — this one is project-scoped") unless rule.global?
      unless rules_engine.toggle_default(rule.id)
        return @host.status("default NOT changed (settings not writable) — the rule is unchanged")
      end
      after = rule_list.find { |r| r.global? && r.id == rule.id }
      note = after.try(&.overridden?) ? " (this project still overrides it)" : ""
      @host.status("global rule default flipped for every project#{note}")
    end

    def rewriter_move(dir : Int32) : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      # Only follow the rule when it actually moved: ⇧J on the last GLOBAL rule cannot push it
      # into the project block (that is a scope change, `s`), and walking the cursor there
      # anyway would read as a swap that never happened.
      if rules_engine.move(rule.id, dir, rule.scope)
        move_sel(dir)
      elsif !at_scope_edge?(rule, dir)
        # Not an edge, so the reorder was refused by the store / settings write. Say so: a
        # silent no-op here reads exactly like "the rule is already at the end of its block",
        # and precedence decides which of two rules touching the same header wins — so an
        # operator who stops trying keeps testing against an order that reverts at next start.
        @host.status("precedence NOT changed (project busy or settings not writable)")
      end
    end

    # Whether the rule already sits at the first/last slot of its own SCOPE block, where `move`
    # legitimately answers false without attempting a write. The slice matters: the list renders
    # globals then project rules, so the merged index would read the last global as mid-list and
    # report a busy store for the one refusal that is by design.
    private def at_scope_edge?(rule : Store::MatchRule, dir : Int32) : Bool
      scoped = rule_list.select { |r| r.scope == rule.scope }
      i = scoped.index { |r| r.id == rule.id }
      return true unless i
      j = i + (dir < 0 ? -1 : 1)
      j < 0 || j >= scoped.size
    end

    def rewriter_duplicate : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      name = rule.name.empty? ? "" : "#{rule.name} copy"
      unless rules_engine.add(rule.target, rule.part, rule.pattern, rule.replacement,
               rule.op, rule.match_kind, name, rule.host, rule.body_file, scope: rule.scope)
        return @host.status("rule NOT duplicated (project busy or settings not writable)")
      end
      @host.status(rule.global? ? "global rule duplicated" : "rule duplicated")
    end

    # `s`: move the selected rule between the global library and this project. The rule keeps
    # its fields and the state it has HERE; what changes is who else sees it.
    def rewriter_scope_toggle : Nil
      rule = selected_rule || return @host.status("no rewrite rule selected")
      to = rule.global? ? Store::RuleScope::Project : Store::RuleScope::Global
      unless rules_engine.set_scope(rule, to)
        return @host.status("scope NOT changed (project busy or settings not writable) — the rule is unchanged")
      end
      # The rule moved between the two blocks, so its row moved too — follow it rather than
      # leaving the highlight on whatever slid into its old index. It lands at the END of the
      # destination block (both stores append), which is an exact answer where matching on the
      # fields would pick the wrong twin among duplicates.
      @sel = last_index_of_scope(to)
      @host.status(to.global? ? "rule is now GLOBAL — it applies in every project" : "rule is now project-scoped")
    end

    def rewriter_reload : Nil
      rules_engine.reload
      @host.status("rules reloaded")
    end

    # Commit the editor overlay: add a new rule or update the edited one, then re-select it.
    # The form's `scope:` row is part of the edit — changing it on an existing rule MOVES the
    # rule between the two stores (fields first, then the re-home, so a refused move leaves
    # the edit applied rather than silently dropping both halves).
    def apply_rewriter_rule(ov : RewriterRuleOverlay) : Bool
      return false unless ov.valid?
      if id = ov.edit_id
        from = ov.edit_scope || Store::RuleScope::Project
        unless rules_engine.update(id, ov.target, ov.part, ov.pattern, ov.replacement,
                 ov.op, ov.match_kind, ov.name, ov.host, ov.body_file, scope: from)
          @host.status("rule NOT saved (project busy or settings not writable) — it is unchanged")
          return true
        end
        if from != ov.scope
          moved = rule_list.find { |r| r.scope == from && r.id == id }
          if moved && !rules_engine.set_scope(moved, ov.scope)
            @host.status("rule saved, but the scope change did not commit — it is still #{from.label}")
          end
        end
      else
        unless rules_engine.add(ov.target, ov.part, ov.pattern, ov.replacement,
                 ov.op, ov.match_kind, ov.name, ov.host, ov.body_file, scope: ov.scope)
          # Report rather than re-select: with nothing added, `last_index_of_scope` would
          # move the highlight onto whatever already sat at the end of that block.
          @host.status("rule NOT added (project busy or settings not writable)")
          return true
        end
        # A global rule lands at the end of the GLOBAL block, which is not the end of the list.
        @sel = last_index_of_scope(ov.scope)
      end
      true
    end

    private def last_index_of_scope(scope : Store::RuleScope) : Int32
      idx = rule_list.rindex { |r| r.scope == scope }
      idx || {rule_list.size - 1, 0}.max
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
      @host.confirm("DELETE EXTRACT RULE", "Delete “$#{rule.name}”? Its binding is forgotten too.",
        confirm_label: "delete", danger: true) do
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
        # This pane is ALWAYS typing — there is no READ mode to fall back to — so `^Y` is not
        # merely the INS spelling of copy here, it is the only one (`rewriter_copy`'s
        # `:preview_in` arm says the same). The footer named neither the band nor the key.
        "type sample HTTP · ⇧arrows select · ^Y copy · ↑ list · ↓/→ output · esc list"
      when :preview_out
        "↑/↓ move · ⇧arrows select · y copy · x line · space cmds · ← input · esc input"
      else
        "[/] sub-tab · ↑/↓ select · a add · ↵/e edit · x on/off · s global/project · d delete · ⇧K/⇧J reorder · esc tabs"
      end
    end
  end
end
