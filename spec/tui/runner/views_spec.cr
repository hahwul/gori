require "../../spec_helper"

# Runner owns a live terminal and is not constructed by specs. Keep its shell-only hide-static
# wiring pinned against the store setting, which is shared with peer gori processes.
private def runner_views_source : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "views.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "Runner hide-static view picker" do
  it "draws its checkbox from the project setting that the toggle writes" do
    source = runner_views_source
    source.should contain("hidden = StaticAsset.hidden?(@session.store)")
  end

  it "reloads the active Target sub-tab after changing the hide-static lens" do
    toggle = runner_views_source.split("def toggle_static_assets", 2)[1].split("\n  end", 2)[0]
    toggle.should contain("sitemap_controller.reload if @active_tab == :target && target_controller.sitemap_active?")
    toggle.should contain("params_controller.run if @active_tab == :target && target_controller.params_active?")
  end
end

describe "Runner saved-view delete" do
  # A peer can make a view active after this TUI loaded its lens, so the pointer is kept off it
  # by what the project has SAVED (`SavedViews.delete`), the same call MCP and the CLI make — and
  # outside the lens check, which only decides whether THIS TUI's filter drops back to All.
  it "clears the saved pointer by the setting, not by its own lens" do
    body = runner_views_source.split("private def delete_view", 2)[1].split("\n  end\n", 2)[0]
    delete = body.index("case SavedViews.delete(store, view)").not_nil!
    lens = body.index("if (active = history_controller.view.active_view) && active.key == view.key").not_nil!
    delete.should be < lens
    body.should_not contain("SavedViews.remove(")
    body.should_not contain("SavedViews.set_active(store, nil)")
    # A refused remove may already have reset the saved pointer, so the lens is re-read from it.
    body.should contain("history_controller.resolve_active_view")
  end

  # A save that committed is never toasted over as plain done when its activation was refused:
  # for a move, that leaves a pointer at the view's old id.
  it "says when a saved view could not be made active" do
    body = runner_views_source.split("private def save_view", 2)[1].split("\n  end\n", 2)[0]
    body.scan("activated_toast(activate_view(").size.should eq(3)
    body.should_not match(/^\s*activate_view\(/m)
  end
end
