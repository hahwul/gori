require "./frame"
require "../sink"
require "../head_rewriter"

module Gori::Proxy::WS
  # After a 101 handshake, relays WebSocket frames in both directions byte-exact
  # (P7) while capturing reassembled text/binary messages to the sink. Control
  # frames (ping/pong/close) are forwarded; close ends the tunnel.
  #
  # Match & Replace over WebSocket (#500 step 1) is the ONE exception to byte-exact, and
  # it is opted into per DIRECTION, per SOCKET: `run` asks the rewriter once, right after
  # the handshake, whether a `part: ws` rule can match this host. A "no" — which is every
  # socket for an operator who has configured no WS rule — runs `pump`, the pre-existing
  # loop, completely untouched. A "yes" runs `pump_rewriting`, which buffers a TEXT message
  # to FIN, applies the rules, and emits the result as ONE frame (fragmentation cannot be
  # preserved once the length changes). Even there, a message the rules do not change goes
  # out as the peer's own frame bytes.
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

    # `rewriter` + `host` are the Match & Replace seam (#500). `host` is the handshake's
    # host, which is what a rule's host glob is matched against — a WS message has no
    # authority of its own, exactly as an intercept hold would scope on the handshake.
    # Both default to "no rewriting", so every caller that only relays keeps today's path.
    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink,
                 rewriter : HeadRewriter? = nil, host : String = "") : Nil
      # Asked ONCE per socket, not per message: a rule can be enabled mid-connection, but
      # re-deciding per message would put a lock on the hot path for an answer that is "no"
      # for every socket in the common case. The next handshake picks up the change — the
      # same lifetime the deflate strip (#518) already has.
      out_rw = nil.as(HeadRewriter?)
      in_rw = nil.as(HeadRewriter?)
      if rw = rewriter
        out_rw = rw if rw.rewrites_ws_out_for_host?(host)
        in_rw = rw if rw.rewrites_ws_in_for_host?(host)
      end

      done = Channel(Bool).new(2) # each pump's payload: did it end by relaying a CLOSE frame?
      spawn do
        clean = if orw = out_rw
                  # client→server: RFC 6455 §5.3 requires every such frame to be masked, so
                  # a re-emitted one carries a fresh key of gori's.
                  pump_rewriting(client, upstream, "out", flow_id, sink, orw, host, mask: true)
                else
                  pump(client, upstream, "out", flow_id, sink)
                end
        done.send(clean)
      end
      spawn do
        clean = if irw = in_rw
                  pump_rewriting(upstream, client, "in", flow_id, sink, irw, host, mask: false)
                else
                  pump(upstream, client, "in", flow_id, sink)
                end
        done.send(clean)
      end

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

    # The rewriting pump for ONE direction (#500 step 1). Only reached when a `part: ws`
    # rule can match this socket's host on this side; `pump` above is what every other
    # socket runs, unchanged.
    private def self.pump_rewriting(src : IO, dst : IO, direction : String, flow_id : Int64,
                                    sink : FlowSink, rewriter : HeadRewriter, host : String,
                                    mask : Bool) : Bool
      RewritingPump.new(src, dst, direction, flow_id, sink, rewriter, host, mask).run
    end

    # One direction's rewriting pump. An object rather than a method because it carries
    # per-message state across frames (the assembly buffer, the message opcode, whether the
    # message has fallen back to byte-exact forwarding). One instance per pump fiber, so
    # nothing here is shared and nothing is locked.
    #
    # The invariant it keeps: gori's own framing is used ONLY for a message the rules
    # actually changed. Everything else — binary messages, oversized frames, messages past
    # the buffer cap, and text messages no rule matched — leaves as the bytes that arrived.
    private class RewritingPump
      @buffer = IO::Memory.new
      @opcode = OP_TEXT
      @passthrough = false       # this message fell back to byte-exact forwarding
      @fresh = true              # no data frame of this message has been buffered yet
      @single_raw : Bytes? = nil # the message's own wire bytes, when it arrived as ONE frame
      @scratch : Bytes

      def initialize(@src : IO, @dst : IO, @direction : String, @flow_id : Int64,
                     @sink : FlowSink, @rewriter : HeadRewriter, @host : String, @mask : Bool)
        @scratch = Bytes.new(STREAM_CHUNK)
      end

      # Same contract as `Relay.pump`: true iff this direction ended by relaying a CLOSE.
      def run : Bool
        clean_close = false
        loop do
          h = WS.read_header(@src) || break
          unless h.data?
            break unless forward_control(h)
            if h.close?
              clean_close = true
              break
            end
            next
          end
          start_message(h.opcode) if h.opcode != OP_CONT
          if h.len > WS::MAX_FRAME
            break unless forward_oversized(h)
            next
          end
          frame = WS.read_body(@src, h) || break
          handle_data(frame)
        end
        clean_close
      rescue
        false # peer closed / reset: this direction ends
      end

      # A control frame (ping/pong/close) never takes part in a rewrite and is forwarded the
      # instant it arrives, byte-exact, even in the middle of a fragmented data message
      # (RFC 6455 §5.4). Parking a PONG behind an assembling message is how a server's
      # 20-30 s ping timer would close the socket out from under the operator.
      private def forward_control(h : WS::Header) : Bool
        # §5.5 caps a control payload at 125 bytes; a peer that advertises more gets its
        # frame streamed rather than its tunnel killed here.
        if h.len > WS::MAX_FRAME
          return Relay.forward_oversized_frame(@src, @dst, h, @direction, @flow_id, @sink, @opcode, @scratch)
        end
        ctl = WS.read_body(@src, h) || return false
        @dst.write(ctl.raw)
        @dst.flush
        true
      end

      # A new message begins. A BINARY message is never rewritten — a text find/replace over
      # protobuf/msgpack/CBOR corrupts rather than edits — so it is put on the byte-exact
      # path here, at its first frame, which preserves its framing and mask key as well.
      private def start_message(opcode : UInt8) : Nil
        # A new data message arriving while the previous one never sent its FIN is an
        # RFC 6455 §5.4 violation. The byte-exact pump forwards it and lets the receiving
        # peer judge; this pump is WITHHOLDING those bytes, so they have to go out here or
        # they are lost on the wire. Emitted non-final, so gori does not invent the FIN the
        # sender never sent — the violation is passed on, not repaired.
        if !@passthrough && @buffer.size > 0
          flush_buffered
          @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, @buffer.to_slice.dup)
          reset_buffer
        end
        @opcode = opcode
        @passthrough = opcode != OP_TEXT
        @fresh = true
        @single_raw = nil
      end

      # A frame too large to buffer: this message can no longer be rewritten. Put whatever
      # is buffered on the wire, surface it to capture (the byte-exact pump's reason —
      # captured prefix bytes must not be dropped, and a later small FIN fragment must not
      # surface as if it were the whole message), then stream the frame through.
      private def forward_oversized(h : WS::Header) : Bool
        flush_buffered unless @passthrough
        if @buffer.size > 0
          @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, @buffer.to_slice.dup)
          reset_buffer
        end
        @passthrough = true
        @single_raw = nil
        Relay.forward_oversized_frame(@src, @dst, h, @direction, @flow_id, @sink, @opcode, @scratch)
      end

      private def handle_data(frame : WS::Frame) : Nil
        if @passthrough
          @dst.write(frame.raw)
          @dst.flush
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode)
          return
        end
        # Outgrowing the buffer we are willing to hold. Put what we have on the wire and let
        # the rest of THIS message stream byte-exact — the same disposition the oversized
        # path takes, and the same one the HTTP body rewrite takes past MAX_REWRITE_BODY:
        # leave it alone rather than grow the proxy heap while a rule is on.
        if @buffer.size + frame.payload.size > MAX_MESSAGE
          flush_buffered
          @dst.write(frame.raw)
          @dst.flush
          @passthrough = true
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode)
          return
        end
        @single_raw = @fresh && frame.fin? ? frame.raw : nil
        @fresh = false
        @buffer.write(frame.payload)
        emit_message if frame.fin?
      end

      # The message is complete: apply the rules and put it on the wire. A rewritten message
      # MUST go out as ONE frame — once its length changes the sender's fragmentation cannot
      # be reproduced — but a message no rule changed is forwarded as the peer's own frame,
      # mask key and all, whenever it arrived as a single frame.
      private def emit_message : Nil
        payload = @buffer.to_slice
        # `out` is a Crystal keyword, hence the name.
        rewritten = if @direction == "out"
                      @rewriter.rewrite_ws_out(payload, @host)
                    else
                      @rewriter.rewrite_ws_in(payload, @host)
                    end
        if (raw = @single_raw) && rewritten == payload
          @dst.write(raw)
        else
          @dst.write(WS.encode(@opcode, rewritten, mask: @mask, fin: true))
        end
        @dst.flush
        # Record what gori WROTE rather than what arrived, the way #513 keeps P7 on h2: the
        # capture has to be the bytes the peer actually sees.
        @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, rewritten.dup)
        reset_buffer
      end

      # Emit everything buffered so far as a NON-final frame, so the rest of the message can
      # stream byte-exact behind it. Reached at most once per message (every caller either
      # switches to passthrough or ends the message immediately after), so this is always
      # the message's leading frame and carries the message opcode rather than OP_CONT.
      private def flush_buffered : Nil
        return if @buffer.size == 0
        @dst.write(WS.encode(@opcode, @buffer.to_slice, mask: @mask, fin: false))
        @dst.flush
      end

      private def reset_buffer : Nil
        @buffer = @buffer.size > RESET_THRESHOLD ? IO::Memory.new : @buffer.tap(&.clear)
      end
    end

    # Appends a data frame's payload to the reassembly buffer (up to the cap; the
    # raw bytes were already forwarded), emitting the message on FIN and reclaiming
    # the backing buffer after a large one. Returns the (possibly reset) buffer.
    #
    # Not `private` only because `RewritingPump` (a nested type, so outside the module's
    # own private scope) shares it — the fallback paths must capture exactly as this pump
    # does, not approximately.
    def self.capture_frame(frame : WS::Frame, assembling : IO::Memory, direction : String,
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
    #
    # Not `private` for the same reason as `capture_frame`: `RewritingPump` is a nested type
    # and shares it, so an oversized frame is forwarded identically on both pumps.
    def self.forward_oversized_frame(src : IO, dst : IO, h : WS::Header, direction : String,
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
