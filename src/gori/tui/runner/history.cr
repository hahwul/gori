# History (list + detail pane) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Toggle whitespace reveal (·→␍␊) in the req/res views — for smuggling tests.
  def toggle_reveal : Nil
    @reveal = !@reveal
    @toast = "whitespace: #{@reveal ? "on (·→␍␊)" : "off"}"
  end

  # Toggle pretty-print of req/res bodies (display only) — global like reveal, so a
  # single `p` flips both History detail and the Repeater response.
  def toggle_pretty : Nil
    @pretty = !@pretty
    @toast = "pretty bodies: #{@pretty ? "on" : "off"}"
  end

  # --- History / detail ExecContext --- (delegated to HistoryController)
  def move_selection(delta : Int32) : Nil
    history_controller.move_selection(delta)
  end

  def open_detail : Nil
    history_controller.open_detail
  end

  def close_detail : Nil
    history_controller.close_detail
  end

  def toggle_follow : Nil
    history_controller.toggle_follow
  end

  def selected_flow_id : Int64?
    history_controller.selected_flow_id
  end

  def copy_selection : Nil
    history_controller.copy_selection(history_target_flow_id)
  end

  def history_query : Nil
    history_controller.history_query
  end

  def history_delete : Nil
    history_controller.history_delete
  end

  def history_clear : Nil
    history_controller.history_clear
  end

  def scroll_detail(delta : Int32) : Nil
    # The two-level detail (HistoryController#handle_detail_body_key/strip_key) now owns
    # the ↑/↓ ladder — ↑-at-top-of-body ascends to the STRIP, ↑-on-strip closes to the
    # tab bar — so this ExecContext method (kept for the abstract def + the shadowed
    # detail.up/down verbs) is a plain delegate. PageUp/Down still route here via the
    # controller directly.
    history_controller.scroll_detail(delta)
  end

  def detail_copy_selection : Nil
    history_controller.detail_copy_selection
  end

  def hscroll_detail(delta : Int32) : Nil
    history_controller.hscroll_detail(delta)
  end

  def toggle_detail_pane : Nil
    history_controller.toggle_detail_pane
  end

  def move_detail_pane(dir : Int32) : Nil
    history_controller.move_detail_pane(dir)
  end

  def toggle_detail_hex : Nil
    history_controller.toggle_detail_hex
  end
end
