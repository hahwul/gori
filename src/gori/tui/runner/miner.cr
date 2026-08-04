# Param Miner — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open the config popup for History's selected flow (space → Mine params).
  # Batch-capable (#442): ONE config popup, then a mining session per marked flow. Capped
  # like the other session-spawning verbs. Flows with no mineable location are dropped here
  # rather than starting an empty session.
  def mine_selected : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    return open_mine_config(miner_controller.build_seed_from_flow(ids.first)) if ids.size == 1
    return unless targets = batch_within_cap(ids, "the Miner")
    seeds = targets.compact_map { |id| miner_controller.build_seed_from_flow(id) }.reject(&.applicable.empty?)
    return (@toast = "no mineable locations in the marked flows") if seeds.empty?
    # The config popup's checkboxes come from ONE seed, and the Runner then narrows the committed
    # config to each other seed's own `applicable` — so a location absent from the seeding flow
    # can never be checked and is silently unmineable everywhere. Seed from the flow offering the
    # MOST locations (a POST with a JSON body, not a bare GET), which makes the widest set of
    # choices reachable. Deliberately not `seeds.first`: that follows the display order, so a
    # history_list_order flip would change what the batch actually mines.
    best = (0...seeds.size).max_by { |i| seeds[i].applicable.size }
    extra = seeds.dup
    extra.delete_at(best)
    open_mine_config(seeds[best], extra)
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

  # The FINDING pane holds focus — the gate for its read verbs.
  def miner_detail_readable? : Bool
    miner_controller.miner_detail_readable?
  end
end
