require "base64"
require "digest/sha1"
require "../proxy/upstream"
require "../proxy/codec/http1"
require "../proxy/ws/frame"
require "./flow_request"

module Gori
  module Repeater
    # Re-establishes a WebSocket session to an origin and repeaters recorded
    # client→server messages, capturing the server's responses. Unlike Engine /
    # H2Engine (one request → one buffered response), this does the HTTP/1.1
    # upgrade handshake, then a scripted exchange: send ONE outbound message as a
    # masked client frame, drain the server's answer until it goes idle, send the
    # next — until the script runs out, the server sends Close, the socket dies, a
    # capture cap trips, or the drain deadline is reached (see DRAIN_DEADLINE: the
    # idle gap between turns is the engine's own waiting and is not charged to it).
    #
    # INTERLEAVED, not send-all-then-drain. Every recorded client→server message used to go
    # out back to back and only then were the responses read, so a protocol whose Nth message
    # depends on the answer to the (N-1)th — a subscribe/ack exchange, a challenge/response
    # auth, anything request/response-shaped over one socket — was replayed as a burst the
    # server was answering out of step, and the transcript listed every "out" row ahead of
    # every "in" row whatever the wire order had actually been. Draining between messages is
    # also what lets the engine learn MID-script that the peer closed (§5.5.1: nothing follows
    # a CLOSE) or went away, so it stops and reports how far it got instead of writing into a
    # socket nobody is reading.
    #
    # One deliberate limitation remains:
    #  - No permessage-deflate: the handshake omits the extension, AND the live
    #    capture relay stores frame payloads verbatim without decompressing them. So
    #    a session captured over a compressed connection holds COMPRESSED bytes;
    #    replaying them to a server that isn't negotiating deflate sends undecodable
    #    input (and compressed server frames likewise can't be read). To repeater such
    #    a session, capture it with compression disabled in the browser.
    module WsEngine
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" # RFC 6455 §1.3 accept magic

      DEFAULT_IDLE      = 3.seconds           # gap of server silence that ends the drain
      HANDSHAKE_TIMEOUT = 15.seconds          # generous read bound for the connect + 101 upgrade
      MAX_RECV_MESSAGES = 1000                # cap captured server messages (anti-flood)
      MAX_RECV_BYTES    = 8_i64 * 1024 * 1024 # cap total captured server payload bytes
      MAX_DRAIN_FRAMES  = 100_000             # hard ceiling on frames processed (ping/empty-fragment flood)
      # Ceiling on ACTIVE drain time across the whole exchange — the time spent reading
      # frames, not the time spent waiting for one. Every read that ends in the idle
      # timeout is credited back (`DrainState#credit_idle`), because that gap is the
      # engine taking its turn and not the origin costing it anything: charged, a
      # healthy origin answering promptly still burned `idle` per message, so at the
      # TUI's 3s default a script longer than 20 messages stopped mid-run and blamed
      # a cap the operator could not raise. What it still bounds is an origin that
      # never goes idle — a steady sub-idle ping cadence stays under MAX_DRAIN_FRAMES
      # and would otherwise pin the tab "inflight" for hours. Unlike the three capture
      # caps above, this one is not about how much was captured; `with_unsent_note`
      # therefore names the deadline rather than "a capture cap".
      DRAIN_DEADLINE    = 60.seconds
      MAX_CONTROL_BYTES = 125 # RFC 6455 §5.5: control-frame payload limit (caps Pong echo)
      # Ping/pong rows kept in the transcript. A server's control frames were dropped
      # entirely, which is why a CLOSE reason and a PING payload never reached the operator —
      # but `recv_count` bounds DATA messages only, so an origin pinging under the idle
      # timeout would grow the transcript to MAX_DRAIN_FRAMES rows of keepalive. A CLOSE is
      # exempt from this: there is at most one, and it is the row that matters.
      MAX_CONTROL_MESSAGES = 64

      # A request head declares a WebSocket upgrade. Matches the `Upgrade: websocket`
      # header case-insensitively (RFC 6455: the token is case-insensitive; browsers
      # send lowercase, but `Upgrade: WebSocket` and no-space forms are equally valid),
      # tolerating flexible whitespace after the colon. The single source of truth for
      # "is this repeater a WebSocket flow?" across the TUI restore paths and MCP tools.
      UPGRADE_HEADER = /(?:^|\n)upgrade:[ \t]*websocket/i

      def self.upgrade_request?(request : String) : Bool
        # scrub: `request` is a captured request head+body kept byte-exact (never scrubbed, P7);
        # an obs-text byte in a header value would make PCRE matches? raise. This is a read-only
        # classification (the request is never re-sent from it), so scrub is lossless and fixes
        # all callers (cli/run.cr's `gori run` path is otherwise unrescued).
        request.scrub.matches?(UPGRADE_HEADER)
      end

      # An outbound message to resend. `opcode` is the RFC 6455 opcode as-is — 0 CONT,
      # 1 TEXT, 2 BIN, 8 CLOSE, 9 PING, 10 PONG, and anything else the operator names — and
      # `shape` carries FIN, the RSV nibble, the masking decision and a declared length that
      # may disagree with the payload.
      #
      # The engine used to fold every message to `opcode == 2 ? OP_BIN : OP_TEXT`, FIN=1,
      # RSV=0, masked with a fresh key. That is one frame shape out of the dozen a WebSocket
      # test needs, so a captured session of twelve distinct shapes replayed as seven
      # identical ones and the difference was never reported.
      #
      # `evidence` is PROVENANCE, the same axis `Repeater::PlanOptions#evidence?` carries for
      # the HTTP half: true when these bytes were CAPTURED (a session seeded from a flow),
      # false when the operator typed them here and now (`--message`, MCP `messages`, a line
      # added to the pane). It is per-message and not per-send because the two populations mix
      # in one list — `--message` overrides a seed, and the TUI pane is a splice over one.
      #
      # A captured frame is replayed as recorded or not at all. `{"$where":"this.a==1"}` is a
      # MongoDB injection test, `{"$ref":…}` is a JSON-Schema document and `$filter` is OData;
      # with the draft policy on, the capture was unreplayable without project env vars, and
      # taking the refusal's own advice sent `{"WHEREVAL":"this.a==1"}` — a JSON object with a
      # key nobody wrote, in place of the payload the whole test was about.
      record OutMsg, opcode : Int32, payload : Bytes,
        shape : Proxy::WS::Shape = Proxy::WS::Shape::DEFAULT,
        evidence : Bool = false

      # One message in the replayed transcript. `direction` is "out" (we sent) or
      # "in" (server sent); `opcode` is the RFC 6455 opcode, no longer folded to 1 or 2.
      #
      # `shape` says how the frame was FRAMED. On an "out" row that is what gori put on the
      # wire — including a FIN the operator cleared, RSV bits they set, a mask key they
      # pinned, and a declared length that disagrees with the payload — so the transcript can
      # be read as evidence instead of being taken on trust. On an "in" row it is the first
      # frame's header as it arrived.
      record Message, direction : String, opcode : Int32, payload : Bytes,
        shape : Proxy::WS::Shape = Proxy::WS::Shape::DEFAULT

      struct Result
        getter handshake_head : Bytes # the server's upgrade response head (empty on connect failure)
        getter messages : Array(Message)
        getter duration_us : Int64
        getter error : String? # a real failure (no connection / no upgrade / IO error)
        getter note : String?  # a non-fatal advisory (e.g. handshake accept mismatch)
        getter close_code : Int32?
        getter? upgraded : Bool
        # A cap-driven truncation of the inbound transcript, as the operator-facing sentence
        # (nil when the drain ran to a clean CLOSE/EOF/idle). DISTINCT from `note`: `note` is a
        # delivery/handshake advisory about a run that is otherwise complete, whereas this says
        # the captured `messages` are SHORT of what the server sent — messages/bytes/frames/
        # deadline/control cap. `drain` also appends ONE synthetic NOTICE_PREFIX `Message` row
        # carrying the same sentence, so the truncation is visible in the transcript on every
        # surface without each serializer having to special-case it; this field is the summary.
        getter truncated : String?

        def initialize(@handshake_head, @messages, @duration_us, @error = nil,
                       @note = nil, @close_code = nil, @upgraded = false, @truncated = nil)
        end

        def ok? : Bool
          @error.nil?
        end
      end

      def self.send(upgrade_request : Bytes, out_messages : Array(OutMsg), *,
                    scheme : String, host : String, port : Int32,
                    verify_upstream : Bool, sni : String? = nil,
                    idle : Time::Span = DEFAULT_IDLE,
                    overrides : Gori::HostOverrides? = nil,
                    keep_key : Bool = false,
                    deadline : Time::Span = DRAIN_DEADLINE) : Result
        started = Time.instant
        # The connect + handshake reads get a generous io_timeout so a slow-but-valid
        # upgrade (cold start / auth / slow proxy) isn't mistaken for a dead origin;
        # the read_timeout is narrowed to `idle` only once we enter the drain, where a
        # read that times out is the EXPECTED "server went quiet → stop" signal.
        ht = HANDSHAKE_TIMEOUT
        tls = scheme == "https" || scheme == "wss"
        # `*_result` rather than the socket-only dial: a WebSocket target fails to come up for
        # exactly the reasons every other send path fails, and `Engine.connect_error` is where
        # those sentences live. Dropping the `DialError` here left this one surface saying
        # "connect failed: host:port" for an untrusted certificate, a plaintext port and an
        # origin that accepts the connection and then goes silent.
        upstream, dial_error = if tls
                                 Proxy::Upstream.dial_tls_result(host, port, verify: verify_upstream, sni: sni, io_timeout: ht, overrides: overrides)
                               else
                                 Proxy::Upstream.dial_result(host, port, io_timeout: ht, overrides: overrides)
                               end
        return err(Engine.connect_error(scheme, host, port, verify_upstream, dial_error), started) unless upstream

        begin
          handshake, keys = build_handshake(upgrade_request, keep_key)
          upstream.write(handshake)
          upstream.flush
          # Bounded like every other origin head read (`Engine.read_response_head`, and
          # `ClientConn#safe_read_head` on the proxy path): the per-read `io_timeout` armed on
          # the dial is reset by every byte, so an origin dripping its 101 handshake one byte at
          # a time pins this fiber for as long as it cares to trickle. `underlying_socket`
          # returns nil for an IO with no settable socket, in which case the deadline is skipped
          # and the behaviour is unchanged.
          head = Proxy::Codec::Http1.read_head(upstream,
            deadline: Proxy::SocketTuning::HEAD_DEADLINE,
            timeout_sock: Proxy::SocketTuning.underlying_socket(upstream))
          # `Engine.no_response_error`, not a local copy of the sentence: a plain `ws://` target
          # behind a proxy that answers the CONNECT and then closes without relaying anything is
          # the same shape as the h1 repeater's clean-EOF case, and a hand-duplicated string here
          # would silently miss the proxy-tunnel clause that builder now carries.
          return err(Engine.no_response_error(host, port), started) unless head

          resp = Proxy::Codec::Http1.parse_response_head(head)
          unless resp.status == 101
            return Result.new(head, [] of Message, elapsed(started),
              error: "server did not upgrade (status #{resp.status})", upgraded: false)
          end
          note = verify_accept(resp, keys)

          messages = [] of Message
          # ONE accounting object for the whole exchange, threaded through every per-message
          # drain: the caps (messages / bytes / frames / deadline / control rows) bound the
          # SESSION, not each gap in it. Per-drain state would have multiplied every one of
          # them by the number of recorded messages, so a 20-message script could have
          # captured 20 × MAX_RECV_BYTES and run for 20 × DRAIN_DEADLINE.
          # `deadline` and not the constant directly, for the same reason `idle` is a parameter:
          # the two bounds are only meaningful against each other (a script of more than
          # `deadline / idle` messages is the regression this pairing exists to catch), and a
          # spec cannot assert that in a run it is willing to wait for. Nothing in the product
          # passes it; every surface takes DRAIN_DEADLINE.
          st = DrainState.new(deadline)
          # Narrow the read bound to `idle` BEFORE the first message goes out. The handshake
          # bound is a PER-READ timeout, and an interleaved replay reads between every pair of
          # messages: left in place, an origin that simply does not answer message 1 would hold
          # message 2 back for HANDSHAKE_TIMEOUT, and a ten-message script for two and a half
          # minutes of nothing. The generous window is not lost — it is spent once, at the end,
          # and only if the exchange produced no inbound frame at all (below).
          set_read_timeout(upstream, idle)
          sent, last_sent_op = exchange(upstream, out_messages, messages, idle, st)
          # The generous first-reply window, spent ONCE and only when nothing ever arrived: a
          # slow-but-alive origin (cold start, auth, a slow proxy in front of it) is not a dead
          # one, which is what the handshake bound protected and what narrowing to `idle` above
          # would otherwise have cost. It is also the ONLY drain a session with no outbound
          # messages gets, which is exactly the single generous drain that shipped before.
          if st.frames == 0 && st.open?
            set_read_timeout(upstream, HANDSHAKE_TIMEOUT)
            drain(upstream, messages, idle, st)
          end
          # Moment 3 (see `drain`) plus the ONE truncation marker row — at the end of the whole
          # exchange rather than of each gap in it, so neither is emitted per message.
          finish(messages, st)
          # Only when the operator did not send one themselves. §5.5.1 allows exactly one
          # CLOSE per direction, so appending gori's after theirs would put a second one on
          # the wire that they did not ask for — and the second frame, not the first, is what
          # the server would be answering. `last_sent_op` and not `out_messages.last?`: an
          # interleaved run can stop early, so the last message SCRIPTED is no longer
          # necessarily the last one SENT.
          send_close(upstream) unless last_sent_op == Proxy::WS::OP_CLOSE.to_i
          # The "out" rows above are appended before the flush and with no delivery evidence —
          # WebSocket has no ack, so a transcript row means "gori wrote this", never "the peer
          # got it". When the origin closes right after the 101 the drain breaks at EOF and
          # `send_close` is rescued, so the run reported `upgraded: true`, `error: null` and
          # listed messages the origin never received (verified at the origin: handshake only,
          # no frame). Say so instead. A NOTE and not an error: a one-way protocol that never
          # answers is legitimate, and in both cases the honest statement is the same —
          # delivery is unconfirmed.
          note = with_delivery_note(note, sent, messages.size, st.close_code)
          note = with_unsent_note(note, sent, out_messages.size, st)
          Result.new(head, messages, elapsed(started), note: note,
            close_code: st.close_code, upgraded: true, truncated: st.truncated)
        rescue ex
          # A failure BEFORE/at the upgrade is a real error; once upgraded, drain swallows
          # mid-exchange IO errors itself, so reaching here means the handshake failed.
          err(ex.message || "ws repeater error", started)
        ensure
          upstream.close rescue nil
        end
      end

      # The interleaved script: one message out, its answer drained, the next out. Returns
      # {how many were actually sent, the opcode of the last one} — the two facts `send` needs
      # afterwards and cannot recover from `out_messages`, because an interleaved run can stop
      # early. Extracted from `send` for its own readability, not because it has another caller.
      private def self.exchange(upstream : IO, out_messages : Array(OutMsg),
                                messages : Array(Message), idle : Time::Span,
                                st : DrainState) : {Int32, Int32?}
        sent = 0
        last_sent_op = nil.as(Int32?)
        out_messages.each do |m|
          # A CLOSE from the server (§5.5.1 forbids data frames after one), a dead socket or
          # a hard capture cap ends the script here. Only an interleaved replay can know any
          # of this mid-run; `with_unsent_note` then says how far it got, rather than listing
          # "out" rows for bytes gori never wrote.
          break unless st.open?
          op = (m.opcode & 0x0f).to_u8
          # The opcode goes out AS GIVEN — the `m.opcode == 2 ? OP_BIN : OP_TEXT` fold that
          # used to live here is why a PING, a PONG, a CLOSE with a chosen code and a lone
          # CONT were inexpressible from every surface at once. `mask: true` is still the
          # DEFAULT (§5.3 requires it of a client), but it is only a default:
          # `shape.masked == false` sends the unmasked client frame that §5.1 says the server
          # must reject, which is the most common WebSocket hardening probe there is.
          #
          # A CLOSE the OPERATOR wrote does NOT stop the loop: "data frames after a CLOSE" is
          # a §5.5.1 test this engine deliberately lets them run, exactly as it lets them send
          # a lone CONT or an unmasked frame. Only the SERVER's close stops it.
          begin
            upstream.write(Proxy::WS.encode(op, m.payload, m.shape, mask: true))
            upstream.flush
          rescue IO::Error
            st.peer_gone = true
            break
          end
          messages << Message.new("out", op.to_i, m.payload, m.shape)
          sent += 1
          last_sent_op = op.to_i
          # Drain this message's answer before the next one leaves. `st` carries the caps,
          # the reassembly buffer and the close/EOF verdict across the calls, so a message the
          # origin fragments ACROSS an idle gap still comes back as one row.
          drain(upstream, messages, idle, st)
        end
        {sent, last_sent_op}
      end

      # Append the unconfirmed-delivery advisory to whatever `note` already says. Kept out of
      # `send` so that method's branch count stays where it was.
      private def self.with_delivery_note(note : String?, sent : Int32, total : Int32,
                                          close_code : Int32?) : String?
        return note unless sent > 0 && total == sent && close_code.nil?
        unreplied = "sent #{sent} message(s) but the peer sent no frame and no close — delivery unconfirmed"
        note ? "#{note}; #{unreplied}" : unreplied
      end

      # The advisory for a script that ended before every recorded message went out. Only an
      # INTERLEAVED replay can produce it: draining between messages is what lets gori learn
      # mid-run that the server closed, that the socket died, or that a capture cap tripped,
      # and stopping is the honest answer to all three — §5.5.1 forbids data frames after a
      # CLOSE, and a write into a dead socket would put "out" rows in the transcript for bytes
      # no peer will ever see. The send-all engine could not detect any of this until it was
      # already over, so it silently claimed to have sent everything.
      private def self.with_unsent_note(note : String?, sent : Int32, total : Int32,
                                        st : DrainState) : String?
        return note if sent >= total
        why = if st.close_code
                "the server sent CLOSE (§5.5.1: no data frames may follow it)"
              elsif st.peer_gone?
                "the connection ended"
              elsif st.deadline_reached?
                # NOT "a capture cap": the deadline is a bound on how long the engine spent
                # reading, and saying "cap" sent operators looking at MAX_RECV_* — the wrong
                # knob for a run that was cut short by time.
                "the #{st.deadline.total_seconds.to_i}s drain deadline was reached"
              else
                "a capture cap was reached"
              end
        unsent = "stopped after #{sent} of #{total} message(s): #{why}"
        note ? "#{note}; #{unsent}" : unsent
      end

      # Everything the drain accumulates, carried ACROSS the per-message drains an interleaved
      # replay performs. It exists because every one of these is a property of the SESSION and
      # not of one gap in it: the caps must bound the whole run, the reassembly buffer must
      # survive an idle gap that falls mid-message, and `open?` is the verdict the send loop
      # consults before each write.
      #
      # Not a `record`: the drain mutates every field, and a struct copied by value into the
      # loop would have lost each drain's accounting the moment it returned.
      class DrainState
        getter deadline : Time::Span # the DRAIN_DEADLINE this exchange runs under

        def initialize(@deadline : Time::Span = DRAIN_DEADLINE)
        end

        property assembling = IO::Memory.new             # the fragments of the message being reassembled
        property msg_opcode : UInt8 = Proxy::WS::OP_TEXT # that message's FIRST frame's opcode
        property shape = Proxy::WS::MessageShape.new     # and its accumulated framing
        property ctl_count = 0                           # ping/pong rows kept (MAX_CONTROL_MESSAGES)
        property recv_bytes = 0_i64                      # captured server payload bytes (MAX_RECV_BYTES)
        property recv_count = 0                          # captured server DATA messages (MAX_RECV_MESSAGES)
        property frames = 0                              # every inbound frame, control included (MAX_DRAIN_FRAMES)
        property close_code : Int32? = nil               # the server's CLOSE status, once it sends one
        property truncated : String? = nil               # the cap sentence, once any cap has fired
        property? marked = false                         # the ONE truncation marker row has been appended
        property? peer_gone = false                      # EOF / IO error / failed write — nothing more can be sent
        property? capped = false                         # a HARD cap ended the drain (the control cap does not)
        property? deadline_reached = false               # ...and that cap was DRAIN_DEADLINE, not a capture cap
        # DRAIN_DEADLINE runs from here, over the whole exchange — but ADVANCED past every idle
        # gap by `credit_idle`, so what it measures is active drain time and not wall clock.
        getter started : Time::Instant = Time.instant

        # Give back a gap that produced nothing. An interleaved replay ends each message's turn
        # on `IO::TimeoutError` after the full `idle`, and charging those gaps to DRAIN_DEADLINE
        # made the deadline a cap on SCRIPT LENGTH: at the TUI's 3s idle, message 21 of a healthy
        # 30-message subscribe/ack exchange was dropped and reported as a capture cap. Waiting is
        # not work. Pushing `started` forward by exactly the elapsed wait keeps the deadline
        # bounding what the engine actually did, while an origin that never goes idle — the case
        # the deadline exists for — is never credited anything and still trips it.
        def credit_idle(gap : Time::Span) : Nil
          @started += gap
        end

        # Whether the next recorded message may still go out. A server CLOSE, a dead socket and
        # a hard cap each mean "no" for a different reason, and `with_unsent_note` names which.
        def open? : Bool
          !peer_gone? && !capped? && @close_code.nil?
        end
      end

      # Read inbound frames until the server sends Close, this message's answer goes idle
      # (read timeout), the socket ends or a cap trips. Reassembles fragmented data messages;
      # answers Ping with a Pong. Every verdict lands in `st`, which the caller carries into
      # the NEXT message's drain — this returns nothing.
      #
      # The idle timeout is no longer the end of the run, it is the end of THIS message's
      # answer: `break` here hands control back to the send loop, which puts the next recorded
      # message on the wire. Only `st.peer_gone` / `st.close_code` / `st.capped` end the
      # exchange, which is why each is recorded rather than inferred from "the loop stopped".
      # `IO::TimeoutError` is split out of `IO::Error` for exactly that reason: they used to
      # share one `break` because both meant "stop", and now one means "your turn" and the
      # other means "there is no peer left to take a turn". (A timeout landing MID-frame is
      # unrecoverable either way — the stream is then desynced — but the next misparse yields
      # an oversized/short frame, `read_frame` answers nil, and the exchange ends there.)
      #
      # Truncating at a cap and reporting a CLEAN result is the bug `st.truncated` fixes
      # (#10 L8-F1): a bare `break` recorded only the close code, so a drain that stopped
      # short of the server's frames was indistinguishable from one that ran to the end. The
      # sibling `Relay.capture_control` (proxy/ws/relay.cr:465) already does the honest thing —
      # ONE synthetic NOTICE_PREFIX row so the truncation shows in the transcript and can never
      # be replayed (`Store::WsMessage#notice?` refuses it). `finish` does the same at the end
      # of the exchange. The break-site caps set the reason UNCONDITIONALLY (the cap that ended
      # the run is the salient one); the control cap, which does not break, only fills it in if
      # nothing else has (`||=`).
      #
      # Reassembly has THREE moments, not one, and this method used to have only the last:
      #
      #   1. a new data frame arriving while the previous message never sent its FIN — an
      #      RFC 6455 §5.4 violation, and the whole point of pointing a repeater at a server;
      #   2. FIN, the ordinary end of a message;
      #   3. the exchange ending with a fragment still unterminated (CLOSE / EOF / idle / a cap).
      #
      # Without 1 the two messages were concatenated, so `TEXT fin=0 "AAA"` then
      # `TEXT fin=1 "BBB"` was reported as one well-formed `AAABBB` that never existed; without
      # 3 an origin that died mid-message left the bytes it did send nowhere at all. The
      # capture relay has had all three since #552 and reported the same origin bytes
      # correctly, so the two surfaces disagreed about the same protocol. `emit_pending` is
      # 1 and 3, `Proxy::WS::MessageShape` is the accumulator both now share, and the flushed
      # fragment carries `fin: false` — gori reports the violation rather than repairing it.
      # Moment 3 lives in `finish` and not at the tail of this loop, because an idle gap is a
      # turn boundary now: a message the origin fragments across one is still ONE message.
      private def self.drain(io : IO, messages : Array(Message), idle : Time::Span,
                             st : DrainState) : Nil
        loop do
          # Count EVERY frame, not just completed messages: an origin flooding pings or
          # empty/non-fin fragments faster than `idle` trips neither the data caps nor
          # the read timeout, so this frame ceiling is what guarantees termination.
          # A deadline also caps total drain time: a steady sub-idle ping cadence stays under
          # MAX_DRAIN_FRAMES yet could otherwise pin the tab "inflight" for hours. Both run
          # from the START of the exchange and not of this message's turn — the frame ceiling
          # over wall clock, the deadline over active drain time only (see `credit_idle`).
          if Time.instant - st.started > st.deadline
            st.truncated = "the #{st.deadline.total_seconds.to_i}s drain deadline was reached; later server frames were not captured"
            st.deadline_reached = true
            st.capped = true
            break
          end
          # Timed from HERE and not from the top of the loop: what gets credited back below is
          # the wait that returned no frame, never time spent reading one.
          read_started = Time.instant
          frame = begin
            Proxy::WS.read_frame(io)
          rescue IO::TimeoutError
            # The idle gap — this message's answer is done; the next one goes out. The gap is
            # the engine's turn, so it is credited back rather than charged to DRAIN_DEADLINE.
            st.credit_idle(Time.instant - read_started)
            break
          rescue IO::Error
            st.peer_gone = true # RST or broken pipe — end the exchange, keep what we have
            break
          end
          if frame.nil? # EOF / truncated
            st.peer_gone = true
            break
          end
          st.frames += 1
          if st.frames > MAX_DRAIN_FRAMES
            st.truncated = "the #{MAX_DRAIN_FRAMES}-frame drain ceiling was reached; later server frames were not captured"
            st.capped = true
            break
          end
          # After the first frame of the exchange, (re-)narrow the per-read bound to `idle`.
          # The send loop already narrowed it; this is what takes it back down when the
          # first-reply grace pass widened it and the origin then answered.
          set_read_timeout(io, idle) if st.frames == 1

          if frame.data?
            if frame.opcode != Proxy::WS::OP_CONT
              if st.shape.frames > 0
                # Moment 1: the previous message never FIN'd. Its bytes are the finding, so
                # they get their own row instead of being merged into this one's — and that
                # row counts against the same caps a completed message does. Without the
                # count, an origin that simply never sends a FIN would buy an unbounded
                # transcript: the byte cap lives on `assembling`, which this flush empties.
                st.recv_count += 1
                st.recv_bytes += st.assembling.bytesize
                st.assembling = emit_pending(messages, st.assembling, st.msg_opcode, st.shape)
                if reason = recv_caps_reason(st.recv_count, st.recv_bytes)
                  st.truncated = reason
                  st.capped = true
                  break
                end
              end
              st.msg_opcode = frame.opcode
            end
            st.shape.note(frame)
            st.assembling.write(frame.payload)
            if st.assembling.bytesize > MAX_RECV_BYTES # runaway fragmented message
              # gori — not the origin — stops accumulating here, so the fragment `finish`
              # flushes with `fin: false` is OUR truncation, not the origin's §5.4 violation.
              # Marking it (the adjacent marker row + this sentence) is what keeps that row
              # from being MISread as a server that never sent a FIN.
              st.truncated = bytes_cap_sentence
              st.capped = true
              break
            end
            if frame.fin?
              payload = st.assembling.to_slice.dup
              st.recv_bytes += payload.size
              st.recv_count += 1
              # First frame's RSV/mask (§5.2 puts an extension's flags there), last frame's
              # FIN, and how many frames it took — the same accounting the capture relay does,
              # so the two agree about identical bytes.
              messages << Message.new("in", st.msg_opcode.to_i, payload, st.shape.take)
              st.assembling = IO::Memory.new
              if reason = recv_caps_reason(st.recv_count, st.recv_bytes)
                st.truncated = reason
                st.capped = true
                break
              end
            end
          elsif frame.close?
            # The CLOSE frame itself joins the transcript, not just its status code. The code
            # was already reported; the REASON — the free-text half of §5.5.1, and where a
            # server actually explains itself — was dropped on the floor, and a PING payload
            # (a real covert channel, and a real length-check bug site) with it.
            #
            # A half-assembled message ahead of it is flushed HERE and not left to `finish`,
            # so the CLOSE row lands AFTER the fragment the origin sent before it — arrival
            # order, which is the order the relay records the same bytes in. That is exactly
            # how `TEXT fin=0 "UNTERMINATED"` followed by a CLOSE left the 12 bytes nowhere.
            st.close_code = close_status(frame.payload)
            st.assembling = emit_pending(messages, st.assembling, st.msg_opcode, st.shape)
            messages << Message.new("in", frame.opcode.to_i, frame.payload.dup, frame.shape)
            break
          else
            # PING/PONG, bounded: `recv_count` only counts DATA messages, so an origin
            # pinging under the idle timeout would otherwise grow this array until
            # MAX_DRAIN_FRAMES — 100k transcript rows for a keepalive. A CLOSE is exempt
            # above; there is at most one, and it is the row that matters.
            if st.ctl_count < MAX_CONTROL_MESSAGES
              st.ctl_count += 1
              messages << Message.new("in", frame.opcode.to_i, frame.payload.dup, frame.shape)
            else
              # Past the cap the ping/pong is still ANSWERED (see send_pong below) but no longer
              # recorded — a drop that otherwise looks exactly like an origin that stopped
              # pinging. `||=`, not `=`: this does not end the exchange, so a hard cap that DOES
              # end it later should own the summary; control only fills in when nothing else
              # fired. It leaves `capped` false for the same reason — the script keeps going.
              st.truncated ||= "the #{MAX_CONTROL_MESSAGES}-control-frame cap was reached; later ping/pong frames were not recorded"
            end
            send_pong(io, frame.payload) if frame.opcode == Proxy::WS::OP_PING
          end
        end
      end

      # Moment 3, plus the ONE truncation marker — once, after the LAST drain of the exchange.
      #
      # Both used to sit at the tail of `drain`, which was the end of the run when there was
      # exactly one drain per session. With a drain per message that would have flushed a
      # half-assembled message at every idle gap (splitting a message the origin fragments
      # slowly into two `fin: false` rows) and appended a marker row per drain instead of the
      # single one the relay sibling emits.
      #
      # The marker goes AFTER the flush so it sits adjacent to (just after) any `fin: false`
      # fragment the runaway-byte cap left behind — the row that says WHY that fragment ends
      # unterminated. NOTICE_PREFIX + an "in" TEXT frame mirrors the relay sibling exactly: it
      # renders in the inbound transcript like the rows it caps, yet a WS repeater seed can
      # never put gori's own sentence back on the wire.
      private def self.finish(messages : Array(Message), st : DrainState) : Nil
        st.assembling = emit_pending(messages, st.assembling, st.msg_opcode, st.shape)
        return if st.marked?
        if reason = st.truncated
          messages << truncation_marker(reason)
          st.marked = true
        end
      end

      # The synthetic row a capped drain leaves behind. Built from `NOTICE_PREFIX` (what
      # `Store::WsMessage#notice?` reads to refuse a replay) so it is a diagnostic and not
      # traffic, and carrying the SAME sentence the Result's `truncated` field does so the row
      # and the summary can never disagree. Direction "in"/OP_TEXT matches `Relay`'s notices.
      private def self.truncation_marker(reason : String) : Message
        Message.new("in", Proxy::WS::OP_TEXT.to_i, "#{Proxy::WS::NOTICE_PREFIX}#{reason}".to_slice)
      end

      # Whatever fragments are buffered, as ONE message, and a fresh buffer. A no-op when
      # nothing is being reassembled. `fin: false` is the point: the origin never sent the
      # FIN, so gori does not invent one — the row says the message ended unterminated, which
      # is the finding. `shape.frames` and not `assembling.bytesize` decides, because a
      # leading fragment with an empty payload is still a fragment that never ended.
      private def self.emit_pending(messages : Array(Message), assembling : IO::Memory,
                                    opcode : UInt8, shape : Proxy::WS::MessageShape) : IO::Memory
        return assembling if shape.frames == 0
        messages << Message.new("in", opcode.to_i, assembling.to_slice.dup, shape.take)
        IO::Memory.new
      end

      # The recv-cap sentence when a DATA cap has tripped, else nil — so the caller both learns
      # it must stop AND which cap to name, in one check. Message count is tested first because
      # a flood of tiny messages and one giant payload are different findings.
      private def self.recv_caps_reason(count : Int32, bytes : Int64) : String?
        if count >= MAX_RECV_MESSAGES
          "the #{MAX_RECV_MESSAGES}-message capture cap was reached; later server messages were not captured"
        elsif bytes >= MAX_RECV_BYTES
          bytes_cap_sentence
        end
      end

      # The byte-cap sentence, in ONE place: the accumulated-recv path (`recv_caps_reason`) and
      # the single-fragment runaway path both hit the same 8 MiB limit and must word it
      # identically. A byte-identical literal in two spots is precisely the "two copies and one
      # omission" the sibling relay's header warns produced its merged-row/dropped-bytes bugs.
      private def self.bytes_cap_sentence : String
        "the #{MAX_RECV_BYTES // (1024 * 1024)} MiB server-payload cap was reached; the transcript is truncated"
      end

      # The per-read bound on the drain. Set both DOWN (to `idle`, before the first message and
      # again once the first frame arrives) and back UP (to HANDSHAKE_TIMEOUT, for the one
      # first-reply grace pass), which is why it is no longer named for narrowing.
      # Both socket types respond; responds_to? keeps the union's IO type happy.
      private def self.set_read_timeout(io : IO, span : Time::Span) : Nil
        io.read_timeout = span if io.responds_to?(:read_timeout=)
      end

      # Echo a Ping as a masked Pong, but never amplify: a control frame's payload is
      # ≤125 bytes (RFC 6455 §5.5), so clamp a hostile oversized ping before reflecting.
      private def self.send_pong(io : IO, ping_payload : Bytes) : Nil
        pong = ping_payload.size > MAX_CONTROL_BYTES ? ping_payload[0, MAX_CONTROL_BYTES] : ping_payload
        io.write(Proxy::WS.encode(Proxy::WS::OP_PONG, pong, mask: true))
        io.flush
      rescue
        # peer gone mid-drain — ignore; the next read ends the drain gracefully
      end

      # 2-byte big-endian status code at the start of a Close payload, if present.
      private def self.close_status(payload : Bytes) : Int32?
        return nil if payload.size < 2
        (payload[0].to_i << 8) | payload[1].to_i
      end

      # Best-effort Close (1000 Normal) so the server tears down cleanly.
      private def self.send_close(io : IO) : Nil
        io.write(Proxy::WS.encode(Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: true)) # 1000
        io.flush
      rescue
        # socket already gone — nothing to close gracefully
      end

      # Rebuilds the upgrade request for repeater: origin-form request line, Sec-WebSocket-
      # Extensions stripped (no permessage-deflate → frames are plain), and — unless
      # `keep_key` — a FRESH Sec-WebSocket-Key. Everything else (Host, Cookie,
      # Authorization, Origin, …) is kept so the repeater carries the original session.
      # Header VALUE bytes are copied verbatim (only the ASCII request line + header NAMES
      # are decoded) so a non-UTF-8-bearing cookie/auth token survives byte-exact, mirroring
      # FlowRequest.origin_form_bytes.
      #
      # Regenerating the key is the DEFAULT and stays the default: a replayed handshake that
      # reuses a captured key looks to a server like a replay, which is what a repeater guard
      # is watching for, and every session that does not ask keeps exactly today's bytes.
      #
      # But the key line was also DELETED and re-appended at the end of the block, so the
      # operator could not send an absent key, a short one, a non-base64 one, two of them, or
      # the same one twice — all handshake tests — and could not control header ORDER either,
      # because their line moved. `keep_key` is the opt-in: their block goes out as written,
      # untouched, key line and position included. It is opt-in rather than the new default
      # because honouring the typed key also means `Sec-WebSocket-Accept` can no longer be
      # asserted (see `verify_accept`), and losing that check silently on every session would
      # trade one blind spot for another.
      #
      # Returns {request bytes, the Sec-WebSocket-Key VALUES actually on the wire}. That is a
      # list and not a String because zero and two are both shapes an operator can now send,
      # and the accept check has to be able to say which it saw.
      private def self.build_handshake(head : Bytes, keep_key : Bool = false) : {Bytes, Array(String)}
        lines = head_lines(head)
        keys = [] of String

        io = IO::Memory.new(head.size + 64)
        req_line = lines.empty? ? "GET / HTTP/1.1" : String.new(lines[0])
        io << (Repeater::FlowRequest.rewrite_request_line(req_line) || req_line) << "\r\n"
        # `skip(1)`, not `lines[1..]`: `head_lines` pops trailing blanks, so an empty or
        # all-blank editor yields `[]` and the Range index raises IndexError. That raise
        # landed AFTER the dial, so the operator got "Index out of bounds" for a connection
        # gori had already opened. The line above already declares the intent — synthesize a
        # request line and let the origin answer — and this negated it.
        lines.skip(1).each do |line|
          next if line.empty?
          name = header_name(line)
          next if name == "sec-websocket-extensions"
          if name == "sec-websocket-key"
            next unless keep_key
            keys << header_value(line)
          end
          io.write(line) # value bytes verbatim (never round-tripped through String)
          io << "\r\n"
        end
        unless keep_key
          key = Base64.strict_encode(Random::Secure.random_bytes(16))
          keys << key
          io << "Sec-WebSocket-Key: " << key << "\r\n"
        end
        io << "\r\n"
        {io.to_slice, keys}
      end

      # Splits a head into its lines (LF-delimited, trailing CR stripped per line) as
      # raw byte slices — no String round-trip — dropping the trailing blank line(s).
      private def self.head_lines(head : Bytes) : Array(Bytes)
        lines = [] of Bytes
        start = 0
        head.each_with_index do |b, i|
          next unless b == 0x0A_u8 # LF
          lines << strip_cr(head[start, i - start])
          start = i + 1
        end
        lines << strip_cr(head[start, head.size - start]) if start < head.size
        while !lines.empty? && lines.last.empty?
          lines.pop
        end
        lines
      end

      private def self.strip_cr(line : Bytes) : Bytes
        line.size > 0 && line[line.size - 1] == 0x0D_u8 ? line[0, line.size - 1] : line
      end

      # The (ASCII) header field name — the bytes before the first ':' — lower-cased
      # for the strip comparison. Only the NAME is decoded; the value stays bytes.
      private def self.header_name(line : Bytes) : String
        ci = line.index(0x3A_u8) # ':'
        String.new(ci ? line[0, ci] : line).strip.downcase
      end

      # The header field VALUE as the operator wrote it, minus the OWS after the colon.
      # Decoded — this feeds the SHA-1 accept computation, which is defined over the key's
      # characters — but never re-sent: `build_handshake` copies the whole line's bytes.
      private def self.header_value(line : Bytes) : String
        ci = line.index(0x3A_u8) # ':'
        return "" unless ci
        String.new(line[ci + 1, line.size - ci - 1]).strip
      end

      # The server's Sec-WebSocket-Accept must be base64(sha1(key + GUID)) (RFC 6455 §4.2.2).
      # A mismatch is surfaced as a non-fatal note (the frames still relayed), since a
      # quirky/misbehaving origin shouldn't abort an otherwise-useful capture.
      #
      # Every branch here says something. The old body opened `return nil unless got` — a
      # server that upgraded with NO accept header at all produced the same silence as a
      # server that answered correctly, which is precisely backwards: the missing header is
      # the finding. And with `keep_key` an operator can now send zero keys or two, at which
      # point there is no single key to derive an expected accept from — so that case reports
      # that it cannot check, rather than quietly not checking.
      private def self.verify_accept(resp : Proxy::Codec::RawResponse, keys : Array(String)) : String?
        got = resp.headers.get?("Sec-WebSocket-Accept")
        if keys.size != 1
          sent = keys.empty? ? "no Sec-WebSocket-Key" : "#{keys.size} Sec-WebSocket-Key headers"
          return "handshake accept NOT verified: the request carried #{sent}, so there is no " \
                 "single key to derive one from (the server answered #{got ? got.inspect : "none"})"
        end
        want = Base64.strict_encode(Digest::SHA1.digest(keys[0] + GUID))
        unless got
          return "handshake accept MISSING: the server sent 101 with no Sec-WebSocket-Accept " \
                 "header (RFC 6455 §4.2.2 requires #{want.inspect})"
        end
        got == want ? nil : "handshake accept mismatch (got #{got.inspect}, want #{want.inspect})"
      end

      private def self.err(message : String, started : Time::Instant) : Result
        Result.new(Bytes.new(0), [] of Message, elapsed(started), error: message)
      end

      private def self.elapsed(started : Time::Instant) : Int64
        (Time.instant - started).total_microseconds.to_i64
      end
    end
  end
end
