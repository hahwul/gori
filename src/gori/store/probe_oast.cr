require "db"

module Gori
  class Store
    # --- probe OAST probes (V12) ---------------------------------------------
    #
    # The durable half of an out-of-band active check: a payload gori planted in a target and
    # the finding it promotes to if that payload ever calls home. See the V12 migration comment
    # for why this state has to outlive the scan that created it.

    # How many outstanding probes one sweep considers. Outstanding means "sent, never called
    # back", which for a real assessment is tens of rows — but a project that probed a large
    # surface with no listener behind it accumulates them without bound, and the sweep runs on a
    # timer. Newest-first so the cap drops the OLDEST unanswered probes, which are also the ones
    # least likely to still be live (a callback usually lands within seconds).
    PROBE_OAST_PENDING_CAP = 1000

    # One outstanding (or already promoted) OAST probe.
    record ProbeOastRecord,
      id : Int64,
      created_at : Int64,
      token : String,
      payload : String,
      session_id : Int64,
      rule_id : String,
      code : String,
      category : String,
      title : String,
      severity : Severity,
      host : String,
      url : String,
      evidence : String?,
      flow_id : Int64?,
      matched_at : Int64?

    PROBE_OAST_COLS = "id, created_at, token, payload, session_id, rule_id, code, category, " \
                      "title, severity, host, url, evidence, flow_id, matched_at"

    # Record a payload that just went out. INSERT OR IGNORE on the UNIQUE token: a re-planned
    # probe mints a fresh token every time, so a collision means the same payload was recorded
    # twice (a retried send) and the first row already carries everything the second would.
    def insert_probe_oast_probe(token : String, payload : String, session_id : Int64,
                                rule_id : String, code : String, category : String,
                                title : String, severity : Severity, host : String,
                                url : String, evidence : String?, flow_id : Int64?) : Nil
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO probe_oast_probes (created_at, token, payload, session_id, " \
               "rule_id, code, category, title, severity, host, url, evidence, flow_id) " \
               "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
          ts, token, payload, session_id, rule_id, code, category, title, severity.value,
          host, url, evidence, flow_id)
        # Evict OUTSTANDING probes past the pending cap in the same write. Un-answered rows are
        # the unbounded axis (a project probing a large surface with no listener behind it plants
        # one per surface and nothing ever matches them); the sweep already only reads the newest
        # cap-worth, so anything older is dead weight the DB would otherwise carry forever.
        # PROMOTED rows are left alone — they are bounded by real findings and are the audit trail
        # tying a callback back to the parameter that drew it.
        c.exec("DELETE FROM probe_oast_probes WHERE matched_at IS NULL AND id NOT IN " \
               "(SELECT id FROM probe_oast_probes WHERE matched_at IS NULL ORDER BY id DESC LIMIT ?)",
          PROBE_OAST_PENDING_CAP)
        nil
      }
    end

    # Probes still waiting for a callback, newest first (see PROBE_OAST_PENDING_CAP).
    def probe_oast_pending(limit : Int32 = PROBE_OAST_PENDING_CAP) : Array(ProbeOastRecord)
      list = [] of ProbeOastRecord
      @db.query("SELECT #{PROBE_OAST_COLS} FROM probe_oast_probes WHERE matched_at IS NULL " \
                "ORDER BY id DESC LIMIT ?", limit) do |rs|
        rs.each { list << read_probe_oast(rs) }
      end
      list
    end

    # Stamp a probe as promoted. The guard in the WHERE clause makes this idempotent: two sweeps
    # racing the same callback (the TUI's timer and a headless scan against the same project)
    # both find the row pending, and only the first UPDATE takes — so the caller can key "did I
    # already emit this issue?" off the affected-row count rather than off its own memory.
    def mark_probe_oast_matched(id : Int64) : Bool
      claimed = false
      # `rows_affected` is read INSIDE the writer closure (the pattern upsert_probe_issue uses
      # for its read-modify-write): exec_task's own return is last_insert_rowid, which says
      # nothing about a conditional UPDATE. The commit flag and the claim flag are separate
      # questions — a rolled-back batch must not report a claim it did not persist.
      ok = exec_task_ok ->(c : DB::Connection) {
        claimed = c.exec("UPDATE probe_oast_probes SET matched_at = ? WHERE id = ? AND matched_at IS NULL",
          now_us, id).rows_affected > 0
        nil
      }
      ok && claimed
    end

    # Drop every probe record for this project (the Probe tab's "clear findings" reaches here
    # too — an outstanding payload whose finding was cleared should not re-appear on the next
    # callback).
    def clear_probe_oast_probes : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM probe_oast_probes"); nil }
    end

    private def read_probe_oast(rs : DB::ResultSet) : ProbeOastRecord
      ProbeOastRecord.new(
        rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int64),
        rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        Severity.new(rs.read(Int32)), rs.read(String), rs.read(String), rs.read(String?),
        rs.read(Int64?), rs.read(Int64?))
    end
  end
end
