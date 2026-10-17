# An event-stream response while it is open (#1631): the RESPONSE pane follows the send's
# `Repeater::LiveBody` until the Result lands, and PRETTY renders an event stream per event.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # The fastest the open stream re-renders. Each render re-parses the whole stream so far, so
  # this, and not the origin's event rate, sets the UI fiber's cost (P6).
  LIVE_EVERY = 250.milliseconds

  @live : Repeater::LiveBody? = nil
  @live_result : Repeater::Result? = nil
  @live_started = Time.instant
  @live_shown = -1
  @live_at : Time::Instant? = nil

  getter live : Repeater::LiveBody?

  # The controller hands the sink of the send it is about to launch. `apply` drops it.
  def live_begin(live : Repeater::LiveBody) : Nil
    @live = live
    @live_result = nil
    @live_started = Time.instant
    @live_shown = -1
    @live_at = nil
  end

  # One UI tick. Re-renders when the stream grew and LIVE_EVERY has passed since the last
  # render; true when it did. A send whose response is not an event stream never opens the
  # sink, so this stays false for it.
  def live_tick(now : Time::Instant = Time.instant) : Bool
    live = @live || return false
    return false if live.head.nil? || live.size == @live_shown
    return false if (at = @live_at) && now - at < LIVE_EVERY
    @live_shown = live.size
    @live_at = now
    @live_result = live.result(@live_started)
    reset_result_caches
    true
  end

  private def live_end : Nil
    @live = nil
    @live_result = nil
  end

  # The response the pane shows: the open stream so far, else the last send's.
  private def shown_result : Repeater::Result?
    @live_result || @result
  end

  # PRETTY for an event stream: one block per event, the rendering History's EVENTS pane uses.
  private def sse_pretty(head : Bytes, src : Bytes?) : Pretty::Result?
    return nil unless Sse.event_stream?(head)
    text = Sse.display_lines(Sse.events(src || Bytes.empty)).join('\n')
    Pretty::Result.new(text.to_slice, "events", :text)
  end
end
