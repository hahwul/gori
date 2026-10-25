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
    return unless @overlay.detail?
    view = history_controller.view
    view.pretty = @pretty # the per-frame push lands after this toast; the answer needs it now
    @toast = "pretty bodies: on — no pretty view for this body" if view.pretty_missing?
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

  def detail_messages_pane? : Bool
    @overlay.detail? && history_controller.view.messages_pane?
  end

  forward toggle_ws_narrow : Nil, to: history_controller

  # --- Inject frame (#1630): the TUI's door to `Proxy::WS::Live.inject` ---------------------

  # The open drill-in's flow, while this process still relays its WebSocket (`HistoryView#ws_open`
  # asks `Proxy::WS::Live`, which holds only h1 relays): an h2 socket and a closed one are never
  # offered.
  def detail_ws_injectable? : Bool
    return false unless @overlay.detail?
    view = history_controller.view
    !!view.detail_flow_id.try { |id| view.ws_open.call(id) }
  end

  def detail_inject_frame : Nil
    return unless detail_ws_injectable? && (id = history_controller.view.detail_flow_id)
    ov = WsInjectOverlay.new(id)
    ov.on_commit = -> { inject_ws_frame(ov) }
    open_overlay(ov)
  end

  # Outcomes the inject fiber hands back, raised on the UI fiber (`drain_ws_inject_outcomes`).
  @ws_inject_outcomes = [] of {String, Symbol}

  # The drain's own call, gated the same way: Layer 2 on the socket's host inside
  # `Live.inject`, no Layer 1 up front (`Outbound.interactive`), one budget slot. Off the UI
  # fiber, since a data frame can wait up to 5 s for a message boundary. A payload that is
  # not hex keeps the card open (false), so a fix is an edit.
  private def inject_ws_frame(ov : WsInjectOverlay) : Bool
    unless payload = ov.payload
      status("inject: #{ov.hex_hint}", :error)
      return false
    end
    sink = @session.proxy.sink
    outbound = Outbound.interactive(@session.scope)
    out = @ws_inject_outcomes
    # Only a data frame waits for a boundary; a control frame goes in at once.
    wait = ov.opcode >= 0x8_u8 ? "injecting" : "waiting for a message boundary"
    status("inject: #{wait} on flow ##{ov.flow_id}…", :busy)
    spawn(name: "gori-ws-inject") do
      out << ov.inject(sink, outbound, payload)
    rescue ex
      out << {"inject failed: #{ex.message}", :error}
    end
    true
  end

  # Raise what the inject fiber reported. True when anything arrived (→ a frame).
  private def drain_ws_inject_outcomes : Bool
    return false if @ws_inject_outcomes.empty?
    @ws_inject_outcomes.each { |(msg, kind)| status(msg, kind) }
    @ws_inject_outcomes.clear
    true
  end
end
