require "../proxy/h2/frame"
require "../proxy/h2/hpack"
require "../proxy/h2/head_codec"
require "../proxy/ws/frame"
require "./h2_engine"

module Gori
  module Repeater
    # An RFC 8441 extended CONNECT stream, presented as a byte stream (#733).
    #
    # ## Why an IO and not a second engine
    #
    # RFC 8441 §5.1 replaces the WebSocket HANDSHAKE and nothing else: once the origin answers
    # 2xx, the stream carries the very same RFC 6455 frames the HTTP/1.1 Upgrade path carries,
    # as the payloads of that stream's DATA frames. A DATA boundary has nothing to do with a
    # WebSocket frame boundary — a frame straddles two DATA frames as readily as ten frames
    # share one — which is exactly the relationship a byte stream already describes.
    #
    # So this is an `IO`, and `WsEngine`'s scripted exchange (`exchange` → `drain` → `finish`,
    # the caps, the reassembly, the masking, the shapes, the Pong echo, the CLOSE) runs over it
    # UNCHANGED. That is the whole design: there is one WebSocket replay engine, one set of
    # caps and one transcript shape, and the transport is a parameter. A second engine would
    # have meant a second `DrainState`, a second set of §5.4 reassembly moments and a second
    # answer to "did the peer close" — the divergence `WsCapture`'s own header records for the
    # CAPTURE side, where the h1 and h2 reassemblers are deliberately one codec for the same
    # reason.
    #
    # The capture side is the mirror image and stays what it was: `H2::WsCapture` reassembles
    # DATA payloads it never writes; this one writes them and reads them back.
    #
    # ## What it owns, and what it borrows
    #
    # Borrowed from `H2Engine`, never re-derived: `SendFlow` (the send-side connection/stream
    # windows and the peer's SETTINGS_INITIAL_WINDOW_SIZE), `apply_settings`, `credit`,
    # `write_header_block`, `window_update`, `ack`, and the two "what did the peer say" sentence
    # builders `goaway_reason` / `rst_reason`. Those are the pieces with real accounting in
    # them, and a copy of a flow-control window is how the two halves of one connection start
    # disagreeing.
    #
    # Owned here: the extended CONNECT handshake, and the read/write dispatch that turns DATA
    # frames into bytes and back.
    #
    # ## Serial, single-fiber, no background pump
    #
    # Every frame is read by whichever call needs one — `read` when the drain wants bytes,
    # `flush` when the write side is waiting for window. Nothing is spawned, so there is no
    # fiber to leak on a timeout, a stop or a peer close (P6): `close` tears down the one
    # connection this stream owns and that is the whole teardown. One stream per connection,
    # dialled per replay: this is not a multiplexer, exactly as `H2Engine::Conn` is not.
    #
    # ## How a failure reaches the operator
    #
    # A peer that RST_STREAMs, GOAWAYs or refuses window does not produce a quiet EOF here. It
    # raises `IO::Error` carrying the peer's own stated reason, which `WsEngine`'s drain and
    # send loop already turn into `DrainState#gone_reason` and from there into the transcript's
    # note — the same sentence shape a torn `wss://` socket produces on the h1 path. A clean
    # END_STREAM (or a socket EOF at a frame boundary) is the one thing that reads back as EOF,
    # because that is the one thing that means "the peer is done".
    class H2WsStream < IO
      private alias Frame = Proxy::H2::Frame
      private alias HPACK = Proxy::H2::HPACK
      private alias HeadCodec = Proxy::H2::HeadCodec

      # RFC 8441 §3. A server advertises this to say extended CONNECT may be used; a client
      # that has not seen it MUST NOT send one, which is why the absence is a refusal here and
      # not something to try anyway and see.
      SETTINGS_ENABLE_CONNECT_PROTOCOL = 0x8_u16

      # Frames read while waiting for the response to the extended CONNECT. The same ceiling
      # `H2Engine::MAX_FRAMES` is for a response read: PING/SETTINGS/WINDOW_UPDATE are not
      # byte-capped and the per-read timeout only fires on IDLE, so a peer that chatters
      # forever without answering needs a COUNT to terminate on.
      MAX_HANDSHAKE_FRAMES = 1_000

      # Ceiling on the header block of the CONNECT's answer. HEADERS/CONTINUATION are not
      # flow-controlled, so a CONTINUATION flood is unbounded without one — the same 1 MiB
      # `H2Engine::MAX_HEADER_BLOCK` bounds a response head with.
      MAX_HEADER_BLOCK = H2Engine::MAX_HEADER_BLOCK

      # Ceiling on inbound bytes queued but not yet handed to a reader.
      #
      # `read` returns the moment one DATA frame lands, so on that path the queue holds one
      # frame. `await_window` is the path that accumulates: it must keep reading to observe the
      # WINDOW_UPDATE it is blocked on, and an origin that answers with a DATA flood while
      # withholding send window would otherwise grow this queue to `H2Engine::MAX_FRAMES` ×
      # `MAX_FRAME` — over a gigabyte on a workbench, for a peer gori is deliberately provoking.
      # Sized at `WsEngine::MAX_RECV_BYTES`, the transcript's own cap: nothing a legitimate
      # exchange queues comes near it, and past it the exchange is over either way.
      MAX_QUEUED = 8_i64 * 1024 * 1024

      # What `open` produced. A record rather than a tuple because four of the five outcomes
      # are distinct sentences and every surface has to be able to tell them apart: a dial that
      # failed, a peer that will not do extended CONNECT, a peer that answered a non-2xx, and a
      # socket that opened.
      #
      # `head` is the origin's answer projected as an h1 response head — the same
      # `HeadCodec.synth_response` projection a captured h2 response is stored as, so
      # `WsEngine::Result#handshake_head` renders identically for both transports and
      # `answered?` means what it means on h1.
      record Opened,
        stream : H2WsStream?,
        head : Bytes,
        status : Int32,
        error : String?,
        note : String? = nil

      getter flow : H2Engine::SendFlow
      getter status : Int32
      getter? closed = false

      # The idle bound the drain last asked for, and this stream's own budget for producing
      # one byte. `WsEngine` sets it through `read_timeout=` before every phase (see
      # `set_read_timeout`), and `Proxy::WS.read_body` narrows it further per read.
      getter read_timeout : Time::Span? = nil

      def initialize(@conn : H2Engine::Conn, @flow : H2Engine::SendFlow, @status : Int32,
                     @host : String, @port : Int32)
        @io = @conn.io.as(IO)
        # Inbound DATA payloads not yet handed to a reader, in arrival order. A Deque and not
        # one buffer because `flush` pumps frames too (waiting for window), so DATA can arrive
        # while the read side is not asking — replacing a single buffer would drop it.
        @inbox = Deque(Bytes).new
        @at = 0         # read cursor into `@inbox.first`
        @queued = 0_i64 # bytes in `@inbox` still to be read (see MAX_QUEUED)
        @outbuf = IO::Memory.new
        @eof = false
        @frames = 0
      end

      # ------------------------------------------------------------------ handshake

      # Dial nothing: open the WebSocket on a connection the CALLER owns, from the captured
      # request head. Splitting the dial out is what lets `WsEngine` report a dead origin in
      # `Engine.connect_error`'s words — the same sentences every other send path uses.
      #
      # `request_head` is the operator's bytes and is parsed by `H2Engine.parse_request`, the
      # ONE h1-text→h2-fields encoder every scripted surface uses. Nothing is added to it and
      # nothing is removed: the `:protocol` pseudo-header comes from the head's own
      # `X-Gori-Protocol` marker (P7 — gori does not invent the field that makes this a
      # WebSocket), `:method`/`:path` are the request line's, and a header the operator kept is
      # a header the origin sees.
      def self.open(conn : H2Engine::Conn, request_head : Bytes, *,
                    scheme : String, host : String, port : Int32,
                    preserve_field_case : Bool = false,
                    stall : Time::Span) : Opened
        io = conn.io
        flow = H2Engine::SendFlow.new
        flow.id = conn.take_stream
        flow.conn = conn.send_window
        flow.stream = conn.initial_window
        flow.initial = conn.initial_window
        flow.settings_seen = conn.settings_seen?
        # The write-side stall bound: how long a WebSocket frame may wait for flow-control
        # window before gori says the origin is not granting it. `WsEngine` passes its `idle` —
        # the drain's gap of server silence — rather than a constant of its own, for the reason
        # `H2Engine::SendFlow#patience` reuses the io_timeout: "the origin said nothing" and
        # "the origin said everything except window" should bound alike, on the one number the
        # operator already sets. It bounds ONE contiguous wait and restarts per DATA frame
        # written, so an origin dripping window in small increments is never cut short.
        flow.patience = stall

        # FLUSH the preface and gori's SETTINGS before reading a byte. `Conn#initialize`
        # deliberately leaves them unflushed so a one-shot h2 send puts preface + SETTINGS +
        # HEADERS in one TLS record — a shape a `tls_preset` run cares about. That trade is not
        # available here at all: §3 makes the peer's SETTINGS a PRECONDITION of the extended
        # CONNECT, so the HEADERS cannot share a record with the preface whatever gori does. And
        # an origin that waits for the client preface before answering (several stacks do) would
        # otherwise deadlock against a `sync = false` TLS socket, both sides waiting to read.
        io.flush

        enabled, err = await_connect_protocol(io, flow, host, port)
        return refused(err) if err
        unless enabled
          return refused(
            "the origin at #{host}:#{port} did not advertise SETTINGS_ENABLE_CONNECT_PROTOCOL " \
            "(RFC 8441 §3), so it will not accept the extended CONNECT a WebSocket over HTTP/2 " \
            "is opened with. gori did not send one: §3 forbids it, and a server that has not " \
            "advertised the setting answers a stream it never agreed to. Replay this socket " \
            "against an origin that does, or capture it over an HTTP/1.1 upgrade")
        end

        fields, body = H2Engine.parse_request(request_head, scheme, host, port, preserve_field_case)
        unless HeadCodec.pseudo(fields, ":protocol")
          return refused(
            "this request head carries no #{HeadCodec::PROTOCOL_MARKER} line, so there is no " \
            "RFC 8441 :protocol pseudo-header to open a WebSocket with")
        end
        H2Engine.write_header_block(io, HPACK::Encoder.new.encode(fields), false, flow.id)
        io.flush

        # A body under the handshake head is NAMED rather than sent or dropped in silence. The
        # stream's DATA frames are the WebSocket's own frames from the 2xx onward, so writing
        # these bytes would put them where the peer reads a frame header — desyncing the socket
        # for the whole session — and dropping them quietly would report a clean run of a
        # request the operator wrote more of. A capture never produces one (an extended CONNECT
        # head has no entity); a hand-edited pane can.
        note = body && !body.empty? ? "#{body.size} byte#{body.size == 1 ? "" : "s"} below the " \
                                      "handshake's blank line were NOT sent: an RFC 8441 extended CONNECT carries no " \
                                      "request body, and this stream's DATA frames are the WebSocket's own frames" : nil
        read_answer(conn, flow, host, port, note)
      end

      # Read the peer's SETTINGS and answer the one question RFC 8441 §3 makes a precondition.
      #
      # Bounded exactly as `H2Engine.await_settings` is, and for the reason its own comment
      # gives: §3.4 makes SETTINGS the server's first frame, but a peer that opens with a PING
      # or a connection WINDOW_UPDATE still sends it a moment later, and reading one frame
      # would judge such an origin as refusing a feature it does in fact offer.
      #
      # A SETTINGS with no 0x8 entry is a definite NO (the default is 0 — §3), so the answer is
      # taken from the FIRST non-ACK SETTINGS and not waited on further.
      private def self.await_connect_protocol(io : IO, flow : H2Engine::SendFlow,
                                              host : String, port : Int32) : {Bool, String?}
        budget = H2Engine::AWAIT_SETTINGS_FRAMES
        while budget > 0
          budget -= 1
          frame = begin
            Frame.read(io)
          rescue IO::TimeoutError
            return {false, "the origin at #{host}:#{port} sent no HTTP/2 SETTINGS frame before " \
                           "the read timed out, so gori could not learn whether it accepts an " \
                           "RFC 8441 extended CONNECT"}
          rescue ex : IO::Error | Gori::Error | OpenSSL::Error
            return {false, "the HTTP/2 connection to #{host}:#{port} ended before the origin's " \
                           "SETTINGS arrived (#{ex.message || ex.class.name})"}
          end
          return {false, "the origin at #{host}:#{port} closed the HTTP/2 connection before " \
                         "sending SETTINGS"} if frame.nil?
          case frame.frame_type
          when Frame::Type::Settings
            next if frame.ack?
            H2Engine.apply_settings(frame, flow)
            flow.settings_seen = true
            H2Engine.ack(io, Frame::Type::Settings, Bytes.empty)
            io.flush
            return {connect_protocol?(frame), nil}
          when Frame::Type::Ping
            unless frame.ack?
              H2Engine.ack(io, Frame::Type::Ping, frame.payload)
              io.flush
            end
          when Frame::Type::WindowUpdate
            H2Engine.credit(frame, flow)
          when Frame::Type::Goaway
            return {false, "#{H2Engine.goaway_reason(frame)} from #{host}:#{port}, before the " \
                           "WebSocket could be opened"}
          else
            # Anything else this early is not the answer; keep reading within the budget.
          end
        end
        {false, "the origin at #{host}:#{port} sent #{H2Engine::AWAIT_SETTINGS_FRAMES} HTTP/2 " \
                "frames without a SETTINGS frame among them, so gori could not learn whether it " \
                "accepts an RFC 8441 extended CONNECT"}
      end

      # SETTINGS_ENABLE_CONNECT_PROTOCOL (id 0x8) with value 1 — RFC 8441 §3. A value other
      # than 0 or 1 is a PROTOCOL_ERROR the peer committed; treated as "not enabled", which is
      # the answer that keeps gori from sending a stream nobody agreed to.
      private def self.connect_protocol?(frame : Frame::Header) : Bool
        payload = frame.payload
        enabled = false
        i = 0
        while i + 6 <= payload.size
          id = IO::ByteFormat::BigEndian.decode(UInt16, payload[i, 2])
          value = IO::ByteFormat::BigEndian.decode(UInt32, payload[i + 2, 4])
          # LAST occurrence wins: RFC 9113 §6.5 says a SETTINGS frame's parameters are applied
          # in order, so a frame carrying the id twice ends on the second value.
          enabled = value == 1_u32 if id == SETTINGS_ENABLE_CONNECT_PROTOCOL
          i += 6
        end
        enabled
      end

      # Read frames until the extended CONNECT is answered. RFC 8441 §5.1: a 2xx opens the
      # socket — NOT a 101, which has no meaning on h2 (RFC 9113 §8.1 forbids the h1 upgrade
      # mechanism outright). Anything else is a refusal with a head the operator can read.
      private def self.read_answer(conn : H2Engine::Conn, flow : H2Engine::SendFlow,
                                   host : String, port : Int32, note : String?) : Opened
        io = conn.io
        block = IO::Memory.new
        seen = 0
        loop do
          seen += 1
          if seen > MAX_HANDSHAKE_FRAMES
            return refused("the origin at #{host}:#{port} sent #{MAX_HANDSHAKE_FRAMES} HTTP/2 " \
                           "frames without answering the extended CONNECT")
          end
          frame = begin
            Frame.read(io)
          rescue IO::TimeoutError
            return refused("the origin at #{host}:#{port} did not answer the RFC 8441 extended " \
                           "CONNECT before the read timed out")
          rescue ex : IO::Error | Gori::Error | OpenSSL::Error
            return refused("the HTTP/2 connection to #{host}:#{port} ended before the extended " \
                           "CONNECT was answered (#{ex.message || ex.class.name})")
          end
          return refused("the origin at #{host}:#{port} closed the HTTP/2 connection before " \
                         "answering the extended CONNECT") if frame.nil?
          case frame.frame_type
          when Frame::Type::Settings
            unless frame.ack?
              H2Engine.apply_settings(frame, flow)
              flow.settings_seen = true
              H2Engine.ack(io, Frame::Type::Settings, Bytes.empty)
              io.flush
            end
          when Frame::Type::Ping
            unless frame.ack?
              H2Engine.ack(io, Frame::Type::Ping, frame.payload)
              io.flush
            end
          when Frame::Type::WindowUpdate
            H2Engine.credit(frame, flow)
          when Frame::Type::Goaway
            return refused("#{H2Engine.goaway_reason(frame)} from #{host}:#{port}, before the " \
                           "extended CONNECT was answered")
          when Frame::Type::RstStream
            next unless frame.stream_id == flow.id
            return refused("#{H2Engine.rst_reason(frame)} from #{host}:#{port} — the origin " \
                           "refused the RFC 8441 extended CONNECT")
          when Frame::Type::Headers, Frame::Type::Continuation
            next unless frame.stream_id == flow.id
            chunk = frame.frame_type == Frame::Type::Headers ? H2Engine.header_block(frame) : frame.payload
            if block.bytesize + chunk.size > MAX_HEADER_BLOCK
              return refused("the origin at #{host}:#{port} sent a header block over " \
                             "#{MAX_HEADER_BLOCK} bytes answering the extended CONNECT")
            end
            block.write(chunk)
            next unless frame.end_headers?
            fields = begin
              conn.decoder.decode(block.to_slice)
            rescue ex
              return refused("the origin at #{host}:#{port} answered the extended CONNECT with " \
                             "a header block gori could not decode (#{ex.message || ex.class.name})")
            end
            status = (HeadCodec.pseudo(fields, ":status") || "0").to_i? || 0
            # An interim 1xx precedes the final answer (RFC 9110 §15.2) and is not one — keep
            # reading, exactly as `H2Engine.read_response` does.
            if status >= 100 && status < 200
              block = IO::Memory.new
              next
            end
            head = HeadCodec.synth_response(fields)
            if status < 200 || status >= 300
              return Opened.new(nil, head, status, nil, note)
            end
            # END_STREAM on the 2xx means the origin opened and immediately closed the socket:
            # there is no stream left to write frames onto, and saying so beats writing into it.
            if frame.end_stream?
              return Opened.new(nil, head, status,
                "the origin at #{host}:#{port} answered #{status} and ended the stream in the " \
                "same HEADERS frame, so the WebSocket was closed before a frame could be sent",
                note)
            end
            return Opened.new(new(conn, flow, status, host, port), head, status, nil, note)
          else
            # PRIORITY / PUSH_PROMISE / DATA before the answer — nothing the handshake needs.
          end
        end
      end

      private def self.refused(reason : String?) : Opened
        Opened.new(nil, Bytes.new(0), 0, reason)
      end

      # ------------------------------------------------------------------ IO

      # The drain's idle bound, forwarded to the socket AND kept: `read` below may have to walk
      # several h2 frames (a SETTINGS, a keepalive PING, a WINDOW_UPDATE) before one DATA frame
      # yields a byte, and the socket's per-read timeout bounds each of those reads rather than
      # the walk. Without a budget of its own, an origin chattering under the idle gap would
      # hold a `read` open indefinitely and `WsEngine`'s turn-taking — which is BUILT on
      # `IO::TimeoutError` meaning "your turn" — would never come round.
      def read_timeout=(span : Time::Span?)
        @read_timeout = span
        # Through a local: `responds_to?` narrows a local variable's type and not an instance
        # variable's, and the socket under an h2 connection is one of two concrete types.
        io = @io
        io.read_timeout = span if io.responds_to?(:read_timeout=)
        span
      end

      def read(slice : Bytes) : Int32
        return 0 if slice.empty?
        loop do
          if front = @inbox.first?
            n = Math.min(slice.size, front.size - @at)
            front[@at, n].copy_to(slice[0, n])
            @at += n
            @queued -= n
            if @at >= front.size
              @inbox.shift
              @at = 0
            end
            return n
          end
          return 0 if @eof
          pump_until_bytes
        end
      end

      # Buffered, then framed by `flush`. `WsEngine` writes one complete WebSocket frame and
      # flushes it, so buffering here is what keeps one WS frame in one DATA frame wherever the
      # send window allows it — the shape a peer's own parser is likeliest to be exercised by,
      # and the one the capture side records.
      def write(slice : Bytes) : Nil
        @outbuf.write(slice)
      end

      # The buffer is SWAPPED, not cleared: `to_slice` is a view into `@outbuf`'s own storage,
      # so handing that view to `write_data` while the same buffer stays live means a later
      # `write` could overwrite bytes still on their way out.
      def flush : Nil
        if @outbuf.bytesize > 0
          data = @outbuf.to_slice
          @outbuf = IO::Memory.new
          write_data(data)
        end
        @io.flush
      end

      # END_STREAM, then the connection. RFC 9113 §8.1: an empty DATA frame with END_STREAM is
      # how a client half-closes a stream it has finished with, which is the h2 form of the FIN
      # the h1 path's socket close sends after the WebSocket CLOSE frame.
      #
      # Best-effort by design: `WsEngine`'s `ensure` calls this after every exit, including the
      # ones where the peer is already gone, and a teardown that raised there would replace a
      # completed transcript with an exception.
      def close : Nil
        return if @closed
        @closed = true
        begin
          @io.write(Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, @flow.id,
            Bytes.empty).to_bytes)
          @io.flush
        rescue
          # peer already gone — the connection close below is the whole teardown that is left
        end
        @conn.close
      end

      # ------------------------------------------------------------------ internals

      # The request body as DATA frames on this stream, never exceeding the peer's send window
      # (RFC 9113 §6.9.1). Where `H2Engine.write_data` RECORDS a stall (it has a Result to hang
      # the sentence on and a response still to read), this RAISES: the caller is
      # `WsEngine#exchange`, whose rescue turns an `IO::Error` into `DrainState#gone_reason` and
      # from there into the transcript's note — so the failure lands in the operator's report
      # by the same route a torn socket does, and the frames already exchanged are kept.
      #
      # Never sets END_STREAM: the stream stays open for the rest of the session. `close` is
      # what half-closes it.
      private def write_data(body : Bytes) : Nil
        offset = 0
        while offset < body.size
          await_window if @flow.available <= 0
          n = Math.min(Math.min(H2Engine::MAX_FRAME.to_i64, (body.size - offset).to_i64),
            @flow.available).to_i
          @io.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, @flow.id,
            body[offset, n]).to_bytes)
          @flow.conn -= n
          @flow.stream -= n
          offset += n
        end
      end

      # Block until the peer grants flow-control window, bounded by `SendFlow#patience` in wall
      # clock. Frames read while waiting are dispatched normally — a WINDOW_UPDATE is the point,
      # and DATA that arrives meanwhile joins `@inbox` rather than being dropped, which is why
      # the inbox is a queue.
      private def await_window : Nil
        deadline = Time.instant + @flow.patience
        granted_before = @flow.granted
        while @flow.available <= 0
          # The peer cannot grant window for frames still sitting in our buffer.
          @io.flush
          if Time.instant >= deadline
            raise IO::Error.new(stalled_sentence(granted_before))
          end
          if @queued > MAX_QUEUED
            raise IO::Error.new(
              "the origin queued over #{MAX_QUEUED // (1024 * 1024)} MiB of inbound WebSocket " \
              "bytes while withholding the flow-control window this frame needs (RFC 9113 §6.9); " \
              "the WebSocket frame was NOT fully written")
          end
          begin
            pump_once
          rescue IO::TimeoutError
            # A quiet gap while the peer owes us window is NOT the drain's "your turn" signal —
            # there is no turn to take until the frame is written. Keep waiting up to
            # `patience`, then say what actually happened. Letting the timeout out of here
            # reported "the connection failed" for an origin that was merely slow to grant.
          end
          raise IO::Error.new(stalled_sentence(granted_before)) if @eof
        end
      end

      private def stalled_sentence(granted_before : Int64) : String
        base = "h2 flow control: the origin's send window did not reopen within " \
               "#{@flow.patience.total_seconds.round(1)}s"
        detail = if @eof
                   "the connection ended before window for the rest was granted (RFC 9113 §6.9)"
                 elsif @flow.granted == granted_before
                   "it granted none at all (RFC 9113 §6.9)"
                 else
                   "it granted window in increments too small to carry the frame (RFC 9113 §6.9)"
                 end
        "#{base} — #{detail}: its connection window is #{@flow.conn} and its stream window " \
        "#{@flow.stream}. The WebSocket frame was NOT fully written."
      end

      # Read and dispatch h2 frames until one yields bytes for `@inbox` or the stream ends.
      #
      # `IO::TimeoutError` is raised, not swallowed: `WsEngine`'s drain reads it as "the origin
      # went idle, take the next turn", and the deadline accounting credits the gap back
      # (`DrainState#credit_idle`). Turning it into an EOF here would end the exchange after the
      # first quiet moment.
      #
      # The budget bounds the WALK and not one read. The socket's per-read timeout only fires on
      # IDLE, so a peer trickling PING / SETTINGS / WINDOW_UPDATE under the idle gap without
      # ever sending a DATA byte would hold this open forever and `WsEngine`'s turn-taking —
      # which is BUILT on the timeout arriving — would never come round.
      private def pump_until_bytes : Nil
        started = Time.instant
        budget = @read_timeout || Settings.io_timeout
        until @eof || !@inbox.empty?
          pump_once
          break if @eof || !@inbox.empty?
          if Time.instant - started >= budget
            raise IO::TimeoutError.new("the origin sent no WebSocket bytes within #{budget}")
          end
        end
      end

      # Read and dispatch EXACTLY one frame.
      #
      # One frame, and not "until something useful arrives", because the two waiters want
      # different things from it: `pump_until_bytes` wants DATA and `await_window` wants a
      # WINDOW_UPDATE. A pump that returned only on DATA left the write side unable to observe
      # the credit it was blocked on at all — it read every WINDOW_UPDATE the origin sent,
      # applied it, and kept reading until the budget expired, so a message larger than the
      # peer's initial window never went out against an origin that was granting window
      # perfectly well.
      private def pump_once : Nil
        frame = begin
          Frame.read(@io)
        rescue Gori::Error
          # `read_exact`'s "unexpected EOF mid-frame" — a FIN that landed inside a frame rather
          # than on its boundary. That is end-of-data, and `WsEngine` reads an EOF as the peer
          # going away, which is what happened. Raising instead would escape the drain's
          # `IO::Error | OpenSSL::Error` rescue and destroy a transcript that is already
          # complete.
          @eof = true
          return
        end
        if frame.nil?
          @eof = true
          return
        end
        @frames += 1
        if @frames > H2Engine::MAX_FRAMES
          @eof = true
          raise IO::Error.new("the origin sent over #{H2Engine::MAX_FRAMES} HTTP/2 frames on " \
                              "this WebSocket stream without ending it")
        end
        dispatch(frame)
      end

      # One frame. Returns true when the caller may stop reading — bytes are queued, or the
      # stream has ended.
      private def dispatch(frame : Frame::Header) : Bool
        case frame.frame_type
        when Frame::Type::Data
          consumed = frame.payload.size # §6.9.1 counts the WHOLE payload, padding included
          if frame.stream_id == @flow.id
            payload = H2Engine.data_block(frame)
            unless payload.empty?
              @inbox << payload.dup
              @queued += payload.size
            end
            @eof = true if frame.end_stream?
          end
          if consumed > 0
            # The CONNECTION window is credited for every DATA frame — including one for a
            # stream this replay does not own, whose bytes still drew down the connection's
            # receive window. The STREAM window is not credited once the stream is done: it is
            # closed, and §6.9 says a WINDOW_UPDATE for a closed stream is at best ignored.
            H2Engine.window_update(@io, 0_u32, consumed)
            H2Engine.window_update(@io, @flow.id, consumed) if frame.stream_id == @flow.id && !@eof
          end
          !@inbox.empty? || @eof
        when Frame::Type::Headers, Frame::Type::Continuation
          # A TRAILING header block. Nothing in an RFC 8441 session is carried in one, so the
          # fields are not decoded — but END_STREAM on it really does end the socket, and the
          # peer's HPACK dynamic table would desync if the block were skipped, so it is fed
          # through the connection's decoder and discarded.
          if frame.stream_id == @flow.id
            absorb_trailers(frame)
            @eof = true if frame.end_stream?
          end
          @eof
        when Frame::Type::Settings
          unless frame.ack?
            H2Engine.apply_settings(frame, @flow)
            @flow.settings_seen = true
            H2Engine.ack(@io, Frame::Type::Settings, Bytes.empty)
            @io.flush
          end
          false
        when Frame::Type::Ping
          unless frame.ack?
            H2Engine.ack(@io, Frame::Type::Ping, frame.payload)
            @io.flush
          end
          false
        when Frame::Type::WindowUpdate
          H2Engine.credit(frame, @flow)
          false
        when Frame::Type::RstStream
          return false unless frame.stream_id == @flow.id
          @eof = true
          raise IO::Error.new("#{H2Engine.rst_reason(frame)} from #{@host}:#{@port} — the origin " \
                              "reset the WebSocket stream")
        when Frame::Type::Goaway
          @eof = true
          raise IO::Error.new("#{H2Engine.goaway_reason(frame)} from #{@host}:#{@port} — the " \
                              "origin closed the HTTP/2 connection carrying the WebSocket")
        else
          false
        end
      end

      # Keep the connection's HPACK decoder in step with a trailing block without interpreting
      # it. §2.3.2 makes the dynamic table connection-lifetime state built up ACROSS blocks, so
      # a block skipped is a table that no longer matches the peer's.
      private def absorb_trailers(frame : Frame::Header) : Nil
        block = frame.frame_type == Frame::Type::Headers ? H2Engine.header_block(frame) : frame.payload
        @conn.decoder.decode(block) unless block.empty?
      rescue
        # A trailer block gori cannot decode is not a reason to lose the transcript; the socket
        # is over either way (this only runs on the stream's own frames, and an undecodable one
        # means the table is already lost).
        nil
      end
    end
  end
end
