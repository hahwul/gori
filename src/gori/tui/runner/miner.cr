# Param Miner — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open the config popup for History's selected flow (space → Mine params).
  def mine_selected : Nil
    id = history_target_flow_id
    return (@toast = "select a flow first") unless id
    open_mine_config(miner_controller.build_seed_from_flow(id))
  end

  # CROSS-TAB: open the config popup for the current Repeater request.
  def mine_from_repeater : Nil
    return unless v = repeater_controller.current_view
    v.flush_decoded_edits # fold a pending split-decode payload edit into the envelope first
    open_mine_config(miner_controller.build_seed_from_request(v.target, v.request_text, v.http2?, v.sni_override))
  end

  def mine_run : Nil
    miner_controller.mine_run
  end

  def mine_stop : Nil
    miner_controller.mine_stop
  end

  def miner_duplicate_subtab : Nil
    miner_controller.miner_duplicate
  end

  def miner_finding_selected? : Bool
    miner_controller.finding_selected?
  end

  # CROSS-TAB: inject the selected Miner finding into the session request and open Repeater.
  def mine_repeater_selected : Nil
    seed = miner_controller.selected_repeater_seed
    return (@toast = "select a finding first") unless seed
    repeater_controller.repeater_from_request(seed.target, seed.request_text, seed.http2, seed.sni,
      name: seed.label)
    @toast = "repeater ← miner: #{seed.label}"
  end
end
