# Comparer (diff two flows) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Open the flow picker to choose the flow for slot :a / :b. Snapshots recent flows
  # through the active Scope lens; the picker filters them in memory. Loading the pick
  # into the slot is the injected commit, so the same picker also serves the entity-link
  # flow (see Runner#build_link_add_picker) with no mode flag in the picker itself.
  def comparer_pick(slot : Symbol) : Nil
    # `raise_on_error: true`, not the TUI default: the lens is an OR chain of per-rule
    # `gori_ci_contains` / REGEXP callbacks, so this query CAN fail where `recent_flows`
    # could not — and the default degrade-to-`[]` would open a card claiming the project
    # holds nothing. Say what happened instead (history_view.cr takes the same exit).
    rows =
      begin
        @session.store.search(@scope.filter, 2000, raise_on_error: true)
      rescue ex
        @toast = "could not list flows: #{ex.message}"
        return
      end
    fp = FlowPicker.new(rows, slot, scoped: @scope.active?)
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

  # `n` / `N`: walk the diff by CHANGE rather than by row. A 900-line response whose diff is
  # one line put that line 400 ↓ presses from the top, with nothing to ask for it directly.
  def comparer_jump_change(dir : Int32) : Nil
    view = comparer_controller.view
    return (@toast = "pick flow A and flow B first") unless view.both_set?
    unless view.jump_change(dir)
      @toast = "no differences — the two are identical"
      return
    end
    @toast = nil # the footer's "n/total" readout is the answer; a toast would just cover it
  end

  # `f`: collapse the unchanged runs to a marker, keeping FOLD_CONTEXT rows of context
  # around every change — the diff of a long response, on one screen.
  def comparer_toggle_fold : Nil
    view = comparer_controller.view
    return (@toast = "pick flow A and flow B first") unless view.both_set?
    @toast = view.toggle_fold ? "comparer: unchanged runs folded" : "comparer: showing every line"
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

  # CROSS-TAB: the active Repeater tab's last send → the next Comparer slot. The Repeater
  # is where a request gets changed one header at a time, so "what did that change do to the
  # response" is the question this tab exists for — and it could not be asked, because a
  # Repeater send leaves no flow row for the picker to find.
  def comparer_add_repeater : Nil
    slot = repeater_controller.current_view.try(&.comparer_slot)
    return (@toast = "send the request first (^R) — there is no response to compare") unless slot
    which = comparer_controller.view.add_slot(slot)
    @toast = "comparer: set #{which.to_s.upcase} ← repeater — open Comparer (^P) to view the diff"
  end

  # CROSS-TAB: the Sitemap cursor's endpoint → the next Comparer slot, resolved through the
  # same representative-flow lookup `sitemap_repeater` / `sitemap_open_flow` use, so all three
  # agree about which capture a tree row stands for.
  def comparer_add_sitemap : Nil
    ep = sitemap_controller.view.selected_endpoint
    return (@toast = "select an endpoint to send") unless ep
    id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
    return (@toast = "no captured request for this path — capture it, or use Discover") unless id
    detail = @session.store.get_flow(id)
    return (@toast = "that request was pruned since the tree was built") unless detail
    which = comparer_controller.view.add_flow(detail)
    @toast = "comparer: set #{which.to_s.upcase} — open Comparer (^P) to view the diff"
  end

  # CROSS-TAB: the selected fuzz result → the next Comparer slot. The request is the one the
  # run sent (reconstructed when the run kept no bodies — the same seed `fuzz.repeater` uses),
  # and the response is whatever the row retained. A run without `keep bodies` still yields a
  # usable slot: `length`/`status`/`duration` were measured either way, so the meta readout and
  # the request diff both work, and only the response half comes up empty.
  def comparer_add_fuzz : Nil
    slot = fuzzer_controller.comparer_slot
    return (@toast = "select a result first") unless slot
    which = comparer_controller.view.add_slot(slot)
    @toast = "comparer: set #{which.to_s.upcase} ← fuzz — open Comparer (^P) to view the diff"
  end

  # Both flows are set — the gate for the diff's row select / copy verbs.
  def comparer_diff_shown? : Bool
    comparer_controller.comparer_diff_shown?
  end
end
