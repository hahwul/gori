# Discover (spider + dir-brute) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Seed a discovery run from the selected Sitemap node — offering the path subtree AND the
  # host root as start-target choices in the config popup.
  def sitemap_discover : Nil
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = "select a host or path to discover"
      return
    end
    id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
    base = id.try { |i| @session.store.flow_row(i).try(&.url) }
    origin = base.try { |u| Discover::Url.parse(u).try { |p| Discover::Url.origin(p) } } || "https://#{ep[:host]}"
    open_discover_config(build_discover_seed(origin, ep[:host], ep[:target]))
  end

  def history_discover : Nil
    id = history_target_flow_id
    # get_flow (not flow_row) so we also have the request head to offer its headers.
    unless id && (detail = @session.store.get_flow(id))
      @toast = "select a flow to discover"
      return
    end
    unless p = Discover::Url.parse(detail.row.url)
      @toast = "flow has no discoverable URL"
      return
    end
    open_discover_config(build_discover_seed(Discover::Url.origin(p), p.host, p.path))
    offer_flow_headers(id, detail.request_head)
  end

  def discover_run : Nil
    discover_controller.discover_run
  end

  def discover_stop : Nil
    discover_controller.discover_stop
  end

  def discover_toggle_pause : Nil
    discover_controller.discover_toggle_pause
  end

  def goto_discover : Nil
    focus_tab(:target)
    target_controller.select_discover
  end
end
