# Probe (passive/active scan issues) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def probe_move(delta : Int32) : Nil
    probe_controller.probe_move(delta)
  end

  def probe_open : Nil
    probe_controller.probe_open
  end

  def probe_close : Nil
    probe_controller.probe_close
  end

  def probe_query : Nil
    probe_controller.view.start_query
  end

  def probe_clear : Nil
    probe_controller.probe_clear
  end

  def probe_delete : Nil
    probe_controller.probe_delete
  end

  # Open the MODE picker (a shell overlay); apply_choice applies it to the analyzer.
  def probe_set_mode : Nil
    @choice_picker = ChoicePicker.for_probe_mode(@session.probe.mode.value)
    @overlay = :choice
  end

  def probe_dismiss : Nil
    probe_controller.probe_dismiss
  end

  def probe_toggle_closed : Nil
    probe_controller.probe_toggle_closed
  end

  def probe_dismiss_code : Nil
    probe_controller.probe_dismiss_code
  end

  def probe_dismiss_host : Nil
    probe_controller.probe_dismiss_host
  end

  # Jump from an issue to its sample evidence: History flow when present, else the
  # Repeater tab that first produced the hit (Repeater-sourced passive issues).
  def probe_open_flow : Nil
    return unless i = probe_controller.view.target_issue
    if fid = i.sample_flow_id
      if history_controller.view.open_detail_id(fid, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = :detail
      else
        @toast = "evidence no longer captured (pruned)"
      end
      return
    end
    if rid = i.sample_repeater_id
      navigate_link_ref(Store::LinkRefKind::Repeater, rid)
      return
    end
    @toast = "this issue has no sample evidence"
  end

  # Send an issue's sample flow to Repeater to re-test it (mirrors issue_repeater_flow).
  # When the only evidence is a Repeater tab, jump there instead of re-spawning.
  def probe_repeater_flow : Nil
    return unless i = probe_controller.view.target_issue
    if fid = i.sample_flow_id
      if @session.store.get_flow(fid)
        repeater_flow(fid)
      else
        @toast = "evidence no longer captured (pruned)"
      end
      return
    end
    if rid = i.sample_repeater_id
      navigate_link_ref(Store::LinkRefKind::Repeater, rid)
      return
    end
    @toast = "this issue has no sample evidence"
  end

  # History list / open detail → the selected (or open) flow.
  def probe_active_selected : Nil
    id = history_target_flow_id
    return (@toast = "select a flow first") unless id
    detail = @session.store.get_flow(id)
    return (@toast = "flow no longer available") unless detail
    open_probe_active_overlay(detail)
  end

  # Probe findings list → the selected issue's sample flow (re-test the evidence in place).
  def probe_active_rescan : Nil
    return (@toast = "select an issue first") unless i = probe_controller.view.target_issue
    fid = i.sample_flow_id
    return (@toast = "this issue has no captured flow to re-scan") unless fid
    detail = @session.store.get_flow(fid)
    return (@toast = "evidence no longer captured (pruned)") unless detail
    open_probe_active_overlay(detail)
  end

  # Repeater → the current session's last HTTP send (request as edited + its response).
  def probe_active_from_repeater : Nil
    detail = repeater_controller.active_scan_detail
    return (@toast = "send the request first (an active scan needs a response)") unless detail
    open_probe_active_overlay(detail, repeater_id: repeater_controller.current_session_db_id)
  end

  # Promote a machine-found Probe issue to a human-confirmed Issue (the bridge to the
  # Issues report). Reuses Store#insert_issue; the issue's severity/host/sample flow carry over.
  def probe_promote : Nil
    return unless i = probe_controller.view.target_issue
    # Promotion marks the source issue Confirmed; a second press would otherwise mint a
    # duplicate Issue for the same issue. Already-Confirmed ⇒ already promoted.
    if i.status.confirmed?
      @toast = "already promoted to an issue"
      return
    end
    fid = @session.store.insert_issue(i.title, i.severity, i.host, i.sample_flow_id)
    # Preserve Repeater-only evidence: with no source flow, link the Issue to the Repeater tab
    # that produced the issue so the evidence pointer survives promotion (insert_issue only
    # carries a flow id).
    if i.sample_flow_id.nil? && (rid = i.sample_repeater_id)
      @session.store.add_link(Store::LinkOwnerKind::Issue, fid, Store::LinkRefKind::Repeater, rid)
    end
    # Mark the source confirmed (= "promoted to an Issue") so it leaves the default
    # open-only lens instead of lingering as unreviewed noise; still reachable via `a`.
    @session.store.update_probe_issue_status(i.id, Store::Status::Confirmed)
    probe_controller.view.reload(@session.store)
    @toast = "promoted to issue — see the Issues tab"
  end

  def probe_rule_toggle : Nil
    probe_controller.rules_toggle_selected
  end

  def probe_rule_add : Nil
    probe_controller.rules_add
  end

  def probe_rule_edit : Nil
    probe_controller.rules_edit
  end

  def probe_rule_delete : Nil
    probe_controller.rules_delete
  end

  def probe_custom_rule_selected? : Bool
    probe_controller.rules_custom_selected?
  end
end
