require "db"
require "json"

module Gori
  class Store
    # --- #123 live-intercept bridge (cross-process: MCP writes, the capturing TUI drains) ---

    INTERCEPT_BRIDGE_KEY = "intercept_bridge"

    # Mirror the currently-held intercept queue for `token` into intercept_held so the MCP
    # process can list/get it. Each item's raw BLOB is written exactly ONCE (held bytes are
    # immutable), items no longer held are DELETEd, and so are rows from any other
    # (dead-session) token — all in one writer transaction, so a rapid hold/forward cycle
    # doesn't re-write large bodies every publish.
    #
    # `edited` is the one column a republish must be able to CHANGE — it tracks whether the
    # operator has unsaved edits on that hold, which flips long after the row was first
    # written — so the upsert updates it and leaves everything else, `raw` above all, alone.
    # As a plain `INSERT OR IGNORE` the flag was frozen at whatever it was when the item was
    # first mirrored, which for every hold is `false`.
    #
    # The `WHERE` on that DO UPDATE is what keeps the paragraph above true. Without it SQLite
    # takes the update branch for every already-present row on every republish — reading the
    # existing record and rewriting it, held BLOB included — and a condition typed into the
    # catch bar republishes on every keystroke. With it, an unchanged flag is a no-op again,
    # exactly as `OR IGNORE` was.
    def publish_intercept_held(token : String, rows : Array(HeldRow)) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM intercept_held WHERE session_token <> ?", token)
        if rows.empty?
          c.exec("DELETE FROM intercept_held WHERE session_token = ?", token)
        else
          keep = [token.as(DB::Any)]
          rows.each { |r| keep << r.item_id }
          placeholders = Array.new(rows.size, "?").join(",")
          c.exec("DELETE FROM intercept_held WHERE session_token = ? AND item_id NOT IN (#{placeholders})", args: keep)
          rows.each do |r|
            # `raw` through `Store.blob_slot`: the column is `BLOB NOT NULL`, an empty slice binds
            # SQL NULL, and the `OR IGNORE` this INSERT used to carry then SWALLOWED the
            # violation — the row simply never appeared. A zero-length WebSocket frame is valid
            # (RFC 6455; the same empty heartbeat
            # `insert_ws_one` has its own `X\'\'` branch for) and it is held like any other, so
            # `intercept_list`/`intercept_get` and `gori run intercept` saw a queue with that item
            # MISSING while the gate kept its fiber blocked — nothing on those surfaces could
            # forward or drop it. Measured: publishing an empty frame and a normal one left only
            # the normal one visible.
            args = [token, r.item_id, r.kind, r.method, r.host, r.port, r.scheme, r.target, r.flow_id] of DB::Any
            slot = Store.blob_slot(args, r.raw)
            args << r.held_at_ms << (r.edited ? 1 : 0) << r.edit_refusal << (r.head_only? ? 1 : 0) << (r.binary? ? 1 : 0)
            c.exec("INSERT INTO intercept_held (session_token, item_id, kind, method, host, port, scheme, target, flow_id, raw, held_at_ms, edited, edit_refusal, head_only, binary) " \
                   "VALUES (?,?,?,?,?,?,?,?,?,#{slot},?,?,?,?,?) " \
                   "ON CONFLICT(session_token, item_id) DO UPDATE SET edited = excluded.edited " \
                   "WHERE intercept_held.edited IS NOT excluded.edited", args: args)
          end
        end
        nil
      }
    end

    def intercept_held(token : String) : Array(HeldRow)
      rows = [] of HeldRow
      @db.query("SELECT session_token, item_id, kind, method, host, port, scheme, target, flow_id, raw, held_at_ms, edited, viewed_ms, edit_refusal, head_only, binary FROM intercept_held WHERE session_token = ? ORDER BY item_id", token) do |rs|
        rs.each { rows << read_held(rs) }
      end
      rows
    end

    # {item_id => viewed_ms} for one session's held rows — the auto-forward reaper's whole
    # question, without the `raw` BLOB.
    #
    # The reaper runs on the cross-process cadence (every 750ms) for as long as anything is
    # held and the human is not on the intercept tab, and it used to ask `intercept_held`, which
    # SELECTs every column. A held multi-MiB response therefore came off disk, through SQLite
    # and into a fresh `Bytes` copy per Item, better than once a second — to read one Int64 per
    # row that the query below reads directly.
    def intercept_viewed_ms(token : String) : Hash(Int64, Int64)
      viewed = {} of Int64 => Int64
      @db.query("SELECT item_id, viewed_ms FROM intercept_held WHERE session_token = ?", token) do |rs|
        rs.each { viewed[rs.read(Int64)] = rs.read(Int64) }
      end
      viewed
    end

    # Stamp `viewed_ms` on held items an MCP intercept_list/get just returned — the agent's
    # liveness signal for the auto-forward reaper. Best-effort (no-op if a row was released).
    def touch_intercept_held(token : String, item_ids : Array(Int64), now_ms : Int64) : Nil
      return if item_ids.empty?
      exec_task ->(c : DB::Connection) {
        args = [now_ms.as(DB::Any), token.as(DB::Any)]
        item_ids.each { |i| args << i }
        placeholders = Array.new(item_ids.size, "?").join(",")
        c.exec("UPDATE intercept_held SET viewed_ms = ? WHERE session_token = ? AND item_id IN (#{placeholders})", args: args)
        nil
      }
    end

    private def read_held(rs : DB::ResultSet) : HeldRow
      token = rs.read(String); item_id = rs.read(Int64); kind = rs.read(String)
      method = rs.read(String); host = rs.read(String); port = rs.read(Int32)
      scheme = rs.read(String); target = rs.read(String); flow_id = rs.read(Int64?)
      raw = rs.read(Bytes); held_at_ms = rs.read(Int64); edited = rs.read(Int32) != 0
      viewed_ms = rs.read(Int64)
      edit_refusal = rs.read(String?); head_only = rs.read(Int32) != 0
      binary = rs.read(Int32) != 0
      HeldRow.new(token, item_id, kind, method, host, port, scheme, target, raw, held_at_ms, flow_id, edited, viewed_ms,
        edit_refusal, head_only, binary)
    end

    # Append one MCP->TUI intercept command. Returns last_insert_rowid (0 on a dropped write —
    # the MCP verb treats 0 as retryable rather than assuming the command was queued).
    def enqueue_intercept_command(token : String?, verb : String, *, item_id : Int64? = nil,
                                  bytes : Bytes? = nil, arg : String? = nil) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO intercept_commands (created_at, session_token, verb, item_id, bytes, arg) VALUES (?,?,?,?,?,?)",
          now_us, token, verb, item_id, bytes, arg)
        nil
      }
    end

    # Forward cursor over the command queue (id > after_id, oldest-first) — the TUI drain
    # watermark. AUTOINCREMENT ids are never reused, so this can't silently skip a row.
    def intercept_commands_after(after_id : Int64, limit : Int32) : Array(CommandRow)
      rows = [] of CommandRow
      @db.query("SELECT id, session_token, verb, item_id, bytes, arg FROM intercept_commands WHERE id > ? ORDER BY id ASC LIMIT ?",
        args: [after_id, limit.to_i64] of DB::Any) do |rs|
        rs.each do
          rows << CommandRow.new(rs.read(Int64), rs.read(String?), rs.read(String),
            rs.read(Int64?), rs.read(Bytes?), rs.read(String?))
        end
      end
      rows
    end

    def latest_intercept_command_id : Int64
      @db.scalar("SELECT COALESCE(MAX(id), 0) FROM intercept_commands").as(Int64)
    end

    def ack_intercept_command(id : Int64, status : String, result : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE intercept_commands SET status = ?, applied_at = ?, result = ? WHERE id = ?", status, now_us, result, id)
        nil
      }
    end

    # {status, result} for one command — the MCP verb bounded-polls this to resolve
    # forwarded/dropped/no_such_item/… instead of assuming success on a possibly-dropped write.
    def command_status(id : Int64) : {String, String?}?
      @db.query("SELECT status, result FROM intercept_commands WHERE id = ?", id) do |rs|
        return {rs.read(String), rs.read(String?)} if rs.move_next
      end
      nil
    end

    # Wipe the bridge state a prior (now-dead) capture session left behind, so no stale snapshot
    # or command can be acted on. Called by the fresh lock holder before it starts publishing.
    def clear_intercept_state! : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM intercept_held")
        c.exec("DELETE FROM intercept_commands")
        nil
      }
    end

    # The bridge blob (enabled/direction/filter/session_token/pending_count/heartbeat_ms) — a
    # single settings row the lock holder republishes; the config mirror + liveness heartbeat.
    def set_intercept_bridge(json : String) : Nil
      set_setting(INTERCEPT_BRIDGE_KEY, json)
    end

    def intercept_bridge : String?
      setting(INTERCEPT_BRIDGE_KEY)
    end

    # --- the bridge client (the processes that read the queue and send it commands) ----------
    #
    # A capturing instance is "live" only if its bridge says capturing AND the heartbeat is
    # recent — otherwise a queued command would never be applied, leaving a hung hold, so a
    # sender refuses up front instead of enqueuing into the void. A command that was queued is
    # then bounded-polled for its ack: POLLS × SLEEP before it is reported unconfirmed.
    INTERCEPT_LIVE_MS   = 10_000_i64
    INTERCEPT_ACK_POLLS =         30
    INTERCEPT_ACK_SLEEP = 100.milliseconds

    # How long `send_intercept_command` waits for an ack, in the milliseconds a refusal names.
    def self.intercept_ack_budget_ms : Int32
      (INTERCEPT_ACK_POLLS * INTERCEPT_ACK_SLEEP.total_milliseconds).to_i
    end

    # The bridge blob, parsed. Every reader takes a field the same way: a missing or
    # wrongly-typed value reads as its default, never as an error.
    struct InterceptBridgeState
      getter fields : Hash(String, JSON::Any)

      def initialize(@fields : Hash(String, JSON::Any))
      end

      # The capturing session's token as published — nil when absent. A command is enqueued
      # under exactly this value.
      def session_token : String?
        @fields["session_token"]?.try(&.as_s?)
      end

      # The token the held rows are keyed by; "" when none was published, which holds nothing.
      def token : String
        session_token || ""
      end

      def enabled? : Bool
        @fields["enabled"]?.try(&.as_bool?) || false
      end

      def direction : String
        @fields["direction"]?.try(&.as_s?) || "requestonly"
      end

      def filter : String
        @fields["filter"]?.try(&.as_s?) || ""
      end

      def heartbeat_ms : Int64
        @fields["heartbeat_ms"]?.try(&.as_i64?) || 0_i64
      end

      # Whole seconds since the last heartbeat, or nil when none was ever published.
      def heartbeat_age_seconds(now_ms : Int64) : Int64?
        hb = heartbeat_ms
        hb > 0 ? (now_ms - hb) // 1000 : nil
      end

      # Derived from LIVENESS, not the blob's static `capturing: true`: a crashed or closed
      # instance leaves a stale blob behind (nothing writes capturing:false, and cleanup only
      # runs at the NEXT session's startup), so the heartbeat is the authoritative signal.
      def live?(now_ms : Int64 = Time.utc.to_unix_ms) : Bool
        return false unless @fields["capturing"]?.try(&.as_bool?)
        hb = heartbeat_ms
        hb > 0 && (now_ms - hb) < INTERCEPT_LIVE_MS
      end
    end

    # The bridge the capturing instance publishes, parsed; nil when no capturing instance has
    # ever published one, or when what is there cannot be read as an object.
    def intercept_bridge_state : InterceptBridgeState?
      raw = intercept_bridge
      return nil unless raw
      JSON.parse(raw).as_h?.try { |h| InterceptBridgeState.new(h) }
    rescue
      nil
    end

    # Every item the bridge's session currently holds — none when it published no token.
    def intercept_held_items(bridge : InterceptBridgeState) : Array(HeldRow)
      token = bridge.token
      token.empty? ? [] of HeldRow : intercept_held(token)
    end

    # One held item, or nil when the session published no token or no longer holds it
    # (already forwarded or dropped elsewhere).
    def intercept_held_item(bridge : InterceptBridgeState, item_id : Int64) : HeldRow?
      token = bridge.token
      return nil if token.empty?
      intercept_held(token).find { |r| r.item_id == item_id }
    end

    # Why a command got no ack. Each sender words these itself.
    enum InterceptSendFailure
      NotLive      # no bridge, or its heartbeat is stale: nothing would drain the command
      NotEnqueued  # the command write was dropped
      NotConfirmed # queued, but no terminal ack within the poll budget
    end

    # The capturing instance's terminal answer to one command (forwarded, dropped, edited,
    # toggled, filter_set, direction_set, no_such_item, stale, …) and its detail line.
    record InterceptAck, status : String, detail : String?

    # Enqueue one command for the live capturing instance, then bounded-poll its ack, so the
    # sender gets a real outcome rather than assuming success on a write that may have been
    # dropped or never drained. `polls` exists for specs; every sender takes the default.
    # It sleeps on the caller's fiber for up to the whole budget, so only a sender process
    # may call it: the capturing instance drains this queue and would wait on its own ack.
    def send_intercept_command(verb : String, *, item_id : Int64? = nil, bytes : Bytes? = nil,
                               arg : String? = nil,
                               polls : Int32 = INTERCEPT_ACK_POLLS) : InterceptAck | InterceptSendFailure
      bridge = intercept_bridge_state
      return InterceptSendFailure::NotLive unless bridge && bridge.live?
      id = enqueue_intercept_command(bridge.session_token, verb, item_id: item_id, bytes: bytes, arg: arg)
      return InterceptSendFailure::NotEnqueued if id == 0
      polls.times do
        if st = command_status(id)
          return InterceptAck.new(st[0], st[1]) unless st[0] == "pending"
        end
        sleep INTERCEPT_ACK_SLEEP
      end
      InterceptSendFailure::NotConfirmed
    end
  end
end
