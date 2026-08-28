# Retest diff (two PROJECTS at endpoint scale) — ExecContext verb implementations, reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays, and
# rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Mnemonics the project picker hands out: 1-9 then a-z. A registry deeper than this is
  # still fully navigable with ↑/↓ — only the type-one-key shortcut runs out, and the
  # picker title says how many rows it is showing out of how many exist rather than
  # quietly listing a prefix.
  DIFF_PICK_KEYS = ("1".."9").to_a.map(&.[0]) + ('a'..'z').to_a

  def diff_pick(slot : Symbol) : Nil
    controller = target_controller.diff
    projects = controller.pickable(slot)
    if projects.empty?
      @toast = "no other project to compare against — capture one, or `gori run project create`"
      return
    end
    shown = projects.first(DIFF_PICK_KEYS.size)
    current = controller.view.slot(slot)
    current_idx = current ? (shown.index { |p| p.db_path == current.db_path } || -1) : -1
    choices = shown.map_with_index do |p, i|
      ChoicePicker::Choice.new(diff_project_label(p), DIFF_PICK_KEYS[i], Theme.text, i)
    end
    open_choice_picker(ChoicePicker.new(diff_pick_title(slot, shown.size, projects.size),
      choices, current_idx, :diff_slot)) do |picker|
      if picked = shown[picker.selected]?
        controller.set_slot(slot, picked)
      end
    end
  end

  private def diff_pick_title(slot : Symbol, shown : Int32, total : Int32) : String
    base = slot == :a ? "DIFF A — BASELINE PROJECT" : "DIFF B — NEWER PROJECT"
    shown < total ? "#{base} (#{shown} of #{total})" : base
  end

  # Name plus when it was last touched: two engagements against one target are routinely
  # named alike, and the date is what tells "q3" from "q3 (rerun)".
  private def diff_project_label(p : Project) : String
    when_ = p.last_modified.try(&.to_local.to_s("%Y-%m-%d"))
    when_ ? "#{p.name}   #{when_}" : p.name
  end

  def diff_swap : Nil
    target_controller.diff.swap
  end

  def diff_run : Nil
    target_controller.diff.run
  end

  def diff_cycle_lens(dir : Int32) : Nil
    target_controller.diff.cycle_lens(dir)
  end

  def diff_move(delta : Int32) : Nil
    target_controller.diff.view.move(delta)
  end

  def diff_rows_shown? : Bool
    @active_tab == :target && target_controller.diff_active? &&
      !target_controller.diff.view.selected_row.nil?
  end

  # CROSS-TAB: this endpoint's capture from each side → the Comparer, which owns the
  # byte-level diff. The endpoint report answers "did this move"; the Comparer answers
  # "how", and re-deriving a line diff here would be a second copy of that tab.
  def diff_to_comparer : Nil
    controller = target_controller.diff
    row = controller.view.selected_row
    return (@toast = "select an endpoint first") unless row
    a, b = controller.comparer_slots
    if a && b
      comparer_controller.view.set_pair(a, b)
      goto_tab(:comparer)
      @toast = "comparer: #{row.key.method} #{row.key.path}"
      return
    end
    only = a || b
    unless only
      @toast = "the capture behind this row is gone — re-run the diff (r)"
      return
    end
    which = comparer_controller.view.add_slot(only)
    goto_tab(:comparer)
    @toast = "comparer: set #{which.to_s.upcase} — this endpoint was captured on one side only"
  end

  # --- the exit: a row becomes an Issue or a Note -----------------------------

  # File the selected endpoint as an Issue, prefilled with what the retest observed.
  #
  # The deliverable of a retest is a list of findings and this tab produces exactly its
  # input, so until this verb the operator retyped every row somewhere else — losing the
  # part only Diff holds: WHICH two projects, which side answered what, which axis moved.
  # `Diff::Record` builds that text once (the Note below and the JSON row both take it from
  # there); the create itself is `IssueForm` + `create_issue_from_form`, untouched (P1/P3).
  def diff_issue : Nil
    recorded = target_controller.diff.selected_record
    return (@toast = "select an endpoint first") unless recorded
    flow_id, build = recorded
    # `insert_issue` writes the issue AND its flow link in ONE transaction, and the shell
    # bails on `new_id == 0` — so a committed issue implies a committed link, and the body
    # may say so up front. (The note path below cannot; see there.)
    #
    # `flow_id` is nil when neither slot names the OPEN project, or when the capture behind
    # the row is gone. The form still opens: the body names both sides either way, and a
    # record with a weaker anchor beats the retyped one this verb exists to replace.
    draft = build.call(!flow_id.nil?)
    open_issue_form(IssueForm.new(draft.title, draft.host, flow_id, draft.severity,
      notes: draft.body, stay_on_create: true))
  end

  # The lighter exit, and on a retest the one that gets used: most rows are worth
  # MENTIONING, not filing. One keystroke, no form — the note carries the same text the
  # issue would, links the same capture, and leaves the cursor where it was so the next row
  # is one `j` away.
  def diff_note : Nil
    recorded = target_controller.diff.selected_record
    return (@toast = "select an endpoint first") unless recorded
    flow_id, build = recorded
    linked = false
    # The note is minted blank, LINKED, and only then given its body — because the body says
    # "linked to this record". A note is two writes where an issue is one (`insert_issue`
    # carries its own `entity_links` row), so building the text first let a store-busy
    # rollback leave a note asserting evidence that was never attached.
    _, saved = notes_controller.create_note do |id|
      # `commit_link_to_owner` rather than a bare `add_link`: it is the one place that also
      # refreshes the note's link preview, and it already reports "already linked".
      linked = !flow_id.nil? &&
               commit_link_to_owner(Store::LinkOwnerKind::Note, id, Store::LinkRefKind::Flow, flow_id)
      build.call(linked).note_text
    end
    parts = [saved ? "note filed" : "note filed — NOT saved yet (project busy)"]
    parts << "capture linked" if linked
    parts << "capture NOT linked (store busy)" if !flow_id.nil? && !linked
    @toast = parts.join(" · ")
  end
end
