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

  # Open the MODE picker (a shell overlay); its injected commit applies it to the analyzer.
  def probe_set_mode : Nil
    open_choice_picker(ChoicePicker.for_probe_mode(@session.probe.mode.value)) { |p| apply_probe_mode(p) }
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
        @overlay = OverlayKind::Detail
      else
        @toast = I18n.sys("evidence no longer captured (pruned)")
      end
      return
    end
    if rid = i.sample_repeater_id
      navigate_link_ref(Store::LinkRefKind::Repeater, rid)
      return
    end
    @toast = I18n.sys("this issue has no sample evidence")
  end

  # ↵ on the AFFECTED URLS list: open the flow THAT url was captured on, which for a group of
  # 50 is 50 different exchanges — `o` can only ever reach the one sample. CROSS-TAB mediator:
  # reads the Probe controller, drives the History controller + overlay (issue_open_flow's shape).
  #
  # The list holds bare strings — `upsert_probe_issue` accumulates `Detection#url` and keeps no
  # per-URL flow id — so the row is resolved through the store by URL, narrowed by the issue's
  # own host (the group is keyed by (code, host), so every URL on the list is on it).
  def probe_open_affected : Nil
    return (@toast = I18n.sys("open an issue first")) unless issue = probe_controller.view.detail_issue
    return (@toast = I18n.sys("no affected URL selected")) unless url = probe_controller.probe_affected_url
    # The sample flow's METHOD, so a group that fired on `GET /v1/me` cannot open the `POST`
    # to the same URL — see Store#flow_id_for_url, which ranks on it first.
    method = probe_controller.view.detail_flow.try(&.method)
    unless fid = @session.store.flow_id_for_url(url, issue.host, method)
      # A Repeater-sourced finding (Probe::FromRepeater) has no `flows` row for its URL AT ALL
      # — the send never went through capture — so "no captured flow" would be true and
      # useless: `o`, one key away, navigates to the session that holds it. Say that instead.
      return (@toast = I18n.sys("this URL came from a Repeater send — o opens it")) if issue.sample_repeater_id
      # NOT "pruned" either: a finding can be older than the capture it names — a `gori run
      # probe` sweep, an issue that outlived a compact — and telling the operator a flow was
      # deleted when it was never in this project sends them looking for a retention setting.
      return (@toast = I18n.sys("no captured flow for that URL"))
    end
    if history_controller.view.open_detail_id(fid, @session.store)
      @active_tab = :history
      @focus = :body
      @overlay = OverlayKind::Detail
    else
      @toast = I18n.sys("evidence no longer captured (pruned)")
    end
  end

  # Send an issue's sample flow to Repeater to re-test it (mirrors issue_repeater_flow).
  # When the only evidence is a Repeater tab, jump there instead of re-spawning.
  def probe_repeater_flow : Nil
    return unless i = probe_controller.view.target_issue
    if fid = i.sample_flow_id
      if @session.store.get_flow(fid)
        repeater_flow(fid)
      else
        @toast = I18n.sys("evidence no longer captured (pruned)")
      end
      return
    end
    if rid = i.sample_repeater_id
      navigate_link_ref(Store::LinkRefKind::Repeater, rid)
      return
    end
    @toast = I18n.sys("this issue has no sample evidence")
  end

  # History list / open detail → the selected (or open) flow, or every MARKED flow (#442).
  # The popup then shows the summed per-rule estimate, so N>1 is confirm-gated by a request
  # count exactly as one flow already was.
  def probe_active_selected : Nil
    ids = history_target_flow_ids
    return (@toast = I18n.sys("select a flow first")) if ids.empty?
    # Capped like the other batch verbs, and for two reasons at once: the estimate below has to
    # load a FULL detail per flow (bodies included) before it can show a count, and ⇧T can mark
    # a whole page — so an uncapped run would freeze the render loop and then offer to send
    # thousands of requests.
    return unless targets = batch_within_cap(ids, "the active scan")
    # Through the store, not the view's rows — a mark can outlive the visible window.
    details = targets.compact_map { |id| @session.store.get_flow(id) }
    return (@toast = I18n.sys("flow no longer available")) if details.empty?
    open_probe_active_overlay(details)
  end

  # Probe findings list → the selected issue's sample flow (re-test the evidence in place).
  def probe_active_rescan : Nil
    return (@toast = I18n.sys("select an issue first")) unless i = probe_controller.view.target_issue
    fid = i.sample_flow_id
    return (@toast = I18n.sys("this issue has no captured flow to re-scan")) unless fid
    detail = @session.store.get_flow(fid)
    return (@toast = I18n.sys("evidence no longer captured (pruned)")) unless detail
    open_probe_active_overlay(detail)
  end

  # Repeater → the current session's last HTTP send (request as edited + its response).
  def probe_active_from_repeater : Nil
    detail = repeater_controller.active_scan_detail
    return (@toast = I18n.sys("send the request first (an active scan needs a response)")) unless detail
    open_probe_active_overlay(detail, repeater_id: repeater_controller.current_session_db_id)
  end

  # Promote a machine-found Probe issue to a human-confirmed Issue (the bridge to the
  # Issues report). Reuses Store#insert_issue; the issue's severity/host/sample flow carry over.
  def probe_promote : Nil
    return unless i = probe_controller.view.target_issue
    # Same call the CLI/MCP promote paths make. A store-busy Failed must NOT read as
    # "already promoted" — that would tell the user to stop retrying the one thing that
    # would fix it.
    case Probe::Triage.promote(@session.store, i).outcome
    in Probe::Triage::Outcome::AlreadyPromoted
      @toast = I18n.sys("already promoted to an issue")
    in Probe::Triage::Outcome::Failed
      @toast = I18n.sys("promotion failed (store busy) — nothing was written, try again")
    in Probe::Triage::Outcome::Promoted
      probe_controller.view.reload(@session.store)
      @toast = I18n.sys("promoted to issue — see the Issues tab")
    end
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

  # A Probe issue's detail is open — the gate for its AFFECTED URLS read verbs.
  def probe_detail_readable? : Bool
    probe_controller.probe_detail_readable?
  end
end
