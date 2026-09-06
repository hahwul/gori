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

    # Per-tick ceiling on analyzer events applied on the render fiber, matching every sibling
    # drain (fuzzer/miner/sequencer/discover/oast controllers, and Runner's FLOW_DRAIN_CAP).
    # This one was uncapped, and the per-event body yields at `insert_event`, so the analyzer
    # could refill its 256-slot channel mid-loop and keep one tick going indefinitely.
    # Whatever is left over is drained on the next tick, 50 ms later.
    DRAIN_CAP = 512

    def initialize(host : Host)
      super(host)
      @probe = ProbeView.new
      @probe.set_scope(@host.session.scope) # honour the lens + show its chip on the bar
      @rules = ProbeRulesView.new
      @sub_idx = 0 # 0 = Findings · 1 = Rules
    end

    # The RULES sub-tab's list — read by specs that drive the row gestures through the view's
    # own hit-tests, the way `view` exposes the findings.
    def rules : ProbeRulesView
      @rules
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

    # ⇥ / ⇧⇥ between the findings list and its preview; off either end the ring returns to
    # the tab bar. The focus-ring hook — a `key.tab?` arm in `handle_body_key` never ran (the
    # Runner claims ⇥ for the ring first), so the `↹ preview` the hint promised was mouse-only.
    def pane_advance(dir : Int32) : Bool
      return false if rules_tab? || @probe.detail_open? || !@probe.preview_enabled?
      @probe.step_preview_focus(dir)
    end

    def page_rows : Int32?
      return @rules.list_page_rows if rules_tab?
      return nil if @probe.detail_open? || (@probe.preview_enabled? && @probe.preview_focus == :preview)
      @probe.list_page_rows
    end

    def body_badge : Symbol
      :body # read-only/navigable list + detail (no inline text editor)
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      mode = Hotkeys.binding_label(reg, "probe.mode", "m")
      filt = Hotkeys.binding_label(reg, "probe.filter", "/")
      # Named in EVERY list state, not just the default one. `command_scope` answers
      # `Scope::Probe` for the mode-off list and for both preview focuses as well (only the
      # Rules sub-tab and an open detail leave it), so `probe.clear` is one keystroke away in
      # all four — and naming it in one would have rebuilt the exact gap 0edc3c5b found, an
      # unadvertised destructive key, in the other three.
      #
      # In the default branch it sits with `d delete` so the danger pair reads together. That
      # is NOT free: the line is the longest on the tab and a narrow terminal clips the right
      # end, so the eleven columns come out of `mode`/`filter` — which the space menu still
      # names. The wipe is the one that has to be legible without opening anything.
      clear = Hotkeys.binding_label(reg, "probe.clear", "⇧X")
      if rules_tab?
        # `↵/e edit`, matching every other rule list — ↵ no longer toggles here (see
        # verbs/probe.cr). Edit and delete are named ONLY when they can fire: both are gated
        # to a selected CUSTOM rule, and built-ins are most of this list, so advertising them
        # on a built-in row promised two keys that did nothing on most of the rows.
        #
        # `esc sub-tabs`, not `esc tabs`: escape goes to the strip (handle_body_key), and the
        # strip is always shown here, so `focus_pane` never downgrades it to the tab bar.
        edits = rules_custom_selected? ? " · ↵/e edit · {probe-rules.delete} delete" : ""
        return keys("↑/↓ select · {probe-rules.toggle} on/off · {probe-rules.add} add#{edits} · space cmds · ↑ sub-tabs · esc sub-tabs")
      elsif @probe.detail_open?
        # `↵ open` and `o flow` are two different destinations and both belong here — the
        # caret's own affected URL, and the issue's sample evidence. The Issues detail names
        # the same pair for the same reason (`↵ open` over its related links, `o flow`).
        keys("↑/↓ URL · ↵ open · ⇧arrows select · {probe.copy} copy · {probe.open-flow} flow · {probe.repeater-flow} repeater · {probe.promote} promote · space cmds · ←/esc back")
      elsif @probe.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @probe.mode.off?
        "#{mode} enable scanning · #{filt} filter · #{clear} clear · space cmds · esc tabs"
      elsif @probe.preview_enabled? && @probe.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · #{clear} clear · space cmds · esc tabs"
      elsif @probe.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · #{clear} clear · #{mode} mode · #{filt} filter · space cmds"
      else
        keys("↑/↓ move · ↵ open · {probe.open-evidence} flow · {probe.repeater-evidence} repeater · {probe.promote-selected} promote · {probe.dismiss-selected} dismiss · {probe.delete-selected} delete · #{clear} clear · #{mode} mode · #{filt} filter · space cmds")
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, SUBTABS, @sub_idx, @subtab_start,
        find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        if rules_tab?
          @rules.render(screen, content, focused)
        else
          proxy = @host.session.proxy
          @probe.render(screen, content, focused: focused,
            listen: {proxy.host, proxy.port}, capturing: @host.session.capturing?)
        end
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      content = BodyChrome.content_rect(rect, strip: true) # inside the frame, below the sub-tab strip
      if rules_tab?
        @host.focus_body
        if row = @rules.gauge_row_at(content, mx, my)
          @rules.select_index(row)
        elsif idx = @rules.row_at(content, mx, my)
          # SELECT ONLY, like the Rewriter's and Colormarker's rule lists. A second click used
          # to toggle — the exact reflex `probe-rules.toggle` gave up its `↵` for, and for the
          # same reason: no other rule list flips a scanning rule off from a repeat gesture,
          # and here the row that answered a double-click was often a BUILT-IN, where `↵`
          # (now edit, gated to custom rules) does nothing at all. One row, two gestures, two
          # answers. `x` toggles.
          @rules.select_index(idx)
        end
        return true
      end
      if @probe.detail_open?
        # The AFFECTED URLS list takes a caret from the pointer; the rest of the card is chrome.
        @host.focus_body
        @probe.detail_click(content, mx, my)
        return true
      end
      @host.focus_body
      if @probe.preview_enabled? && @probe.preview_at?(content, mx, my)
        @probe.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @probe.list_split(content)
      # The list's scroll gauge on the frame's right hairline — `list_row_at` excludes that
      # column, so it was the one part of the list a click could not reach.
      if row = @probe.gauge_row_at(content, mx, my)
        @probe.set_preview_focus(:list)
        @probe.select_index(row)
        return true
      end
      # Row 0 — the MODE band. Its chip and its `a:CLOSED` badge are drawn in the dresses this
      # codebase uses for clickable chrome and were the only two that answered nothing.
      if chip = @probe.mode_band_hit(list_rect, mx, my)
        # `probe.set-mode` lives on the Runner (it raises a picker), unlike the lens toggle.
        chip == :mode ? @host.probe_set_mode : probe_toggle_closed
        return true
      end
      if my == list_rect.y + 1 && !@probe.querying? # the filter-bar row (below the MODE band)
        @probe.start_query
        return true
      end
      return true unless idx = @probe.list_row_at(content, mx, my)
      @probe.set_preview_focus(:list)
      idx == @probe.selected_index ? probe_open : @probe.select_index(idx) # select-first, then open
      true
    end

    # Pointer-aware: the preview under the cursor scrolls without taking focus from the list.
    # Same `content` rect `handle_click` hit-tests with.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      return handle_wheel(step) if rules_tab? || @probe.detail_open?
      content = BodyChrome.content_rect(rect, strip: true)
      if @probe.preview_enabled? && @probe.preview_at?(content, mx, my)
        @probe.wheel_preview(step)
      else
        @probe.move(step)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if rules_tab?
        @rules.move(step)
      elsif @probe.detail_open?
        @probe.detail_wheel(step) # viewport only — ↑/↓ are the caret
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
        when key.up?, key.lower_k?   then @probe.detail_move(-1, ev.shift?)
        when key.down?, key.lower_j? then @probe.detail_move(1, ev.shift?)
        else                              return @probe.detail_motion_key(ev) # Home/End/PgUp/PgDn, ⇧ extending
        end
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
      when key.enter?                  then @probe.stop_query
      when key.escape?                 then @probe.cancel_query
      when key.tab?                    then @probe.query_complete
      when (act = LineEdit.action(ev)) then @probe.query_edit(act) # ⌃/⌥←→, Home/End, Delete, ⌥⌫ — before plain ⌫, which would swallow ⌥⌫
      when key.backspace?              then @probe.query_backspace
      when key.left?                   then @probe.query_move(-1)
      when key.right?                  then @probe.query_move(1)
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
    # Returns whether the number of listed rows CHANGED. The caller uses that to decide
    # between a full terminal repaint and the cell diff: a row added or removed can leave a
    # stale tail the diff will not repair, but a row whose contents merely changed cannot.
    def refresh_from_store : Bool
      store = @host.session.store
      before = @probe.row_count
      @probe.reload(store)
      @rules.reload(store)
      @probe.row_count != before
    end

    # Drain the analyzer's events (called each main-loop tick from the Runner).
    # List data is primarily refreshed via Runner's Store#probe_generation poll
    # (channel events can be dropped when the buffer is full). Still refresh here so a
    # delivered IssueEvent never leaves the in-memory view behind. Returns true when
    # anything was drained (forces a redraw — badge/status even if Probe is not focused).
    #
    # The list reload is coalesced to ONE per drain and gated on Probe being the active tab,
    # because `refresh_from_store` is a full-table `probe_issues` SELECT plus filter — the
    # same cost the Runner's probe_generation poll already refuses to pay off-tab, for the
    # reason its comment gives ("repainting the whole screen up to 20 times a second" during
    # a scan). Per-event it was worse still: the reload ran once per IssueEvent, on the render
    # fiber, which is exactly what probe/event.cr's contract already says it must not do
    # ("the controller coalesces them into a single list reload per frame"). Off-tab is caught
    # up by `on_enter` — the only way into the Probe tab is `focus_tab`, which runs it.
    def drain_events : Bool
      drained = false
      needs_refresh = false
      n = 0
      events = @host.session.probe.events
      while n < DRAIN_CAP && (ev = nonblocking_event(events))
        n += 1
        drained = true
        case ev
        when Probe::IssueEvent
          needs_refresh = true
          if summary = ev.summary
            # #124: log to the AI event feed regardless of the human notification.
            @host.session.store.insert_event("probe", "issue_found", "success", "Probe: #{summary}", goto_tab: "probe")
            @host.notifications.push(:success, "Probe: #{summary}", source: "probe")
            # Status toast is visible on every tab and pairs with the list paint.
            @host.status("Probe: #{summary}") if Settings.notify_toast?
          end
        when Probe::ErrorEvent
          # Bottom bar only — a scan error is operational noise, not a result to push
          # into the notification center (#127). Still logged to the #124 event feed
          # (the AI firehose logs freely; only the human center suppresses it).
          @host.session.store.insert_event("probe", "error", "error", "Probe: #{ev.message}", goto_tab: "probe")
          @host.status("probe error: #{ev.message}", :error)
        when Probe::CompleteEvent
          # A manual "Run active scan" in Always mode came back clean — the analyzer only emits
          # this when the operator asked to be told either way, so it always posts to the tray.
          @host.session.store.insert_event("probe", "scan_complete", "info", "Probe: #{ev.message}", goto_tab: "probe")
          @host.notifications.push(:info, "Probe: #{ev.message}", source: "probe")
          @host.status("Probe: #{ev.message}") if Settings.notify_toast?
        end
      end
      refresh_from_store if needs_refresh && @host.active_tab == :probe
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
      @host.confirm("DELETE ISSUE", "Delete “#{title}” on #{host}?", confirm_label: "delete", danger: true) do
        # Suppress FIRST: delete's exec_task yields to the store writer, and an
        # in-flight Active/passive fiber can re-upsert the same (code, host) in
        # that window if suppress runs after delete.
        @host.session.probe.suppress(code, host)
        @probe.delete_by_id(@host.session.store, id)
      end
    end

    def probe_clear : Nil
      # A toast, not a silent return. While this was menu-only the empty case was self-evident
      # — you were looking at the list you had just opened a menu over. ⇧X is pressed without
      # that, and an advertised key that answers with nothing at all reads as a key that
      # failed. `activity_clear` says the same thing for the same reason.
      return @host.status("probe: nothing to clear") if @probe.empty?
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
    #
    # The code/host is captured NOW, before the confirm is raised, for the reason probe_delete
    # spells out one screen up — and these two mass-mutate, so getting it wrong is worse here.
    # The modal answers on a LATER tick (its action runs from on_close), and the Runner's
    # per-tick probe_generation poll is NOT gated on the overlay: a peer writer on the same
    # project (MCP probe_dismiss/probe_delete, a second gori instance, `gori run probe`) can
    # make the cursor issue leave the open-only list in between, at which point ProbeView's
    # apply_filter loses its prev_id anchor and clamps onto a DIFFERENT issue. Re-deriving the
    # group from the cursor at answer time then dismissed every open issue sharing the OTHER
    # issue's code — and the toast took its count from the re-resolved issue and its code from
    # the prompt, so one sentence reported two different groups.
    def probe_dismiss_code : Nil
      return unless i = @probe.target_issue
      code = i.code
      @host.confirm("DISMISS GROUP", "Dismiss all open “#{code}” issues?", confirm_label: "dismiss", danger: false) do
        n = ProbeController.dismiss_open_by_code(@host.session.store, @host.session.scope, code)
        @probe.reload(@host.session.store)
        @host.status("dismissed #{n} \"#{code}\" issue#{n == 1 ? "" : "s"}")
      end
    end

    def probe_dismiss_host : Nil
      return unless i = @probe.target_issue
      host = i.host
      @host.confirm("DISMISS GROUP", "Dismiss all open issues on #{host}?", confirm_label: "dismiss", danger: false) do
        n = ProbeController.dismiss_open_by_host(@host.session.store, host)
        @probe.reload(@host.session.store)
        @host.status("dismissed #{n} issue#{n == 1 ? "" : "s"} on #{host}")
      end
    end

    # Mute every OPEN issue carrying `code`, honouring the ⇧S scope lens exactly as the
    # visible list does: dismissing "all with this code" from a scoped view must not silently
    # mute issues on out-of-scope hosts the operator cannot see, and the returned count must
    # equal what was actually muted.
    #
    # Class-level and store-only on purpose. It takes the code the confirm was RAISED with, so
    # there is no cursor left for a late answer to re-read — the property this fix turns on —
    # and a spec can drive it without standing up a Runner. Counts the writes that COMMITTED
    # (update_probe_issue_status answers that, and store/probe_issues.cr is explicit that
    # callers must not drop the answer), so a busy or rolled-back store reports "dismissed 0"
    # rather than a number of rows it merely attempted.
    def self.dismiss_open_by_code(store : Store, scope : Scope?, code : String) : Int32
      lens = scope.try(&.active?) == true ? scope : nil
      targets = store.probe_issues.select do |i|
        i.code == code && i.status.open? && (lens.nil? || lens.host_in_scope?(i.host))
      end
      targets.count { |i| store.update_probe_issue_status(i.id, Store::Status::FalsePositive) }
    end

    # Mute every OPEN issue on `host`. One bulk UPDATE rather than a per-id loop: the host is
    # a single visible row, so the scope lens — which filters BY host — already admits every
    # row this touches, and there is no cross-scope leak to guard against. Returns how many
    # were open beforehand, or 0 when the batch did not commit.
    def self.dismiss_open_by_host(store : Store, host : String) : Int32
      n = store.open_probe_issue_count(host: host)
      store.dismiss_probe_by_host(host) ? n : 0
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
        # Toggle to the OPPOSITE of the displayed state via `set_rule_enabled` (not a bare
        # add/delete): a DEFAULT-OFF rule inverts the stored-set membership — see
        # Gori::Probe::DEFAULT_DISABLED_RULES.
        Gori::Probe.set_rule_enabled(dis, row.rule_id, !row.enabled?)
        # Both scan-rule writers report whether the toggle COMMITTED. Without this the status
        # bar said `disabled rule "X"` while the very next `reload_rules` re-drew the row as
        # still enabled — two lines of UI contradicting each other with no way to tell which
        # was true. Same refusal as the CLI/MCP twins.
        unless store.set_probe_disabled_rules(dis)
          @host.status("rule \"#{row.title}\" NOT changed (project busy)")
          return
        end
        @host.status(row.enabled? ? "disabled rule \"#{row.title}\"" : "enabled rule \"#{row.title}\"")
      when :custom
        c = row.custom.not_nil!
        on = !c.enabled
        # BOTH writers answer. `Settings.set_scan_rule_enabled` returns whether the section
        # reached disk — `Settings.save` refuses outright after a half-read load, and it puts
        # the array back when the write did not commit — and this branch used to throw that
        # answer away behind a comment claiming settings.json had no commit flag to read. It
        # does, `apply_custom_rule` below already acts on it, and a global scan rule the strip
        # says is off while it is still matching (or still on while it is not) is the same
        # false negative that refusal exists to prevent.
        ok = c.global? ? Settings.set_scan_rule_enabled(c.id, on) : store.set_probe_custom_rule_enabled(c.id.to_i64, on)
        unless ok
          @host.status("rule \"#{c.title}\" NOT changed (#{write_cause(c.scope)})")
          return
        end
        @host.status(on ? "enabled rule \"#{c.title}\"" : "disabled rule \"#{c.title}\"")
      else
        return
      end
      reload_rules
    end

    def rules_add : Nil
      @host.open_custom_rule_editor(nil)
    end

    # Both of these are reachable only from a selected CUSTOM rule, and both used to return
    # in silence on anything else — so `e` and `d` on a built-in were dead keys with no word
    # about why. The hint no longer promises them there (see `body_hint`), but a key can still
    # be pressed on the strength of muscle memory, and a rule list that answers nothing is the
    # same "did gori see that?" moment every sibling list avoids.
    def rules_edit : Nil
      c = selected_custom_rule || return
      @host.open_custom_rule_editor(c)
    end

    # The selected CUSTOM rule, or nil with the reason on the strip. Built-ins live in code —
    # there is nothing to open and nothing to remove — so the message names that rather than
    # saying "nothing selected", which would be false: a row IS selected.
    private def selected_custom_rule : Probe::CustomRule?
      row = @rules.selected_row
      return row.custom if row && row.custom
      @host.status(row ? "built-in rules can't be edited or deleted — x turns one off" : "no rule selected")
      nil
    end

    def rules_delete : Nil
      c = selected_custom_rule || return
      # Sentence-case title, `Delete` button — the same dress every other policy-rule delete
      # wears. This one shouted "DELETE RULE" over a lowercase `delete` button, so the one
      # dialog an operator sees least often was also the one that looked unlike the rest.
      @host.confirm("DELETE PROBE RULE",
        "Delete custom rule “#{c.title}”? Existing findings from it are kept until cleared.",
        confirm_label: "delete", danger: true) do
        ok = remove_custom_rule(c.id, c.scope, @host.session.store)
        reload_rules
        # The delete answers, and dropping that answer said "deleted" over a rule that is
        # still installed and still matching — the row `reload_rules` redraws one line later
        # then contradicts the strip. `Settings.delete_scan_rule`'s own comment names the
        # stake: "an operator removing a noisy rule has to be able to trust that sentence".
        @host.status(ok ? "probe rule deleted: #{c.title}" : "rule \"#{c.title}\" NOT deleted (#{write_cause(c.scope)}) — it is still scanning")
      end
    end

    # Persist an add/edit from the overlay. Returns false (keep the form open) when invalid, or
    # when the writer for the rule's scope refused the edit — the operator's fields are the only
    # remaining copy of it. A scope change on edit moves the rule between the global library and
    # the project DB.
    def apply_custom_rule(ov : CustomRuleOverlay) : Bool
      return false unless ov.valid?
      store = @host.session.store
      if id = ov.edit_id
        # `CustomRuleOverlay.editing` sets the pair together, so a non-nil `edit_id` always
        # carries one; the fallback only keeps this branch off the "moved between libraries"
        # path for a form that somehow has an id and no origin.
        from = ov.edit_scope || ov.scope
        if ov.scope == from
          if ov.scope == "global"
            # settings.json answers the same "did it COMMIT" question as the project writer
            # below: `Settings.save` refuses outright after a half-read load, and a rolled-back
            # edit no longer stays live in `Settings.scan_rules` — so the rule the operator just
            # widened still matches on the old pattern, and saying otherwise is the same false
            # negative the project branch refuses. Same refusal, same open form.
            unless Settings.update_scan_rule(id, ov.rule_title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity.label)
              @host.status("rule \"#{ov.rule_title}\" NOT updated (settings not writable) — it still matches on the old pattern")
              return false
            end
          else
            # The project writer reports whether the edit COMMITTED. Saying "updated custom
            # rule" over a rolled-back batch leaves the operator scanning with the OLD pattern
            # believing it is the new one — a false negative they were told not to expect — so
            # refuse, and return false to keep the form open with the edits intact for a retry.
            unless store.update_probe_custom_rule(id.to_i64, ov.rule_title, ov.description, ov.side, ov.region, ov.kind, ov.pattern, ov.severity)
              @host.status("rule \"#{ov.rule_title}\" NOT updated (project busy) — it still matches on the old pattern")
              return false
            end
          end
        else
          # A scope change is a MOVE between the two libraries, and both halves answer. INSERT
          # FIRST: a refused insert after a committed delete loses the rule outright, while a
          # refused delete after a committed insert only leaves a duplicate — which the strip
          # can name and the operator can remove. Neither answer was read at all, so the pair
          # could do either and still report "updated custom rule".
          # The rule's on/off bit rides along. Both writers default a NEW rule to enabled and
          # the form carries no `enabled` field, so a rule the operator had turned off started
          # scanning again the moment its scope was cycled — a muted rule un-muting itself with
          # nothing on the strip to say so.
          unless insert_custom_rule(ov, store, enabled: custom_rule_enabled?(id, from, store))
            @host.status("rule \"#{ov.rule_title}\" NOT moved (#{write_cause(ov.scope)}) — " \
                         "it is still #{from}")
            return false
          end
          unless remove_custom_rule(id, from, store)
            # Saved, so the form closes; the leftover is named because only the operator can
            # clear it, and until they do the same rule files findings twice.
            reload_rules
            @host.status("rule \"#{ov.rule_title}\" added to the #{ov.scope} library but the " \
                         "#{from} copy could NOT be removed (#{write_cause(from)}) — delete it there")
            return true
          end
        end
        @host.status("updated custom rule")
      else
        unless insert_custom_rule(ov, store)
          @host.status("rule \"#{ov.rule_title}\" NOT added (#{write_cause(ov.scope)}) — " \
                       "nothing is scanning for it")
          return false
        end
        @host.status("added custom rule")
      end
      reload_rules
      true
    end

    # Whether the new rule reached its library. Both writers report a refusal in their own
    # dialect: `add_scan_rule` answers "" (the `0_i64` of this family's id type) and
    # `insert_probe_custom_rule` answers 0 — NOT nil — for a batch that never committed, and
    # 0 is TRUTHY in Crystal, which is the trap `Probe::Triage.promote` names.
    private def insert_custom_rule(ov : CustomRuleOverlay, store : Store, enabled : Bool = true) : Bool
      if ov.scope == "global"
        !Settings.add_scan_rule(ov.rule_title, ov.description, ov.side, ov.region, ov.kind,
          ov.pattern, ov.severity.label, enabled).empty?
      else
        store.insert_probe_custom_rule(ov.rule_title, ov.description, ov.side, ov.region,
          ov.kind, ov.pattern, ov.severity, enabled) != 0
      end
    end

    # Whether the rule `id` in `scope`'s library is currently ON — read so a MOVE between the
    # two libraries carries the bit instead of re-minting the rule enabled. A rule the lookup
    # cannot find keeps the insert's own default.
    private def custom_rule_enabled?(id : String, scope : String, store : Store) : Bool
      if scope == "global"
        Settings.scan_rules.find { |r| r.id == id }.try(&.enabled) != false
      else
        store.probe_custom_rules.find { |r| r.id.to_s == id }.try(&.enabled?) != false
      end
    end

    # Drop a custom rule from the library its `scope` names; whether the write committed.
    private def remove_custom_rule(id : String, scope : String, store : Store) : Bool
      scope == "global" ? Settings.delete_scan_rule(id) : store.delete_probe_custom_rule(id.to_i64)
    end

    # The cause clause for a refused write, by the library it was aimed at — the two strings
    # the edit branch above already uses, spelled once.
    private def write_cause(scope : String) : String
      scope == "global" ? "settings not writable" : "project busy"
    end

    private def reload_rules : Nil
      @rules.reload(@host.session.store)
      @host.session.probe.reload_rule_config
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # The detail's AFFECTED URLS only: the issue list selects rows, where a drag is a fast
    # repeated select and a double-click is two opens.
    def supports_drag? : Bool
      !rules_tab? && @probe.detail_open?
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless supports_drag?
      @probe.detail_click(BodyChrome.content_rect(rect, strip: true), mx, my, selecting: true)
    end

    # RULES: a pair on a row opens its editor — what ↵ / `e` (`probe-rules.edit`) do, and the
    # same method, so a built-in row gets the same sentence the key gives it ("built-in rules
    # can't be edited") rather than two silent selects. Elsewhere the pair selects a word in
    # the detail's AFFECTED URLS, as before. Same `content` rect as `handle_click`.
    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      content = BodyChrome.content_rect(rect, strip: true)
      if rules_tab?
        return false unless idx = @rules.row_at(content, mx, my)
        @rules.select_index(idx)
        # A section header or the empty placeholder is not a rule: `select_index` refused it,
        # so acting now would edit whichever row was selected before. Decline instead.
        return false unless @rules.selected_index == idx
        rules_edit
        return true
      end
      return false unless supports_drag?
      @probe.detail_select_word(content, mx, my)
    end

    # --- READ-pane delegators (the detail's read verbs + the Runner's read_* ladders) ---
    def probe_detail_readable? : Bool
      !rules_tab? && @probe.detail_open?
    end

    # The AFFECTED URL under the caret — what `probe.open-affected` navigates to.
    def probe_affected_url : String?
      return nil unless probe_detail_readable?
      @probe.affected_url
    end

    def probe_detail_selection_active? : Bool
      @probe.detail_selection?
    end

    def probe_detail_selection_text : String
      @probe.detail_copy_text
    end

    def probe_detail_select_line : Nil
      @probe.detail_select_line
    end

    def probe_detail_clear_selection : Nil
      @probe.detail_clear_selection
    end

    def probe_issue_selected? : Bool
      !rules_tab? && !@probe.detail_open? && !@probe.selected_issue.nil?
    end

    # `y` wherever the tab is: the detail's URLs when the detail is open, else the issue row
    # under the cursor as a report line with its affected URLs beneath (#964's shape).
    def probe_copy : Nil
      return probe_detail_copy if probe_detail_readable?
      return unless (issue = @probe.selected_issue) && probe_issue_selected?
      head = "[#{issue.severity}] #{issue.title} · #{issue.host}"
      copy_text(issue.affected.empty? ? head : "#{head}\n#{issue.affected.join('\n')}", "issue")
    end

    # `y`: the selected URLs, or every affected URL when nothing is selected. This list IS the
    # finding's evidence, and it had no copy at all.
    def probe_detail_copy : Nil
      return unless probe_detail_readable?
      sel = @probe.detail_selection?
      text = sel ? @probe.detail_copy_text : @probe.detail_copy_all
      return if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end
  end
end
