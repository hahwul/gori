# Issues report — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def issue_create : Nil
    id = history_target_flow_id
    return unless id
    if row = @session.store.flow_row(id)
      open_issue_form(IssueForm.new("#{row.method} #{row.target}", row.host, id))
    end
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

  def issue_severity(delta : Int32) : Nil
    issues_controller.issue_severity(delta)
  end

  def issue_status(delta : Int32) : Nil
    issues_controller.issue_status(delta)
  end

  # Open the colour pickers for the issue currently in the detail view. The picker (a
  # shell overlay) writes the chosen value to the open issue on commit.
  def issue_set_severity : Nil
    return unless f = issues_controller.view.detail_issue
    open_choice_picker(ChoicePicker.for_severity(f.severity.value)) { |p| apply_issue_choice(p) }
  end

  def issue_set_status : Nil
    return unless f = issues_controller.view.detail_issue
    open_choice_picker(ChoicePicker.for_status(f.status.value)) { |p| apply_issue_choice(p) }
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

  def issue_hscroll(delta : Int32) : Nil
    issues_controller.issue_hscroll(delta)
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
