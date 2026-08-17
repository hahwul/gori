# Repeater workbench — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- Repeater ExecContext --- (delegated to RepeaterController; cross-tab mediators kept)
  # CROSS-TAB mediator: load History's selection into a new Repeater tab.
  # Batch-capable (#442): one sub-tab per marked flow, capped (BATCH_SUBTAB_CAP) since ⇧T
  # over a filtered list can mark up to a full page. Nothing is SENT here — a Repeater
  # session only fires on ^R — so the >1 case just confirms the sub-tab count.
  def repeater_selected : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    return repeater_controller.repeater_flow(ids.first) if ids.size == 1
    return unless ids = batch_within_cap(ids, "Repeater")
    targets = ids
    confirm("SEND TO REPEATER", "Open #{targets.size} flows as #{targets.size} Repeater sub-tabs?",
      confirm_label: "open", danger: false) do
      opened = 0
      targets.each do |id|
        next unless @session.store.flow_row(id) # a stale mark: skip, report in the summary
        repeater_controller.repeater_flow(id)
        opened += 1
      end
      @toast = batch_summary("opened", opened, targets.size)
    end
  end

  def repeater_new : Nil
    repeater_controller.repeater_new
  end

  def repeater_send : Nil
    repeater_controller.repeater_send
  end

  def repeater_send_group : Nil
    repeater_controller.repeater_send_group
  end

  # Open the Repeater sub-tab search picker (space → s). Snapshots the open
  # sessions; the picker filters them in memory and jumps on ↵.
  def repeater_find_subtab : Nil
    subtab_search_open
  end

  def repeater_subtab_count : Int32
    repeater_controller.count
  end

  # Space-menu (:subtab) counterparts of the strip's `r` rename chord / ^W close —
  # reuse the SAME shell-owned rename prompt / confirm-gated close, not a new path.
  def repeater_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  # Space-menu counterparts of the strip's `t` tag chord / `/` filter chord (issue
  # #121) — reuse the SAME shell-owned tag prompt / controller-owned filter bar.
  def repeater_tag_subtab : Nil
    open_tag_edit(current_subtab_index)
  end

  def repeater_filter_subtabs : Nil
    repeater_controller.start_subtab_filter
  end

  def repeater_close_subtab : Nil
    repeater_controller.request_close
  end

  def repeater_duplicate_subtab : Nil
    repeater_controller.repeater_duplicate
  end

  def repeater_toggle_hex : Nil
    repeater_controller.repeater_toggle_hex
  end

  def repeater_toggle_decoded : Nil
    repeater_controller.repeater_toggle_decoded
  end

  def repeater_toggle_sni : Nil
    repeater_controller.repeater_toggle_sni
  end

  def repeater_toggle_auto_content_length : Nil
    repeater_controller.repeater_toggle_auto_content_length
  end

  def repeater_toggle_http2 : Nil
    repeater_controller.repeater_toggle_http2
  end

  def repeater_toggle_ws_key : Nil
    repeater_controller.repeater_toggle_ws_key
  end

  def repeater_toggle_grpc_reframe : Nil
    repeater_controller.repeater_toggle_grpc_reframe
  end

  # Space-menu (:response) counterparts of the response pane's raw `d`/`x` keys —
  # same RepeaterView toggles, just reachable without memorizing the key.
  def repeater_toggle_resp_diff : Nil
    # Pane-gated: plain `d` is a response-only tool (request has other uses).
    return unless (v = repeater_controller.current_view) && v.focus == :response
    v.toggle_resp_mode
  end

  def repeater_toggle_resp_hex : Nil
    return unless (v = repeater_controller.current_view) && v.focus == :response
    v.toggle_resp_hex
  end

  def repeater_pretty_request : Nil
    repeater_controller.repeater_pretty_request
  end

  def repeater_minimize : Nil
    repeater_controller.repeater_minimize
  end

  def repeater_auto_mark : Nil
    repeater_controller.repeater_auto_mark
  end

  def repeater_mark_word : Nil
    repeater_controller.repeater_mark_word
  end

  def repeater_insert_marker : Nil
    repeater_controller.repeater_insert_marker
  end

  def repeater_clear_marks : Nil
    repeater_controller.repeater_clear_marks
  end

  # ^Q: jump focus DOWN into the visible CHAIN pane (the marker under the cursor). The
  # controller gates on the request pane + cursor-in-marker and toasts otherwise.
  def repeater_attach_chain : Nil
    repeater_controller.repeater_focus_chain_pane
  end

  def repeater_copy : Nil
    repeater_controller.repeater_copy
  end

  def repeater_copy_all : Nil
    repeater_controller.repeater_copy_all
  end

  def repeater_read_mode? : Bool
    repeater_controller.repeater_read_mode?
  end
end
