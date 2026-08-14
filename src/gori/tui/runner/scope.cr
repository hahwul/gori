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
    # A host gori itself could not store as a rule — a flow captured with no Host header at
    # all, say — is named, not counted as added and not blamed on the store below.
    hosts, unusable = hosts.map(&.strip).partition { |h| !h.empty? && Scope.valid?("host", h) }
    return (@toast = "no usable host on the selected flow#{ids.size == 1 ? "" : "s"}") if hosts.empty?
    # `add` answers whether the rule LANDED and `enable` whether the lens flag COMMITTED;
    # both answers used to be discarded and the toast said "added <host> to scope" either way.
    # A busy or locked project was therefore told hosts were scoped while the scope had not
    # changed — the one claim every other scope write path in gori checks (the CLI, MCP, and
    # the Project pane's own :failed branch). `add` collapses "already there" and "the store
    # refused it" into ONE false, so neither is read off its return: the rule list says which
    # is which. Present before ⇒ already scoped; absent after ⇒ the store refused it.
    known = hosts.select { |h| scope_has_host_include?(h) }
    hosts.each { |h| @scope.add("include", "host", h) }
    lens = @scope.enable
    history_controller.view.reload(@session.store)
    missing = hosts.reject { |h| scope_has_host_include?(h) }
    added = hosts - known - missing
    # ONE tail for every outcome. Two early returns here dropped `unusable` and `lens`, so
    # "already in scope: 2 hosts" could be the whole report of a press that ALSO failed to
    # turn on the lens it was pressed for — the same silence this method is being fixed for.
    msg =
      if !added.empty?
        m = "added #{name_hosts(added)} to scope (#{@scope.size})"
        m += " · #{known.size} already there" unless known.empty?
        m
      elsif !missing.empty?
        "scope NOT changed (project busy) — nothing was added"
      else
        "already in scope: #{name_hosts(known)}"
      end
    msg += " · #{missing.size} NOT added (project busy)" unless missing.empty? || added.empty?
    msg += " · #{unusable.size} skipped (not a host)" unless unusable.empty?
    msg += " · lens NOT enabled (project busy)" unless lens
    @toast = msg
  end

  # One host by name, several by count — the toast has one line and a batch can be 12 hosts.
  private def name_hosts(hosts : Array(String)) : String
    hosts.size == 1 ? hosts.first : "#{hosts.size} hosts"
  end

  # Is `host` already an include/host rule? The read-back behind scope_add_host's report.
  private def scope_has_host_include?(host : String) : Bool
    @scope.rules.any? { |r| r.include? && r.host_type? && r.pattern == host }
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
