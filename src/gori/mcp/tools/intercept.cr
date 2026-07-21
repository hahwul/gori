require "json"
require "../../store"
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
        raw = str(h, "raw")
        return err("missing required 'raw' (the full edited wire message)", "INVALID_ARGUMENT", field: "raw") if raw.nil? || raw.empty?
        # Normalize line endings to CRLF (like the human intercept editor), then sync
        # Content-Length to the edited body. Bytes are LITERAL — no Env.expand_wire, so a remote
        # agent's $SECRET references are never expanded into forwarded traffic; and no smuggling
        # guard, because byte-exact forwarding of arbitrary edits is the whole point of an
        # intercept editor in a security tool (matches the human forward_bytes contract).
        wire = raw.gsub(/\r?\n/, "\r\n")
        bytes = Fuzz::ContentLength.sync(wire.to_slice, add_when_missing: true)
        enqueue_intercept("forward_edit", item_id: id, bytes: bytes)
      end

      private def intercept_toggle(h) : Result
        want = bool(h, "enable")
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
      private def enqueue_intercept(verb : String, *, item_id : Int64? = nil, bytes : Bytes? = nil, arg : String? = nil) : Result
        bridge = intercept_bridge_state
        unless bridge && intercept_live?(bridge)
          return busy("no live capturing gori instance is draining intercept commands (open the project's TUI with intercept on)")
        end
        token = bridge["session_token"]?.try(&.as_s?)
        id = store.enqueue_intercept_command(token, verb, item_id: item_id, bytes: bytes, arg: arg)
        return busy("could not enqueue intercept command (store write dropped); retry") if id == 0
        await_intercept_ack(id)
      end

      private def await_intercept_ack(id : Int64) : Result
        INTERCEPT_ACK_POLLS.times do
          if st = store.command_status(id)
            return intercept_ack_result(st[0], st[1]) unless st[0] == "pending"
          end
          sleep INTERCEPT_ACK_SLEEP
        end
        err("intercept command not confirmed within #{(INTERCEPT_ACK_POLLS * INTERCEPT_ACK_SLEEP.total_milliseconds).to_i}ms — the capturing instance may be busy; retry",
          "NOT_CONFIRMED", retryable: true)
      end

      private def intercept_ack_result(status : String, detail : String?) : Result
        case status
        when "forwarded"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "detail", detail } })
        when "dropped"
          Result.new(JSON.build { |j| j.object { j.field "status", "dropped"; j.field "detail", detail } })
        when "edited"
          Result.new(JSON.build { |j| j.object { j.field "status", "forwarded"; j.field "edited", true; j.field "detail", detail } })
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
    end
  end
end
