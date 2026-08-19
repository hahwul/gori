require "db"

module Gori
  class Store
    # --- Fuzzer / Intruder (V16) ---------------------------------------------
    # Writes go through exec_task (writer fiber). Own commits bump data_version on
    # the read pool (see data_version docs); live TUI paths must soft-sync, not
    # full-restore session UI on every poll.

    # The template is an operator's REQUEST — captured wire bytes seeded by `^F`, so it can
    # hold a NUL (a gRPC/protobuf frame, a gzip'd POST, a multipart PNG). The column is TEXT
    # storage and the driver reads TEXT through a NUL-TERMINATED pointer, so `rs.read(String)`
    # truncated it at the first 0x00 while the write side bound the full bytesize — the bytes
    # were on disk and the read threw them away. Measured: 73 bytes in, 58 out.
    #
    # Same fix, same reason as `RepeaterSessions::REQUEST_COL`, whose column was migrated for
    # exactly this in V2; the Fuzzer was the last workbench still on the broken shape. CAST is
    # a documented no-op on an already-BLOB value, so this is safe on every existing row.
    TEMPLATE_COL = "CAST(template AS BLOB) AS template"

    def fuzz_sessions : Array(FuzzSessionRecord)
      list = [] of FuzzSessionRecord
      @db.query("SELECT id, target, #{TEMPLATE_COL}, http2, sni, config, flow_id, position, name FROM fuzz_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << FuzzSessionRecord.new(
            rs.read(Int64), rs.read(String), String.new(rs.read(Bytes)), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_fuzz_session(id : Int64) : FuzzSessionRecord?
      @db.query(
        "SELECT id, target, #{TEMPLATE_COL}, http2, sni, config, flow_id, position, name FROM fuzz_sessions WHERE id = ?",
        id) do |rs|
        return FuzzSessionRecord.new(
          rs.read(Int64), rs.read(String), String.new(rs.read(Bytes)), rs.read(Int32) != 0,
          rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?)) if rs.move_next
      end
      nil
    end

    def insert_fuzz_session(target : String, template : String, http2 : Bool, sni : String?,
                            config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_sessions (created_at, updated_at, target, template, http2, sni, config, flow_id, position, name) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, template, http2 ? 1 : 0, sni, config, flow_id, position, name)
        nil
      }
    end

    def update_fuzz_session(id : Int64, target : String, template : String, http2 : Bool,
                            sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_sessions SET target=?, template=?, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?",
          target, template, http2 ? 1 : 0, sni, config, name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a fuzz session's custom sub-tab name — its own UPDATE,
    # separate from update_fuzz_session so a rename never rewrites the template/config
    # (mirrors set_repeater_name).
    #
    # Returns whether the write committed (false = store busy/locked/closing), like
    # `set_repeater_name` next door: this went through `exec_task`, whose Int64 reply is
    # `last_insert_rowid` and so says nothing at all about an UPDATE. The caller
    # (`FuzzerController#apply_rename`) has already put the new label on the view, so a
    # rolled-back batch leaves the chip reading a name the project never took — silently,
    # until the session reloads. It needs the answer to say so.
    def set_fuzz_session_name(id : Int64, name : String?) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Cascades `entity_links`, for `delete_repeater`'s reason (repeater_sessions.cr states it
    # in full): `fuzz_sessions.id` is `INTEGER PRIMARY KEY` WITHOUT AUTOINCREMENT, and closing
    # a sub-tab (^W) deletes at the TOP of the id space, so the very next ^N is handed the id
    # that just went. A link left behind therefore does not settle at `fuzz #1 (gone)` — it
    # re-binds, `stale: false`, to a session against a DIFFERENT target, and an issue's
    # evidence confidently names traffic the operator never linked (links overlay, exports,
    # MCP `list_links`). Losing the pointer is strictly better than a pointer that starts lying.
    #
    # Both statements in ONE exec_task: the writer batches ops into a single transaction, so a
    # rollback that spares the link row while the session goes is exactly the stranded state
    # this exists to prevent. Matched on ref_kind AND ref_id — session ids collide across
    # kinds (every workbench table starts at 1), so ref_id alone would take a live miner/flow
    # ref with it.
    # Deletes a session AND everything hanging off it: `fuzz_runs.session_id` → `fuzz_results.run_id`.
    # Without the cascade, closing a Fuzzer tab removed the session row and left every run and
    # every result behind — and `fuzz_results` holds `request`, `response_head` and `response_body`,
    # which is the dominant byte cost of a fuzzing project (it is why the compress popup lists
    # "Fuzzer responses" as its own category). Nothing else could ever reach them: the retention
    # sweep only walks flows/ws/h2, and every read here filters by `session_id`, so the rows were
    # invisible in the UI as well as unbounded. Measured on three tiny results — 16.5 kB kept for a
    # session that no longer existed; a real sweep is thousands of results with real bodies.
    #
    # The second pair of statements reaps rows ALREADY stranded by an older build, so a project
    # heals the next time a tab is closed rather than needing a compact. `fuzz_sessions.id` is
    # AUTOINCREMENT (V10), so a dangling `session_id` can never be re-pointed at a new session —
    # this is a space leak, not the evidence-contamination class.
    #
    # Returns whether the delete COMMITTED, like `delete_repeater` next door: a rolled-back batch
    # leaves the row, so the tab the operator closed comes back on the next project open.
    def delete_fuzz_session(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM fuzz_results WHERE run_id IN (SELECT id FROM fuzz_runs WHERE session_id = ?)", id)
        c.exec("DELETE FROM fuzz_runs WHERE session_id = ?", id)
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'fuzz' AND ref_id = ?", id)
        c.exec("DELETE FROM fuzz_sessions WHERE id = ?", id)
        # Already-stranded rows from before the cascade existed. RUNS FIRST, then results:
        # a stranded run still exists in `fuzz_runs` (only its session is gone), so reaping
        # results first would find none orphaned by `run_id` and then the run's removal would
        # strand them with nothing left to sweep. The spec caught exactly that ordering.
        c.exec("DELETE FROM fuzz_runs WHERE session_id IS NOT NULL AND session_id NOT IN (SELECT id FROM fuzz_sessions)")
        c.exec("DELETE FROM fuzz_results WHERE run_id NOT IN (SELECT id FROM fuzz_runs)")
        nil
      }
    end
  end
end
