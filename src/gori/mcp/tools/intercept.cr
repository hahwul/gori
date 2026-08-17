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

      # Parse the bridge blob the capturing TUI publishes (nil when no capturing instance is
      # live / has ever published). See Runner#publish_intercept_bridge.
      private def intercept_bridge_state : Hash(String, JSON::Any)?
        raw = store.intercept_bridge
        return nil unless raw
        JSON.parse(raw).as_h?
      rescue
        nil
      end

      private def intercept_list(h) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        bridge = intercept_bridge_state
        unless bridge
          return Result.new(JSON.build do |j|
            j.object do
              j.field "available", false
              j.field "reason", "no capturing gori instance is publishing intercept state (open the project's TUI to intercept)"
            end
          end)
        end
        token = bridge["session_token"]?.try(&.as_s?) || ""
        hb = bridge["heartbeat_ms"]?.try(&.as_i64?) || 0_i64
        now_ms = Time.utc.to_unix_ms
        items = token.empty? ? [] of Store::HeldRow : store.intercept_held(token)
        # Stamp viewed_ms so the capturing instance's auto-forward reaper sees the agent is
        # watching (only meaningful when we can actually act; skip in read-only mode).
        store.touch_intercept_held(token, items.map(&.item_id), now_ms) if @allow_actions && !items.empty?
        Result.new(JSON.build do |j|
          j.object do
            j.field "available", true
            # Derive `capturing` from LIVENESS, not the blob's static true: a crashed/closed
            # instance leaves a stale blob behind (nothing writes capturing:false, and cleanup
            # only runs at the NEXT session's startup), so echoing it would report a dead session
            # as live. intercept_live? (heartbeat < 10s) is the authoritative freshness signal.
            j.field "capturing", intercept_live?(bridge)
            j.field "enabled", bridge["enabled"]?.try(&.as_bool?) || false
            j.field "direction", bridge["direction"]?.try(&.as_s?) || "both"
            j.field "filter", bridge["filter"]?.try(&.as_s?) || ""
            j.field "heartbeat_age_seconds", (hb > 0 ? ((now_ms - hb) // 1000) : nil)
            j.field "pending_count", items.size
            j.field("items") { j.array { items.each { |r| Serialize.intercept_item_row(j, r, include_sensitive, now_ms) } } }
          end
        end)
      end

      private def intercept_get(h) : Result
        item_id = int(h, "item_id")
        return err(id_error(h, "item_id"), "INVALID_ARGUMENT", field: "item_id") unless item_id
        include_sensitive = bool_arg(h, "include_sensitive", false)
        bridge = intercept_bridge_state
        return not_found("no capturing gori instance is publishing intercept state") unless bridge
        token = bridge["session_token"]?.try(&.as_s?) || ""
        row = token.empty? ? nil : store.intercept_held(token).find { |r| r.item_id == item_id }
        return not_found("held item #{item_id} is not currently held (already forwarded/dropped, or never held)") unless row
        store.touch_intercept_held(token, [row.item_id], Time.utc.to_unix_ms) if @allow_actions
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
        bridge = intercept_bridge_state
        return nil unless bridge
        token = bridge["session_token"]?.try(&.as_s?) || ""
        return nil if token.empty?
        store.intercept_held(token).find { |r| r.item_id == item_id }
      end

      # --- #123 live intercept (write side; gated behind allow_actions) -------

      # A capturing instance is "live" only if its bridge says capturing AND the heartbeat is
      # recent — otherwise a queued command would never be applied (leaving a hung hold), so a
      # mutating verb refuses up front instead of enqueuing into the void.
      INTERCEPT_LIVE_MS   = 10_000_i64
      INTERCEPT_ACK_POLLS =         30
      INTERCEPT_ACK_SLEEP = 100.milliseconds

      private def intercept_live?(bridge : Hash(String, JSON::Any)) : Bool
        return false unless bridge["capturing"]?.try(&.as_bool?)
        hb = bridge["heartbeat_ms"]?.try(&.as_i64?) || 0_i64
        hb > 0 && (Time.utc.to_unix_ms - hb) < INTERCEPT_LIVE_MS
      end

      private def intercept_forward(h) : Result
        id = int(h, "item_id")
        return err(id_error(h, "item_id"), "INVALID_ARGUMENT", field: "item_id") unless id
        enqueue_intercept("forward", item_id: id)
      end

      private def intercept_drop(h) : Result
        id = int(h, "item_id")
        return err(id_error(h, "item_id"), "INVALID_ARGUMENT", field: "item_id") unless id
        enqueue_intercept("drop", item_id: id)
      end

      private def intercept_forward_edit(h) : Result
        id = int(h, "item_id")
        return err(id_error(h, "item_id"), "INVALID_ARGUMENT", field: "item_id") unless id
        row = held_row_for_edit(id)
        edited = intercept_edit_bytes(h, row)
        return edited if edited.is_a?(Result)
        # Bytes are LITERAL — no Env.expand_wire, so a remote agent's $SECRET references are
        # never expanded into forwarded traffic; and no smuggling guard, because byte-exact
        # forwarding of arbitrary edits is the whole point of an intercept editor in a security
        # tool (matches the human forward_bytes contract).
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
        bytes = sync ? Fuzz::ContentLength.sync(edited, add_when_missing: true) : edited
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
      #     still frames) while the BODY is left untouched — `RequestBuilder.normalize_raw`,
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
        RequestBuilder.normalize_raw(raw)
      end

      private def intercept_toggle(h) : Result
        want = optional_bool_arg(h, "enable")
        return err("missing required 'enable' (true or false)", "INVALID_ARGUMENT", field: "enable") if want.nil?
        enqueue_intercept("toggle", arg: want ? "true" : "false")
      end

      private def intercept_set_filter(h) : Result
        q = str(h, "query")
        return err("missing required 'query' (empty string to clear)", "INVALID_ARGUMENT", field: "query") if q.nil?
        enqueue_intercept("set_filter", arg: q)
      end

      private def intercept_set_direction(h) : Result
        dir = str(h, "direction").try(&.downcase)
        unless dir && {"both", "request", "response"}.includes?(dir)
          return err("invalid 'direction' (expected both | request | response)", "INVALID_ARGUMENT", field: "direction")
        end
        enqueue_intercept("set_direction", arg: dir)
      end

      # Enqueue one command for the live capturing instance, then bounded-poll its ack so the
      # agent gets a real outcome (forwarded/dropped/no_such_item/…) rather than assuming success
      # on a write that may have been dropped or never drained.
      # `extra` rides onto the SUCCESS envelope so a verb can report what it did to the
      # caller's bytes — see `intercept_forward_edit`'s Content-Length switch. Reporting a
      # transformation is not optional: a surface that shows a value which did not go out is
      # itself the defect.
      private def enqueue_intercept(verb : String, *, item_id : Int64? = nil, bytes : Bytes? = nil,
                                    arg : String? = nil,
                                    extra : Hash(String, JSON::Any)? = nil) : Result
        bridge = intercept_bridge_state
        unless bridge && intercept_live?(bridge)
          return busy("no live capturing gori instance is draining intercept commands (open the project's TUI with intercept on)")
        end
        token = bridge["session_token"]?.try(&.as_s?)
        id = store.enqueue_intercept_command(token, verb, item_id: item_id, bytes: bytes, arg: arg)
        return busy("could not enqueue intercept command (store write dropped); retry") if id == 0
        await_intercept_ack(id, extra)
      end

      private def await_intercept_ack(id : Int64, extra : Hash(String, JSON::Any)? = nil) : Result
        INTERCEPT_ACK_POLLS.times do
          if st = store.command_status(id)
            return intercept_ack_result(st[0], st[1], extra) unless st[0] == "pending"
          end
          sleep INTERCEPT_ACK_SLEEP
        end
        err("intercept command not confirmed within #{(INTERCEPT_ACK_POLLS * INTERCEPT_ACK_SLEEP.total_milliseconds).to_i}ms — the capturing instance may be busy; retry",
          "NOT_CONFIRMED", retryable: true)
      end

      private def intercept_ack_result(status : String, detail : String?,
                                       extra : Hash(String, JSON::Any)? = nil) : Result
        case status
        when "forwarded"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "detail", detail; emit_extra(j, extra) } })
        when "dropped"
          Result.new(JSON.build { |j| j.object { j.field "status", "dropped"; j.field "detail", detail } })
        when "edited"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "edited", true; j.field "detail", detail; emit_extra(j, extra) } })
        when "toggled", "filter_set", "direction_set"
          Result.new(JSON.build { |j| j.object { j.field "status", status; j.field "detail", detail } })
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
          "List HTTP messages currently HELD by the live intercept queue of the capturing " \
          "gori instance, plus intercept state (enabled/direction/filter) and a liveness " \
          "heartbeat. This is how an agent 'sits in the loop' alongside the human — inspect " \
          "held requests/responses, then forward/drop/edit them (see intercept_forward etc). " \
          "available:false when no bridge has ever been published; capturing:false (with a " \
          "growing heartbeat_age_seconds) when the last capturing instance is no longer live, " \
          "in which case mutating verbs refuse. Header values redacted unless " \
          "include_sensitive:true." do |s|
          s.field "include_sensitive", boolprop("show Authorization/Cookie/etc header values instead of [REDACTED] (default false)")
        end

        tool j, "intercept_get",
          "Full detail for ONE held intercept item (redacted head + body size). Pass " \
          "include_sensitive:true to ALSO get the full raw message base64 (unredacted; edit it " \
          "and send it back as intercept_forward_edit's raw_base64 for a byte-exact round " \
          "trip) — otherwise raw is withheld " \
          "(raw_redacted:true) since base64 is not redaction. NOT_FOUND if the item was " \
          "already forwarded/dropped or never held. Header values redacted unless " \
          "include_sensitive:true." do |s|
          s.field "item_id", intprop("held item id from intercept_list"), required: true
          s.field "include_sensitive", boolprop("show sensitive header values instead of [REDACTED] (default false)")
        end

        return unless @allow_actions

        tool j, "intercept_forward",
          "Forward a currently-held intercept item (from intercept_list) byte-exact, letting " \
          "the request/response continue. The action is applied by the capturing gori instance " \
          "and surfaced as a visible notification to the human operator. Returns the outcome " \
          "(forwarded | no_such_item if it was already released | not_confirmed to retry)." do |s|
          s.field "item_id", intprop("held item id from intercept_list"), required: true
        end

        tool j, "intercept_drop",
          "Drop a currently-held intercept item: the proxy answers the client a canned 502 and " \
          "the message never reaches its destination. Applied by the capturing instance and " \
          "surfaced to the human. Returns dropped | no_such_item | not_confirmed." do |s|
          s.field "item_id", intprop("held item id from intercept_list"), required: true
        end

        tool j, "intercept_forward_edit",
          "Forward a held intercept item with EDITED bytes. Supply the full replacement wire " \
          "message in EITHER `raw_base64` (byte-exact; the round trip for the bytes " \
          "intercept_get returns as raw_base64, and the only channel a binary body survives) " \
          "OR `raw` (plain text, for an ordinary edit). Content-Length is recomputed to match " \
          "the body by default; pass update_content_length:false to forward your framing " \
          "headers untouched (a CL/TE desync). Otherwise the bytes are forwarded byte-exact " \
          "(NO variable expansion — a " \
          "security tool forwards exactly what you send). In `raw`, a lone LF in the HEADER " \
          "block becomes CRLF so a hand-typed message still frames; the BODY is untouched. " \
          "Applied by the capturing instance + surfaced to the human. Returns " \
          "forwarded (edited:true, content_length_synced) | no_such_item | not_confirmed." do |s|
          s.field "item_id", intprop("held item id from intercept_list"), required: true
          s.field "raw", strprop("the full edited HTTP wire message as text (request/status line + headers + body)")
          s.field "raw_base64", strprop("the full edited wire message, base64 — byte-exact; use this for a binary body")
          s.field "update_content_length", boolprop("recompute Content-Length to match the edited body (default true). Set FALSE to hold your own value — a Content-Length shorter or longer than the body, or Content-Length alongside Transfer-Encoding, is the canonical request-smuggling primitive and the reason to hold a request at all. With it false, `raw_base64` really is byte-exact end to end.")
        end

        tool j, "intercept_toggle",
          "Enable or disable the live intercept catch (desired state — idempotent). NOTE: " \
          "enabling only affects NEW connections; an already-established HTTP/2 connection " \
          "stays un-held. Applied by the capturing instance. Returns toggled | busy." do |s|
          s.field "enable", boolprop("true = start holding matching traffic; false = stop (auto-forwards anything currently held)"), required: true
        end

        tool j, "intercept_set_filter",
          "Set the conditional-intercept filter — a gori-QL-like query that NARROWS which " \
          "in-flight messages are held (e.g. 'host:api.example.com method:POST'). Empty " \
          "clears it (hold everything in scope). Applied by the capturing instance." do |s|
          s.field "query", strprop("filter query; empty string clears the filter"), required: true
        end

        tool j, "intercept_set_direction",
          "Set which leg(s) intercept holds: both | request | response. Applied by the " \
          "capturing instance." do |s|
          s.field "direction", strprop("both | request | response"), required: true
        end
      end
    end
  end
end
