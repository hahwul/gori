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

  forward open_detail : Nil, to: history_controller

  # Pins the flow on screen for the rest of this event (`@detail_pin`, runner.cr): the verbs
  # that close the detail and then jump resolve their target AFTER this returns, when the
  # overlay is gone and the resolvers would answer with the marks instead.
  def close_detail : Nil
    @detail_pin = history_controller.view.detail_flow_id if @overlay.detail?
    history_controller.close_detail
  end

  # `⇧N`/`⇧P` in the drill-in — the next/previous flow, in place. `@detail_pin` is deliberately
  # NOT set: unlike `close_detail`, this stays in the detail, and the pin exists for verbs
  # that leave it and then resolve a target.
  def detail_step_item(delta : Int32) : Nil
    history_controller.detail_step_item(delta)
  end

  forward toggle_follow : Nil,
    selected_flow_id : Int64?,
    to: history_controller

  # --- multi-select marks (#442) ---
  def selected_flow_ids : Array(Int64)
    history_target_flow_ids
  end

  forward marked_flow_count : Int32,
    history_mark_toggle : Nil,
    history_mark_all : Nil,
    history_mark_clear : Nil,
    to: history_controller

  def history_mark_extend(delta : Int32) : Nil
    history_controller.history_mark_extend(delta)
  end

  # One flow → its full raw request (the byte-exact dump you'd paste into Repeater).
  # N flows → the URL list, since concatenating N request dumps is never the ask;
  # the other multi-flow formats live behind Copy-as (#copy_as_menu).
  def copy_selection : Nil
    ids = history_target_flow_ids
    ids.size > 1 ? history_controller.copy_urls(ids) : history_controller.copy_selection(ids.first?)
  end

  forward history_query : Nil, to: history_controller

  # `v` — see runner/views.cr for the picker and the whole view-editing surface.
  def history_view_pick : Nil
    open_history_view_picker
  end

  # See runner/columns.cr for the list card, the per-column form and the store writes.
  def history_columns_edit : Nil
    open_history_columns
  end

  # See HistoryController#grpc_reflect — the target is the selected row's, so the verb has
  # nothing to prompt for, and the fetch runs off the UI fiber.
  def history_grpc_reflect : Nil
    history_controller.grpc_reflect
  end

  forward history_delete : Nil,
    history_clear : Nil,
    to: history_controller

  def scroll_detail(delta : Int32) : Nil
    # The two-level detail (HistoryController#handle_detail_body_key/strip_key) now owns
    # the ↑/↓ ladder — ↑-at-top-of-body ascends to the STRIP, ↑-on-strip closes to the
    # tab bar — so this ExecContext method (kept for the abstract def + the shadowed
    # detail.up/down verbs) is a plain delegate. PageUp/Down still route here via the
    # controller directly.
    history_controller.scroll_detail(delta)
  end

  forward detail_copy : Nil,
    toggle_detail_pane : Nil,
    to: history_controller

  def move_detail_pane(dir : Int32) : Nil
    history_controller.move_detail_pane(dir)
  end

  forward toggle_detail_hex : Nil, to: history_controller

  def toggle_unicode_escapes : Nil
    history_controller.toggle_unicode_decoding
  end
end
