# Sitemap tree — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def sitemap_move(delta : Int32) : Nil
    sitemap_controller.sitemap_move(delta)
  end

  def sitemap_toggle : Nil
    sitemap_controller.sitemap_toggle
  end

  def sitemap_expand : Nil
    sitemap_controller.sitemap_expand
  end

  def sitemap_collapse : Nil
    sitemap_controller.sitemap_collapse
  end

  def sitemap_query : Nil
    sitemap_controller.sitemap_query
  end

  def sitemap_tag : Nil
    sitemap_controller.sitemap_tag
  end

  def sitemap_toggle_grouping : Nil
    sitemap_controller.sitemap_toggle_grouping
  end

  def sitemap_repeater : Nil
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = "select an endpoint to send"
      return
    end
    if id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      repeater_flow(id)
    else
      @toast = "no captured request for this path — capture it, or use Discover"
    end
  end
end
