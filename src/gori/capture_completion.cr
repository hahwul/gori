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
        event.kind == :updated
      end
    end
  end
end
