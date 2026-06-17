require "./frame"
require "../sink"

module Gori::Proxy::WS
  # After a 101 handshake, relays WebSocket frames in both directions byte-exact
  # (P7) while capturing reassembled text/binary messages to the sink. Control
  # frames (ping/pong/close) are forwarded; close ends the tunnel.
  module Relay
    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink) : Nil
      done = Channel(Nil).new(2)
      spawn { pump(client, upstream, "out", flow_id, sink); done.send(nil) }
      spawn { pump(upstream, client, "in", flow_id, sink); done.send(nil) }
      2.times { done.receive }
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
          assembling.write(frame.payload)
          if frame.fin?
            sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup)
            assembling.clear
          end
        end
        break if frame.close?
      end
    rescue
      # peer closed / reset: this direction ends
    end
  end
end
