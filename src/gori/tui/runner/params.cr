# Params (the per-endpoint parameter inventory, #1231) — ExecContext verb implementations,
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays,
# and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  private def params_controller : ParamsController
    target_controller.params
  end

  # ↑ at the top row leaves for the sub-tab strip, like Diff's list and every other list pane.
  def params_move(delta : Int32) : Nil
    view = params_controller.view
    return request_focus(:subtabs) if delta < 0 && view.at_top?
    view.move(delta)
  end

  def params_run : Nil
    params_controller.run
  end

  def params_toggle_headers : Nil
    params_controller.toggle_all_headers
    @toast = params_controller.view.all_headers? ? "params: all headers" : "params: standard headers left out"
  end

  def params_clear_target : Nil
    params_controller.set_target(nil)
  end

  def params_copy_names : Nil
    params_controller.copy_names
  end

  def params_export : Nil
    params_controller.export_wordlist
  end

  def params_rows_shown? : Bool
    @active_tab == :target && target_controller.params_active? &&
      !params_controller.view.selected_row.nil?
  end

  def params_targeted? : Bool
    @active_tab == :target && target_controller.params_active? && !params_controller.view.target.nil?
  end

  # The Sitemap's `p`: Params narrowed to the cursor row — its host, or the endpoint paths
  # under it.
  def sitemap_params : Nil
    unless t = sitemap_controller.view.selected_params_target
      @toast = "select a host or path first"
      return
    end
    target_controller.select_params(t)
    @focus = :body
  end

  # The row's flow was pruned, or a History clear gave its id to another request.
  PARAMS_GONE = "that request is gone since the scan — rescan (^R)"

  # CROSS-TAB: the row's NEWEST carrying flow in the History detail — the hop
  # `sitemap_open_flow` makes, by id rather than by a representative-flow lookup, since the
  # inventory already knows which flows carried the name.
  def params_open_flow : Nil
    unless row = params_controller.view.selected_row
      @toast = "select a parameter first"
      return
    end
    if (id = params_controller.carrying_flow_id(row)) && history_controller.view.open_detail_id(id, @session.store)
      @active_tab = :history
      @focus = :body
      @overlay = OverlayKind::Detail
    else
      @toast = PARAMS_GONE
    end
  end

  # CROSS-TAB: mine the row's endpoint (its newest carrying flow as the base request), with
  # the names seen on the host's OTHER endpoints tested first. Its own names are left out on
  # purpose — Miner skips a name the base request already carries (`already-in-request`).
  def params_mine : Nil
    view = params_controller.view
    unless row = view.selected_row
      @toast = "select a parameter first"
      return
    end
    seed = params_controller.carrying_flow_id(row).try { |id| miner_controller.build_seed_from_flow(id) }
    unless seed
      @toast = PARAMS_GONE
      return
    end
    names = ParamInventory.neighbor_names(view.host_rows(row.host), row.host, row.path)
    open_mine_config(seed.copy_with(names: names))
  end
end
