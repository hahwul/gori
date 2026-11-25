# Intercept (hold-and-decide) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward intercept_toggle : Nil,
    intercept_forward : Nil,
    intercept_drop : Nil,
    intercept_forward_all : Nil,
    intercept_query : Nil,
    intercept_cycle_direction : Nil,
    selected_intercept_id : Int64?,
    intercept_mark_toggle : Nil,
    intercept_mark_all : Nil,
    intercept_mark_clear : Nil,
    to: intercept_controller

  def intercept_mark_extend(delta : Int32) : Nil
    intercept_controller.intercept_mark_extend(delta)
  end

  forward marked_intercept_count : Int32, to: intercept_controller

  # The read-only held-message preview is on screen — the gate for its read verbs.
  forward intercept_copyable? : Bool, to: intercept_controller

  forward intercept_preview_readable? : Bool, to: intercept_controller

  # CROSS-TAB: Send flow to… → Repeater from the hold queue. Opens the held request — with an
  # edit not forwarded yet — in a new Repeater tab and decides nothing: the message stays held,
  # so "hold it, then work it in Repeater" no longer means forwarding it first. Batch-capable
  # like History's (`repeater_selected`): the marks, capped and confirmed. Seeds are taken
  # BEFORE the confirm, so the tabs hold what was on screen when the operator asked.
  def intercept_repeater : Nil
    ic = intercept_controller
    ids = ic.send_target_ids
    return (@toast = "nothing held to send") if ids.empty?
    if ids.size == 1
      open_held_in_repeater(ic.repeater_seed(ids.first))
      return
    end
    return unless ids = batch_within_cap(ids, "Repeater", "held messages")
    # Only what will open is counted and confirmed: a WebSocket message or a head-only hold in
    # the marks is not a tab, and "Open 5 …" over three tabs is the count the toast then contradicts.
    seeds = ids.map { |id| ic.repeater_seed(id) }.reject(String)
    skipped = ids.size - seeds.size
    return (@toast = Runner.held_none_toast(ids.size)) if seeds.empty?
    if seeds.size == 1
      open_held_in_repeater(seeds.first)
      @toast = Runner.held_batch_toast(1, skipped) if skipped > 0
      return
    end
    note = skipped > 0 ? " (#{skipped} skipped)" : ""
    confirm("SEND TO REPEATER", "Open #{seeds.size} held requests as Repeater tabs#{note}? Nothing is forwarded; they stay held.",
      confirm_label: "open", danger: false) do
      opened = seeds.count { |s| open_held_in_repeater(s, quiet: true) }
      @toast = Runner.held_batch_toast(opened, ids.size - opened)
    end
  end

  # The batch toast, inside the 80-column budget at a 20-mark cap.
  def self.held_batch_toast(opened : Int32, skipped : Int32) : String
    tail = skipped > 0 ? ", #{skipped} skipped" : ""
    "still held · opened #{Gori.plural(opened, "tab")}#{tail} (not saved)"
  end

  def self.held_none_toast(marked : Int32) : String
    "none of the #{marked} marked can open in Repeater"
  end

  HELD_OPENED   = "still held at Intercept · this tab is not saved"
  HELD_RESPONSE = "response still held — this is its request"

  # One seed into the Repeater; false (with the reason as the toast unless `quiet`) when the
  # held message has nothing a Repeater tab can hold.
  private def open_held_in_repeater(seed : InterceptController::HeldSeed | Int64 | String,
                                    quiet : Bool = false) : Bool
    case seed
    in String
      @toast = seed.as(String) unless quiet
      false
    in Int64
      unless @session.store.flow_row(seed)
        @toast = "flow ##{seed} was pruned — nothing to send" unless quiet
        return false
      end
      repeater_controller.repeater_flow(seed)
      @toast = HELD_RESPONSE unless quiet # one segment: fits 80
      true
    in InterceptController::HeldSeed
      repeater_controller.repeater_held(seed.target, seed.text, seed.held, seed.http2, seed.auto_cl, seed.id)
      # No label: the tab in front shows the request, and at 80 columns a URL pushed the one
      # sentence that matters off the line. "still held" leads because the line is cut from the
      # right.
      @toast = HELD_OPENED unless quiet
      true
    end
  ensure
    # The toast here already says the hold is still there, and leaving Intercept with a queue
    # is exactly what `announce_first_hold` fires on: its "go to Intercept to forward" replaced
    # this sentence on the next frame.
    @hold_announced = true
  end
end
