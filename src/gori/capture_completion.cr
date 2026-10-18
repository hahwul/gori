require "./proto"
require "./store/models"

module Gori
  # Decides when `gori run capture --max` may count a flow. The 101/2xx handshake is
  # committed before an upgraded tunnel's transcript, so those flows become countable only
  # after their tunnel-completion event. A handshake that aborts before a tunnel opens remains
  # countable on `:updated`; accepted streams wait for completion even if their final state
  # aborts.
  class CaptureCompletion
    def awaits_tunnel?(row : Store::FlowRow) : Bool
      return row.state.complete? if row.status == 101
      Proto.websocket?(row.status, row.connect_protocol)
    end

    def ready?(event : Store::FlowEvent, row : Store::FlowRow) : Bool
      if awaits_tunnel?(row)
        event.kind == :tunnel_completed
      else
        # Not while Pending: an event stream publishes `:updated` when its head lands, long
        # before the response is finished (#1631).
        event.kind == :updated && !row.state.pending?
      end
    end

    # `ready?`, and true only the first time for a flow. The printer reads the row when the
    # event arrives, not when it was published, so an event stream that closes at once has its
    # head's `:updated` and its final one both read a Complete row (#1631). Duplicates arrive
    # within one burst, so the last RECENT ids are enough to catch them.
    def count?(event : Store::FlowEvent, row : Store::FlowRow) : Bool
      return false unless ready?(event, row)
      return false unless @counted.add?(event.id)
      @recent << event.id
      @counted.delete(@recent.shift) if @recent.size > RECENT
      true
    end

    RECENT = 4096
    @counted = Set(Int64).new
    @recent = Deque(Int64).new
  end
end
