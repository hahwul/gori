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

    # Bounded wait for the peer's REPLYING close frame once we've relayed one direction's
    # CLOSE (RFC 6455 §7.1.1 closing handshake), before tearing the tunnel down. This is a
    # local channel wait (not a network read — the WS tunnel's socket timeouts are relaxed,
    # see SocketTuning.relax in ClientConn), so it's kept well under the proxy's 30 s
    # baseline IO timeout (SocketTuning::CLIENT_IO_TIMEOUT / Upstream::IO_TIMEOUT): a real
    # peer replies near-instantly, and a dead one shouldn't pin the tunnel for 30 s.
    CLOSE_TIMEOUT = 5.seconds

    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink) : Nil
      done = Channel(Bool).new(2) # each pump's payload: did it end by relaying a CLOSE frame?
      spawn { done.send(pump(client, upstream, "out", flow_id, sink)) }
      spawn { done.send(pump(upstream, client, "in", flow_id, sink)) }

      # The first direction to end tells us how to tear down:
      #   - abnormal end (EOF / reset / truncated frame): the peer is gone — close both
      #     sockets NOW so the other pump's blocked read unblocks (raises → rescued → sends
      #     done). Without this a half-open peer pins the surviving pump fiber + socket
      #     forever.
      #   - clean end (it just forwarded a CLOSE frame): that's only HALF the RFC 6455
      #     closing handshake — the peer's REPLYING close frame is very likely still in
      #     flight on the OTHER direction. Closing immediately here is exactly the race that
      #     used to drop it (the local "forward, then break" is near-instant; the peer's
      #     reply needs a real round trip). Give the other pump a bounded window
      #     (CLOSE_TIMEOUT) to relay that reply before tearing down.
      first_clean = done.receive
      second_pending = true
      if first_clean
        select
        when done.receive
          second_pending = false # other side finished within the window (reply relayed, or its own end)
        when timeout(CLOSE_TIMEOUT)
          # peer never replied — give up waiting; the pump below is reaped after closing.
        end
      end
      client.close rescue nil
      upstream.close rescue nil
      # Every path above consumes exactly one of the two `done` sends before this point
      # except the "still waiting" case, so reap the outstanding one now (closing the
      # sockets just unblocked its pending read) — `run` must never return with a pump
      # fiber still alive.
      done.receive if second_pending
    end

    # Chunk size for streaming an oversized frame's payload (see stream_payload).
    STREAM_CHUNK = 64 * 1024

    # One direction: read a frame header → forward the frame byte-exact → capture
    # the reassembled message on FIN. A frame larger than MAX_FRAME is streamed
    # through (byte-exact, P7) rather than aborting the whole tunnel; its payload is
    # too large to buffer, so capture records a marker for that frame instead.
    #
    # Returns whether this direction ended by successfully relaying a CLOSE frame (the
    # "clean" end of the RFC 6455 closing handshake) — as opposed to an abnormal end (EOF,
    # reset, or a truncated frame, all `false`) — so `run` can tell the two cases apart and
    # give the peer's replying CLOSE a bounded window instead of tearing the tunnel down
    # the instant either direction stops.
    private def self.pump(src : IO, dst : IO, direction : String, flow_id : Int64, sink : FlowSink) : Bool
      assembling = IO::Memory.new
      message_opcode = OP_TEXT
      scratch = Bytes.new(STREAM_CHUNK)
      clean_close = false
      loop do
        h = WS.read_header(src) || break
        message_opcode = h.opcode if h.data? && h.opcode != OP_CONT

        if h.len > WS::MAX_FRAME
          # Flush any buffered leading fragments of this message before the oversized-frame
          # marker, so captured prefix bytes aren't dropped and a later small FIN fragment
          # can't be surfaced as if it were the whole message.
          if h.data? && assembling.size > 0
            sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup)
            assembling = assembling.size > RESET_THRESHOLD ? IO::Memory.new : assembling.tap(&.clear)
          end
          break unless forward_oversized_frame(src, dst, h, direction, flow_id, sink, message_opcode, scratch)
          if h.close? # an oversized CLOSE still terminates the tunnel, like a normal one
            clean_close = true
            break
          end
          next
        end

        frame = WS.read_body(src, h) || break
        dst.write(frame.raw)
        dst.flush
        assembling = capture_frame(frame, assembling, direction, flow_id, sink, message_opcode)
        if frame.close?
          clean_close = true
          break
        end
      end
      clean_close
    rescue
      false # peer closed / reset: this direction ends
    end

    # Appends a data frame's payload to the reassembly buffer (up to the cap; the
    # raw bytes were already forwarded), emitting the message on FIN and reclaiming
    # the backing buffer after a large one. Returns the (possibly reset) buffer.
    private def self.capture_frame(frame : WS::Frame, assembling : IO::Memory, direction : String,
                                   flow_id : Int64, sink : FlowSink, message_opcode : UInt8) : IO::Memory
      return assembling unless frame.data?
      remaining = MAX_MESSAGE - assembling.size
      if remaining > 0 && !frame.payload.empty?
        take = {frame.payload.size, remaining}.min
        assembling.write(frame.payload[0, take])
      end
      return assembling unless frame.fin?
      sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup)
      assembling.size > RESET_THRESHOLD ? IO::Memory.new : assembling.tap(&.clear)
    end

    # Forwards a frame whose payload exceeds MAX_FRAME byte-exact (P7) by streaming
    # it rather than buffering — the capture cap bounds the projection, not the
    # forward. Returns false if the peer died mid-payload (caller ends the
    # direction). ANY oversized data frame (final or not) is surfaced as a marker so
    # it isn't silently lost — a non-final oversized fragment would leave no trace.
    private def self.forward_oversized_frame(src : IO, dst : IO, h : WS::Header, direction : String,
                                             flow_id : Int64, sink : FlowSink, message_opcode : UInt8,
                                             scratch : Bytes) : Bool
      dst.write(h.bytes)
      forwarded = WS.stream_payload(src, dst, h.len, scratch)
      dst.flush
      return false unless forwarded # peer died mid-payload
      if h.data?
        marker = "[gori] #{h.len}-byte WebSocket frame forwarded; too large to capture".to_slice
        sink.on_ws_message(flow_id, direction, message_opcode.to_i, marker)
      end
      true
    end
  end
end
