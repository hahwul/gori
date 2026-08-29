# Project ACTIVITY pane (#864) — ExecContext verb implementations plus the one CROSS-TAB hop,
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Open whatever the selected event NAMES. The routing rule is `ProjectView.activity_target`,
  # a pure function of the row, so the decision is spec-able without a Runner and there is
  # exactly one of it.
  #
  # Two destinations, and they are not interchangeable. A row carrying `goto_tab` chose that
  # tab when it was written (Probe's H3 notice names Probe even though it also carries a flow),
  # so the producer's declaration wins; a row carrying only `flow_id` is a binding or hook
  # failure, where the captured exchange IS the explanation. The flow hop is deliberately the
  # SAME one `discover_open_flow` makes — drive the History controller, then raise its detail —
  # because the detail overlay's own navigation is gated on `@active_tab == :history`.
  def activity_open : Nil
    unless row = project_controller.view.activity_selected_row
      @toast = "no event selected"
      return
    end
    unless target = ProjectView.activity_target(row)
      # Most of the feed records something that happened rather than something to look at, and
      # a key that silently does nothing reads as a bug. Name the absence instead.
      @toast = "this event records no jump target"
      return
    end
    if tab = target.tab
      run_goto(Jobs::Goto.new(tab, target.session_id))
    elsif fid = target.flow_id
      # The row holds an id that was committed, so only a prune or a retention sweep between
      # then and now reaches the miss branch.
      open_flow_detail(fid, "that flow was pruned since the event recorded it")
    end
  end

  def activity_filter_source : Nil
    project_controller.activity_filter_source
  end

  def activity_filter_level : Nil
    project_controller.activity_filter_level
  end

  def activity_filter_actor : Nil
    project_controller.activity_filter_actor
  end

  def activity_clear_filters : Nil
    project_controller.activity_clear_filters
  end

  def activity_find : Nil
    project_controller.activity_find
  end

  def activity_refresh : Nil
    project_controller.activity_refresh
  end

  # DESTRUCTIVE, and the prompt has to say which record is going. `c` in the notification
  # center empties a hundred in-memory notes; `c` here deletes the durable log of what every
  # agent and background job did to this project — the same keystroke, two very different
  # losses — so this one asks, and names the audit trail explicitly rather than saying
  # "clear activity" and leaving the operator to find out what that meant.
  def activity_clear : Nil
    # `events_recent` deliberately does not rescue (its rows are an answer, not a garnish), so
    # every caller owns the failure. This was the one that did not: an error here escaped verb
    # dispatch into the tick-error breaker, spending its budget on a "recovered from an
    # internal error" repaint instead of the toast every other activity path produces.
    empty = begin
      @session.store.events_recent(1).rows.empty?
    rescue ex : DB::Error | SQLite3::Exception
      Log.warn(exception: ex) { "activity: event feed read failed before clear" }
      @toast = "could not read the event feed — see gori.log"
      return
    end
    if empty
      @toast = "activity: nothing to clear"
      return
    end
    # HAND-WRAPPED, like every other confirm in the app. `ConfirmDialog` splits on '\n' and
    # nothing else, and caps the card at 60 columns — so a line written as prose is TRUNCATED,
    # and this one lost the half that says what is being deleted ("…what each attac…"). A
    # destructive confirm that cannot finish naming the thing it destroys is the one place the
    # cap must not be discovered at runtime; keep every line inside ~50 columns.
    confirm("CLEAR ACTIVITY",
      "Delete every event in this project's feed?\n\n" \
      "That includes the agent audit trail — what each\n" \
      "attached agent changed and sent.\n" \
      "This can't be undone.",
      confirm_label: "clear", danger: true) do
      ok = @session.store.clear_events
      project_controller.reload_activity
      @toast = ok ? "activity cleared" : "activity NOT cleared (project busy) — the feed is unchanged"
    end
  end

  def activity_row_selected? : Bool
    !project_controller.view.activity_selected_row.nil?
  end
end
