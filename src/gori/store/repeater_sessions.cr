require "db"

module Gori
  class Store
    # --- Repeater workbench tabs (persisted + cross-session synced) -------------
    # Writes go through exec_task on the long-lived writer connection. That IS a
    # different connection from the read pool, so PRAGMA data_version (polled on a
    # pool connection) DOES bump for our own commits — the TUI's apply_external_change
    # / reconcile must soft-sync and skip unchanged rows, not assume "own writes are
    # invisible". Callers that full-restore on every poll self-clobber.

    # `repeaters.request` is declared TEXT (schema.cr) but every CURRENT insert/update
    # binds it as `Bytes`, which SQLite stores as BLOB regardless of the column's
    # declared affinity — see the V2 migration's `CAST(request AS BLOB)` comment for the
    # history (an older gori bound it as a Crystal `String`, producing TEXT-storage-class
    # rows that silently truncated at an embedded NUL on read). That migration fixed data
    # existing at upgrade time, but it can't protect a row written LATER by a mismatched
    # writer — e.g. a `gori mcp`/TUI process still running an out-of-date binary against
    # an already-migrated project db, which is exactly how gori is meant to be run
    # long-lived alongside a dev rebuild. Every read below casts defensively so a
    # TEXT-storage-class value coerces to Bytes instead of `rs.read(Bytes)` raising an
    # unhandled DB::ColumnTypeMismatchError — which, left unhandled, doesn't just fail
    # that one row: `repeaters`/`repeaters_meta`/`repeaters_mcp` read ALL rows in a single
    # query, so one bad row crashed the entire CLI/TUI/MCP process and blocked every
    # Repeater operation for the project. CAST is a documented no-op on an
    # already-BLOB-storage value, so this never changes behavior for the common case.
    REQUEST_COL = "CAST(request AS BLOB) AS request"

    # Full repeater rows INCLUDING the persisted response BLOBs. Used once at project
    # open to seed each tab's last response (V11). NOT for the recurring reconcile
    # poll — use `repeaters_meta` there to avoid re-materializing every tab's
    # (potentially multi-MB) response on each cross-session commit.
    def repeaters : Array(RepeaterRecord)
      list = [] of RepeaterRecord
      @db.query("SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, response_head, response_body, response_error, response_duration_us, name, sni, tags FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            rs.read(Bytes?), rs.read(Bytes?), rs.read(String?), rs.read(Int64?), rs.read(String?), rs.read(String?),
            tags: rs.read(String?))
        end
      end
      list
    end

    # Request-side metadata only (no response BLOBs) — for the 750ms reconcile poll,
    # which only converges target/request/flags/position and never reads the
    # response (responses are personal per session). Response fields stay nil.
    def get_repeater(id : Int64) : RepeaterRecord?
      @db.query(
        "SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, sni, name FROM repeaters WHERE id = ?",
        id) do |rs|
        return RepeaterRecord.new(
          rs.read(Int64), rs.read(String), rs.read(Bytes),
          rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
          sni: rs.read(String?), name: rs.read(String?)) if rs.move_next
      end
      nil
    end

    # One full Repeater row including its persisted response body. MCP uses this
    # for explicit, paged body reads; unlike `repeaters`, it never materializes all
    # repeater response BLOBs just to retrieve one continuation chunk.
    def get_repeater_full(id : Int64) : RepeaterRecord?
      @db.query(
        "SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, " \
        "response_head, response_body, response_error, response_duration_us, name, sni, tags " \
        "FROM repeaters WHERE id = ?", id) do |rs|
        if rs.move_next
          return RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            rs.read(Bytes?), rs.read(Bytes?), rs.read(String?), rs.read(Int64?), rs.read(String?), rs.read(String?),
            tags: rs.read(String?))
        end
      end
      nil
    end

    def repeaters_meta : Array(RepeaterRecord)
      list = [] of RepeaterRecord
      @db.query("SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, sni FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?))
        end
      end
      list
    end

    # Persisted repeater tabs for MCP: request-side fields plus the last response HEAD
    # (no response body — keeps the tool lightweight).
    def repeaters_mcp : Array(RepeaterRecord)
      list = [] of RepeaterRecord
      @db.query(
        "SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, sni, " \
        "name, response_head, response_error, response_duration_us FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?), name: rs.read(String?),
            response_head: rs.read(Bytes?), response_error: rs.read(String?), response_duration_us: rs.read(Int64?))
        end
      end
      list
    end

    # Returns the new row id (or 0 if the store is closing — the caller normalizes
    # 0 → nil so a later update never targets a bogus row).
    def insert_repeater(target : String, request : Bytes, http2 : Bool,
                        auto_cl : Bool, flow_id : Int64?, position : Int32, sni : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, auto_content_length, flow_id, position, sni) VALUES (?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, flow_id, position, sni)
        nil
      }
    end

    def update_repeater(id : Int64, target : String, request : Bytes, http2 : Bool, auto_cl : Bool,
                        sni : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE repeaters SET target = ?, request = ?, http2 = ?, auto_content_length = ?, sni = ?, updated_at = ? WHERE id = ?",
          target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, sni, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a repeater tab's custom name — its own UPDATE, separate
    # from the request-side update_repeater so a rename never rewrites the request.
    def set_repeater_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE repeaters SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a repeater tab's flat tags (V31) — its own narrow UPDATE,
    # like set_repeater_name, so tagging never rewrites the request. `tags` is the
    # space-joined token set; nil/blank clears it.
    def set_repeater_tags(id : Int64, tags : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE repeaters SET tags = ?, updated_at = ? WHERE id = ?", tags, now_us, id)
        nil
      }
    end

    # Persist a repeater tab's LAST send result (V11) so it survives a reopen. Kept
    # separate from update_repeater (the request side) — called once each send
    # completes. `head` is the response head bytes (empty on error), `error` is set
    # only when the send failed. Via exec_task (writer connection), so this DOES
    # bump the TUI data_version poll; Repeater reconcile soft-syncs around it.
    def update_repeater_response(id : Int64, head : Bytes, body : Bytes?, error : String?, duration_us : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE repeaters SET response_head = ?, response_body = ?, response_error = ?, response_duration_us = ?, updated_at = ? WHERE id = ?",
          head, body, error, duration_us, now_us, id)
        nil
      }
    end

    def delete_repeater(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM ws_messages WHERE repeater_id = ?", id)
        c.exec("DELETE FROM repeaters WHERE id = ?", id)
        nil
      }
    end

    def update_repeater_ws_messages(id : Int64, messages : Array(String)) : Nil
      exec_task ->(conn : DB::Connection) {
        conn.exec("DELETE FROM ws_messages WHERE repeater_id = ?", id)
        messages.each do |msg_text|
          masked_msg = Env.mask_secrets(msg_text)
          ts = now_us
          # See insert_ws_one: an empty payload binds SQL NULL and violates the NOT NULL
          # column (an empty repeater message text hits this), so store X'' for it.
          slice = masked_msg.to_slice
          empty = slice.empty?
          args = [0_i64, id, ts, "out", 1] of DB::Any
          args << slice unless empty
          conn.exec(
            "INSERT INTO ws_messages (flow_id, repeater_id, created_at, direction, opcode, payload) " \
            "VALUES (?,?,?,?,?,#{empty ? "X''" : "?"})", args: args
          )
        end
        nil
      }
    end
  end
end
