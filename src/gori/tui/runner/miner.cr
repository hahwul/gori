# Param Miner — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open the config popup for History's selected flow (space → Send flow to… → Miner).
  # Batch-capable (#442): ONE config popup, then a mining session per marked flow. Capped
  # like the other session-spawning verbs. Flows with no mineable location are dropped here
  # rather than starting an empty session.
  #
  # Each flow is seeded with the names its origin's OTHER endpoints carry (#1231), as the
  # Params sub-tab's Mine is — scanned while the popup is up (`seed_mine_names`).
  def mine_selected : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    return seed_mine_names(open_mine_config(miner_controller.build_seed_from_flow(ids.first))) if ids.size == 1
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
    seed_mine_names(open_mine_config(seeds[best], extra))
  end

  # Start the popup's inventory scan (Start cancels it — see `open_mine_config`).
  private def seed_mine_names(ov : MineConfigOverlay?) : Nil
    miner_controller.scan_seed_names(ov) if ov
  end

  # CROSS-TAB: open the config popup for the current Repeater request.
  def mine_from_repeater : Nil
    return unless v = repeater_controller.current_view
    v.flush_decoded_edits # fold a pending split-decode payload edit into the envelope first
    open_mine_config(miner_controller.build_seed_from_request(v.target, v.request_text, v.http2?, v.sni_override))
  end

  forward mine_run : Nil,
    mine_stop : Nil,
    mine_filter : Nil,
    to: miner_controller

  def miner_duplicate_subtab : Nil
    miner_controller.miner_duplicate
  end

  def mine_reconfigure : Nil
    reconfigure_mine
  end

  # Reopen the config popup on the focused session, filled from its own config. Apply writes
  # the popup's knobs onto a COPY of that config (what the popup has no row for survives) and
  # persists it; it does not start a run. Refused while the session is mining.
  def reconfigure_mine : Nil
    return (@toast = "no miner session to reconfigure") unless v = miner_controller.current_view
    if why = miner_controller.reconfigure_blocked_reason(v)
      return (@toast = why)
    end
    seed = miner_controller.build_seed_from_session(v)
    return (@toast = "no mineable locations for this request") if seed.applicable.empty?
    ov = MineConfigOverlay.new(seed, macro_sessions: macro_session_choices)
    ov.prefill(v.config)
    ov.on_commit = -> {
      if ov.any_checked?
        miner_controller.reconfigure_session(v, ov.apply_to(v.config.dup))
        true
      else
        @toast = "select at least one location to mine"
        false
      end
    }
    open_overlay(ov)
  end

  # The strip's raw `e` rename / ^W close, promoted to verbs. `Runner#renameable_subtabs?`
  # and `#subtab_close` have listed :miner all along; only the VERBS were missing, so the
  # `:subtab` space-menu group here held Duplicate alone and neither key was rebindable.
  def miner_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def miner_close_subtab : Nil
    miner_controller.request_close
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
  forward miner_detail_readable? : Bool, to: miner_controller

  forward miner_results_readable? : Bool, to: miner_controller
end
