require "./frame"
require "./message_gate"
require "../sink"
require "../head_rewriter"
require "../../interceptor"

module Gori::Proxy::WS
  # The 101 handshake's identity, threaded into the relay because a WebSocket message has
  # none of its own: no authority, no scheme, no path. A rule's host glob, an intercept
  # hold's scope test and the queue row's label are all the HANDSHAKE's — the same answer
  # #492 step 3 gave a held h2 response ("inventing one is how a hold escapes scope").
  record Context,
    host : String = "",
    port : Int32 = 0,
    scheme : String = "http",
    method : String = "GET",
    target : String = "/" do
    NONE = new
  end

  # After a 101 handshake, relays WebSocket frames in both directions byte-exact
  # (P7) while capturing reassembled text/binary messages to the sink. Control
  # frames (ping/pong/close) are forwarded; close ends the tunnel.
  #
  # Two features break byte-exact, and both are opted into per DIRECTION, per SOCKET — `run`
  # asks each lens once, right after the handshake:
  #
  #   * **Match & Replace** (#500 step 1) — is a `part: ws` rule live for this host on this
  #     side?
  #   * **Intercept hold** (#500 step 2) — is catch on, with a condition that carries an
  #     explicit `proto:ws`, for this host on this side?
  #
  # Two "no"s — which is every socket for an operator who has configured neither — run `pump`,
  # the pre-existing loop, completely untouched. Either "yes" runs `pump_assembling`, which
  # buffers a message to FIN and then runs it through ONE pipeline: rewrite, then hold. The
  # hold's edit is a STAGE inside that pipeline, not a second one beside it — two pipelines
  # would mean the operator editing bytes the rules had not seen, or rules re-running over an
  # operator's edit. Even on that path, a message neither stage changed goes out as the peer's
  # own frame bytes, mask key and all.
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

    # `rewriter` is the Match & Replace seam (#500 step 1) and `interceptor` the hold seam
    # (step 2); `ctx` is the 101 handshake's identity, which both scope on. All three default
    # to "off", so every caller that only relays keeps today's byte-exact path.
    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink,
                 rewriter : HeadRewriter? = nil, ctx : Context = Context::NONE,
                 interceptor : Gori::Interceptor? = nil) : Nil
      # Asked ONCE per socket, not per message: a rule or the catch condition can change
      # mid-connection, but re-deciding per message would put a lock on the hot path for an
      # answer that is "no" for every socket in the common case. The next handshake picks up
      # the change — the same lifetime the deflate strip (#518) already has, and the reason
      # "enabling catch does not reach an already-open socket" is in the docs.
      out_rw = ws_rewriter(rewriter, ctx.host, to_server: true)
      in_rw = ws_rewriter(rewriter, ctx.host, to_server: false)
      # One gate per DIRECTION: a direction is one ordering domain, and the gate writes to
      # that direction's destination socket. client→server is "out", so its destination is
      # the upstream leg.
      out_gate = ws_gate(interceptor, upstream, flow_id, sink, ctx, "out", mask: true)
      in_gate = ws_gate(interceptor, client, flow_id, sink, ctx, "in", mask: false)

      done = Channel(Bool).new(2) # each pump's payload: did it end by relaying a CLOSE frame?
      # client→server: RFC 6455 §5.3 requires every such frame to be masked, so a re-emitted
      # one carries a fresh key of gori's.
      spawn { done.send(direction_pump(client, upstream, "out", flow_id, sink, out_rw, ctx, out_gate, mask: true)) }
      spawn { done.send(direction_pump(upstream, client, "in", flow_id, sink, in_rw, ctx, in_gate, mask: false)) }

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

    # This direction's Match & Replace lens, or nil when no `part: ws` rule can reach this
    # host on this side.
    private def self.ws_rewriter(rewriter : HeadRewriter?, host : String, *,
                                 to_server : Bool) : HeadRewriter?
      return nil unless rw = rewriter
      live = to_server ? rw.rewrites_ws_out_for_host?(host) : rw.rewrites_ws_in_for_host?(host)
      live ? rw : nil
    end

    # This direction's hold gate, or nil when the catch condition does not arm one.
    private def self.ws_gate(interceptor : Gori::Interceptor?, dst : IO, flow_id : Int64,
                             sink : FlowSink, ctx : Context, direction : String,
                             mask : Bool) : MessageGate?
      return nil unless ic = interceptor
      return nil unless ic.arms_ws_hold?(ctx.host, to_server: direction == "out")
      MessageGate.new(direction, dst, flow_id, sink, ic, ctx, mask: mask)
    end

    # One direction's loop. `pump` — the pre-existing byte-exact one — unless this direction
    # has a rewriter or a hold gate to run, which is what keeps an unconfigured socket on the
    # path it has always taken.
    private def self.direction_pump(src : IO, dst : IO, direction : String, flow_id : Int64,
                                    sink : FlowSink, rewriter : HeadRewriter?, ctx : Context,
                                    gate : MessageGate?, mask : Bool) : Bool
      return pump(src, dst, direction, flow_id, sink) unless rewriter || gate
      pump_assembling(src, dst, direction, flow_id, sink, rewriter, ctx, gate, mask: mask)
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
        # A new data message arriving while the previous one never sent its FIN is an RFC 6455
        # §5.4 violation. `capture_frame` only emits on FIN, so without this the two messages
        # were concatenated into ONE History row — `TEXT fin=0 "AAA"` then `TEXT fin=1 "BBB"`
        # surfaced as `AAABBB` while the origin correctly received two frames. `AssemblingPump`
        # was given this reset explicitly (`start_message`) and the oversized branch below has
        # it too; the default pump, which every socket with no rule and no hold runs, did not —
        # so the two pumps disagreed about identical bytes. Capture only: the wire is untouched.
        if h.data? && h.opcode != OP_CONT
          assembling = emit_pending(assembling, direction, flow_id, sink, message_opcode)
          message_opcode = h.opcode
        end

        if h.len > WS::MAX_FRAME
          # Flush any buffered leading fragments of this message before the oversized-frame
          # marker, so captured prefix bytes aren't dropped and a later small FIN fragment
          # can't be surfaced as if it were the whole message.
          assembling = emit_pending(assembling, direction, flow_id, sink, message_opcode) if h.data?
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
    ensure
      # An unterminated fragment when the direction ends. gori already put those bytes on the
      # wire frame by frame, so dropping them here made History disagree with what gori itself
      # relayed — `TEXT fin=0 "UNTERMINATED"` then a CLOSE left no row at all. Emitted on both
      # the clean and the reset path, which is why this is an `ensure` and not a tail statement.
      # `AssemblingPump#run`'s own `ensure` flushes its withheld half for the same reason.
      # `ensure` types every body-assigned local as nilable (the raise could precede the
      # assignment), so bind it before asking.
      if buf = assembling
        emit_pending(buf, direction, flow_id, sink, message_opcode || OP_TEXT) rescue nil
      end
    end

    # Surface whatever fragments are buffered as ONE message and hand back a cleared buffer.
    # A no-op when nothing is buffered. Three callers need exactly this: a new data message
    # arriving before the previous one FIN'd (RFC 6455 §5.4), an oversized frame that ends the
    # buffered prefix, and teardown with an unterminated fragment still held. They had two
    # copies and one omission between them, which is how the merged-row and dropped-bytes bugs
    # got in; `AssemblingPump` has the same three moments and its own equivalents.
    private def self.emit_pending(assembling : IO::Memory, direction : String, flow_id : Int64,
                                  sink : FlowSink, message_opcode : UInt8) : IO::Memory
      return assembling if assembling.size == 0
      sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup)
      assembling.size > RESET_THRESHOLD ? IO::Memory.new : assembling.tap(&.clear)
    end

    # The assembling pump for ONE direction (#500). Only reached when a `part: ws` rule can
    # match this socket's host on this side, or when the catch condition arms a hold there;
    # `pump` above is what every other socket runs, unchanged.
    private def self.pump_assembling(src : IO, dst : IO, direction : String, flow_id : Int64,
                                     sink : FlowSink, rewriter : HeadRewriter?, ctx : Context,
                                     gate : MessageGate?, mask : Bool) : Bool
      AssemblingPump.new(src, dst, direction, flow_id, sink, rewriter, ctx, gate, mask).run
    ensure
      # The direction ended (cleanly or not). Hand every still-held message back to the
      # Interceptor so no ghost queue row survives the socket and no wait fiber leaks —
      # `H2::StreamGate#close`'s contract. This is also where the CLOSE_TIMEOUT ceiling lands:
      # when the PEER closes the other direction, `run` gives this one 5 s and then closes the
      # sockets, which unblocks the read here and reaps whatever was still held.
      gate.try(&.close)
    end

    # One direction's assembling pump. An object rather than a method because it carries
    # per-message state across frames (the assembly buffer, the message opcode, whether the
    # message has fallen back to byte-exact forwarding). One instance per pump fiber, so
    # nothing here is shared and nothing is locked — the GATE owns the only shared state,
    # because a wait fiber writes through it.
    #
    # The invariant it keeps: gori's own framing is used ONLY for a message a rule or the
    # operator actually changed. Everything else — binary messages nobody edited, oversized
    # frames, messages past the buffer cap, and text messages no rule matched — leaves as the
    # bytes that arrived.
    private class AssemblingPump
      @buffer = IO::Memory.new
      @opcode = OP_TEXT
      @passthrough = false       # this message fell back to frame-by-frame byte-exact forwarding
      @rewritable = false        # ... and this one is eligible for Match & Replace (TEXT + a live rule)
      @fresh = true              # no data frame of this message has been buffered yet
      @single_raw : Bytes? = nil # the message's own wire bytes, when it arrived as ONE frame
      @scratch : Bytes

      def initialize(@src : IO, @dst : IO, @direction : String, @flow_id : Int64,
                     @sink : FlowSink, @rewriter : HeadRewriter?, @ctx : Context,
                     @gate : MessageGate?, @mask : Bool)
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
      ensure
        # The abnormal exits (EOF, a truncated frame, a reset) are withholding the same bytes
        # a CLOSE would have been, and the byte-exact pump would already have forwarded them —
        # so dropping them silently is a difference between the two pumps that should not
        # exist. Best-effort: this path is usually taken BECAUSE a peer went away.
        #
        # GATED sockets are deliberately excluded, and NOT because of ordering. `bypass` runs
        # `fail_open_locked` before it yields, so routing this through it would force every
        # still-undecided held message out to the origin on any abnormal end — flipping
        # `MessageGate#close`'s deliberate discard into a fail-open as a side effect, for
        # messages the operator never looked at. With a gate armed, what happens to withheld
        # bytes at teardown is `close`'s decision and it has already made it.
        (flush_withheld rescue nil) if @gate.nil?
      end

      # A control frame (ping/pong/close) never takes part in a rewrite or a hold and is
      # forwarded the instant it arrives, byte-exact, even in the middle of a fragmented data
      # message (RFC 6455 §5.4). Parking a PONG behind an assembling or held message is how a
      # server's 20-30 s ping timer would close the socket out from under the operator — and
      # on the hold path that is not a refinement, it is the whole reason this pump may not
      # block. See `MessageGate`'s header.
      #
      # A CLOSE is the one control frame that cannot simply overtake: §5.5.1 forbids data
      # frames after it, so anything still queued would never reach the peer. Design D5
      # resolves the queue instead — everything undecided forwards, in order, then the CLOSE.
      # Parking the CLOSE was the alternative and does not work against today's teardown: a
      # pump that does not write it never returns "clean", so `run` reads the direction as an
      # abnormal end and tears both sockets down, destroying the hold with no decision at all.
      private def forward_control(h : WS::Header) : Bool
        # §5.5 caps a control payload at 125 bytes; a peer that advertises more gets its
        # frame streamed rather than its tunnel killed here.
        if h.len > WS::MAX_FRAME
          return bypassing("a control frame too large to buffer arrived") do
            Relay.forward_oversized_frame(@src, @dst, h, @direction, @flow_id, @sink, @opcode, @scratch)
          end
        end
        ctl = WS.read_body(@src, h) || return false
        if ctl.close?
          # The queue is resolved AND this pump's own half-assembled message is put out, in
          # that order, before the CLOSE. §5.5.1 forbids data frames after it, so bytes this
          # pump is WITHHOLDING have exactly this one chance — `start_message`'s comment
          # already states the rule ("they have to go out here or they are lost on the wire")
          # and it was applied at that one exit only. A `TEXT fin=0 "secret "` followed by a
          # CLOSE reached the origin as the CLOSE alone, on neither the wire nor in capture,
          # while the byte-exact pump forwards those bytes.
          bypass("the peer closed this direction") do
            flush_withheld
            write_direct(ctl.raw)
          end
        elsif gate = @gate
          gate.write_control(ctl.raw)
        else
          write_direct(ctl.raw)
        end
        true
      end

      # A new message begins.
      #
      # A BINARY message is never REWRITTEN — a text find/replace over protobuf/msgpack/CBOR
      # corrupts rather than edits — but it IS holdable, so it only falls onto the
      # frame-by-frame byte-exact path when no gate is armed. With a gate it is assembled like
      # any other message, offered to the operator, and (unless they edited it) re-emitted as
      # the frame that arrived.
      private def start_message(opcode : UInt8) : Nil
        # A new data message arriving while the previous one never sent its FIN is an
        # RFC 6455 §5.4 violation. The byte-exact pump forwards it and lets the receiving
        # peer judge; this pump is WITHHOLDING those bytes, so they have to go out here or
        # they are lost on the wire. Emitted non-final, so gori does not invent the FIN the
        # sender never sent — the violation is passed on, not repaired.
        #
        # The RESET is unconditional and the flush is not, which is the half that was missing:
        # a PASSTHROUGH message feeds the same `@buffer` through `capture_frame`, and that
        # empties only on FIN — so a passthrough message that never FIN'd left its bytes in
        # front of the next message's. With a `part: ws` rule live and no gate, BINARY is
        # passthrough and TEXT is not, so `BIN fin=0 "LEAK"` then `TEXT fin=1 "second"` put
        # `LEAKSECOND` on the wire as one TEXT frame. Its bytes need no flush (they were
        # already written frame by frame) but they must not stay in the buffer.
        bypass("a message arrived before the previous one sent its FIN") { flush_withheld } if @buffer.size > 0
        @opcode = opcode
        @rewritable = opcode == OP_TEXT && !@rewriter.nil?
        @passthrough = !@rewritable && @gate.nil?
        @fresh = true
        @single_raw = nil
      end

      # A frame too large to buffer: this message can no longer be rewritten OR held. Put
      # whatever is buffered on the wire, surface it to capture (the byte-exact pump's
      # reason — captured prefix bytes must not be dropped, and a later small FIN fragment
      # must not surface as if it were the whole message), then stream the frame through.
      private def forward_oversized(h : WS::Header) : Bool
        # The prefix's capture row goes in FIRST, because it preceded the oversized frame on
        # the wire and `Relay.pump` records the two in that order. Emitting it afterwards put
        # the "[gori] N-byte … too large to capture" marker ABOVE the fragment it followed, so
        # the two pumps disagreed about an identical frame sequence.
        prefix = @buffer.size > 0 ? @buffer.to_slice.dup : nil
        prefix.try { |p| @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, p) }
        forwarded = bypassing("a frame too large to buffer arrived") do
          flush_buffered unless @passthrough
          Relay.forward_oversized_frame(@src, @dst, h, @direction, @flow_id, @sink, @opcode, @scratch)
        end
        reset_buffer if prefix
        @passthrough = true
        @rewritable = false
        @single_raw = nil
        forwarded
      end

      private def handle_data(frame : WS::Frame) : Nil
        if @passthrough
          write_direct(frame.raw)
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode)
          return
        end
        # Outgrowing the buffer we are willing to hold. Put what we have on the wire and let
        # the rest of THIS message stream byte-exact — the same disposition the oversized
        # path takes, and the same one the HTTP body rewrite takes past MAX_REWRITE_BODY:
        # leave it alone rather than grow the proxy heap while a rule is on.
        if @buffer.size + frame.payload.size > MAX_MESSAGE
          bypass("a message outgrew the #{MAX_MESSAGE}-byte assembly buffer") do
            flush_buffered
            write_direct(frame.raw)
          end
          @passthrough = true
          @rewritable = false
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode)
          return
        end
        @single_raw = @fresh && frame.fin? ? frame.raw : nil
        @fresh = false
        @buffer.write(frame.payload)
        emit_message if frame.fin?
      end

      # The message is complete. ONE pipeline: rewrite, then hold, then the wire.
      #
      # The hold is a STAGE here rather than a second pipeline beside this one, which is what
      # #513's D3 established on h2 and what makes the two features composable: what the
      # operator sees in the editor is what the rules produced, and what they forward is what
      # goes out — no rule re-runs over a human's edit, and no edit is made against bytes the
      # rules had not touched yet.
      #
      # Past the gate, a rewritten OR edited message MUST go out as ONE frame — once its
      # length changes the sender's fragmentation cannot be reproduced — but a message nothing
      # changed is forwarded as the peer's own frame, mask key and all, whenever it arrived as
      # a single frame.
      private def emit_message : Nil
        payload = @buffer.to_slice
        rewritten = rewrite(payload)
        raw = (r = @single_raw) && rewritten == payload ? r : nil
        if gate = @gate
          # Never blocks: the gate either writes through or parks the message and waits on a
          # fiber of its own, so the next frame — including a PING — is read immediately.
          gate.submit(@opcode, rewritten, raw)
        else
          write_direct(raw || WS.encode(@opcode, rewritten, mask: @mask, fin: true))
          # Record what gori WROTE rather than what arrived, the way #513 keeps P7 on h2: the
          # capture has to be the bytes the peer actually sees.
          @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, rewritten.dup)
        end
        reset_buffer
        # This message is over, so the NEXT data frame starts one — even a stray `OP_CONT`,
        # which does not go through `start_message`. Without the reset that frame found
        # `@fresh == false`, dropped its own `raw`, and was re-emitted under the PREVIOUS
        # message's opcode with a fresh mask key: gori silently REPAIRING a §5.4 violation
        # that the byte-exact pump passes through for the peer to judge. That breaks this
        # class's stated invariant — gori's own framing is used only for a message a rule or
        # the operator actually changed.
        @fresh = true
        @single_raw = nil
      end

      # Match & Replace, or the payload untouched when this message is not eligible (binary,
      # or no `part: ws` rule live on this side). `out` is a Crystal keyword, hence the name.
      private def rewrite(payload : Bytes) : Bytes
        rw = @rewriter
        return payload unless @rewritable && rw
        @direction == "out" ? rw.rewrite_ws_out(payload, @ctx.host) : rw.rewrite_ws_in(payload, @ctx.host)
      end

      # Emit everything buffered so far as a NON-final frame, so the rest of the message can
      # stream byte-exact behind it. Reached at most once per message (every caller either
      # switches to passthrough or ends the message immediately after), so this is always
      # the message's leading frame and carries the message opcode rather than OP_CONT.
      private def flush_buffered : Nil
        return if @buffer.size == 0
        write_direct(WS.encode(@opcode, @buffer.to_slice, mask: @mask, fin: false))
      end

      # Put a half-assembled message on the wire and into capture, then forget it. Only the
      # bytes this pump is WITHHOLDING: in passthrough they went out frame by frame already,
      # so there is nothing owed to the wire — but the buffer still has to be cleared, or its
      # bytes ride in front of the next message (see `start_message`).
      #
      # Emitted NON-final, so gori does not invent a FIN the sender never sent.
      private def flush_withheld : Nil
        return if @buffer.size == 0
        flush_buffered unless @passthrough
        @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, @buffer.to_slice.dup)
        reset_buffer
      end

      # A write that goes STRAIGHT to the socket, bypassing the queue. Every caller either
      # runs with no gate at all, or is already inside `bypass` (which has emptied the queue
      # and holds the gate's lock), so this can never interleave with a release.
      private def write_direct(bytes : Bytes) : Nil
        @dst.write(bytes)
        @dst.flush
      end

      # Run `block` after the gate's queue has been forced out in arrival order. A no-op
      # passthrough when no hold is armed, which is what keeps the rewrite-only path exactly
      # as step 1 shipped it.
      private def bypass(reason : String, &block : -> Nil) : Nil
        if gate = @gate
          gate.bypass(reason, &block)
        else
          block.call
        end
      end

      # `bypass` for a block that answers whether the peer survived the write.
      private def bypassing(reason : String, &block : -> Bool) : Bool
        ok = false
        bypass(reason) { ok = block.call }
        ok
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
