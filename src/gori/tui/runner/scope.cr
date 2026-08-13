# Scope lens + rule editing — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # 's' / scope.edit: the Scope editor lives in the Project tab now, so jump there
  # and focus its SCOPE pane (saving the outgoing tab, like any tab switch).
  def scope_open : Nil
    focus_tab(:project)
    project_controller.focus_scope
  end

  # Batch-capable (#442): every marked flow's host, deduped, in ONE lens edit + one reload.
  # 12 flows on 2 hosts adds 2 rules, not 12.
  def scope_add_host : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    # Resolved through the store, never the view's rows: a kept mark can outlive the
    # visible window (filter change, trim, follow reload).
    hosts = ids.compact_map { |id| @session.store.flow_row(id).try(&.host) }.uniq!
    return (@toast = "no flows left to add") if hosts.empty?
    hosts.each { |h| @scope.add("include", "host", h) }
    @scope.enable
    history_controller.view.reload(@session.store)
    added = hosts.size == 1 ? hosts.first : "#{hosts.size} hosts"
    @toast = "added #{added} to scope (#{@scope.size})"
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

  # Toggle the sandbox from the palette — same path the Project NETWORK pane row/click takes,
  # so the empty-allowlist danger confirm and the write-committed check apply here too. No
  # reload: the sandbox changes what the proxy BLOCKS next, not what the current lists show.
  def scope_toggle_sandbox : Nil
    toggle_sandbox
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
