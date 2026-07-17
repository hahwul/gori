# Scope lens + rule editing — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # 's' / scope.edit: the Scope editor lives in the Project tab now, so jump there
  # and focus its SCOPE pane (saving the outgoing tab, like any tab switch).
  def scope_open : Nil
    focus_tab(:project)
    project_controller.focus_scope
  end

  def scope_add_host : Nil
    id = history_target_flow_id
    return unless id
    if row = @session.store.flow_row(id)
      @scope.add("include", "host", row.host)
      @scope.enable
      history_controller.view.reload(@session.store)
      @toast = "added #{row.host} to scope (#{@scope.size})"
    end
  end

  # Toggle the scope display lens (in-scope-only ⇄ all flows) right from History —
  # the lens filters History/Sitemap, so reload the active list and confirm the state.
  def scope_toggle_lens : Nil
    @scope.toggle
    history_controller.view.reload(@session.store)
    sitemap_controller.reload if @active_tab == :target && target_controller.sitemap_active?
    probe_controller.view.reload(@session.store) if @active_tab == :probe
    project_controller.toast_scope_state
  end

  # Project SCOPE-pane rule editing (a/e/d + space menu → popup overlay).
  def scope_add_rule : Nil
    project_controller.scope_add_rule
  end

  def scope_edit_rule : Nil
    project_controller.scope_edit_rule
  end

  def scope_delete_rule : Nil
    project_controller.scope_delete_rule
  end

  def scope_rule_selected? : Bool
    @scope.size > 0
  end
end
