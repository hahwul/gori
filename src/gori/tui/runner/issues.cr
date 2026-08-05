# Issues report — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # ONE issue, every targeted flow attached as evidence (#442). The form's title/host/primary
  # evidence come from the first flow; the rest ride along as extra_flow_ids and are linked
  # after the insert — so marking 5 flows and pressing ⇧F files one finding with five samples,
  # not five issues.
  def issue_create : Nil
    ids = history_target_flow_ids
    return if ids.empty?
    # The primary supplies the title/host/evidence; it is the CURSOR row when that is itself a
    # target, else the oldest mark — never `ids.first`, which follows the display order and would
    # hand a different flow the title after a history_list_order flip.
    primary = history_controller.primary_target_flow_id
    # Find the first target that still resolves rather than dead-ending on a stale primary: with
    # 5 marks and the primary deleted from another surface, giving up would silently discard four
    # live marks with no form and no toast.
    row = primary.try { |id| @session.store.flow_row(id) }
    row ||= ids.each.compact_map { |id| @session.store.flow_row(id) }.first?
    return (@toast = "no flows left to file an issue for") unless row
    open_issue_form(IssueForm.new("#{row.method} #{row.target}", row.host, row.id,
      extra_flow_ids: ids.reject(row.id)))
  end

  def issues_new : Nil
    open_issue_form(IssueForm.new)
  end

  def issues_query : Nil
    issues_controller.view.start_query
  end

  def issues_move(delta : Int32) : Nil
    issues_controller.issues_move(delta)
  end

  def issues_open : Nil
    issues_controller.issues_open
  end

  def issue_close : Nil
    issues_controller.issue_close
  end

  def issues_delete : Nil
    issues_controller.issues_delete
  end

  # The ONE resolver every batch-capable Issues verb calls: the marks if any are set, else
  # the cursor row — and just the open issue when the detail is up, which is pinned to one
  # (the plural of IssuesView#target_issue's own precedence).
  #
  # Callers must resolve each id THROUGH THE STORE, never through the view's rows: a kept
  # mark can outlive the visible list via a filter change or a peer's write.
  def issues_target_ids : Array(Int64)
    if f = issues_controller.view.detail_issue
      return [f.id]
    end
    issues_controller.target_issue_ids
  end

  def selected_issue_ids : Array(Int64)
    issues_target_ids
  end

  def selected_issue_id : Int64?
    issues_controller.view.selected_id
  end

  def marked_issue_count : Int32
    issues_controller.marked_issue_count
  end

  def issues_mark_toggle : Nil
    issues_controller.issues_mark_toggle
  end

  def issues_mark_all : Nil
    issues_controller.issues_mark_all
  end

  def issues_mark_clear : Nil
    issues_controller.issues_mark_clear
  end

  def issues_mark_extend(delta : Int32) : Nil
    issues_controller.issues_mark_extend(delta)
  end

  def issue_severity(delta : Int32) : Nil
    issues_controller.issue_severity(delta)
  end

  def issue_status(delta : Int32) : Nil
    issues_controller.issue_status(delta)
  end

  # Open the colour pickers over the effective target set — the open detail's issue, else
  # the marks, else the cursor row. The picker (a shell overlay) writes the chosen value to
  # every target on commit. The ids are captured HERE, not re-resolved at commit: the list
  # re-sorts on the very edit this makes, so re-reading the marks afterwards would be
  # reading a list the pick itself moved.
  def issue_set_severity : Nil
    ids = issues_target_ids
    return if ids.empty?
    seed = issues_picker_seed(ids)
    return (@toast = "no issues left to update") unless seed
    open_choice_picker(ChoicePicker.for_severity(seed.severity.value)) { |p| apply_issue_choice(p, ids) }
  end

  def issue_set_status : Nil
    ids = issues_target_ids
    return if ids.empty?
    seed = issues_picker_seed(ids)
    return (@toast = "no issues left to update") unless seed
    open_choice_picker(ChoicePicker.for_status(seed.status.value)) { |p| apply_issue_choice(p, ids) }
  end

  # Which target's current value the picker opens on: the privileged one (the cursor row when
  # it is itself a target, else the oldest — NOT the display-order first, which the severity
  # sort would reshuffle on every edit), falling through to the next id that still resolves
  # so a single stale mark can't dead-end a live batch.
  private def issues_picker_seed(ids : Array(Int64)) : Store::Issue?
    store = @session.store
    primary = issues_controller.view.detail_issue.try(&.id) || issues_controller.primary_target_issue_id
    primary.try { |id| store.get_issue(id) } ||
      ids.each.compact_map { |id| store.get_issue(id) }.first?
  end

  def issue_edit_notes : Nil
    issues_controller.issue_edit_notes
  end

  def issues_notes_read_mode? : Bool
    issues_controller.issues_notes_read_mode?
  end

  def issues_copy : Nil
    issues_controller.issues_copy
  end

  def issues_copy_all : Nil
    issues_controller.issues_copy_all
  end

  # Re-open the create form seeded from the open issue (title + severity), in
  # edit mode — commit updates instead of inserting (create_issue_from_form).
  # Stays in the shell: it opens the issue-form OVERLAY (shell-owned).
  def issue_edit_title : Nil
    return unless f = issues_controller.view.detail_issue
    open_issue_form(IssueForm.new(f.title, f.host, f.flow_id, f.severity, edit_id: f.id, heading: "EDIT ISSUE"))
  end

  # Jump from an issue to its linked flow's request/response in History. CROSS-TAB
  # mediator: reads the Issues controller, drives the History controller + overlay.
  def issue_open_flow : Nil
    return unless f = issues_controller.view.detail_issue
    return (@toast = "this issue has no linked flow") unless fid = f.flow_id
    if history_controller.view.open_detail_id(fid, @session.store)
      @active_tab = :history
      @focus = :body
      @overlay = OverlayKind::Detail
    else
      @toast = "evidence no longer captured (pruned)"
    end
  end

  # Send an issue's linked flow to the Repeater tab to re-test the evidence. CROSS-TAB
  # mediator: reads the Issues controller, opens a Repeater tab.
  def issue_repeater_flow : Nil
    return unless f = issues_controller.view.detail_issue
    return (@toast = "this issue has no linked flow") unless fid = f.flow_id
    if @session.store.get_flow(fid)
      repeater_flow(fid)
    else
      @toast = "evidence no longer captured (pruned)"
    end
  end

  def issue_links : Nil
    return unless f = issues_controller.view.detail_issue
    open_links_overlay(Store::LinkOwnerKind::Issue, f.id)
  end

  def issue_open_link : Nil
    if res = issues_controller.view.selected_resolved_link
      navigate_link_ref(res.link.ref_kind, res.link.ref_id)
    else
      @toast = "no related link selected"
    end
  end

  def issue_link_move(delta : Int32) : Nil
    issues_controller.issue_link_move(delta)
  end

  # Ask where to write the report, then write it. The empty-store check happens BEFORE the
  # popup (asking for a path and then refusing to write is worse than not asking), and uses
  # count_issues rather than materializing store.issues here and again in the controller.
  def issues_export(format : Symbol) : Nil
    if @session.store.count_issues == 0
      @toast = "no issues to export"
      return
    end
    ext = format == :json ? "json" : "md"
    kind = format == :json ? :issues_json : :issues_md
    open_export(kind, File.join(Dir.current, "issues.#{ext}")) { |p| issues_controller.issues_export_to(format, p) }
  end
end
