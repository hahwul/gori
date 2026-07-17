# Comparer (diff two flows) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Open the flow picker to choose the flow for slot :a / :b. Snapshots recent
  # flows; the picker filters them in memory.
  def comparer_pick(slot : Symbol) : Nil
    @flow_picker = FlowPicker.new(@session.store.recent_flows(2000), slot)
    @overlay = :comparer_pick
  end

  def comparer_swap : Nil
    comparer_controller.view.swap
    @toast = "comparer: swapped A ⇄ B"
  end

  def comparer_toggle_pane : Nil
    view = comparer_controller.view
    view.toggle_pane
    @toast = "comparer: comparing #{view.pane}s"
  end

  def comparer_new : Nil
    comparer_controller.comparer_new
  end

  def comparer_close_subtab : Nil
    comparer_controller.comparer_close
    resolve_subtab_focus_after_close
  end

  def comparer_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def comparer_duplicate_subtab : Nil
    comparer_controller.comparer_duplicate
  end

  # CROSS-TAB mediator: send History's selected flow to the next Comparer slot
  # on the *active* comparison sub-tab (rings A → B → A).
  def comparer_add_selected : Nil
    id = history_target_flow_id
    return (@toast = "select a flow first") unless id
    detail = @session.store.get_flow(id)
    return (@toast = "flow no longer available") unless detail
    slot = comparer_controller.view.add_flow(detail)
    @toast = "comparer: set #{slot.to_s.upcase} — open Comparer (^P) to view the diff"
  end
end
