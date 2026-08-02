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
      #     back `0xC3 0xBF`). The TUI refuses to even open its editor on a binary WS message
      #     for the identical reason (`read_only_selection?`); `raw` refuses here by name
      #     instead of forwarding the wrong bytes, and `raw_base64` is the byte-exact escape
      #     hatch it already is for a binary HTTP body.
      #
      # Exactly one of `raw`/`raw_base64`, so a caller that sends both is told rather than
      # silently having one ignored.
      private def intercept_edit_bytes(h, row : Store::HeldRow?) : Bytes | Result
        b64 = str(h, "raw_base64").presence
        raw = str(h, "raw").presence
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
    end
  end
end
