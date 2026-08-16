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

  # The identity LIST card. Add/edit hand off to the form and come back here.
  #
  # An overlay cannot open another overlay — `open_overlay` is private to the Runner — so the
  # list ARMS `pending` and closes, and this `on_close` (run by the shell AFTER the card is
  # dropped) is what opens the form. Same shape as the Links list → picker hand-off.
  def open_authorize_identities : Nil
    open_authorize_identities_at(nil)
  end

  private def open_authorize_identities_at(cursor : Int32?) : Nil
    list = AuthorizeIdentitiesOverlay.new(authorize_controller.identities, cursor)
    list.on_change = ->(updated : Array(Gori::Authorize::Identity)) {
      authorize_controller.replace_identities(updated)
    }
    list.on_close = -> {
      if pending = list.pending
        open_authorize_identity_form(pending, list.selected)
      end
    }
    open_overlay(list)
  end

  private def open_authorize_identity_form(pending : AuthorizeIdentitiesOverlay::Pending,
                                           cursor : Int32) : Nil
    all = authorize_controller.identities
    idx = pending.index
    editing = idx ? all[idx]? : nil
    # Every OTHER identity's name, so the form can refuse a duplicate: two rows under one
    # label in the results table would leave no way to tell which session produced which.
    taken = all.each_with_index.compact_map { |(id, i)| i == idx ? nil : id.name }.to_a
    form = AuthorizeIdentityOverlay.new(editing, idx, taken)
    form.on_commit = -> { authorize_controller.apply_identity(idx, form.build_identity) }
    # Both paths — saved or cancelled — return to a FRESHLY built list, so it shows whatever
    # the commit just wrote.
    form.on_close = -> { open_authorize_identities_at(cursor) }
    open_overlay(form)
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

  def authorize_toggle_passive : Nil
    authorize_controller.toggle_passive
  end

  def authorize_passive? : Bool
    authorize_controller.passive?
  end

  def authorize_identities : Nil
    if authorize_controller.identities_editable?
      open_authorize_identities
    else
      @toast = "a run is in flight — ^X to stop it first"
    end
  end
end
