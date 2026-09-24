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
