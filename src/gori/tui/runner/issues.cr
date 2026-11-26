# Issues report — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # ONE issue, every targeted flow attached as evidence (#442). The form's title/host/primary
  # evidence come from the first flow; the rest ride along as extra_flow_ids and are linked
  # after the insert — so marking 5 flows and pressing ⇧F files one finding with five samples,
  # not five issues.
  #
  # And the bytes go with it (#1038). This is the most-used filing path in the program, so it
  # follows the same rule "Link…" does: what proved the finding is COPIED, not only pointed
  # at. The copies are taken and their gates answered BEFORE the form opens — the operator is
  # about to spend a minute on a title, and an exchange can change underneath it — then handed
  # to the form, which writes them once the issue exists. A pending flow is attached exactly
  # as it is today; it simply has no bytes to keep.
  def issue_create : Nil
    ids = history_target_flow_ids
    return if ids.empty?
    return if history_hidden_marks_gate?("ADD ISSUE", "File one issue with") { issue_create }
    # The primary supplies the title/host/evidence; it is the CURSOR row when that is itself a
    # target, else the oldest mark — never `ids.first`, which follows the display order and would
    # hand a different flow the title after a history_list_order flip.
    # The drill-in's flow first: filed from it, the flow on screen is the primary even when
    # the list underneath holds marks or follow moved the cursor (the controller only knows
    # the marks and the cursor). `@detail_pin` for a caller that closed the detail first.
    # The hidden-marks card's cursor-row answer has exactly one target, and the controller's
    # primary would still read the marks it was chosen over.
    primary = @detail_pin || detail_pinned_flow_id ||
              (history_cursor_pick? ? ids.first : history_controller.primary_target_flow_id)
    # Find the first target that still resolves rather than dead-ending on a stale primary: with
    # 5 marks and the primary deleted from another surface, giving up would silently discard four
    # live marks with no form and no toast.
    row = primary.try { |id| @session.store.flow_row(id) }
    row ||= ids.each.compact_map { |id| @session.store.flow_row(id) }.first?
    return (@toast = "no flows left to file an issue for") unless row
    extra = ids.reject(row.id)
    refs = ([row.id] + extra).map { |id| {Store::LinkRefKind::Flow, id} }
    with_freeze_gates(evidence_snapshots(refs).compact_map(&.snapshot), "a new issue") do |copies|
      open_issue_form(IssueForm.new("#{row.method} #{row.target}", row.host, row.id,
        extra_flow_ids: extra, snapshots: copies))
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

  forward issues_open : Nil,
    issue_close : Nil,
    to: issues_controller

  # `⇧N`/`⇧P` in the drill-in — the next/previous issue, in place.
  def issue_step_item(delta : Int32) : Nil
    issues_controller.issue_step_item(delta)
  end

  forward issues_delete : Nil,
    issues_clear : Nil,
    to: issues_controller

  # The ONE resolver every batch-capable Issues verb calls: the marks if any are set, else
  # the cursor row — and just the open issue when the detail is up, which is pinned to one
  # (the plural of IssuesView#target_issue's own precedence).
  #
  # Callers must resolve each id THROUGH THE STORE, never through the view's rows: a kept
  # mark can outlive the visible list via a filter change or a peer's write.
  def issues_target_ids : Array(Int64)
    if picked = @issues_marks_pick
      return picked[0]
    end
    if f = issues_controller.view.detail_issue
      return [f.id]
    end
    issues_controller.target_issue_ids
  end

  # The Issues twin of `@history_marks_pick` / `history_hidden_marks_gate?` (runner.cr): the
  # hidden-marks card's answer, held for the one synchronous re-run of the verb that raised it.
  @issues_marks_pick : {Array(Int64), Bool}? = nil

  private def issues_hidden_marks_gate?(heading : String, question : String, *,
                                        skip_in_detail : Bool = true, &rerun : -> Nil) : Bool
    return false if @issues_marks_pick || @active_tab != :issues || (skip_in_detail && issues_controller.view.detail_open?)
    issues_controller.hidden_marks_card?(heading, question) do |ids, cursor_only|
      @issues_marks_pick = {ids, cursor_only}
      begin
        rerun.call
      ensure
        @issues_marks_pick = nil
      end
    end
  end

  def selected_issue_ids : Array(Int64)
    issues_target_ids
  end

  def selected_issue_id : Int64?
    issues_controller.view.selected_id
  end

  forward marked_issue_count : Int32,
    issues_mark_toggle : Nil,
    issues_mark_all : Nil,
    issues_mark_clear : Nil,
    to: issues_controller

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
    return if issues_hidden_marks_gate?("SET SEVERITY", "Set the severity of") { issue_set_severity }
    seed = issues_picker_seed(ids)
    return (@toast = "no issues left to update") unless seed
    open_choice_picker(ChoicePicker.for_severity(seed.severity.value)) { |p| apply_issue_choice(p, ids) }
  end

  def issue_set_status : Nil
    ids = issues_target_ids
    return if ids.empty?
    return if issues_hidden_marks_gate?("SET STATUS", "Set the status of") { issue_set_status }
    seed = issues_picker_seed(ids)
    return (@toast = "no issues left to update") unless seed
    open_choice_picker(ChoicePicker.for_status(seed.status.value)) { |p| apply_issue_choice(p, ids) }
  end

  # Score the target set. Same target rule as the two pickers above, and the same reason the
  # ids are captured here: a cvss write re-sorts the list under the modal (it moves severity
  # with it), so re-reading the marks at commit would read a list this edit just moved.
  def issue_set_cvss : Nil
    ids = issues_target_ids
    return if ids.empty?
    return if issues_hidden_marks_gate?("SET CVSS", "Score") { issue_set_cvss }
    seed = issues_picker_seed(ids)
    return (@toast = "no issues left to update") unless seed
    calc = CvssCalculatorOverlay.new(seed.cvss || "")
    calc.on_commit = -> { apply_issue_cvss(calc, ids) }
    open_overlay(calc)
  end

  # Which target's current value the picker opens on: the privileged one (the cursor row when
  # it is itself a target, else the oldest — NOT the display-order first, which the severity
  # sort would reshuffle on every edit), falling through to the next id that still resolves
  # so a single stale mark can't dead-end a live batch.
  private def issues_picker_seed(ids : Array(Int64)) : Store::Issue?
    store = @session.store
    # The hidden-marks card's cursor-row answer has one target; the controller's primary
    # would still read the marks it was chosen over.
    primary = issues_controller.view.detail_issue.try(&.id) ||
              (@issues_marks_pick.try(&.[1]) ? ids.first? : issues_controller.primary_target_issue_id)
    primary.try { |id| store.get_issue(id) } ||
      ids.each.compact_map { |id| store.get_issue(id) }.first?
  end

  forward issue_edit_notes : Nil,
    issues_notes_read_mode? : Bool,
    to: issues_controller

  # Re-open the create form seeded from the open issue (title + severity), in
  # edit mode — commit updates instead of inserting (create_issue_from_form).
  # Stays in the shell: it opens the issue-form OVERLAY (shell-owned).
  def issue_edit_title : Nil
    return unless f = issues_controller.view.detail_issue
    open_issue_form(IssueForm.new(f.title, f.host, f.flow_id, f.severity, edit_id: f.id, heading: "EDIT ISSUE", cvss: f.cvss || ""))
  end

  def issue_links : Nil
    return unless f = issues_controller.view.detail_issue
    open_links_overlay(Store::LinkOwnerKind::Issue, f.id)
  end

  # `issue_open_link`, `issue_goto_link` and `issue_repeater_flow` live in runner/evidence.cr:
  # all three act on the RELATED row under the cursor — ↵ shows its exchange, `s` goes to its
  # source, `r` sends it to the Repeater — and the frozen half of each is the same code the
  # Evidence tab runs, so the three belong beside it.
  #
  # There is no `issue_open_flow` any more: `o` opened the primary flow in History, which is
  # `s` on the first RELATED row now that the primary flow IS that row.

  def issue_link_move(delta : Int32) : Nil
    issues_controller.issue_link_move(delta)
  end

  # The export formats, in the order `ChoicePicker.for_export_format` lists them — its
  # `Choice#value` is an index into this array, so the picker holds the labels and this
  # holds the symbols, and neither spells the other's half.
  EXPORT_FORMATS = [:markdown, :json, :sarif]

  # Step one: WHICH format. Asked rather than baked into the verb because the answer changes
  # per export — the same finding goes to a teammate as Markdown and to CI as SARIF — and a
  # verb per format meant a new palette entry every time a format was added.
  #
  # The empty-store check happens BEFORE the picker for the reason it used to happen before
  # the path popup: asking two questions and then refusing to write is worse than not asking.
  # It uses count_issues rather than materializing store.issues here and again downstream.
  def issues_export_pick : Nil
    return if issues_hidden_marks_gate?("EXPORT ISSUES", "Export", skip_in_detail: false) { issues_export_pick }
    if refusal = issues_export_refusal
      @toast = refusal
      return
    end
    pick = @issues_marks_pick
    # A modal opened from inside another's commit is not closed afterwards (see
    # `close_active_overlay`) — the same seam `open_view_scope` rides for its two-step.
    open_choice_picker(ChoicePicker.for_export_format) do |p|
      @issues_marks_pick = pick
      begin
        issues_export(EXPORT_FORMATS[p.selected_value]? || :markdown)
      ensure
        @issues_marks_pick = nil
      end
    end
  end

  # Step two: WHERE to write it. Still reachable on its own — `gori run issues --export` has
  # no picker, and a caller that already knows the format should not have to open one.
  def issues_export(format : Symbol) : Nil
    return if issues_hidden_marks_gate?("EXPORT ISSUES", "Export", skip_in_detail: false) { issues_export(format) }
    if refusal = issues_export_refusal
      @toast = refusal
      return
    end
    # The marks, else the filtered list, else everything — named on the card.
    ids, subject = issues_export_selection || {nil, "all #{Gori.plural(@session.store.count_issues, "issue")}"}
    ext, kind = case format
                when :json  then {"json", :issues_json}
                when :sarif then {"sarif", :issues_sarif}
                else             {"md", :issues_md}
                end
    open_export(kind, File.join(Dir.current, "issues.#{ext}"), subject) { |dest| issues_controller.issues_export_to(format, dest, ids) }
  end

  private def issues_export_refusal : String?
    return "no issues to export" if @session.store.count_issues == 0
    sel = issues_export_selection
    "no issues match the filter" if sel && sel[0].empty?
  end

  # Marks and the filter narrow the export only ON the Issues tab, where they are on screen.
  # The palette's "Export issues…" from any other tab writes all of them: the view there is a
  # snapshot from the last visit, and a filter nobody can see must not thin a report.
  private def issues_export_selection : {Array(Int64), String}?
    if pick = @issues_marks_pick
      ids, cursor_only = pick
      return {ids, cursor_only ? "1 issue" : "#{Gori.plural(ids.size, "marked issue")}"}
    end
    issues_controller.view.export_selection if @active_tab == :issues
  end
end
