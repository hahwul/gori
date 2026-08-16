# Authorize (access-control / multi-identity replay) — ExecContext verb implementations,
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop and Host facade).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: History's selected (or marked) flows → the Authorize queue, then jump there.
  # Batch-capable: every marked flow becomes a request row, replayed under the same identities.
  def authorize_seed_selected : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    added, skipped = authorize_controller.seed_flows(ids)
    goto_tab(:authorize) if added > 0
    @toast = authorize_seed_toast(added, skipped)
  end

  # CROSS-TAB: the Sitemap cursor's endpoint → the Authorize queue, resolved through the same
  # representative-flow lookup the Comparer/Repeater sends use.
  def authorize_seed_sitemap : Nil
    ep = sitemap_controller.view.selected_endpoint
    return (@toast = "select an endpoint to send") unless ep
    id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
    return (@toast = "no captured request for this path — capture it, or use Discover") unless id
    added, skipped = authorize_controller.seed_flows([id])
    goto_tab(:authorize) if added > 0
    @toast = authorize_seed_toast(added, skipped)
  end

  # What a seed actually did. A duplicate is REPORTED rather than dropped in silence — the
  # queue size not moving is otherwise indistinguishable from the send having failed.
  private def authorize_seed_toast(added : Int32, skipped : Int32) : String
    return "authorize: already queued" if added == 0 && skipped > 0
    return "those flows are no longer available" if added == 0
    base = "authorize: loaded #{added} request#{added == 1 ? "" : "s"}"
    return "#{base}, #{skipped} already queued" if skipped > 0
    "#{base} — ^R to run"
  end

  def authorize_run : Nil
    authorize_controller.run(:pending)
  end

  def authorize_run_all : Nil
    authorize_controller.run(:all)
  end

  def authorize_run_one : Nil
    authorize_controller.run(:one)
  end

  def authorize_stop : Nil
    authorize_controller.stop
  end

  def authorize_remove : Nil
    authorize_controller.remove_selected
  end

  def authorize_clear : Nil
    authorize_controller.clear
  end

  def authorize_has_target? : Bool
    authorize_controller.has_target?
  end

  def authorize_running? : Bool
    authorize_controller.running?
  end
end
