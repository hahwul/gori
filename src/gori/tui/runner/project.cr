# Project description pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward project_desc_read_mode? : Bool, to: project_controller

  # Edit tags — the new-project form's tags field on a card, suggesting the host's other tags.
  # A `--db` project has no registry directory to hold them, so it says so instead.
  def project_edit_tags : Nil
    view = project_controller.view
    project = @session.project
    unless view.registry_project?(project)
      @toast = "tags belong to registry projects — this one was opened with --db"
      return
    end
    reg = ProjectRegistry.new(Paths.projects_dir)
    original = reg.read_tags(project)
    ov = TagPromptOverlay.new(original, ProjectRegistry.tag_counts(reg.entries))
    ov.on_commit = -> {
      begin
        stored = reg.set_tags(project, ov.tags, expected: original)
        view.tags = stored
        @toast = stored.empty? ? "tags cleared" : "tagged #{stored.map { |t| "##{t}" }.join(' ')}"
        true
      rescue ex : Gori::Error | File::Error | IO::Error
        @toast = "can't save tags — #{ex.message}"
        false # keep the card: the tags are still there to fix
      end
    }
    open_overlay(ov)
  rescue ex : Gori::Error | IO::Error
    @toast = "can't edit tags — #{ex.message}"
  end
end
