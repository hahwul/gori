require "./ws_engine"

module Gori
  module Repeater
    # A WebSocket the operator keeps OPEN (#1630): connect once, send messages one at a time,
    # and read what the server pushes in between. `WsEngine.send` (dial, scripted exchange,
    # hang up) stays as it is; the two share the dial and the 101 (`WsEngine.open_h1`).
    #
    # One owner for the upgraded socket: ONE reader fiber and a write `Mutex` that every
    # writer takes (operator sends, pongs, heartbeat auto-replies, the close). The lock is held
    # around write+flush only, never across a read — see the deadlock note above `@in_frame`
    # in `proxy/ws/relay.cr`.
    #
    # HTTP/1.1 only: `H2WsStream` is serial and single-fiber by design (`refusal`).
    #
    # The transcript is in memory, a ring capped like the scripted engine's capture
    # (MAX_RECV_MESSAGES rows, MAX_RECV_BYTES of payload). A long session drops its oldest
    # rows instead of stopping; `dropped` counts them. Like every Repeater WebSocket send, it
    # is not written to History.
    class WsSession
      MAX_ENTRIES = WsEngine::MAX_RECV_MESSAGES
      MAX_BYTES   = WsEngine::MAX_RECV_BYTES
      # How long `close` waits for the server's CLOSE before hanging up anyway (§7.1.1).
      CLOSE_GRACE = 2.seconds
      # Keepalive rows one session records: a server PING/PONG, a heartbeat an auto-reply
      # matched, and that reply. The scripted engine's MAX_CONTROL_MESSAGES, for its reason: an
      # origin pinging every few seconds would otherwise push every data row out of the ring.
      # Past it they are still answered, only counted (`keepalive_unrecorded`).
      # ponytail: a lifetime cap, not a window; a rolling one if a session must show late pings.
      MAX_KEEPALIVE_ROWS = WsEngine::MAX_CONTROL_MESSAGES

      # A heartbeat answered for the operator: an inbound TEXT message whose payload is
      # EXACTLY `match` gets a TEXT `reply`. Exact rather than a pattern, because it writes into
      # the session unasked. Off unless a surface passes one.
      record AutoReply, match : String, reply : String

      # Engine.IO: the server's `2` (ping) is answered with `3` (pong), the pair
      # `WsProto::SocketIo` decodes as a heartbeat.
      ENGINE_IO_HEARTBEAT = AutoReply.new("2", "3")

      # One transcript row. `seq` counts every row ever appended, so `transcript(after:)`
      # still finds what is new after the ring dropped old rows. `auto` marks a row the session
      # wrote itself (a heartbeat reply); `keepalive` a row under MAX_KEEPALIVE_ROWS.
      record Entry, seq : Int64, at : Time, message : WsEngine::Message, auto : Bool = false,
        keepalive : Bool = false do
        # A server message a surface waiting for an answer should wake on: not a keepalive.
        def reply? : Bool
          message.direction == "in" && !keepalive
        end
      end

      # What `open` produced: the session when the 101 came back, and always the handshake as
      # a `WsEngine::Result` (head, error, note, sent_head), so surfaces reuse their
      # handshake rendering.
      record Opened, session : WsSession?, result : WsEngine::Result do
        # No session, and `reason` as the handshake's error.
        def self.refused(reason : String) : Opened
          new(nil, WsEngine::Result.new(Bytes.new(0), [] of WsEngine::Message, 0_i64, reason))
        end
      end

      # The server's CLOSE status, once it sent one.
      getter close_code : Int32?
      # Why the session ended; nil while open.
      getter close_reason : String?
      # WHEN the session ended — the moment `end_with` first ran, not when a surface first
      # noticed (#1630). Set with `close_reason`, so a reader that sees `closed?` has it too.
      getter closed_at : Time?
      # Rows evicted from the ring to stay inside MAX_ENTRIES / MAX_BYTES.
      getter dropped = 0_i64
      # Payload bytes currently held in the ring — a surface stretches its render throttle by
      # this, so a big transcript re-renders less often (#1630).
      getter ring_bytes = 0_i64
      # Keepalive frames answered but not recorded, past MAX_KEEPALIVE_ROWS.
      getter keepalive_unrecorded = 0_i64

      @keepalive_rows = 0
      @ring = Deque(Entry).new
      @seq = 0_i64
      @write_lock = Mutex.new
      # Closed by the reader when it exits.
      @done = Channel(Nil).new
      # One slot, fed without blocking, so the reader never waits on an absent listener.
      @signal = Channel(Nil).new(1)
      @closing = false
      @sent_close = false
      # The inbound message being reassembled (§5.4).
      @assembling = IO::Memory.new
      @msg_opcode = Proxy::WS::OP_TEXT
      @shape = Proxy::WS::MessageShape.new

      # Why this upgrade cannot become a session, or nil. Read off the bytes, the way
      # `WsEngine.send` picks its transport.
      def self.refusal(upgrade_request : Bytes) : String?
        return nil unless Proxy::WS.extended_connect_request?(String.new(upgrade_request))
        "a persistent WebSocket session is HTTP/1.1 only for now: this handshake is an " \
        "RFC 8441 extended CONNECT (WebSocket over HTTP/2), which a follow-up adds; send it as a script instead"
      end

      # Dial, upgrade, start the reader. `expand` runs over each operator message before it is
      # framed (the send seam's binding pass, which `Sender#open_ws` supplies). `gate` is the
      # per-send Layer-2 re-check (#1630): the open is gated once, but a session lasts hours,
      # so every operator `send` asks it again. It is `Outbound#send_block`, a hand-authored
      # send's Layer 2: the Sandbox the operator may turn on mid-session (with the port-bearing
      # excludes it folds in), reached through its throttled scope reload. An exclude alone
      # does not stop it, as it does not stop any hand-authored send (DESIGN.md §3).
      # `outbound` charges each operator `send` to the project request budget (#1601), as
      # `ws_inject` charges each injected frame. Ungated by itself otherwise:
      # `Sender#open_ws` is the gated door for the handshake.
      def self.open(upgrade_request : Bytes, *, scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    overrides : Gori::HostOverrides? = nil, keep_key : Bool = false,
                    tls_preset : String? = nil, cancel : Proc(Bool)? = nil,
                    auto_replies : Array(AutoReply) = [] of AutoReply,
                    expand : Proc(WsEngine::OutMsg, WsEngine::OutMsg)? = nil,
                    gate : Proc(String?)? = nil, outbound : Gori::Outbound? = nil) : Opened
        if reason = refusal(upgrade_request)
          return Opened.refused(reason)
        end
        started = Time.instant
        opened = WsEngine.open_h1(upgrade_request, scheme: scheme, host: host, port: port,
          verify_upstream: verify_upstream, sni: sni, overrides: overrides, keep_key: keep_key,
          tls_preset: tls_preset, cancel: cancel, started: started)
        return Opened.new(nil, opened) if opened.is_a?(WsEngine::Result)
        # `cancel` bounds the connect only; after it, `close` ends the session.
        opened.watcher.try(&.stop)
        result = WsEngine::Result.new(opened.head, [] of WsEngine::Message, Engine.elapsed(started),
          note: opened.note, upgraded: true).with_sent_head(opened.sent_head)
        Opened.new(new(opened.io, auto_replies, expand, gate, outbound), result)
      end

      def initialize(@io : IO, @auto_replies : Array(AutoReply),
                     @expand : Proc(WsEngine::OutMsg, WsEngine::OutMsg)?,
                     @gate : Proc(String?)? = nil, @outbound : Gori::Outbound? = nil)
        # Silence is normal on an open session, so no read bound. Cleared before the reader
        # parks: a timeout armed after a fiber has parked does not fire.
        io = @io
        io.read_timeout = nil if io.responds_to?(:read_timeout=)
        spawn(name: "gori-ws-session") { read_loop }
      end

      def closed? : Bool
        !@close_reason.nil?
      end

      # Rows with `seq > after`, oldest first.
      def transcript(after : Int64 = 0_i64) : Array(Entry)
        @ring.select { |e| e.seq > after }
      end

      # The seq of the newest row ever appended (0 before the first). A surface polls this to
      # decide whether to re-render WITHOUT copying the ring (#1630). It counts evicted rows
      # too, so it only ever grows.
      def last_seq : Int64
        @seq
      end

      # `{sent, received}` counted over the live ring, in one pass — for a surface's `↑ ↓`
      # read-out, without the two extra ring copies `transcript.count` would take. An evicted
      # row is not counted; `dropped` says how many.
      def counts : {Int32, Int32}
        out = recv = 0
        @ring.each { |e| e.message.direction == "out" ? (out += 1) : (recv += 1) }
        {out, recv}
      end

      # Block until a row is appended or the session ends, at most `timeout`. True when woken.
      # One waiter per session: the signal has a single slot. An ended session answers at
      # once, through `@done`, rather than sleeping out the timeout.
      def wait(timeout : Time::Span) : Bool
        select
        when @signal.receive then true
        when @done.receive? then true
        when timeout(timeout) then false
        end
      end

      # Frame and write one operator message: masked, unless its shape asks for the unmasked
      # client frame (the same probe `WsEngine.exchange` allows). Nil when written, else why
      # not. A row means "gori wrote this", not "the peer got it".
      #
      # May wait for the project request budget's rate (`outbound`), on the caller's fiber:
      # `cancel`, a close, or the Outbound's own halt ends that wait.
      def send(message : WsEngine::OutMsg, cancel : Proc(Bool)? = nil) : String?
        if reason = @close_reason
          return "the session is closed: #{reason}"
        end
        # Layer 2, re-checked per send (#1630). A refusal ends the session: a Sandbox change
        # that now blocks this host is not a "skip one frame" — the operator has
        # decided the target is off-limits, so the socket must not stay open for the next send.
        # Torn down WITHOUT the CLOSE grace (unlike `close`), since this runs on the caller's
        # fiber (the MCP worker) and must not block; the reader exits when `@io` closes.
        if gate = @gate
          if reason = gate.call
            end_with("a scope or Sandbox change refused a mid-session send (#{reason}); the session was closed")
            @io.close rescue nil
            notify
            return "the send was refused: #{reason}; the session was closed"
          end
        end
        if reason = admit(cancel)
          return reason
        end
        message = @expand.try(&.call(message)) || message
        op = (message.opcode & 0x0f).to_u8
        bytes = Proxy::WS.encode(op, message.payload, message.shape, mask: true)
        # Before the write, so a server CLOSE the reader handles meanwhile is not answered twice.
        @sent_close = true if op == Proxy::WS::OP_CLOSE
        if reason = write(bytes, admitted: true)
          return reason
        end
        append(WsEngine::Message.new("out", op.to_i, message.payload, message.shape))
        nil
      end

      # Send CLOSE, give the server CLOSE_GRACE to answer with its own, then hang up and wait
      # for the reader to exit. Idempotent, and a no-op beyond the hang-up once the server
      # has already ended the session.
      #
      # BLOCKS: CLOSE_GRACE at least, and up to the dial's write timeout more when another
      # write holds the lock or the peer has stopped reading. Never call it on a UI loop; a
      # surface spawns it.
      def close(code : Int32 = 1000, reason : String = "") : Nil
        return if @closing
        @closing = true
        was_open = !closed?
        end_with("closed by the operator (#{code})")
        if was_open && !@sent_close
          payload = IO::Memory.new
          payload.write_bytes(code.to_u16!, IO::ByteFormat::BigEndian)
          payload << reason
          # Set BEFORE the write: it can yield (the lock, a slow peer), and a server CLOSE the
          # reader takes meanwhile must not get a second CLOSE of its own (§5.5.1).
          @sent_close = true
          if write(Proxy::WS.encode(Proxy::WS::OP_CLOSE, payload.to_slice, mask: true)).nil?
            append(WsEngine::Message.new("out", Proxy::WS::OP_CLOSE.to_i, payload.to_slice))
            select
            when @done.receive?
            when timeout(CLOSE_GRACE)
            end
          end
        end
        @io.close rescue nil
        @done.receive?
      end

      # One slot of the project request budget for an operator `send` (#1601), or the refusal.
      # Only the operator's frames: a pong, an auto-reply or the close is the session's own.
      # A close that landed during the wait hands the slot back.
      private def admit(cancel : Proc(Bool)?) : String?
        ob = @outbound || return
        halt = ob.halt
        if reason = ob.admit(halt: -> { closed? || !!cancel.try(&.call) || !!halt.try(&.call) })
          return reason
        end
        return unless reason = @close_reason
        ob.refund(1)
        "the session is closed: #{reason}"
      end

      # Every writer goes through here: the lock covers write+flush and nothing else.
      #
      # A failed write ENDS the session. It may have stopped part-way through a frame (a write
      # timeout against a peer that stopped reading), and the next frame's bytes would then
      # land inside that frame's declared payload. Closing `@io` also ends the reader.
      #
      # An `admitted` operator send that finds the session already ended writes nothing, so
      # it hands its budget slot back, as `admit` does for a close during the wait.
      private def write(bytes : Bytes, admitted : Bool = false) : String?
        @write_lock.synchronize do
          if admitted && (reason = @close_reason)
            @outbound.try(&.refund(1))
            return "the session is closed: #{reason}"
          end
          @io.write(bytes)
          @io.flush
        end
        nil
      rescue ex : IO::Error | OpenSSL::Error
        reason = "the write failed (#{ex.message.presence || ex.class.name})"
        end_with("#{reason}; the session was closed")
        @io.close rescue nil
        reason
      end

      # Append a row, evicting the oldest past MAX_ENTRIES / MAX_BYTES (the newest row is
      # always kept), and wake a waiter. A `keepalive` row past MAX_KEEPALIVE_ROWS is only
      # counted.
      private def append(m : WsEngine::Message, auto : Bool = false, keepalive : Bool = false) : Nil
        if keepalive
          if @keepalive_rows >= MAX_KEEPALIVE_ROWS
            @keepalive_unrecorded += 1
            return
          end
          @keepalive_rows += 1
        end
        @seq += 1
        @ring << Entry.new(@seq, Time.utc, m, auto, keepalive)
        @ring_bytes += m.payload.size
        while @ring.size > MAX_ENTRIES || (@ring_bytes > MAX_BYTES && @ring.size > 1)
          @ring_bytes -= @ring.shift.message.payload.size
          @dropped += 1
        end
        notify
      end

      private def notify : Nil
        select
        when @signal.send(nil)
        else
        end
      end

      # The ONE reader. Nothing raises out of it: each way it ends becomes `close_reason`,
      # and the `ensure` hangs up and releases `close`.
      private def read_loop : Nil
        loop do
          header = Proxy::WS.read_header(@io)
          break end_with("the connection ended") unless header
          if header.len > Proxy::WS::MAX_FRAME
            # Its payload stays unread, so the stream is out of step: the session ends.
            break end_with("a server frame declared #{header.len} bytes, over the " \
                           "#{Proxy::WS::MAX_FRAME // (1024 * 1024)} MiB per-frame cap")
          end
          frame = Proxy::WS.read_body(@io, header)
          break end_with("the connection ended mid-frame") unless frame
          break unless on_frame(frame)
        end
      rescue ex : IO::Error | OpenSSL::Error
        end_with("the connection failed (#{ex.message.presence || ex.class.name})")
      rescue ex
        end_with("the session reader failed (#{ex.message.presence || ex.class.name})")
      ensure
        flush_pending
        end_with("the connection ended")
        @io.close rescue nil
        @done.close
        notify
      end

      # The first reason wins: an operator's close or a server CLOSE is not overwritten by the
      # EOF that follows it.
      private def end_with(reason : String) : Nil
        return if @close_reason
        @close_reason = reason
        @closed_at = Time.utc
      end

      # One inbound frame; false ends the session.
      private def on_frame(frame : Proxy::WS::Frame) : Bool
        return on_data(frame) if frame.data?
        if frame.close?
          flush_pending # arrival order: the fragment before the CLOSE row
          @close_code = WsEngine.close_status(frame.payload)
          append(WsEngine::Message.new("in", frame.opcode.to_i, frame.payload, frame.shape))
          end_with("the server sent CLOSE#{@close_code.try { |c| " #{c}" }}")
          # §5.5.1: answer with a CLOSE (echoing the status) unless gori already sent one.
          unless @sent_close
            @sent_close = true
            write(Proxy::WS.encode(Proxy::WS::OP_CLOSE, frame.payload[0, Math.min(2, frame.payload.size)], mask: true))
          end
          return false
        end
        append(WsEngine::Message.new("in", frame.opcode.to_i, frame.payload, frame.shape), keepalive: true)
        if frame.opcode == Proxy::WS::OP_PING
          # Never amplify: a control payload is at most 125 bytes (§5.5).
          pong = frame.payload[0, Math.min(WsEngine::MAX_CONTROL_BYTES, frame.payload.size)]
          write(Proxy::WS.encode(Proxy::WS::OP_PONG, pong, mask: true))
        end
        true
      end

      # A data frame, reassembled across fragments (§5.4) by the accumulator the capture relay
      # and `WsEngine.drain` share.
      private def on_data(frame : Proxy::WS::Frame) : Bool
        if frame.opcode != Proxy::WS::OP_CONT
          # A new message while the previous never sent FIN: that one gets its own
          # `fin: false` row rather than being merged into this one.
          flush_pending
          @msg_opcode = frame.opcode
        elsif @shape.frames == 0
          # A CONT with no message to continue (§5.4 violation): recorded as opcode 0, never
          # as the previous message's opcode, so the row shows what the server sent.
          @msg_opcode = Proxy::WS::OP_CONT
        end
        @shape.note(frame)
        @assembling.write(frame.payload)
        if @assembling.bytesize > MAX_BYTES
          end_with("a server message passed the #{MAX_BYTES // (1024 * 1024)} MiB cap; the session was closed")
          return false
        end
        return true unless frame.fin?
        payload = @assembling.to_slice.dup
        @assembling = IO::Memory.new
        rule = @msg_opcode == Proxy::WS::OP_TEXT ? @auto_replies.find { |r| r.match.to_slice == payload } : nil
        append(WsEngine::Message.new("in", @msg_opcode.to_i, payload, @shape.take), keepalive: !rule.nil?)
        auto_reply(rule) if rule
        true
      end

      # A buffered fragment that never got its FIN, as one `fin: false` row. A no-op when
      # nothing is being reassembled.
      private def flush_pending : Nil
        return if @shape.frames == 0
        payload = @assembling.to_slice.dup
        @assembling = IO::Memory.new
        append(WsEngine::Message.new("in", @msg_opcode.to_i, payload, @shape.take))
      end

      private def auto_reply(rule : AutoReply) : Nil
        reply = rule.reply.to_slice
        if write(Proxy::WS.encode(Proxy::WS::OP_TEXT, reply, mask: true)).nil?
          append(WsEngine::Message.new("out", Proxy::WS::OP_TEXT.to_i, reply), auto: true, keepalive: true)
        end
      end
    end
  end
end
