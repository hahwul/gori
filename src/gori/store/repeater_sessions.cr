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
      @db.query("SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, response_head, response_body, response_error, response_duration_us, name, sni, tags, ws_keep_key, ws_http_only FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            rs.read(Bytes?), rs.read(Bytes?), rs.read(String?), rs.read(Int64?), rs.read(String?), rs.read(String?),
            tags: rs.read(String?), ws_keep_key: rs.read(Int32) != 0, ws_http_only: rs.read(Int32) != 0)
        end
      end
      list
    end

    # Request-side metadata only (no response BLOBs) — for the 750ms reconcile poll,
    # which only converges target/request/flags/position and never reads the
    # response (responses are personal per session). Response fields stay nil.
    def get_repeater(id : Int64) : RepeaterRecord?
      @db.query(
        "SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, sni, name, ws_keep_key, ws_http_only FROM repeaters WHERE id = ?",
        id) do |rs|
        return RepeaterRecord.new(
          rs.read(Int64), rs.read(String), rs.read(Bytes),
          rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
          sni: rs.read(String?), name: rs.read(String?), ws_keep_key: rs.read(Int32) != 0,
          ws_http_only: rs.read(Int32) != 0) if rs.move_next
      end
      nil
    end

    # One full Repeater row including its persisted response body. MCP uses this
    # for explicit, paged body reads; unlike `repeaters`, it never materializes all
    # repeater response BLOBs just to retrieve one continuation chunk.
    def get_repeater_full(id : Int64) : RepeaterRecord?
      @db.query(
        "SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, " \
        "response_head, response_body, response_error, response_duration_us, name, sni, tags, ws_keep_key, ws_http_only " \
        "FROM repeaters WHERE id = ?", id) do |rs|
        if rs.move_next
          return RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            rs.read(Bytes?), rs.read(Bytes?), rs.read(String?), rs.read(Int64?), rs.read(String?), rs.read(String?),
            tags: rs.read(String?), ws_keep_key: rs.read(Int32) != 0, ws_http_only: rs.read(Int32) != 0)
        end
      end
      nil
    end

    def repeaters_meta : Array(RepeaterRecord)
      list = [] of RepeaterRecord
      @db.query("SELECT id, target, #{REQUEST_COL}, http2, auto_content_length, flow_id, position, sni, ws_keep_key, ws_http_only FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?), ws_keep_key: rs.read(Int32) != 0, ws_http_only: rs.read(Int32) != 0)
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
        "name, tags, response_head, response_error, response_duration_us, ws_keep_key, ws_http_only FROM repeaters ORDER BY position, id") do |rs|
        rs.each do
          list << RepeaterRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?), name: rs.read(String?), tags: rs.read(String?),
            response_head: rs.read(Bytes?), response_error: rs.read(String?), response_duration_us: rs.read(Int64?),
            ws_keep_key: rs.read(Int32) != 0, ws_http_only: rs.read(Int32) != 0)
        end
      end
      list
    end

    # Returns the new row id (or 0 if the store is closing — the caller normalizes
    # 0 → nil so a later update never targets a bogus row).
    def insert_repeater(target : String, request : Bytes, http2 : Bool,
                        auto_cl : Bool, flow_id : Int64?, position : Int32, sni : String? = nil,
                        ws_keep_key : Bool = false, ws_http_only : Bool = false) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, auto_content_length, flow_id, position, sni, ws_keep_key, ws_http_only) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, flow_id, position, sni, ws_keep_key ? 1 : 0, ws_http_only ? 1 : 0)
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def update_repeater(id : Int64, target : String, request : Bytes, http2 : Bool, auto_cl : Bool,
                        sni : String? = nil, ws_keep_key : Bool = false,
                        ws_http_only : Bool = false) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE repeaters SET target = ?, request = ?, http2 = ?, auto_content_length = ?, sni = ?, ws_keep_key = ?, ws_http_only = ?, updated_at = ? WHERE id = ?",
          target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, sni, ws_keep_key ? 1 : 0, ws_http_only ? 1 : 0, now_us, id)
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

    # Returns whether the write committed (false = store busy/locked/closing).
    #
    # Cascades `entity_links`, unlike the deliberately-dangling FLOW case, and the difference
    # is id REUSE. `repeaters.id` is `INTEGER PRIMARY KEY` without AUTOINCREMENT, and repeaters
    # are routinely deleted at the TOP of the id space — closing the newest tab — which resets
    # the counter immediately. So a link left pointing at repeater #1 read `#1 (gone)` for as
    # long as it took to open one more tab, and then resolved, `stale: false`, to an
    # UNRELATED request: an issue's evidence pointer confidently naming a different URL, in
    # the TUI overlay, both exports and MCP `list_links`.
    #
    # Flows can afford to dangle because their ids never come back: both prune paths delete
    # from the bottom (`WHERE id <= cutoff`), so `MAX(id)` always survives and the next insert
    # is `max + 1`. "Gone" is genuinely more informative than absent THERE. Here it is a
    # pointer that silently starts lying, which is worse than either.
    def delete_repeater(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM ws_messages WHERE repeater_id = ?", id)
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'repeater' AND ref_id = ?", id)
        c.exec("DELETE FROM repeaters WHERE id = ?", id)
        nil
      }
    end

    # Replace a repeater session's outbound WebSocket messages.
    #
    # The author's payload is persisted VERBATIM — a store row is a claim that those exact
    # bytes are the author's, so a value that happens to match a session binding must NOT be
    # masked to `$KEY` here. `Env.mask_secrets` is a draft-/display-time transform; running
    # it on this WRITE path rewrote a live value the author typed (or, when seeded from a
    # `--flow`, a capture's own bytes) into `$CTOK`, which every later send (the TUI evidence
    # path, `gori run`, MCP) then put on the wire instead of what the author wrote. Binding
    # substitution belongs at the SEND seam (`Repeater::Sender#expand_messages` /
    # `RepeaterView#ws_out_messages`), which expands `$KEY` unless the frame is evidence.
    # This mirrors `insert_repeater` (request bytes stored verbatim) and `insert_ws_one`
    # (a captured frame stored verbatim).
    #
    # The V7 shape columns ride along, through the same `bind_ws_shape` the capture writer
    # uses. A session is the only place a `declared_len` can live at all — a length header
    # that disagrees with its payload cannot be read back off a wire, so it is authored once
    # and has to survive the round trip through here or it is not expressible twice.
    def update_repeater_ws_messages(id : Int64, messages : Array(WsOutMessage)) : Nil
      exec_task ->(conn : DB::Connection) {
        conn.exec("DELETE FROM ws_messages WHERE repeater_id = ?", id)
        messages.each do |msg|
          ts = now_us
          # See insert_ws_one: an empty payload binds SQL NULL and violates the NOT NULL
          # column (an empty repeater message text hits this), so store X'' for it.
          slice = msg.payload
          empty = slice.empty?
          args = [0_i64, id, ts, "out", msg.opcode] of DB::Any
          args << slice unless empty
          Store.bind_ws_shape(args, msg.shape)
          conn.exec(
            "INSERT INTO ws_messages (flow_id, repeater_id, created_at, direction, opcode, payload, " \
            "fin, rsv, masked, mask_key, frames, declared_len) " \
            "VALUES (?,?,?,?,?,#{empty ? "X''" : "?"},?,?,?,?,?,?)", args: args
          )
        end
        nil
      }
    end
  end
end
