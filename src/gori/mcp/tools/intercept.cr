require "base64"
require "json"
require "../../store"
require "../request_builder"
require "../serialize"
require "../../fuzz"

module Gori
  module MCP
    class Tools
      # --- #123 live intercept (read side) ------------------------------------

      @[Tool("intercept_list")]
      private def intercept_list(h) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        # The bridge blob the capturing TUI publishes (Runner#publish_intercept_bridge); nil
        # when no capturing instance has ever published one.
        bridge = store.intercept_bridge_state
        unless bridge
          return Result.new({
            available: false,
            reason:    "no capturing gori instance is publishing intercept state (open the project's TUI to intercept)",
          }.to_json)
        end
        now_ms = Time.utc.to_unix_ms
        items = store.intercept_held_items(bridge)
        # Under REPLY_ROWS_BUDGET (#1649): a held head previews up to 1 KiB, and a queue is not
        # bounded. `offset` pages the rest; the held set moves between calls, so a row can
        # shift past a page edge, and the next poll from 0 still lists it.
        offset = clamp_nonneg(optional_int_arg(h, "offset"))
        page = offset_slice(items, offset)
        parts = fit_rows(page) { |rj, r, _| Serialize.intercept_item_row(rj, r, include_sensitive, now_ms) }
        shown = page.first(parts.size)
        # Stamp viewed_ms so the capturing instance's auto-forward reaper sees the agent is
        # watching (only meaningful when we can actually act — see `touches_held?`). Only the
        # rows this reply carried: an item the agent never saw is not one it is handling.
        store.touch_intercept_held(bridge.token, shown.map(&.item_id), now_ms) if touches_held? && !shown.empty?
        Result.new(JSON.build do |j|
          j.object do
            j.field "available", true
            # Derive `capturing` from LIVENESS, not the blob's static true: a crashed/closed
            # instance leaves a stale blob behind, so echoing it would report a dead session
            # as live (see `InterceptBridgeState#live?`).
            j.field "capturing", bridge.live?
            j.field "enabled", bridge.enabled?
            j.field "direction", bridge.direction
            j.field "filter", bridge.filter
            j.field "heartbeat_age_seconds", bridge.heartbeat_age_seconds(now_ms)
            j.field "pending_count", items.size
            emit_offset_page(j, offset, parts.size, page.size, items.size)
            j.field("items") { raw_rows(j, parts) }
          end
        end)
      end

      # Whether reading a held item may stamp `viewed_ms`. The capturing instance's reaper
      # reads that stamp as "an agent is handling this hold" and stops auto-forwarding it, so
      # only an agent that CAN forward or drop may claim it: under --read-only, or with
      # "Intercept control" switched off, a polling agent would otherwise park the operator's
      # traffic until they came to the Intercept tab themselves.
      private def touches_held? : Bool
        @allow_actions && denied_permission("intercept_forward").nil?
      end

      @[Tool("intercept_get")]
      private def intercept_get(h) : Result
        item_id = required_id(h, "item_id")
        include_sensitive = bool_arg(h, "include_sensitive", false)
        bridge = store.intercept_bridge_state
        return not_found("no capturing gori instance is publishing intercept state") unless bridge
        row = store.intercept_held_item(bridge, item_id)
        return not_found("held item #{item_id} is not currently held (already forwarded/dropped, or never held)") unless row
        store.touch_intercept_held(bridge.token, [row.item_id], Time.utc.to_unix_ms) if touches_held?
        Result.new(JSON.build { |j| Serialize.intercept_item_detail(j, row, include_sensitive, Time.utc.to_unix_ms) })
      end

      # The held row for `item_id`, straight off the #123 bridge — nil when no live bridge, no
      # session token, or the item is no longer held (already forwarded/dropped elsewhere).
      # `intercept_forward_edit` needs this BEFORE it picks a normalization rule: a WS item has
      # no HTTP head at all, so the rule that CRLF-promotes bare LF in a "header block" must
      # never run on it (see `intercept_edit_bytes`). A nil here just falls back to the
      # HTTP-shaped rule, which is harmless — the enqueue below will resolve `no_such_item` on
      # its own if the row really is gone.
      private def held_row_for_edit(item_id : Int64) : Store::HeldRow?
        store.intercept_bridge_state.try { |bridge| store.intercept_held_item(bridge, item_id) }
      end

      # --- #123 live intercept (write side; gated behind allow_actions) -------

      @[Tool("intercept_forward", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_forward(h) : Result
        id = required_id(h, "item_id")
        enqueue_intercept("forward", item_id: id)
      end

      @[Tool("intercept_drop", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_drop(h) : Result
        id = required_id(h, "item_id")
        enqueue_intercept("drop", item_id: id)
      end

      @[Tool("intercept_forward_edit", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_forward_edit(h) : Result
        id = required_id(h, "item_id")
        row = held_row_for_edit(id)
        edited = intercept_edit_bytes(h, row)
        return edited if edited.is_a?(Result)
        # Bytes are LITERAL — no Env.expand_wire, so a remote agent's $SECRET references are
        # never expanded into forwarded traffic; and no smuggling guard, because byte-exact
        # forwarding of arbitrary edits is the whole point of an intercept editor in a security
        # tool (matches the human pending_edit contract).
        #
        # Content-Length sync is now a DECLARED argument, default on. It used to be
        # unconditional, one line under that very comment — which made a CL desync (CL shorter
        # than the body, CL longer than the body, CL+TE), *the* canonical reason to hold a
        # request, unexpressible, and made the advertised byte-exact `raw_base64` channel not
        # byte-exact. Default on keeps the ordinary edit ("I changed the body, frame it for
        # me") working; `update_content_length:false` is the desync switch, and the result
        # says which one ran so the caller never has to assume.
        #
        # A WS item never gets this rewrite, full stop — not even when the caller asked for it.
        # There is no head, so `ContentLength.sync` would have to invent a header LINE and
        # splice it into the payload body (`add_when_missing` was written for a GET growing a
        # body, not for turning a chat message into one), exactly the trap the TUI's own
        # `pending_edit` comment calls out. Mirrors the TUI: WS is never offered the toggle.
        ws = row.try(&.ws?) || false
        sync = !ws && bool_arg(h, "update_content_length", true)
        bytes = sync ? Fuzz::ContentLength.sync_edit(edited) : edited
        enqueue_intercept("forward_edit", item_id: id, bytes: bytes,
          extra: {"content_length_synced" => JSON::Any.new(sync && bytes != edited)})
      end

      # The replacement wire message.
      #
      # `raw_base64` is the byte-exact channel for ANY held item — a JSON string cannot carry
      # arbitrary octets, so it is the only way a binary body (or a binary WS frame) survives
      # the round trip `intercept_get` starts when it hands back `raw_base64`.
      #
      # `raw` behaves differently depending on WHAT is held, because the two shapes are not the
      # same message:
      #   - An HTTP head+body: lone LFs in the HEADER block become CRLF (a hand-typed message
      #     still frames) while the BODY is left untouched — `Repeater::UrlRequest.normalize_raw`,
      #     the same rule `send_request`'s `raw` uses.
      #   - A WebSocket message (`row.ws?`): there IS no header block — no start line, no
      #     headers, no head/body split — so running the HTTP rule on it is not "safe
      #     normalization", it is corruption: with no blank line to bound it, the WHOLE payload
      #     is treated as "header" and every bare LF the operator typed is promoted to CRLF (a
      #     17-byte unedited round trip came back 19 bytes on the wire). `raw` is taken
      #     LITERALLY instead, mirroring the TUI's `@loaded_ws` branch in
      #     `intercept_view#pending_edit` (`wire_bytes`, never `Env.expand_wire`/normalize).
      #   - A WebSocket BINARY frame (`row.binary?`): even taken literally, a JSON string
      #     cannot carry an arbitrary octet — a byte above 0x7F round-trips through JSON's
      #     Unicode text encoding as MULTIPLE bytes, silently growing the payload (`0xFF` came
      #     back `0xC3 0xBF`). The TUI answers the identical problem with a HEX editor over the
      #     payload (`InterceptView#hex_editing?`) — a byte channel, which is what this one is
      #     not — so `raw` refuses here by name instead of forwarding the wrong bytes, and
      #     `raw_base64` is the byte-exact escape hatch it already is for a binary HTTP body.
      #
      # Exactly one of `raw`/`raw_base64`, so a caller that sends both is told rather than
      # silently having one ignored.
      private def intercept_edit_bytes(h, row : Store::HeldRow?) : Bytes | Result
        # `strict_str`, NOT `str`: both of these ARE the wire message, so the coercion `str`
        # applies to a scalar is the one failure this argument pair cannot survive. `12345678`
        # coerces to a string that DECODES to six octets, so gori would forward bytes the
        # caller never named — into traffic a human is holding mid-flight. `create_repeater`'s
        # `request_base64` has always refused it (`base64_str`); this site did not, so the same
        # mistake was an error there and a silent edit here.
        b64 = strict_str(h, "raw_base64").presence
        raw = strict_str(h, "raw", expected: "a JSON string; use raw_base64 for exact octets").presence
        if b64 && raw
          return err("pass only one of 'raw' or 'raw_base64'", "INVALID_ARGUMENT", field: "raw_base64")
        end
        if b64
          decoded = begin
            Base64.decode(b64)
          rescue
            return err("invalid 'raw_base64' (not valid base64)", "INVALID_ARGUMENT", field: "raw_base64")
          end
          return err("'raw_base64' decoded to an empty message", "INVALID_ARGUMENT", field: "raw_base64") if decoded.empty?
          return decoded
        end
        unless raw
          return err("missing required 'raw' (the full edited wire message) — or 'raw_base64' for byte-exact bytes",
            "INVALID_ARGUMENT", field: "raw")
        end
        if row.try(&.ws?)
          if row.try(&.binary?)
            return err("held item #{row.not_nil!.item_id} is a WebSocket BINARY message — 'raw' is a JSON string and cannot carry it byte-exact (a byte over 0x7F re-encodes to multiple bytes); use 'raw_base64' instead",
              "INVALID_ARGUMENT", field: "raw")
          end
          return raw.to_slice
        end
        Repeater::UrlRequest.normalize_raw(raw)
      end

      @[Tool("intercept_toggle", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_toggle(h) : Result
        want = optional_bool_arg(h, "enable")
        return err("missing required 'enable' (true or false)", "INVALID_ARGUMENT", field: "enable") if want.nil?
        enqueue_intercept("toggle", arg: want ? "true" : "false")
      end

      @[Tool("intercept_set_filter", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_set_filter(h) : Result
        q = required_str(h, "query", "(empty string to clear)", blank: true)
        # A field the hold gate refuses (`InterceptFilter::UNSUPPORTED_FIELDS`) compiles to a
        # never-match, so `scope:in` here holds NOTHING and `-scope:in` holds EVERY in-flight
        # message until each is forwarded by hand — and an agent has no note row to read. Refused
        # at the two surfaces that submit a COMPLETE condition (here and `gori run intercept
        # filter`), never in `Interceptor#set_filter`: the TUI bar applies the condition on every
        # keystroke, so a refusal there would reject conditions mid-word.
        if bad = Gori::InterceptFilter.refusal(q)
          return err(bad, "INVALID_ARGUMENT", field: "query")
        end
        bridge = store.intercept_bridge_state
        dir = bridge.try { |b| Interceptor::Direction.from_arg?(b.direction) }
        enqueue_intercept("set_filter", arg: q, extra: direction_note_extra(q, dir))
      end

      # A `status:` condition under a requests-only catch holds nothing until the direction
      # changes. Said as a `note` beside the ack, never a refusal: either half may change next.
      private def direction_note_extra(query : String, dir : Interceptor::Direction?) : Hash(String, JSON::Any)?
        return nil unless dir
        note = Interceptor.direction_note(query, dir, "intercept_set_direction response or both holds them")
        note ? {"note" => JSON::Any.new(note)} : nil
      end

      @[Tool("intercept_set_direction", gated: true, agent_action: true, permission: "intercept")]
      private def intercept_set_direction(h) : Result
        raw = str(h, "direction").try(&.strip).presence
        unless raw
          return err("missing required 'direction' (#{INTERCEPT_DIRECTIONS.join(" | ")})", "INVALID_ARGUMENT", field: "direction")
        end
        unless dir = Interceptor::Direction.from_arg?(raw)
          return err("invalid 'direction' #{raw.inspect} (expected #{INTERCEPT_DIRECTIONS.join(" | ")})", "INVALID_ARGUMENT", field: "direction")
        end
        filter = store.intercept_bridge_state.try(&.filter) || ""
        enqueue_intercept("set_direction", arg: dir.arg, extra: direction_note_extra(filter, dir))
      end

      # --- #1630 inject a frame into a live proxied WebSocket ----------------------
      #
      # The capturing TUI holds the socket, so the frame crosses the same bridge the intercept
      # verbs use and the TUI writes it (`Proxy::WS::Live.inject`). Layer 1 is decided HERE,
      # strictly, against the flow's own host; Layer 2 (Sandbox) runs there, on the socket.
      @[Tool("ws_inject", gated: true, agent_action: true, permission: "send")]
      private def ws_inject(h) : Result
        flow_id = required_id(h, "flow_id")
        direction = str(h, "direction").try(&.strip).presence || "out"
        unless direction.in?("out", "in")
          return err("invalid 'direction' #{direction.inspect} (expected out | in)", "INVALID_ARGUMENT", field: "direction")
        end
        kind = str(h, "opcode").try(&.strip.downcase).presence || "text"
        opcode = Proxy::WS::Live::OPCODES[kind]?
        unless opcode
          return err("invalid 'opcode' #{kind.inspect} (expected #{Proxy::WS::Live::OPCODES.keys.join(" | ")})",
            "INVALID_ARGUMENT", field: "opcode")
        end
        payload = ws_inject_payload(h)
        return payload if payload.is_a?(Result)
        flow = store.get_flow(flow_id)
        return not_found("flow #{flow_id} not found") unless flow
        if refusal = Proxy::WS::Live.flow_refusal(String.new(flow.request_head))
          return err(refusal, "INVALID_ARGUMENT", field: "flow_id")
        end
        row = flow.row
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        sc = ob.check_request(row.scheme, row.host, row.target, row.port)
        return scope_blocked(sc, field: "flow_id", passes_exclude: ob.send_passes_exclude?) if sc.blocked?
        ws_inject_result(store.send_ws_inject(flow_id, direction, opcode, payload), row.host)
      end

      # Exactly one of `payload` (literal text, no token expansion) or `payload_base64`
      # (byte-exact); neither is an empty payload, which a ping or a close may well want.
      private def ws_inject_payload(h) : Bytes | Result
        b64 = strict_str(h, "payload_base64")
        text = strict_str(h, "payload", expected: "a JSON string; use payload_base64 for exact octets")
        return err("pass only one of 'payload' or 'payload_base64'", "INVALID_ARGUMENT", field: "payload_base64") if b64 && text
        return (text || "").to_slice unless b64
        begin
          Base64.decode(b64)
        rescue
          err("invalid 'payload_base64' (not valid base64)", "INVALID_ARGUMENT", field: "payload_base64")
        end
      end

      private def ws_inject_result(outcome : Store::InterceptAck | Store::InterceptSendFailure, host : String) : Result
        if outcome.is_a?(Store::InterceptAck)
          detail = outcome.detail || ""
          case outcome.status
          when "injected"
            return Result.new({status: "injected", detail: detail}.to_json)
          when "refused"
            return sandbox_blocked(detail, host, "flow_id") if detail == Outbound::SANDBOX_ERROR
            return budget_refused(detail) if Outbound.budget_refusal?(detail)
            return err(detail, "REFUSED", field: "flow_id")
          when "stale"
            return err(detail, "SESSION_CHANGED")
          else
            return err("ws_inject #{outcome.status}: #{detail}", "INTERNAL")
          end
        end
        case outcome
        in .not_live?
          busy("no live capturing gori instance holds this socket — injection needs the project's TUI " \
               "capturing (a headless capture cannot inject)")
        in .not_enqueued?
          busy("could not enqueue the inject (store write dropped); retry")
        in .not_confirmed?
          # Not retryable: a write that started before the deadline may still land, so a blind
          # retry can inject twice (`Live::EXPIRED` keeps one that had not started from going out).
          err("inject not confirmed within #{Store.ws_inject_ack_budget_ms}ms — the capturing instance may be busy; " \
              "check the flow's messages (get_flow) before retrying, it may still have gone out",
            "NOT_CONFIRMED", retryable: false)
        end
      end

      # Send one command to the live capturing instance and wait for its ack
      # (`Store#send_intercept_command`), so the agent gets a real outcome
      # (forwarded/dropped/no_such_item/…) rather than assuming success on a write that may have
      # been dropped or never drained.
      # `extra` rides onto the SUCCESS envelope so a verb can report what it did to the
      # caller's bytes — see `intercept_forward_edit`'s Content-Length switch. Reporting a
      # transformation is not optional: a surface that shows a value which did not go out is
      # itself the defect.
      private def enqueue_intercept(verb : String, *, item_id : Int64? = nil, bytes : Bytes? = nil,
                                    arg : String? = nil,
                                    extra : Hash(String, JSON::Any)? = nil) : Result
        outcome = store.send_intercept_command(verb, item_id: item_id, bytes: bytes, arg: arg)
        return intercept_ack_result(outcome.status, outcome.detail, extra) if outcome.is_a?(Store::InterceptAck)
        case outcome
        in .not_live?
          busy("no live capturing gori instance is draining intercept commands (open the project's TUI with intercept on)")
        in .not_enqueued?
          busy("could not enqueue intercept command (store write dropped); retry")
        in .not_confirmed?
          err("intercept command not confirmed within #{Store.intercept_ack_budget_ms}ms — the capturing instance may be busy; retry",
            "NOT_CONFIRMED", retryable: true)
        end
      end

      private def intercept_ack_result(status : String, detail : String?,
                                       extra : Hash(String, JSON::Any)? = nil) : Result
        case status
        when "forwarded"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "detail", detail; emit_extra(j, extra) } })
        when "dropped"
          Result.new({status: "dropped", detail: detail}.to_json)
        when "edited"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "edited", true; j.field "detail", detail; emit_extra(j, extra) } })
        when "toggled", "filter_set", "direction_set"
          Result.new(JSON.build { |j| j.object { j.field "status", status; j.field "detail", detail; emit_extra(j, extra) } })
        when "no_such_item"
          not_found(detail || "the held item is no longer held (already forwarded/dropped)")
        when "stale"
          err(detail || "command targeted a previous capture session; re-list held items", "SESSION_CHANGED")
        else
          err("intercept command #{status}: #{detail}", "INTERNAL")
        end
      end

      private def emit_extra(j : JSON::Builder, extra : Hash(String, JSON::Any)?) : Nil
        extra.try &.each { |k, v| j.field k, v }
      end

      # The tools/list schemas for the live-intercept tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_intercept_tools(j : JSON::Builder) : Nil
        tool j, "intercept_list",
          "List messages HELD by the capturing gori's live intercept queue, plus state " \
          "(enabled/direction/filter) and heartbeat. available:false = no bridge ever; " \
          "capturing:false (growing heartbeat_age_seconds) = capturer gone, mutating verbs " \
          "refuse. HTTP row: head_preview + body_size; WebSocket row: body_preview (omitted for " \
          "BINARY), body_size = payload. operator_editing:true = the HUMAN has unsaved edits in " \
          "that hold; forwarding/editing/dropping discards them, so leave it or ask first." do |s|
          s.field "include_sensitive", boolprop("show Authorization/Cookie/etc values instead of [REDACTED]")
          s.field "offset", intprop("held items to skip (default 0); `has_more` = stopped short of pending_count")
        end

        tool j, "intercept_get",
          "Detail for ONE held item (redacted head + body size; WebSocket: body_preview, " \
          "body_size = payload). NOT_FOUND once forwarded/dropped or never held." do |s|
          s.field "item_id", intprop("held item id (intercept_list)"), required: true
          s.field "include_sensitive", boolprop("unredacted headers plus raw_base64 (byte-exact, for intercept_forward_edit); else raw_redacted:true")
        end

        return unless @allow_actions

        tool j, "intercept_forward",
          "Forward a held item byte-exact (shown to the operator). Discards unsaved human edits (operator_editing:true). Returns forwarded | " \
          "no_such_item (already released) | not_confirmed (retry)." do |s|
          s.field "item_id", intprop("held item id (intercept_list)"), required: true
        end

        tool j, "intercept_drop",
          "Drop a held item: the client gets a canned 502 and the message never reaches its " \
          "destination. Destroys unsaved human edits (operator_editing:true). Returns dropped | " \
          "no_such_item | not_confirmed." do |s|
          s.field "item_id", intprop("held item id (intercept_list)"), required: true
        end

        tool j, "intercept_forward_edit",
          "Forward a held item with EDITED bytes: the full wire message, sent verbatim (NO " \
          "variable expansion) except Content-Length (update_content_length). Replaces any " \
          "unsaved human edits (operator_editing:true). Returns forwarded (edited:true, " \
          "content_length_synced) | no_such_item | not_confirmed." do |s|
          s.field "item_id", intprop("held item id (intercept_list)"), required: true
          s.field "raw", strprop("message as text (not with raw_base64); a lone LF in the HEADER block becomes CRLF, body untouched")
          s.field "raw_base64", strprop("message as base64, byte-exact (round-trips intercept_get's raw_base64); the only way a binary body survives")
          s.requires_one_of "raw", "raw_base64"
          s.field "update_content_length", boolprop("recompute Content-Length to the edited body (default true). FALSE keeps your framing (CL mismatching the body, or CL + Transfer-Encoding: the smuggling primitive); raw_base64 is then byte-exact end to end")
        end

        tool j, "intercept_toggle",
          "Enable/disable the live intercept catch (idempotent; applies to live " \
          "connections). Returns toggled | busy." do |s|
          s.field "enable", boolprop("true holds matching traffic; false stops and auto-forwards everything held"), required: true
        end

        tool j, "intercept_set_filter",
          "Set the intercept filter NARROWING which in-flight messages are held." do |s|
          s.field "query", strprop("QL-like query, e.g. 'host:api.example.com method:POST'; '' clears (hold everything in scope)"), required: true
        end

        tool j, "ws_inject",
          "Inject ONE frame into a still-open WebSocket the proxy relays (captured HTTP/1.1 " \
          "Upgrade flow), on the app's own socket and session. ACTIVE, scope-gated on the " \
          "flow's host. Sent verbatim (no token expansion, no Match & Replace), ahead of any " \
          "held message. A text/binary frame waits up to 5 s for a fragmented message on that " \
          "side, then is REFUSED. Needs the capturing TUI (not headless); recorded on the flow " \
          "with origin:\"gori\". HTTP/2 WebSockets refused. Returns injected | REFUSED (closed, " \
          "mid-message, sandbox) | not_confirmed." do |s|
          s.field "flow_id", intprop("WebSocket flow id (list_history)"), required: true
          s.field "direction", enumprop("out = client→server (masked), in = server→client (default out)", %w[out in])
          s.field "opcode", enumprop("default text", Proxy::WS::Live::OPCODES.keys)
          s.field "payload", strprop("payload text, literal")
          s.field "payload_base64", strprop("payload as base64, byte-exact")
          s.field "allow_unscoped", boolprop("inject even outside (or without) a configured scope")
        end

        tool j, "intercept_set_direction",
          "Set which leg(s) intercept holds (default request; intercept_list's " \
          "requestonly/responseonly spellings accepted)." do |s|
          s.field "direction", enumprop("side(s) held", INTERCEPT_DIRECTION_ARGS), required: true
        end
      end
    end
  end
end
