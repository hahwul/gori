# Comparer (diff two flows) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Open the flow picker to choose the flow for slot :a / :b. Snapshots recent
  # flows; the picker filters them in memory. Loading the pick into the slot is the
  # injected commit, so the same picker also serves the entity-link flow (see
  # Runner#build_link_add_picker) with no mode flag in the picker itself.
  def comparer_pick(slot : Symbol) : Nil
    fp = FlowPicker.new(@session.store.recent_flows(2000), slot)
    fp.on_commit = -> { comparer_load_slot(fp, slot) }
    open_overlay(fp)
  end

  private def comparer_load_slot(fp : FlowPicker, slot : Symbol) : Bool
    if row = fp.selected_row
      if detail = @session.store.get_flow(row.id)
        comparer_controller.view.set_slot(slot, detail)
        @toast = "comparer: set #{slot.to_s.upcase} — #{row.method} #{row.host}"
      else
        @toast = "flow no longer available"
      end
    end
    true
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
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    return comparer_add_pair(ids) if ids.size == 2
    # 1 mark (or none — the cursor row), or 3+: keep the next-slot ring. 3+ marks has no
    # meaning for a two-slot diff, so it falls back rather than silently picking two.
    @toast = "comparer takes 2 flows — mark exactly 2, or use the cursor row" if ids.size > 2
    id = ids.first
    detail = @session.store.get_flow(id)
    return (@toast = "flow no longer available") unless detail
    slot = comparer_controller.view.add_flow(detail)
    @toast = "comparer: set #{slot.to_s.upcase} — open Comparer (^P) to view the diff"
  end

  # Exactly 2 marked (#442): fill A and B directly instead of making the user guess where
  # today's next-slot ring (A → B → A) happens to be. A is the OLDER flow (lower id) and B
  # the newer regardless of the list's display direction — a diff reads before → after.
  private def comparer_add_pair(ids : Array(Int64)) : Nil
    older, newer = ids.minmax
    a = @session.store.get_flow(older)
    b = @session.store.get_flow(newer)
    return (@toast = "flow no longer available") unless a && b
    comparer_controller.view.set_pair(a, b)
    @toast = "comparer: A ##{older} · B ##{newer} — open Comparer (^P) to view the diff"
  end

  # Both flows are set — the gate for the diff's row select / copy verbs.
  def comparer_diff_shown? : Bool
    comparer_controller.comparer_diff_shown?
  end
end
