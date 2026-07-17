# Sequencer (token randomness) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open the config popup for History's selected flow (space → Send to Sequencer).
  def sequence_selected : Nil
    id = history_target_flow_id
    return (@toast = "select a flow first") unless id
    open_sequence_config(sequencer_controller.build_seed_from_flow(id))
  end

  # CROSS-TAB: open the config popup for the current Repeater request.
  def sequence_from_repeater : Nil
    return unless v = repeater_controller.current_view
    v.flush_decoded_edits
    open_sequence_config(sequencer_controller.build_seed_from_request(v.target, v.request_text, v.http2?, v.sni_override))
  end

  # CROSS-TAB: open the config popup for the selected Sitemap endpoint's captured flow.
  def sequence_from_sitemap : Nil
    ep = sitemap_controller.view.selected_endpoint
    return (@toast = "select an endpoint to send") unless ep
    if id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      open_sequence_config(sequencer_controller.build_seed_from_flow(id))
    else
      @toast = "no captured request for this path — capture it, or use Discover"
    end
  end

  def sequence_run : Nil
    sequencer_controller.sequence_run
  end

  def sequence_stop : Nil
    sequencer_controller.sequence_stop
  end

  def sequence_configure : Nil
    reconfigure_sequence
  end
end
