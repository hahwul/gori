require "./frame"
require "./message_gate"
require "../sink"
require "../socket_tuning"
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
  # own frames — every fragment, in order, with its own FIN/RSV bits and mask key, and with
  # any PING/PONG that arrived BETWEEN the fragments still sitting where it arrived (RFC 6455
  # §5.4). That last clause is not decoration: whether a peer tolerates a control frame
  # mid-message is a standard hardening probe, so hoisting one — which is what this pump did
  # to every socket with a rule or a catch armed, matching or not — deletes the test rather
  # than running it. The interleave is given up at exactly one point, and only for the message
  # it applies to: when an intercept hold actually PARKS the message, where a control frame
  # cannot wait for a human (see `MessageGate`'s header).
  module Relay
    # How one direction's pump stopped reading. `pump`/`AssemblingPump#run` used to answer
    # this as a Bool ("did it relay a CLOSE frame?"), which collapsed the two ways a socket
    # can end WITHOUT one — and gori knows which it was, because they arrive differently:
    # a FIN is a clean end of stream (`read_fully?` → nil) and a reset RAISES on gori's own
    # read. Neither reached the operator, so a `101 / complete / empty transcript` flow could
    # not answer "did the peer hang up normally, or did something kill this socket" — which
    # is the question that flow is opened to ask. It is also what `Relay.run` needs to know
    # whether a gate's DESTINATION is still worth claiming a delivery to (see `MessageGate`).
    enum Ending
      # This direction relayed a CLOSE frame — the clean half of the RFC 6455 §7.1.1
      # closing handshake. The peer is closing on purpose and is still reading.
      Close
      # End of stream with no CLOSE frame: the peer's FIN, or a frame truncated by it.
      Eof
      # The read raised: a transport reset, a broken pipe, an unreadable socket.
      Reset
    end

    # One direction's outcome, tagged with WHICH direction it was — `run` needs the pairing
    # to decide which gate's destination socket the ending is about.
    record DirectionEnd, direction : String, ending : Ending do
      def clean? : Bool
        ending.close?
      end
    end

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
    #
    # It is ALSO, once a hold is armed, the operator's decision window: from the moment
    # either peer sends CLOSE, an undecided held message has this long. It is not
    # configurable, and deliberately so — a longer window buys nothing, because the message
    # is not destroyed at the deadline any more. `settle` forwards it unedited while the
    # sockets are still open (the disposition every other involuntary release here takes),
    # `warn_close_deadline` says the window expired, and the ws_messages row is written. A
    # setting would only let an operator hold a dead-peer tunnel open longer.
    CLOSE_TIMEOUT = 5.seconds

    # PING/PONG frames recorded per direction, per socket, before capture stops.
    #
    # Control frames were not captured AT ALL until V7, which cost the operator the CLOSE
    # code and reason — the single most diagnostic thing a failed WebSocket test produces,
    # and something the repeater engine already reported (`Result#close_code`), so the two
    # surfaces disagreed about the same protocol. A PING payload is a real covert channel
    # and a real length-check bug site, and it was invisible too.
    #
    # But `insert_ws_message` BLOCKS until the write commits, and PING/PONG is the one frame
    # type a peer can emit without bound and without the operator's app doing anything. An
    # uncapped capture would throttle the relay to DB speed on a ping flood — a cost the
    # forward path did not have before, on frames nobody asked to see. So keepalives are
    # bounded and CLOSE is not: there is at most one CLOSE per direction, and it is the whole
    # reason this exists. Crossing the bound writes one marker row rather than going quiet.
    MAX_CONTROL_CAPTURE = 64

    # How many control frames may be parked between the fragments of ONE assembling message
    # so their arrival position can be reproduced on the wire (see `AssemblingPump`).
    #
    # A ceiling and not a policy. Parking is what keeps the interleave, but a peer that opens
    # a message with `TEXT fin=0` and then pings forever would park a PONG the far end's
    # 20-30 s ping timer is waiting for (RFC 6455 §5.5.2/§5.5.3) — the exact liveness failure
    # `MessageGate`'s header exists to prevent. Past this many, exactness is given up for that
    # message: everything parked is written out at once and the rest of the message's control
    # frames overtake it as they always did.
    MAX_PARKED_CONTROLS = 8

    # The largest a §5.5-compliant control frame can be ON THE WIRE: 125 payload bytes plus
    # the 2-byte header, plus the 4-byte masking key a client→server frame carries (§5.3).
    # `@parked` holds `ctl.raw`, which is the whole frame — so a ceiling derived from the
    # PAYLOAD cap alone would fire at seven fully compliant PINGs and make
    # MAX_PARKED_CONTROLS unreachable for max-size frames.
    MAX_CONTROL_FRAME_BYTES = 125 + 2 + 4

    # ... and the same ceiling in BYTES, which the count alone does not give.
    #
    # §5.5 caps a control payload at 125 bytes, and this constant used to be documented as
    # bounding the parked bytes for free because of it. It does not: `forward_control`
    # deliberately does NOT enforce that cap (a peer that advertises more gets its frame
    # relayed, not its tunnel killed — P7, and see the comment there), so a peer that opens a
    # message with `TEXT fin=0` and then sends eight 16 MiB PINGs parks a second copy of all
    # of them — ~128 MiB per direction, outside the MAX_MESSAGE budget that bounds `@buffer`
    # and `@raw`. Crossing this takes exactly the same disposition as crossing the count:
    # warn once, write everything parked out ahead of the message, and let this frame and
    # every later one overtake. Which bytes reach the wire is unchanged; only where they sit
    # relative to the message's fragments is.
    MAX_PARKED_BYTES = MAX_PARKED_CONTROLS * MAX_CONTROL_FRAME_BYTES

    # The direction column every notice row is written on, and it is NOT the direction the
    # notice is about.
    #
    # A notice is gori's own statement, and a `ws_messages` row on the OUT direction is not
    # only a record — it is a repeater SEED. `run repeater create --flow`, MCP
    # `create_repeater` and the TUI all take every `direction == "out"` row's opcode and
    # bytes straight across, by design (a binary frame and an invalid-UTF-8 text frame both
    # have to round-trip), so a 242-byte `[gori] …` sentence written on "out" is replayed to
    # the application under test as a masked client→server TEXT frame the client never sent —
    # a fabricated, malformed message injected into the operator's own test case, and a
    # `sent 11 message(s)` for 10 client frames. **A diagnostic is not traffic.**
    #
    # "in" is what `record_notice` has always used and is what made the `Sec-WebSocket-
    # Extensions` advisory safe; the parking-ceiling advisory was built on that precedent and
    # broke exactly the property that made it safe. The cost is that the row no longer says
    # which side it is about, so the SENTENCE has to — see `AssemblingPump#side`. Readers get
    # a second, independent guard in `Store::WsMessage#notice?`, because a flow captured by an
    # older build still carries an "out" notice row.
    NOTICE_DIRECTION = "in"

    # `rewriter` is the Match & Replace seam (#500 step 1) and `interceptor` the hold seam
    # (step 2); `ctx` is the 101 handshake's identity, which both scope on. All three default
    # to "off", so every caller that only relays keeps today's byte-exact path.
    #
    # `notice` is something the HANDSHAKE settled that the frames cannot show — today, what
    # gori did with `Sec-WebSocket-Extensions` (#518). It is recorded as the first
    # `ws_messages` row so it sits above the frames it explains and travels wherever they do:
    # History's WS pane, `gori run show`, MCP `get_flow`, an export. A `gori.log` line reaches
    # only an operator who already knew to tail it.
    def self.run(client : IO, upstream : IO, flow_id : Int64, sink : FlowSink,
                 rewriter : HeadRewriter? = nil, ctx : Context = Context::NONE,
                 interceptor : Gori::Interceptor? = nil, notice : String? = nil) : Nil
      record_notice(sink, flow_id, notice)
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
      # Built HERE and not inside the pump fiber, for the same reason `settle` is called from
      # this method: what a pump is WITHHOLDING can only reach the peer while the sockets are
      # still open, and on a gated socket the pump's own `ensure` is reached only AFTER the
      # two `close` calls below. See `AssemblingPump#flush_at_teardown`.
      out_pump = assembling_pump(client, upstream, "out", flow_id, sink, out_rw, ctx, out_gate, mask: true)
      in_pump = assembling_pump(upstream, client, "in", flow_id, sink, in_rw, ctx, in_gate, mask: false)

      done = Channel(DirectionEnd).new(2) # each pump's payload: HOW that direction ended
      # client→server: RFC 6455 §5.3 requires every such frame to be masked, so a re-emitted
      # one carries a fresh key of gori's.
      spawn { done.send(DirectionEnd.new("out", run_direction(client, upstream, "out", flow_id, sink, out_pump, out_gate))) }
      spawn { done.send(DirectionEnd.new("in", run_direction(upstream, client, "in", flow_id, sink, in_pump, in_gate))) }

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
      first = done.receive
      # Only the endings observed BEFORE the two `close` calls below are the PEERS'. The one
      # reaped afterwards is gori's own teardown unblocking a parked read, and attributing
      # that to a peer would be the diagnostic inventing traffic facts.
      observed = [first]
      second_pending = true
      if first.clean?
        select
        when second = done.receive
          second_pending = false # other side finished within the window (reply relayed, or its own end)
          observed << second
        when timeout(CLOSE_TIMEOUT)
          # peer never replied — give up waiting; the pump below is reaped after closing.
          warn_close_deadline(out_gate, in_gate)
        end
      end
      # Every write below happens BEFORE the two `close` calls, and this tunnel's socket
      # timeouts were cleared on the way in (`SocketTuning.relax` in ClientConn) so an idle
      # WebSocket is not reaped — which leaves `close` as the only escape hatch for a blocked
      # write, and it is sequenced after. A held message is up to MAX_MESSAGE with up to
      # MessageGate::MAX_DEFERRED_BYTES queued behind it, far past any socket buffer, so an
      # origin that stopped reading pins this fiber, both pump fibers, both fds and one of the
      # server's connection slots forever — the fd-exhaustion shape `Pump.blind_tunnel`'s
      # comment cross-closes to avoid, reached here through the teardown writes instead.
      # Re-arm a bounded timeout so a stalled peer RAISES: `MessageGate#write_message` and
      # `AssemblingPump#flush_at_teardown` already rescue a failed write into the "could not be
      # delivered" disposition, and the closes below then run normally. Armed after the
      # decision window and not before it, because `arm` sets the READ timeout too — a
      # surviving pump tripping at exactly CLOSE_TIMEOUT would land in `observed` as a peer
      # `Reset` that never happened.
      SocketTuning.arm(client, CLOSE_TIMEOUT)
      SocketTuning.arm(upstream, CLOSE_TIMEOUT)
      # Resolve both hold queues BEFORE the sockets go. `MessageGate#close` runs from the
      # pump's `ensure`, which is only reached because the two lines below unblocked its
      # read — so a message released there is written to a socket that is already gone. This
      # is the one moment at which a held message can still reach its peer.
      #
      # ... and `destination_dead` is the moment at which it CANNOT, which is a different
      # thing from failing to write. See the parameter's own doc on `MessageGate#settle`.
      out_gate.try(&.settle("the socket is closing", destination_dead: destination_dead?(observed, "out")))
      in_gate.try(&.settle("the socket is closing", destination_dead: destination_dead?(observed, "in")))
      # ... and the same moment, for the same reason, is the last one at which a HALF-assembled
      # message and the control frames parked between its fragments can still reach the peer.
      # The gates above resolve what a HUMAN still owns; this resolves what the pump itself is
      # withholding, and it goes second because those bytes arrived after everything queued.
      out_pump.try(&.flush_at_teardown)
      in_pump.try(&.flush_at_teardown)
      record_teardown(sink, flow_id, observed)
      client.close rescue nil
      upstream.close rescue nil
      # Every path above consumes exactly one of the two `done` sends before this point
      # except the "still waiting" case, so reap the outstanding one now (closing the
      # sockets just unblocked its pending read) — `run` must never return with a pump
      # fiber still alive.
      done.receive if second_pending
    end

    # The handshake's advisory as a `ws_messages` row, ahead of any frame. What it reports is
    # what gori did to (or found in) the ORIGIN's 101, and `NOTICE_DIRECTION` is why it is
    # written where it is. Best-effort — a capture write that fails must never stop the socket
    # from relaying.
    private def self.record_notice(sink : FlowSink, flow_id : Int64, notice : String?) : Nil
      n = notice
      return if n.nil? || n.empty?
      sink.on_ws_message(flow_id, NOTICE_DIRECTION, OP_TEXT.to_i, "#{NOTICE_PREFIX}#{n}".to_slice)
    rescue
      nil
    end

    # Is the socket a gate WRITES to already past the point where a delivery can be claimed?
    #
    # A gate's destination is the OTHER direction's source: `out`'s destination is the
    # upstream leg, which the `in` pump reads, and `in`'s is the client, which `out` reads.
    # So a direction's destination is known unreachable exactly when the OPPOSITE direction
    # ended without a CLOSE frame — a peer that sent one is closing on purpose and is still
    # reading, which is why the CLOSE path (`Relay::CLOSE_TIMEOUT`'s decision window) keeps
    # forwarding and keeps writing its `ws_messages` row.
    private def self.destination_dead?(observed : Array(DirectionEnd), direction : String) : Bool
      other = direction == "out" ? "in" : "out"
      observed.any? { |e| e.direction == other && !e.clean? }
    end

    # A peer that RESET the socket, said on the flow's own `ws_messages` stream — the seam
    # `AssemblingPump#warn_teardown_loss` and the `Sec-WebSocket-Extensions` advisory already
    # use, so it travels to History's WS pane, `gori run show`, MCP `get_flow` and an export
    # rather than to a `gori.log` only an operator who knew to tail it ever reads.
    #
    # gori HAS the FIN-vs-RST bit and was throwing it away: a peer's reset RAISES on gori's
    # own read while a FIN is a clean end of stream, and neither reached the flow. An operator
    # looking at a `101 / complete / empty transcript` flow is asking exactly whether the peer
    # hung up normally or something killed the socket, and nothing on disk could answer.
    #
    # Only the RESET earns a row, and the sentence says so, so its ABSENCE is readable rather
    # than ambiguous. A WebSocket that ends on a FIN with no CLOSE frame is the ordinary way
    # one dies in the field — a closed tab, a dropped network, a restarted origin — and
    # annotating those would put a `[gori]` row on a large fraction of every capture to say
    # "nothing unusual happened", which is exactly how the anomalous row stops being noticed.
    # Only endings observed BEFORE `run` closes the sockets are considered, so gori's own
    # teardown is never reported as a peer's. Best-effort, and on `NOTICE_DIRECTION` for the
    # reason stated there.
    private def self.record_teardown(sink : FlowSink, flow_id : Int64,
                                     observed : Array(DirectionEnd)) : Nil
      reset = observed.find(&.ending.reset?) || return
      note = teardown_sentence(reset)
      ::Log.info { "ws #{reset.direction}: #{note}" }
      sink.on_ws_message(flow_id, NOTICE_DIRECTION, OP_TEXT.to_i,
        "#{NOTICE_PREFIX}#{note}".to_slice)
    rescue
      nil
    end

    # The SENTENCE has to name the side, because the row is written on `NOTICE_DIRECTION`.
    # `out` reads the client and `in` reads the server, so the peer named here is the one
    # whose bytes stopped arriving.
    private def self.teardown_sentence(e : DirectionEnd) : String
      peer = e.direction == "out" ? "the client" : "the server"
      "#{peer} ended this WebSocket with a transport-level RESET and no CLOSE frame — " \
      "something killed the socket rather than closing it (RFC 6455 §7.1.1). A peer that " \
      "closes normally, with or without the closing handshake, leaves no row here"
    end

    # CLOSE_TIMEOUT just expired with a message still held. Nothing else tells the operator
    # that their decision window closed — the queue row simply vanishes from the TUI — and
    # "why did my held message go out unedited" is unanswerable without this line.
    private def self.warn_close_deadline(out_gate : MessageGate?, in_gate : MessageGate?) : Nil
      held = [out_gate, in_gate].compact.select(&.pending?)
      return if held.empty?
      ::Log.warn do
        "ws: a peer sent CLOSE and the other side did not answer within " \
        "#{CLOSE_TIMEOUT.total_seconds.to_i}s — " \
        "the decision window for #{held.size == 1 ? "a" : "both"} direction's held message(s) " \
        "is over; they are being forwarded unedited before the tunnel is torn down"
      end
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

    # This direction's assembling pump, or nil when neither a `part: ws` rule nor a hold is
    # live on it — `pump`, the pre-existing byte-exact loop, is what every other socket runs
    # and it carries no state across frames, so it needs no object.
    private def self.assembling_pump(src : IO, dst : IO, direction : String, flow_id : Int64,
                                     sink : FlowSink, rewriter : HeadRewriter?, ctx : Context,
                                     gate : MessageGate?, mask : Bool) : AssemblingPump?
      return nil unless rewriter || gate
      AssemblingPump.new(src, dst, direction, flow_id, sink, rewriter, ctx, gate, mask)
    end

    # One direction's loop, on whichever pump `assembling_pump` chose.
    private def self.run_direction(src : IO, dst : IO, direction : String, flow_id : Int64,
                                   sink : FlowSink, assembling : AssemblingPump?,
                                   gate : MessageGate?) : Ending
      return pump(src, dst, direction, flow_id, sink) unless assembling
      begin
        assembling.run
      ensure
        # The direction ended (cleanly or not). Hand every still-held message back to the
        # Interceptor so no ghost queue row survives the socket and no wait fiber leaks —
        # `H2::StreamGate#close`'s contract. This is also where the CLOSE_TIMEOUT ceiling
        # lands: when the PEER closes the other direction, `run` gives this one 5 s and then
        # closes the sockets, which unblocks the read here and reaps whatever was still held.
        gate.try(&.close)
      end
    end

    # Chunk size for streaming an oversized frame's payload (see stream_payload).
    STREAM_CHUNK = 64 * 1024

    # One direction: read a frame header → forward the frame byte-exact → capture
    # the reassembled message on FIN. A frame larger than MAX_FRAME is streamed
    # through (byte-exact, P7) rather than aborting the whole tunnel; its payload is
    # too large to buffer, so capture records a marker for that frame instead.
    #
    # Returns HOW this direction ended (see `Ending`): a relayed CLOSE frame is the "clean"
    # end of the RFC 6455 closing handshake, and `run` gives the peer's replying CLOSE a
    # bounded window on it instead of tearing the tunnel down the instant either direction
    # stops. The two abnormal ends are kept apart rather than collapsed, because gori reads
    # them differently and the operator needs the difference.
    private def self.pump(src : IO, dst : IO, direction : String, flow_id : Int64, sink : FlowSink) : Ending
      assembling = IO::Memory.new
      message_opcode = OP_TEXT
      scratch = Bytes.new(STREAM_CHUNK)
      ending = Ending::Eof
      shape = MessageShape.new
      controls = 0
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
          assembling = emit_pending(assembling, direction, flow_id, sink, message_opcode, shape)
          message_opcode = h.opcode
        end

        if h.len > WS::MAX_FRAME
          # Flush any buffered leading fragments of this message before the oversized-frame
          # marker, so captured prefix bytes aren't dropped and a later small FIN fragment
          # can't be surfaced as if it were the whole message.
          assembling = emit_pending(assembling, direction, flow_id, sink, message_opcode, shape) if h.data?
          break unless forward_oversized_frame(src, dst, h, direction, flow_id, sink, message_opcode, scratch)
          if h.close? # an oversized CLOSE still terminates the tunnel, like a normal one
            ending = Ending::Close
            break
          end
          next
        end

        frame = WS.read_body(src, h) || break
        dst.write(frame.raw)
        dst.flush
        controls = capture_control(frame, direction, flow_id, sink, controls)
        shape.note(frame) if frame.data?
        assembling = capture_frame(frame, assembling, direction, flow_id, sink, message_opcode, shape)
        if frame.close?
          ending = Ending::Close
          break
        end
      end
      ending
    rescue
      Ending::Reset # the read RAISED: a transport reset, not the peer's FIN
    ensure
      # An unterminated fragment when the direction ends. gori already put those bytes on the
      # wire frame by frame, so dropping them here made History disagree with what gori itself
      # relayed — `TEXT fin=0 "UNTERMINATED"` then a CLOSE left no row at all. Emitted on both
      # the clean and the reset path, which is why this is an `ensure` and not a tail statement.
      # `AssemblingPump#run`'s own `ensure` flushes its withheld half for the same reason.
      # `ensure` types every body-assigned local as nilable (the raise could precede the
      # assignment), so bind it before asking.
      if buf = assembling
        emit_pending(buf, direction, flow_id, sink, message_opcode || OP_TEXT,
          shape || MessageShape.new) rescue nil
      end
    end

    # Surface whatever fragments are buffered as ONE message and hand back a cleared buffer.
    # A no-op when nothing is buffered. Three callers need exactly this: a new data message
    # arriving before the previous one FIN'd (RFC 6455 §5.4), an oversized frame that ends the
    # buffered prefix, and teardown with an unterminated fragment still held. They had two
    # copies and one omission between them, which is how the merged-row and dropped-bytes bugs
    # got in; `AssemblingPump` has the same three moments and its own equivalents.
    private def self.emit_pending(assembling : IO::Memory, direction : String, flow_id : Int64,
                                  sink : FlowSink, message_opcode : UInt8,
                                  shape : MessageShape) : IO::Memory
      if assembling.size == 0
        # No row for a zero-byte message — but the accumulator still has to be cleared when a
        # fragment WAS noted, because a LEADING FRAGMENT MAY BE EMPTY. `TEXT fin=0 ""` then
        # `TEXT fin=1 "BBB"` left the empty frame's note standing, so "BBB" surfaced as a
        # two-frame message that never ended. `AssemblingPump#flush_withheld` states the same
        # rule; the two pumps have to record identical facts about identical bytes.
        shape.reset if shape.frames > 0
        return assembling
      end
      sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup, shape.take)
      assembling.size > RESET_THRESHOLD ? IO::Memory.new : assembling.tap(&.clear)
    end

    # Record a control frame (RFC 6455 §5.5). Returns the running PING/PONG count for this
    # direction — see MAX_CONTROL_CAPTURE for why CLOSE is exempt from it.
    #
    # The forward already happened: this is capture only, and it runs AFTER the write for the
    # same reason every other capture call here does — a blocking DB round-trip must never sit
    # between a peer's frame and its delivery.
    def self.capture_control(frame : WS::Frame, direction : String, flow_id : Int64,
                             sink : FlowSink, seen : Int32) : Int32
      return seen if frame.data?
      if frame.close?
        sink.on_ws_message(flow_id, direction, frame.opcode.to_i, frame.payload.dup, frame.shape)
        return seen
      end
      n = seen + 1
      if n <= MAX_CONTROL_CAPTURE
        sink.on_ws_message(flow_id, direction, frame.opcode.to_i, frame.payload.dup, frame.shape)
      elsif n == MAX_CONTROL_CAPTURE + 1
        # One marker, then silence — but the operator is told which it is. A capture that
        # simply stops looks exactly like a peer that stopped pinging.
        # Keeps the flooding frame's OWN opcode and direction, so it sits in the ping stream
        # it stands for. That makes it a row a repeater seed would otherwise replay as a PING
        # carrying this sentence; `NOTICE_PREFIX` is what `Store::WsMessage#notice?` reads to
        # refuse it, which is why this marker is built from the constant and not a literal.
        marker = "#{NOTICE_PREFIX}more than #{MAX_CONTROL_CAPTURE} ping/pong frames on this " \
                 "direction; the rest are forwarded but not recorded".to_slice
        sink.on_ws_message(flow_id, direction, frame.opcode.to_i, marker, frame.shape)
      end
      n
    end

    # One direction's assembling pump (#500). Only reached when a `part: ws` rule can match
    # this socket's host on this side, or when the catch condition arms a hold there; `pump`
    # above is what every other socket runs, unchanged.
    #
    # An object rather than a method because it carries per-message state across frames (the
    # assembly buffer, the message opcode, whether the message has fallen back to byte-exact
    # forwarding) — and because `Relay.run` has to reach that state at teardown, while the
    # sockets are still open (`flush_at_teardown`). One instance per pump fiber — and that
    # last clause is what makes the state shared anyway, because `Relay.run` reaches it from
    # its OWN fiber while this pump is still reading frames. `@in_frame` is what keeps those
    # two out of each other's way; the GATE owns the other shared state, because a wait fiber
    # writes through it.
    #
    # The invariant it keeps: gori's own framing is used ONLY for a message a rule or the
    # operator actually changed. Everything else — binary messages nobody edited, oversized
    # frames, messages past the buffer cap, and text messages no rule matched — leaves as the
    # bytes that arrived.
    private class AssemblingPump
      @buffer = IO::Memory.new
      @opcode = OP_TEXT
      @passthrough = false # this message fell back to frame-by-frame byte-exact forwarding
      @rewritable = false  # ... and this one is eligible for Match & Replace (TEXT + a live rule)
      # This message's own wire frames, concatenated in arrival order — headers, FIN/RSV bits
      # and mask keys included. Re-emitted verbatim whenever nothing changed the payload, which
      # is what keeps the invariant above true for a FRAGMENTED message too. It used to hold
      # only a single frame's `raw` (`@fresh && frame.fin?`), so every multi-frame message went
      # out re-framed as ONE frame under a mask key gori invented — including messages no rule
      # matched, on a socket armed for a rule scoped to some other host. Fragmentation IS the
      # payload for per-frame length checks and WAF/IDS bypass tests, so removing it removed
      # the property under test.
      @raw = IO::Memory.new
      @raw_kept = true # ... and whether those bytes are still complete (see MAX_MESSAGE)
      # PING/PONG frames that arrived BETWEEN this message's fragments, each paired with the
      # offset into `@raw` it arrived at. They are NOT on the wire yet: writing them the
      # instant they arrive is what hoisted a control frame ahead of the fragments it was
      # interleaved with, on every socket where a `part: ws` rule or a `proto:ws` catch was
      # armed — even one whose condition matched nothing. Individual frame bytes survived
      # that; the SEQUENCE did not, and the sequence is the §5.4 question.
      #
      # Bounded by MAX_PARKED_CONTROLS and MAX_PARKED_BYTES, and only ever populated while
      # this message is still un-rewritten and un-held: `park_control?` declines on the
      # passthrough path (whose frames are already on the wire, so the order is kept for free)
      # and `emit_message` hands them to the gate the moment a hold actually parks the message.
      @parked = [] of {Int32, Bytes}
      # What `@parked` currently holds, in bytes. Tracked rather than summed because
      # `park_control?` asks on every control frame; it is reset wherever `@parked` is emptied.
      @parked_bytes = 0
      @parked_overflowed = false
      @in_bypass = false # the gate's lock is already held, so writes must not re-take it
      @torn_down = false # `flush_at_teardown` has run; there is nothing left to owe the wire
      # Whether this pump is part-way through one frame — set for the whole of `step`, which is
      # everything below the header read: the assembly state (`@buffer`, `@raw`, `@shape`,
      # `@parked`) and every write to `@dst`. It exists because `Relay.run` reaches
      # `flush_at_teardown` from ITS OWN fiber while this pump's fiber is alive and mid-message.
      # Without the guard the teardown flush yields mid-flush (`@sink.on_ws_message`, a store
      # round-trip; a `@dst.write` that hits EAGAIN; `MessageGate#settle`'s own `Fiber.yield`),
      # the pump appends the fragment that just arrived, and then the flush's `reset_buffer`
      # wipes it — the fragment reaching neither the wire nor a row, or the message re-emitted
      # with its already-flushed leading frames duplicated.
      #
      # A plain Bool and not a Mutex, deliberately: gori runs on the single-threaded cooperative
      # scheduler (AGENTS.md §3), so a flag set and cleared with no yield between is exact — and
      # a Mutex here DEADLOCKS. `step` blocks in `WS.read_body`'s `read_fully?` waiting for a
      # payload the peer may never finish, so a lock taken across it is held indefinitely;
      # `Relay.run` would then block in `flush_at_teardown` and never reach the two `close`
      # calls that are the only thing able to unblock that read (a socket's `read_timeout`
      # armed AFTER a fiber has parked does not fire — measured). One truncated frame from
      # either peer would pin both fds, all three fibers, and one of the server's connection
      # slots forever. So the teardown flush never waits: it skips a pump that is mid-frame and
      # lets that pump's own `ensure` flush after the close, where a failed write is already
      # accounted as teardown loss.
      @in_frame = false
      @scratch : Bytes
      # The V7 frame-shape accumulator and this direction's ping/pong capture budget. Both
      # pumps have to record identical facts about identical bytes, or an operator's finding
      # would depend on whether a rule happened to be live on some other host.
      @shape = MessageShape.new
      @controls = 0

      def initialize(@src : IO, @dst : IO, @direction : String, @flow_id : Int64,
                     @sink : FlowSink, @rewriter : HeadRewriter?, @ctx : Context,
                     @gate : MessageGate?, @mask : Bool)
        @scratch = Bytes.new(STREAM_CHUNK)
      end

      # What `run` does with one frame, once `step` has handled it.
      enum Step
        Continue # keep reading
        Stop     # end of stream, a truncated frame, or this pump is already torn down
        Closed   # a CLOSE frame was relayed: the clean half of the §7.1.1 handshake
      end

      # Same contract as `Relay.pump`: HOW this direction ended (see `Ending`).
      def run : Ending
        ending = Ending::Eof
        loop do
          h = WS.read_header(@src) || break
          case step(h)
          when Step::Closed
            ending = Ending::Close
            break
          when Step::Stop
            break
          end
        end
        ending
      rescue
        Ending::Reset # the read RAISED: a transport reset, not the peer's FIN
      ensure
        # The abnormal exits (EOF, a truncated frame, a reset) are withholding the same bytes
        # a CLOSE would have been, and the byte-exact pump would already have forwarded them —
        # so dropping them silently is a difference between the two pumps that should not
        # exist. Reached FIRST for the direction that ends on its own (the sockets are still
        # open — `Relay.run` is parked on `done.receive`); a no-op for the other one, which
        # `run` has already flushed. Either way `flush_at_teardown` runs exactly once.
        flush_at_teardown
      end

      # One frame, marked `@in_frame` for its whole length (see the declaration) — the body read
      # included, because a frame is not a unit until its payload is in hand and letting the
      # teardown flush run between a header and its own body is the same interleave. The wait
      # that costs is the HEADER read, and that one stays outside: it is where this fiber parks
      # between frames, and a flush is exactly what should be allowed to happen there.
      private def step(h : WS::Header) : Step
        # `Relay.run` has already flushed this pump and is about to close both sockets. What
        # this loop assembles from here reaches neither the wire nor a row — the flush that
        # would have put it out has run, and `@torn_down` has disabled the `ensure`'s — so the
        # direction ends here instead, leaving the bytes on the peer's socket rather than
        # swallowing them into a buffer nobody will flush.
        return Step::Stop if @torn_down
        @in_frame = true
        unless h.data?
          return Step::Stop unless forward_control(h)
          return h.close? ? Step::Closed : Step::Continue
        end
        start_message(h.opcode) if h.opcode != OP_CONT
        if h.len > WS::MAX_FRAME
          return forward_oversized(h) ? Step::Continue : Step::Stop
        end
        frame = WS.read_body(@src, h) || return Step::Stop
        handle_data(frame)
        Step::Continue
      ensure
        @in_frame = false
      end

      # Everything this pump is still WITHHOLDING — a half-assembled message's fragments and
      # any control frame parked between them — put on the wire in arrival order, and into
      # capture. Idempotent, and best-effort: it is normally reached BECAUSE a peer went away.
      #
      # It cannot be left to the `ensure` above on a GATED socket. That `ensure` is reached
      # there only because `Relay.run` closed both sockets to unblock this pump's read, so the
      # write would have nowhere to go — which is exactly why the flush used to be skipped
      # (`if @gate.nil?`). That exclusion was harmless until #554 started PARKING control
      # frames: before it, a control frame was on the wire the instant it arrived, so there
      # was nothing in `@parked` to lose. After it, a gated socket that ended without a CLOSE
      # delivered neither the parked PING nor the fragment it was parked inside — while the
      # arrival-time `capture_control` row still claimed the PING had gone out. Losing a
      # keepalive on a gated socket is the liveness failure `MAX_PARKED_CONTROLS` and
      # `MessageGate`'s header exist to prevent, so the answer is to write the frames, not to
      # stop recording them. `Relay.run` calls this while both sockets are still open, right
      # after `settle` — the same moment, and for the same reason.
      #
      # It is also the one flush that is normally reached BECAUSE the peer died, so it is the
      # one whose write can fail — and a control frame's capture row is written at ARRIVAL
      # (`Relay.capture_control`, whose own comment says "the forward already happened"),
      # which was harmless only while a control frame went out the instant it arrived. Parking
      # made "arrived" and "was delivered" two events and this is exactly where they diverge:
      # against an origin that hard-RSTs, the origin's own accounting says 0 bytes received
      # while gori's capture carries a PING row. The row is not wrong about the arrival — the
      # client really did send that PING, and deleting the row would throw away evidence gori
      # holds — so what was missing is the sentence saying it never got out. `MessageGate`'s
      # `write_message` states the same contract from the other side ("a `ws_messages` row is
      # gori's claim that the peer saw these bytes"), and a refusal has to name itself.
      # Called from TWO fibers: this pump's own `ensure`, and `Relay.run`'s teardown while this
      # pump is still reading. `@in_frame` decides which of them gets to do it — see its
      # declaration for why that is a flag and not a lock.
      def flush_at_teardown : Nil
        return if @torn_down
        # Mid-frame: this pump owns the assembly state right now, and half of it is on the
        # stack of a `step` that has not returned. Leave it alone — `Relay.run` closes the
        # sockets immediately after this, which ends that `step`, and the `ensure` below its
        # loop then runs this again from the fiber that does own the state. What is owed goes
        # out there or is reported by `warn_teardown_loss`; it is never silently dropped.
        return if @in_frame
        @torn_down = true
        # Snapshotted BEFORE the attempt: `flush_parked` empties `@parked` ahead of its own
        # write, so after a raise there is nothing left to count.
        owed_controls = @parked.size
        owed_bytes = @passthrough ? 0 : @buffer.size
        begin
          bypass("the socket is closing") { flush_withheld }
        rescue
          warn_teardown_loss(owed_controls, owed_bytes)
        end
      rescue
        nil
      end

      # The teardown flush could not reach the peer. Say so on the flow's own `ws_messages`
      # stream, positioned after every row it corrects, so `run show`, MCP `get_flow`, the WS
      # pane and an export all carry it. `gori.log` reaches only an operator who knew to tail
      # it, and the frames this is about are the ones an operator arms a fragmentation test to
      # watch.
      private def warn_teardown_loss(controls : Int32, bytes : Int32) : Nil
        return if controls == 0 && bytes == 0
        parts = [] of String
        if controls > 0
          parts << "#{controls} control frame(s) parked between its fragments — the ping/pong " \
                   "row(s) above record their ARRIVAL, not their delivery"
        end
        parts << "#{bytes} byte(s) of its payload, which reached no row at all" if bytes > 0
        note = "the #{side} socket died before an unfinished message could be flushed: " \
               "#{parts.join("; and ")}"
        ::Log.warn { "ws #{@direction}: #{note}" }
        record_notice(note)
      end

      # A control frame (ping/pong/close) never takes part in a rewrite or a hold, and it is
      # forwarded byte-exact. WHEN it is forwarded has two answers, and the difference is the
      # §5.4 interleave.
      #
      # While this pump is withholding a message's fragments and nothing has yet been changed
      # or held, the frame is PARKED at its arrival position (`park_control?`) and rides out
      # inside the message's own wire bytes — so `TEXT fin=0 "AAA"` / `PING` / `CONT fin=1
      # "BBB"` reaches the peer in that order, the order the byte-exact pump has always given
      # it. Writing it immediately instead put the PING first on every socket with a `part:
      # ws` rule or a `proto:ws` catch armed, matching or not, which silently deleted the
      # test an operator arms such a socket to run.
      #
      # Everywhere else it goes out the instant it arrives: between messages, on the
      # passthrough path (whose fragments are already on the wire), past the parking ceiling,
      # and — the one that matters — the moment a hold actually PARKS the message. Holding a
      # PONG behind a human is how a server's 20-30 s ping timer closes the socket out from
      # under the operator, and on that path it is not a refinement, it is the whole reason
      # this pump may not block. See `MessageGate`'s header.
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
        elsif park_control?(ctl)
          # Nothing on the wire yet: it leaves with the message it is interleaved with.
        elsif gate = @gate
          gate.write_control(ctl.raw)
        else
          write_direct(ctl.raw)
        end
        # After the forward, exactly like `Relay.pump` — the two pumps must record the same
        # control frames or the CLOSE code would depend on whether a rule was live.
        @controls = Relay.capture_control(ctl, @direction, @flow_id, @sink, @controls)
        true
      end

      # Park this control frame at its arrival position inside the message being assembled,
      # answering whether it was taken (the caller then writes nothing). Declined when there
      # is no assembling message to interleave it with, when this message's own wire bytes
      # are gone anyway (passthrough, or past the raw cap — in both cases the fragments are
      # already on the wire, so arrival order is preserved by writing straight through), and
      # once MAX_PARKED_CONTROLS frames or MAX_PARKED_BYTES bytes have piled up.
      private def park_control?(ctl : WS::Frame) : Bool
        return false if @passthrough || !@raw_kept || @raw.size == 0
        # A message that never ends must not sit on the peer's PONG, and it must not pin the
        # proxy's heap either. Either ceiling gives up exactness for this message, says so
        # once, and lets this frame and every later one overtake.
        if @parked.size >= MAX_PARKED_CONTROLS
          warn_parking_ceiling("more than #{MAX_PARKED_CONTROLS} control frames")
          flush_parked
          return false
        end
        if @parked_bytes + ctl.raw.size > MAX_PARKED_BYTES
          warn_parking_ceiling("more than #{MAX_PARKED_BYTES} bytes of control frames")
          flush_parked
          return false
        end
        @parked << {@raw.size, ctl.raw.dup}
        @parked_bytes += ctl.raw.size
        true
      end

      # Write every parked control frame out, in arrival order, ahead of the message they
      # arrived inside. The disposition when the interleave cannot be reproduced: gori is
      # re-framing the message, a hold has parked it, or the ceiling above tripped.
      private def flush_parked : Nil
        return if @parked.empty?
        bytes = parked_bytes
        @parked.clear
        @parked_bytes = 0
        return unless bytes
        if (gate = @gate) && !@in_bypass
          gate.write_control(bytes)
        else
          write_direct(bytes)
        end
      end

      # The parked frames' bytes, concatenated in arrival order, or nil when none.
      private def parked_bytes : Bytes?
        return nil if @parked.empty?
        io = IO::Memory.new
        @parked.each { |(_, bytes)| io.write(bytes) }
        io.to_slice
      end

      # This message's own wire bytes with the parked control frames spliced back in at the
      # offsets they arrived at — the exact octets the peer wrote, in the exact order. With
      # nothing parked (the common case even here) it is a VIEW into `@raw` and costs nothing;
      # a caller that outlives this message — only the gate does — dups it.
      private def interleaved_raw : Bytes
        return @raw.to_slice if @parked.empty?
        data = @raw.to_slice
        io = IO::Memory.new(data.size + 32)
        pos = 0
        @parked.each do |(at, bytes)|
          io.write(data[pos, at - pos]) if at > pos
          io.write(bytes)
          pos = at
        end
        io.write(data[pos, data.size - pos]) if pos < data.size
        io.to_slice
      end

      # The ceiling tripped, so gori is about to put this message's parked control frames on
      # the wire AHEAD of the fragments they arrived between: the §5.4 interleave the peer
      # reads off this socket is no longer the one the peer sent.
      #
      # That is a fact about the wire, so it goes on the flow's own `ws_messages` stream and
      # not only into `gori.log` — #518's argument for the `Sec-WebSocket-Extensions`
      # advisory, and the `[gori] …` convention `capture_control`'s ping-flood marker and
      # `forward_oversized_frame`'s already use. Without the row nothing downstream can tell
      # the two dispositions apart: control frames are recorded at ARRIVAL and message rows at
      # EMIT either way, so History, `gori run show`, MCP `get_flow` and an export show the
      # same "controls, then the message" ordering whether the interleave was preserved or
      # given up. Once per direction per socket, like the warn and like `MAX_CONTROL_CAPTURE`'s
      # marker — its POSITION in the stream is what names the message it applies to.
      #
      # `crossed` names WHICH ceiling gave way — the count or the byte total — because the two
      # answer different operator questions ("my peer is pinging in a loop" vs "my peer is
      # sending control frames §5.5 says cannot exist"), and the sentence is the only place
      # that can say so.
      private def warn_parking_ceiling(crossed : String) : Nil
        return if @parked_overflowed
        @parked_overflowed = true
        note = "#{crossed} arrived between the fragments " \
               "of one #{side} message; they were forwarded ahead of it so the peer's ping " \
               "timer still sees a reply. The frames are byte-exact; their position relative " \
               "to that message's fragments is not"
        ::Log.warn { "ws #{@direction}: #{note}" }
        record_notice(note)
      end

      # A statement about this SOCKET as a `ws_messages` row. Best-effort exactly as
      # `Relay.record_notice` is — a row that fails to write must never stop the relay from
      # forwarding — and on `NOTICE_DIRECTION` for the reason stated there.
      private def record_notice(note : String) : Nil
        @sink.on_ws_message(@flow_id, NOTICE_DIRECTION, OP_TEXT.to_i,
          "#{NOTICE_PREFIX}#{note}".to_slice)
      rescue
        nil
      end

      # This direction in words. `@direction`'s own "out"/"in" is the row's COLUMN, and a
      # notice row is written on `NOTICE_DIRECTION` rather than here — so the sentence is the
      # only thing left that can say which side it is about, and without it a notice about the
      # client's frames would read as something the origin did.
      private def side : String
        @direction == "out" ? "client→server" : "server→client"
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
        #
        # `@shape.frames` and not `@buffer.size` decides, for the reason `flush_withheld`
        # states: a LEADING FRAGMENT MAY BE EMPTY, so `TEXT fin=0 ""` then `TEXT fin=1 "BBB"`
        # is a message half-assembled with an empty buffer — and asking the buffer skipped the
        # flush, after which `reset_raw` discarded the empty frame's own wire bytes. The
        # byte-exact pump forwards it.
        if @shape.frames > 0 || !@parked.empty?
          bypass("a message arrived before the previous one sent its FIN") { flush_withheld }
        end
        @opcode = opcode
        @rewritable = opcode == OP_TEXT && !@rewriter.nil?
        @passthrough = !@rewritable && @gate.nil?
        reset_raw
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
        # Taken whether or not there is a prefix ROW to hang it on: an empty leading fragment
        # is still a noted frame, and leaving the accumulator standing would put its FIN, its
        # RSV bits and its place in `frames` on the next message — and would leave
        # `flush_withheld` believing a fragment is still owed.
        shape = @shape.take
        prefix.try { |p| @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, p, shape) }
        forwarded = bypassing("a frame too large to buffer arrived") do
          flush_buffered unless @passthrough
          Relay.forward_oversized_frame(@src, @dst, h, @direction, @flow_id, @sink, @opcode, @scratch)
        end
        reset_buffer if prefix
        @passthrough = true
        @rewritable = false
        reset_raw
        forwarded
      end

      private def handle_data(frame : WS::Frame) : Nil
        @shape.note(frame)
        if @passthrough
          write_direct(frame.raw)
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode, @shape)
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
          @buffer = Relay.capture_frame(frame, @buffer, @direction, @flow_id, @sink, @opcode, @shape)
          return
        end
        keep_raw(frame)
        @buffer.write(frame.payload)
        emit_message if frame.fin?
      end

      # Accumulate this frame's own wire bytes. Bounded by MAX_MESSAGE like the payload
      # buffer, because framing overhead is per-frame and a peer sending millions of
      # one-byte fragments would otherwise cost more here than the payload cap allows.
      # Past the cap the message simply loses its byte-exact form and is re-framed, the
      # same disposition every other over-the-cap path in this class takes.
      private def keep_raw(frame : WS::Frame) : Nil
        return unless @raw_kept
        if @raw.size + frame.raw.size > MAX_MESSAGE
          # The frames these were parked between are gone, so there is no position left to
          # hold them at. Out they go, ahead of whatever this message is re-framed as.
          flush_parked
          @raw_kept = false
          @raw = IO::Memory.new
          return
        end
        @raw.write(frame.raw)
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
      # changed is forwarded as the peer's OWN frames: every fragment, in order, with its own
      # FIN/RSV bits and its own mask key.
      private def emit_message : Nil
        payload = @buffer.to_slice
        rewritten = rewrite(payload)
        # The gate outlives this call and reuses its own buffers, so it gets a copy; the
        # direct write below is done with the bytes before `reset_buffer` runs and does not.
        reusable = @raw_kept && @raw.size > 0 && rewritten == payload
        # The shape belongs to whatever goes on the wire, not to what arrived. Re-framing is
        # the one moment gori's own framing replaces the sender's, so the row has to say so —
        # otherwise a rewritten message would claim the RSV bits and the fragment count of the
        # frames it just replaced.
        arrived = @shape.take
        emitted = reusable ? arrived : WS::Shape.new(masked: @mask)
        # gori is re-framing this message, so the sender's fragmentation is gone and there is
        # no position left to hold an interleaved control frame at. Out it goes ahead of the
        # message — what this pump did for EVERY message before parking existed.
        flush_parked unless reusable
        if gate = @gate
          # Never blocks: the gate either writes through or parks the message and waits on a
          # fiber of its own, so the next frame — including a PING — is read immediately.
          # It gets the message's frames in both forms because only IT knows which applies:
          # written through, the peer's own interleave goes back on the wire; parked on a
          # hold, the control frames are split back out and sent now (see `WS::RawFrames`).
          # Pass `emitted`, not `arrived`: when re-framing, MessageGate records the shape
          # on write, and the arrived multi-fragment RSV/mask is a lie about what goes out
          # (one frame, gori's key). `emitted` was already computed above and was a dead
          # store on this branch.
          gate.submit(@opcode, rewritten,
            reusable ? WS::RawFrames.new(interleaved: interleaved_raw.dup,
              data_only: @raw.to_slice.dup, controls: parked_bytes) : nil,
            emitted)
        else
          write_direct(reusable ? interleaved_raw : WS.encode(@opcode, rewritten, mask: @mask, fin: true))
          # Record what gori WROTE rather than what arrived, the way #513 keeps P7 on h2: the
          # capture has to be the bytes the peer actually sees.
          @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, rewritten.dup, emitted)
        end
        # This message is over, so the NEXT data frame starts one — even a stray `OP_CONT`,
        # which does not go through `start_message`. Without `reset_buffer`'s reset of the
        # accumulated wire bytes, that frame would ride out behind the PREVIOUS message's
        # frames: gori silently REPAIRING a §5.4 violation that the byte-exact pump passes
        # through for the peer to judge. That breaks this class's stated invariant — gori's
        # own framing is used only for a message a rule or the operator actually changed.
        reset_buffer
      end

      # Match & Replace, or the payload untouched when this message is not eligible (binary,
      # or no `part: ws` rule live on this side). `out` is a Crystal keyword, hence the name.
      private def rewrite(payload : Bytes) : Bytes
        rw = @rewriter
        return payload unless @rewritable && rw
        @direction == "out" ? rw.rewrite_ws_out(payload, @ctx.host) : rw.rewrite_ws_in(payload, @ctx.host)
      end

      # Emit everything buffered so far, so the rest of the message can stream byte-exact
      # behind it. The buffer holds the payload as it ARRIVED (the rewrite only runs in
      # `emit_message`), so the sender's own frames say the same thing byte for byte and are
      # preferred — same invariant as `emit_message`. Only when they are gone (past the raw
      # cap) is the prefix re-framed, as a NON-final frame carrying the message opcode rather
      # than OP_CONT: this is reached at most once per message, so it is always the leading one.
      private def flush_buffered : Nil
        if @raw_kept && @raw.size > 0
          # The peer's frames, control-frame interleave and all. Asked FIRST, and about `@raw`
          # rather than about `@buffer`, because a LEADING FRAGMENT MAY BE EMPTY: `TEXT fin=0`
          # with a zero-byte payload is how a sender opens a message, and it puts bytes in
          # `@raw` and none in `@buffer`. Testing the buffer first sent that frame nowhere —
          # every caller goes on to `reset_raw` — so a socket with a `part: ws` rule armed and
          # matching nothing silently dropped a frame the byte-exact pump forwards, which is
          # the one invariant this pump exists to keep.
          write_direct(interleaved_raw)
          @parked.clear
          @parked_bytes = 0
        elsif @buffer.size > 0
          flush_parked # re-framed: nowhere to put them but in front
          write_direct(WS.encode(@opcode, @buffer.to_slice, mask: @mask, fin: false))
        else
          # Nothing of this message's own is owed (passthrough, or past the raw cap with an
          # empty buffer), but a control frame parked between its fragments still is.
          flush_parked
        end
      end

      # Put a half-assembled message on the wire and into capture, then forget it. Only the
      # bytes this pump is WITHHOLDING: in passthrough they went out frame by frame already,
      # so there is nothing owed to the wire — but the buffer still has to be cleared, or its
      # bytes ride in front of the next message (see `start_message`).
      #
      # Emitted NON-final, so gori does not invent a FIN the sender never sent.
      private def flush_withheld : Nil
        # `@shape.frames` and not `@buffer.size` answers "is a fragment still owed?" — the
        # accumulator's own header says so, and this is the caller it was written for. A
        # LEADING FRAGMENT MAY BE EMPTY, so a message can be half-assembled with an empty
        # payload buffer; the buffer test called that "nothing here" and `reset_raw` then
        # dropped the frame. Only a control frame parked between fragments is owed when
        # nothing at all is being assembled — and even that cannot happen today, since
        # `park_control?` declines while `@raw` is empty.
        if @shape.frames == 0
          flush_parked
          return
        end
        flush_buffered unless @passthrough
        # A zero-byte message gets no row, matching `Relay.emit_pending` — the byte-exact
        # pump's equivalent — because the two pumps have to record identical facts about
        # identical bytes. The accumulator is still taken: left standing, this fragment's FIN
        # and RSV bits and its place in `frames` would be claimed by the NEXT message's row.
        if @buffer.size > 0
          @sink.on_ws_message(@flow_id, @direction, @opcode.to_i, @buffer.to_slice.dup, @shape.take)
        else
          @shape.take
        end
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
          # `bypass` yields UNDER the gate's mutex, so anything the block writes has to go
          # straight to the socket — `write_control` would re-take a lock this fiber already
          # holds, which Crystal's checked Mutex raises on rather than deadlocking.
          @in_bypass = true
          begin
            gate.bypass(reason, &block)
          ensure
            @in_bypass = false
          end
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
        reset_raw
      end

      private def reset_raw : Nil
        @raw = @raw.size > RESET_THRESHOLD ? IO::Memory.new : @raw.tap(&.clear)
        @raw_kept = true
        # Whoever ended the message has already disposed of these (written them through, or
        # handed them to the gate); the offsets they carry belong to a buffer that is gone.
        @parked.clear
        @parked_bytes = 0
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
                           flow_id : Int64, sink : FlowSink, message_opcode : UInt8,
                           shape : MessageShape) : IO::Memory
      return assembling unless frame.data?
      remaining = MAX_MESSAGE - assembling.size
      # Exactly the frame that crosses the cap, so one notice per message rather than one
      # per frame: after this, `remaining` is 0 for every later fragment.
      # Fires on the frame that first COSTS bytes. `> remaining` is the ordinary overrun;
      # `== remaining && !fin?` is the exact fill — nothing is lost in this frame, but the
      # buffer is now full and every later fragment (there is one, or FIN would be set) is
      # dropped whole with `remaining` already 0, which would leave the overrun unreported.
      crossed = remaining > 0 &&
                (frame.payload.size > remaining || (frame.payload.size == remaining && !frame.fin?))
      if remaining > 0 && !frame.payload.empty?
        take = {frame.payload.size, remaining}.min
        assembling.write(frame.payload[0, take])
      end
      if crossed
        # Say that the transcript is short. The oversized-FRAME path already writes a
        # `NOTICE_PREFIX` marker for its own case (see `stream_oversized_frame`), and a
        # message assembled past MAX_MESSAGE is the same loss reached by fragmentation —
        # but it used to be recorded with `fin: true` and a plausible payload, so a
        # truncated transcript was indistinguishable from a complete one. `ws_messages`
        # carries no truncation column (unlike `CapturedResponse#body_truncated`), so the
        # marker is a row of its own; `NOTICE_PREFIX` is what `Store::WsMessage#notice?`
        # reads to refuse replaying it as a seed. The payload row that follows keeps the
        # captured PREFIX, which is the evidence worth having.
        # NO `shape.take` here — `take` RESETS the accumulator, so consuming it for this
        # notice handed the real payload row that follows a fabricated shape (frames 1,
        # masked nil), losing the fragment count and the masking evidence the shape exists
        # to record. The default shape is also the honest one: this row is gori's own
        # sentence, not a frame the peer sent — the same choice every other NOTICE row makes.
        sink.on_ws_message(flow_id, direction, message_opcode.to_i,
          "#{NOTICE_PREFIX}WebSocket message truncated at #{MAX_MESSAGE} bytes for capture; " \
          "the forwarded message was longer".to_slice)
      end
      return assembling unless frame.fin?
      sink.on_ws_message(flow_id, direction, message_opcode.to_i, assembling.to_slice.dup, shape.take)
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
        # Stands in for a real frame at that frame's own position, so it keeps the message's
        # opcode and this direction — and is therefore a row a seed would replay. Built from
        # `NOTICE_PREFIX` so `Store::WsMessage#notice?` refuses it.
        marker = "#{NOTICE_PREFIX}#{h.len}-byte WebSocket frame forwarded; too large to capture".to_slice
        # The marker row still carries the frame's own header facts — its FIN, its RSV bits
        # and its mask key are exactly what an operator is asking about when a frame is this
        # size, and they are the part gori DID read.
        sink.on_ws_message(flow_id, direction, message_opcode.to_i, marker, h.shape)
      end
      true
    end
  end
end
