# Notes scratchpad — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def notes_links : Nil
    notes_controller.save_notes
    id = notes_controller.view.current_note_id
    refresh_note_link_preview(id)
    open_links_overlay(Store::LinkOwnerKind::Note, id)
  end

  # --- notes scratchpad (sub-tab actions). The body's text editing stays inline
  # in NotesController; these power the space menu reachable from the sub-tab strip. ---
  def notes_new : Nil
    notes_controller.notes_new
  end

  def notes_close : Nil
    notes_controller.notes_close
    resolve_subtab_focus_after_close
  end

  def notes_duplicate_subtab : Nil
    notes_controller.notes_duplicate
  end

  def notes_copy : Nil
    notes_controller.notes_copy
  end

  def notes_copy_all : Nil
    notes_controller.notes_copy_all
  end

  def notes_read_mode? : Bool
    notes_controller.notes_read_mode?
  end

  def notes_clear : Nil
    notes_controller.notes_clear
  end

  # Write the current note to a .md file (space menu → "Export note…").
  #
  # The emptiness check happens BEFORE the popup: asking for a path and then refusing to
  # write is worse than not asking at all (issues_export's "no issues to export" is the same
  # call). No focus_pane(:body) either — unlike notes_goto/notes_find, this doesn't target
  # the body's cursor.
  def notes_export : Nil
    view = notes_controller.view
    if view.current_text.strip.empty?
      @toast = "note is empty — nothing to export"
      return
    end
    base = Notes.export_basename(view.current_text, view.current_index)
    open_export(:note, File.join(Dir.current, base)) { |p| notes_controller.notes_export_to(p) }
  end

  def notes_edit : Nil
    focus_pane(:body)
    run_external_editor(notes_controller.view.current_text, :notes) { |t| notes_controller.view.replace_current(t) }
  end

  def notes_goto : Nil
    focus_pane(:body)
    open_goto(:notes)
  end

  def notes_find : Nil
    focus_pane(:body)
    open_search(:notes)
  end
end
