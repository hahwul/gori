# An event-stream response while it is open (#1631): the RESPONSE pane follows the send's
# `Repeater::LiveBody` until the Result lands, and PRETTY renders an event stream per event.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # The fastest the open stream re-renders. Each render re-parses the whole stream so far, so
  # this, and not the origin's event rate, sets the UI fiber's cost (P6), and the pause grows
  # by one LIVE_EVERY per LIVE_STRETCH of stream: a render measured 5 ms at 1 MiB and 23 ms at
  # 8 MiB, so the UI fiber's share stays near 2% at any size.
  LIVE_EVERY   = 250.milliseconds
  LIVE_STRETCH = 1024 * 1024

  # The pause after a render of `size` bytes of open stream. History's detail of an open
  # stream re-parses it the same way, so it waits the same pause (`HistoryView#refresh_detail`).
  def self.live_pause(size : Int32) : Time::Span
    LIVE_EVERY * (1 + size // LIVE_STRETCH)
  end

  @live : Repeater::LiveBody? = nil
  @live_result : Repeater::Result? = nil
  @live_started = Time.instant
  @live_shown = -1
  @live_at : Time::Instant? = nil
  # The arrival times of the stream `@result` holds, kept after it closes (#1631).
  @result_times : Array(Int64)? = nil

  # How many times the open stream has rendered (the first one is when it opened).
  getter live_renders = 0

  getter live : Repeater::LiveBody?

  # The controller hands the sink of the send it is about to launch. `apply` drops it.
  def live_begin(live : Repeater::LiveBody) : Nil
    @live = live
    @live_result = nil
    @live_started = Time.instant
    @live_shown = -1
    @live_at = nil
    @live_renders = 0
    @scroll = 0 # the stream is a new document; don't open it at the last response's row
  end

  # One UI tick. Re-renders when the stream grew and LIVE_EVERY has passed since the last
  # render; true when it did. A send whose response is not an event stream never opens the
  # sink, so this stays false for it.
  def live_tick(now : Time::Instant = Time.instant) : Bool
    live = @live || return false
    return false if live.head.nil? || live.size == @live_shown
    return false if (at = @live_at) && now - at < RepeaterView.live_pause(live.size)
    @live_shown = live.size
    @live_at = now
    @live_renders += 1
    @live_result = live.result(@live_started)
    # The view caches only: `reset_result_caches` would also reset the pane's horizontal
    # scroll (`resp_wrap_reset`) on every update.
    drop_resp_view_cache
    @resp_wrap.clear
    @diff_lines_cache = nil
    @resp_hex_bytes = nil
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

  # PRETTY for an event stream: one block per event over the latest
  # `HistoryView::DETAIL_LOG_CAP`, the rendering and the window History's EVENTS pane uses.
  private def sse_pretty(head : Bytes, src : Bytes?) : Pretty::Result?
    return nil unless Sse.event_stream?(head)
    events = Sse.events(src || Bytes.empty)
    times = @live_result ? @live.try(&.times) : @result_times
    lines, shown = Sse.latest_lines(events, HistoryView::DETAIL_LOG_CAP, times)
    if shown < events.size
      lines.unshift("")
      lines.unshift("— showing the latest #{shown} of #{events.size} events; #{events.size - shown} older not shown —")
    end
    Pretty::Result.new(lines.join('\n').to_slice, "events", :text)
  end
end
