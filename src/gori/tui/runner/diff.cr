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
end
