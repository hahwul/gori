require "../tab_controller"
require "../probe_view"
require "../probe_rules_view"
require "../custom_rule_overlay"
require "../../store"
require "../../probe"
require "../../settings"
require "../../hotkeys"

module Gori::Tui
  # The Probe tab: the grouped scan-issue list + a per-issue detail (affected URLs,
  # remediation, sample evidence). Owns ProbeView and drains the Session analyzer's events
  # (issue persisted → reload; active reflection → notification). Modeled on
  # IssuesController: navigation/open/filter/mode are scoped VERBS dispatched centrally;
  # only the `/` filter editing is a controller-claimed text sub-mode. The MODE and
  # set-status pickers are shell overlays (ChoicePicker), so they stay in the Runner.
  class ProbeController < TabController
    # The two fixed sub-tabs: the scan results/mode view, and the rule-management view.
    SUBTABS = ["Findings", "Rules"]

    def initialize(host : Host)
      super(host)
      @probe = ProbeView.new
      @probe.set_scope(@host.session.scope) # honour the lens + show its chip on the bar
      @rules = ProbeRulesView.new
      @sub_idx = 0 # 0 = Findings · 1 = Rules
    end

    def view : ProbeView
      @probe
    end

    def tab : Symbol
      :probe
    end

    # Findings drives the scan-issue verbs (Probe / ProbeDetail); Rules is its own scope so
    # none of the Findings verbs (mode/filter/open) fire there — its actions are ProbeRules verbs.
    def command_scope : Verb::Scope
      return Verb::Scope::ProbeRules if @sub_idx == 1
      @probe.detail_open? ? Verb::Scope::ProbeDetail : Verb::Scope::Probe
    end

    # --- fixed sub-tab strip (no ^N/^W/rename) ---
    def subtab_labels : Array(String)
      SUBTABS
    end

    def subtab_index : Int32
      @sub_idx
    end

    def subtab_strip_shown? : Bool
      true
    end

    def subtabs_fixed? : Bool
      true
    end

    def move_subtab(dir : Int32) : Nil
      @sub_idx = (@sub_idx + dir).clamp(0, SUBTABS.size - 1)
    end

    def jump_subtab(idx : Int32) : Nil
      @sub_idx = idx if 0 <= idx < SUBTABS.size
    end

    def rules_tab? : Bool
      @sub_idx == 1
    end

    # PageUp/PageDown/Home/End: page the open issue's detail body, else the issue list.
    # Both the view's move and scroll_detail clamp (scroll_detail's ceiling lands at
    # render), so the large Home/End magnitude is safe.
    def body_scroll(delta : Int32) : Bool
      if rules_tab?
        @rules.move(delta)
      else
        @probe.detail_open? ? @probe.scroll_detail(delta) : @probe.move(delta)
      end
      true
    end

    def body_badge : Symbol
      :body # read-only/navigable list + detail (no inline text editor)
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      mode = Hotkeys.binding_label(reg, "probe.mode", "m")
      filt = Hotkeys.binding_label(reg, "probe.filter", "/")
      if rules_tab?
        return "↑/↓ move · ↵/x toggle · a add · e edit · d delete · space cmds · ↑ sub-tabs · esc tabs"
      elsif @probe.detail_open?
        "o flow · r repeater · p promote · c dismiss · d delete · space cmds · ←/esc back"
      elsif @probe.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @probe.mode.off?
        "#{mode} enable scanning · #{filt} filter · space cmds · esc tabs"
      elsif @probe.preview_enabled? && @probe.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs"
      elsif @probe.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · #{mode} mode · #{filt} filter · space cmds"
      else
        "o flow · r repeater · p promote · c dismiss · d delete · #{mode} mode · #{filt} filter · space cmds"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, SUBTABS, @sub_idx, @subtab_start) do |content|
        if rules_tab?
          @rules.render(screen, content, focused)
        else
          proxy = @host.session.proxy
          @probe.render(screen, content, focused: focused,
            listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
        end
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      content = BodyChrome.content_rect(rect, strip: true) # inside the frame, below the sub-tab strip
      if rules_tab?
        @host.focus_body
        if idx = @rules.row_at(content, mx, my)
          # Select first; a click on the already-selected row toggles it (whole row is the switch).
          @rules.selected_index == idx ? rules_toggle_selected : @rules.select_index(idx)
        end
        return true
      end
      return true if @probe.detail_open? # detail pane: clicks are inert (use keys)
      @host.focus_body
      if @probe.preview_enabled? && @probe.preview_at?(content, mx, my)
        @probe.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @probe.list_split(content)
      if my == list_rect.y + 1 && !@probe.querying? # the filter-bar row (below the MODE band)
        @probe.start_query
        return true
      end
      return true unless idx = @probe.list_row_at(content, mx, my)
      @probe.set_preview_focus(:list)
      idx == @probe.selected_index ? probe_open : @probe.select_index(idx) # select-first, then open
      true
    end

    def handle_wheel(step : Int32) : Bool
      if rules_tab?
        @rules.move(step)
      elsif @probe.detail_open?
        @probe.scroll_detail(step)
      else
        @probe.move(step)
      end
      true
    end

    # Detail scroll + list preview Tab focus. List nav is verb-driven; when detail is
    # closed we claim Tab (preview) only. When open, ↑/↓ scroll the detail pane.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if rules_tab?
        # Nav (↑/↓, j/k) + Esc→strip are controller-owned; everything else (a/e/d/x/↵ ProbeRules
        # verbs, space menu, global chords) falls through to the keymap.
        return false if ev.ctrl? || ev.alt?
        case
        when key.up?, key.lower_k?
          @rules.at_top? ? @host.request_focus(:subtabs) : @rules.move(-1)
        when key.down?, key.lower_j? then @rules.move(1)
        when key.escape?             then @host.request_focus(:subtabs)
        else                              return false
        end
        return true
      end
      return false if ev.ctrl? || ev.alt?
      if @probe.detail_open?
        case
        when key.up?, key.lower_k?   then @probe.scroll_detail(-1)
        when key.down?, key.lower_j? then @probe.scroll_detail(1)
        else                              return false
        end
        return true
      end
      if @probe.preview_enabled? && key.tab?
        @probe.cycle_preview_focus
        return true
      end
      false
    end

    # The `/` filter bar — a text sub-mode the shell claims before the focus ring (mirrors
    # Issues). Live filtering: every edit re-derives the visible list inside the view.
    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then @probe.stop_query
      when key.escape?    then @probe.cancel_query
      when key.tab?       then @probe.query_complete
      when key.backspace? then @probe.query_backspace
      when key.left?      then @probe.query_move(-1)
      when key.right?     then @probe.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @probe.query_insert(c)
          @probe.query_set_preedit("")
        end
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @probe.querying?
      @probe.query_set_preedit(text)
      true
    end

    def querying? : Bool
      @probe.querying?
    end

    def on_enter : Nil
      refresh_from_store
    end

    def on_external_change : Nil
      refresh_from_store
    end

    # Re-query the issue list from the store. Called from on_enter, data_version
    # soft-sync, IssueEvent drain, and Runner's per-tick Store#probe_generation poll.
    def refresh_from_store : Nil
      store = @host.session.store
      @probe.reload(store)
      @rules.reload(store)
    end

    # Drain the analyzer's events (called each main-loop tick from the Runner).
    # List data is primarily refreshed via Runner's Store#probe_generation poll
    # (channel events can be dropped when the buffer is full). Still refresh here so a
    # delivered IssueEvent never leaves the in-memory view behind. Returns true when
    # anything was drained (forces a redraw — badge/status even if Probe is not focused).
    def drain_events : Bool
      drained = false
      events = @host.session.probe.events
      while ev = nonblocking_event(events)
        drained = true
        case ev
        when Probe::IssueEvent
          refresh_from_store
          if summary = ev.summary
            # #124: log to the AI event feed regardless of the human notification.
            @host.session.store.insert_event("probe", "issue_found", "success", "Probe: #{summary}", goto_tab: "probe")
            @host.notifications.push(:success, "Probe: #{summary}", source: "probe")
            # Status toast is visible on every tab and pairs with the list paint.
            @host.status("Probe: #{summary}")
          end
        when Probe::ErrorEvent
          # Bottom bar only — a scan error is operational noise, not a result to push
          # into the notification center (#127). Still logged to the #124 event feed
          # (the AI firehose logs freely; only the human center suppresses it).
          @host.session.store.insert_event("probe", "error", "error", "Probe: #{ev.message}", goto_tab: "probe")
          @host.status(ev.message)
        end
      end
      drained
    end

    private def nonblocking_event(ch : Channel(Probe::Event)) : Probe::Event?
      select
      when e = ch.receive
        e
      else
        nil
      end
    rescue Channel::ClosedError
      nil
    end

    # --- ExecContext delegates (from the Runner) ---

    def probe_move(delta : Int32) : Nil
      if @probe.preview_enabled? && @probe.preview_focus == :preview
        @probe.move(delta)
        return
      end
      return @host.request_focus(:subtabs) if delta < 0 && @probe.at_top? # ↑ at top pops to the sub-tab strip
      @probe.move(delta)
    end

    def probe_open : Nil
      @probe.open_detail(@host.session.store)
    end

    def probe_close : Nil
      @probe.close_detail
    end

    def probe_query : Nil
      @probe.start_query
    end

    def probe_delete : Nil
      return unless i = @probe.target_issue
      # Capture the id/code/host NOW: the confirm resolves on a later tick, and a background
      # probe_generation reload can shift the selection in between — so both the suppress and
      # the delete must target THIS issue by id, not whatever happens to be selected at confirm.
      id, code, host, title = i.id, i.code, i.host, i.title
      @host.confirm("DELETE ISSUE", "Delete \"#{title}\" on #{host}?", confirm_label: "delete", danger: true) do
        # Suppress FIRST: delete's exec_task yields to the store writer, and an
        # in-flight Active/passive fiber can re-upsert the same (code, host) in
        # that window if suppress runs after delete.
        @host.session.probe.suppress(code, host)
        @probe.delete_by_id(@host.session.store, id)
      end
    end

    def probe_clear : Nil
      return if @probe.empty?
      @host.confirm("CLEAR ISSUES", "Delete ALL Probe issues for this project?\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        @probe.clear(@host.session.store)
        @host.session.probe.clear_suppressions
      end
    end

    # `c`: toggle dismiss (open ↔ false-positive) on the open/selected issue.
    def probe_dismiss : Nil
      return unless @probe.target_issue
      st = @probe.toggle_dismiss(@host.session.store)
      # A synchronous user action → transient toast (the list updates in place too),
      # matching the rest of the app; the notification center is for async events.
      @host.status(st.try(&.open?) ? "issue re-opened" : "issue dismissed")
    end

    # `a`: flip the open-only ⇄ show-closed lens.
    def probe_toggle_closed : Nil
      showing = @probe.toggle_show_closed
      @host.status(showing ? "showing closed issues" : "showing open issues only")
    end

    # Space-menu bulk actions: mute every OPEN issue sharing the targeted issue's code / host
    # (a confirm guards the mass mutation; it's reversible via show-closed + c).
    def probe_dismiss_code : Nil
      return unless i = @probe.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open \"#{i.code}\" issues?", confirm_label: "dismiss", danger: false) do
        n = @probe.dismiss_by_code(@host.session.store)
        @host.status("dismissed #{n} \"#{i.code}\" issue#{n == 1 ? "" : "s"}")
      end
    end

    def probe_dismiss_host : Nil
      return unless i = @probe.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open issues on #{i.host}?", confirm_label: "dismiss", danger: false) do
        n = @probe.dismiss_by_host(@host.session.store)
        @host.status("dismissed #{n} issue#{n == 1 ? "" : "s"} on #{i.host}")
      end
    end

    # --- Rules sub-tab actions (ProbeRules verbs + clicks) ---

    # Whether the highlighted Rules row is a user CUSTOM rule (gates edit/delete).
    def rules_custom_selected? : Bool
      !!@rules.selected_row.try(&.custom)
    end

    # Toggle the selected rule on/off. Built-ins flip the per-project disabled set; custom rules
    # flip their persisted `enabled` flag (global in settings.json, project in the DB). Then reload
    # the view + the analyzer config (which re-scans recent flows so a re-enabled rule finds hits).
    def rules_toggle_selected : Nil
      row = @rules.selected_row
      return unless row && row.selectable?
      store = @host.session.store
      case row.kind
      when :builtin
        dis = store.probe_disabled_rules
        row.enabled? ? dis.add(row.rule_id) : dis.delete(row.rule_id)
        store.set_probe_disabled_rules(dis)
        @host.status(row.enabled? ? "disabled rule \"#{row.title}\"" : "enabled rule \"#{row.title}\"")
      when :custom
        c = row.custom.not_nil!
        on = !c.enabled
        c.global? ? Settings.set_scan_rule_enabled(c.id, on) : store.set_probe_custom_rule_enabled(c.id.to_i64, on)
        @host.status(on ? "enabled rule \"#{c.title}\"" : "disabled rule \"#{c.title}\"")
      else
        return
      end
      reload_rules
    end

    def rules_add : Nil
      @host.open_custom_rule_editor(nil)
    end

    def rules_edit : Nil
      c = @rules.selected_row.try(&.custom) || return
      @host.open_custom_rule_editor(c)
    end

    def rules_delete : Nil
      c = @rules.selected_row.try(&.custom) || return
      @host.confirm("DELETE RULE",
        "Delete custom rule \"#{c.title}\"?\nExisting findings from it are kept until cleared.",
        confirm_label: "delete", danger: true) do
        c.global? ? Settings.delete_scan_rule(c.id) : @host.session.store.delete_probe_custom_rule(c.id.to_i64)
        reload_rules
        @host.status("deleted rule \"#{c.title}\"")
      end
    end

    # Persist an add/edit from the overlay. Returns false (keep the form open) when invalid. A
    # scope change on edit moves the rule between the global library and the project DB.
    def apply_custom_rule(ov : CustomRuleOverlay) : Bool
      return false unless ov.valid?
      store = @host.session.store
      if id = ov.edit_id
        if ov.scope == ov.edit_scope
          if ov.scope == "global"
            Settings.update_scan_rule(id, ov.title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity.label)
          else
            store.update_probe_custom_rule(id.to_i64, ov.title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity)
          end
        else
          ov.edit_scope == "global" ? Settings.delete_scan_rule(id) : store.delete_probe_custom_rule(id.to_i64)
          insert_custom_rule(ov, store)
        end
        @host.status("updated custom rule")
      else
        insert_custom_rule(ov, store)
        @host.status("added custom rule")
      end
      reload_rules
      true
    end

    private def insert_custom_rule(ov : CustomRuleOverlay, store : Store) : Nil
      if ov.scope == "global"
        Settings.add_scan_rule(ov.title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity.label)
      else
        store.insert_probe_custom_rule(ov.title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity)
      end
    end

    private def reload_rules : Nil
      @rules.reload(@host.session.store)
      @host.session.probe.reload_rule_config
    end
  end
end
