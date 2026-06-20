require "./frame"
require "../sink"

module Gori::Proxy::WS
  # After a 101 handshake, relays WebSocket frames in both directions byte-exact
  # (P7) while capturing reassembled text/binary messages to the sink. Control
  # frames (ping/pong/close) are forwarded; close ends the tunnel.
  module Relay
    # Cap on a reassembled (possibly fragmented) message we buffer for capture.
    # The raw forward is always byte-exact (P7); only the captured projection is
    # bounded, so a giant streamed message can't exhaust memory.
    MAX_MESSAGE = 16 * 1024 * 1024

    # After a message larger than this, drop the reassembly buffer instead of
    # IO::Memory#clear (which keeps the peak-sized backing buffer allocated for the
    # connection's whole life) so one big frame early on doesn't pin memory on an
    # otherwise-idle long-lived connection.
    RESET_THRESHOLD = 256 * 1024

    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink) : Nil
      done = Channel(Nil).new(2)
      spawn { pump(client, upstream, "out", flow_id, sink); done.send(nil) }
      spawn { pump(upstream, client, "in", flow_id, sink); done.send(nil) }
      # When EITHER direction ends (EOF / close / reset), close both sockets so the
      # other pump's blocked read unblocks (raises → rescued → sends done). Without
      # this a half-open peer pins the surviving pump fiber + socket forever.
      done.receive
      client.close rescue nil
      upstream.close rescue nil
      done.receive
    end

    # One direction: read frame → forward raw bytes → capture message on FIN.
    private def self.pump(src : IO, dst : IO, direction : String, flow_id : Int64, sink : FlowSink) : Nil
      assembling = IO::Memory.new
      message_opcode = OP_TEXT
      loop do
        frame = WS.read_frame(src) || break
        dst.write(frame.raw)
        dst.flush

        if frame.data?
          message_opcode = frame.opcode if frame.opcode != OP_CONT
          # Append only up to the cap; raw bytes were already forwarded above.
          remaining = MAX_MESSAGE - assembling.size
          if remaining > 0 && !frame.payload.empty?
            take = {frame.payload.size, remaining}.min
            assembling.write(frame.payload[0, take])
          end
          if frame.fin?
            sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup)
            # Reclaim the backing buffer after a large message; clear() alone keeps it.
            assembling = assembling.size > RESET_THRESHOLD ? IO::Memory.new : assembling.tap(&.clear)
          end
        end
        break if frame.close?
      end
    rescue
      # peer closed / reset: this direction ends
    end
  end
end
