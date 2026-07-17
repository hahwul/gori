require "db"

module Gori
  class Store
    # --- probe scan issues (V20) ---------------------------------------------

    # Cap on distinct affected URLs kept per grouped issue (newest accumulate; once full,
    # further hits still bump hit_count but the URL list stops growing).
    PROBE_AFFECTED_CAP = 50
    # Cap on distinct evidence labels accumulated per issue group (see merge_evidence).
    PROBE_EVIDENCE_CAP = 12

    PROBE_COLS = "id, code, category, host, title, severity, status, hit_count, affected, " \
                 "sample_flow_id, evidence, first_seen, last_seen, sample_repeater_id"

    # Group-merge upsert keyed by (code, host): a read-modify-write run INSIDE the writer
    # closure (atomic — the writer is the only writer), which a plain ON CONFLICT can't do
    # because it must dedup+cap the affected-URL JSON and raise severity to the max seen.
    # No-op when (code, host) is in probe_suppressions (hard-deleted this project).
    def upsert_probe_issue(d : Probe::Detection) : Nil
      ts = now_us
      wrote = false
      exec_task ->(c : DB::Connection) {
        if c.query_one?("SELECT 1 FROM probe_suppressions WHERE code = ? AND host = ?",
             d.code, d.host, as: Int64)
          return nil
        end
        existing = c.query_one?(
          "SELECT id, affected, severity, evidence, title FROM probe_issues WHERE code = ? AND host = ?",
          d.code, d.host, as: {Int64, String, Int32, String?, String})
        if existing
          id, aff_json, sev, prev_evidence, prev_title = existing
          urls = parse_affected(aff_json)
          urls << d.url if !urls.includes?(d.url) && urls.size < PROBE_AFFECTED_CAP
          new_sev = sev > d.severity.value ? sev : d.severity.value
          # Keep the title in sync with the highest-severity observation: a code whose title
          # is severity-dependent (reflected_param: HTML ⇒ Medium "Reflected parameter" vs
          # non-HTML ⇒ Low "…(non-HTML context)") must not show an escalated badge next to the
          # lower-severity title. Adopt the incoming title only when it RAISES severity; for
          # fixed-title codes (the vast majority) this is a no-op.
          new_title = d.severity.value > sev ? d.title : prev_title
          # For the type-labeled infoleak codes, accumulate every distinct type seen
          # for this (code, host) group so a later flow's different secret/error type
          # isn't masked by the first-wins COALESCE. Other codes keep their first
          # representative sample.
          new_evidence = accumulate_evidence?(d.code) ? merge_evidence(prev_evidence, d.evidence) : (prev_evidence || d.evidence)
          c.exec("UPDATE probe_issues SET hit_count = hit_count + 1, affected = ?, severity = ?, " \
                 "title = ?, evidence = ?, last_seen = ? WHERE id = ?",
            urls.to_json, new_sev, new_title, new_evidence, ts, id)
        else
          c.exec("INSERT INTO probe_issues (code, category, host, title, severity, status, hit_count, " \
                 "affected, sample_flow_id, evidence, first_seen, last_seen, sample_repeater_id) " \
                 "VALUES (?,?,?,?,?,0,1,?,?,?,?,?,?)",
            d.code, d.category, d.host, d.title, d.severity.value,
            [d.url].to_json, d.flow_id, d.evidence, ts, ts, d.repeater_id)
        end
        wrote = true
        nil
      }
      bump_probe_generation if wrote # after commit (exec_task blocks until writer replies)
    end

    # Codes whose evidence is a TYPE label (not a one-off sample), so a (code, host)
    # group should list every distinct type seen rather than pin to the first.
    private def accumulate_evidence?(code : String) : Bool
      code == "secret_in_body" || code == "error_stack_leak" || code == "secret_in_ws"
    end

    # Union of distinct evidence labels for one issue group, ", "-joined and capped.
    private def merge_evidence(existing : String?, incoming : String?) : String?
      return existing if incoming.nil? || incoming.empty?
      return incoming if existing.nil? || existing.empty?
      parts = existing.split(", ").map(&.strip).reject(&.empty?)
      return existing if parts.includes?(incoming) || parts.size >= PROBE_EVIDENCE_CAP
      (parts << incoming).join(", ")
    end

    def probe_issues(category : String? = nil, host : String? = nil,
                     min_severity : Severity? = nil) : Array(ProbeIssue)
      conds = [] of String
      args = [] of DB::Any
      if c = category
        conds << "category = ?"; args << c
      end
      if h = host
        conds << "host = ?"; args << h
      end
      if ms = min_severity
        conds << "severity >= ?"; args << ms.value
      end
      where = conds.empty? ? "" : " WHERE #{conds.join(" AND ")}"
      list = [] of ProbeIssue
      @db.query("SELECT #{PROBE_COLS} FROM probe_issues#{where} ORDER BY severity DESC, last_seen DESC",
        args: args) do |rs|
        rs.each { list << read_probe_issue(rs) }
      end
      list
    rescue
      [] of ProbeIssue # never crash the run loop over a read
    end

    def get_probe_issue(id : Int64) : ProbeIssue?
      @db.query("SELECT #{PROBE_COLS} FROM probe_issues WHERE id = ?", id) do |rs|
        return read_probe_issue(rs) if rs.move_next
      end
      nil
    end

    def update_probe_issue_status(id : Int64, status : Status) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE probe_issues SET status = ?, last_seen = ? WHERE id = ?", status.value, now_us, id)
        nil
      }
      bump_probe_generation
    end

    # Bulk-mute every OPEN issue sharing this code (or host) — mark false-positive so the
    # whole group leaves the default open-only view and stays muted across re-hits. A plain
    # delete can't durably mute: `upsert_probe_issue` resurrects the row as `open` on the
    # next matching observation. Already-triaged rows (confirmed/fp/resolved) are left as-is.
    def dismiss_probe_by_code(code : String) : Nil
      bulk_dismiss_probe("code = ?", code)
    end

    def dismiss_probe_by_host(host : String) : Nil
      bulk_dismiss_probe("host = ?", host)
    end

    # `clause` is a fixed internal predicate ("code = ?" / "host = ?"), never user text.
    private def bulk_dismiss_probe(clause : String, arg : DB::Any) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE probe_issues SET status = ?, last_seen = ? WHERE #{clause} AND status = ?",
          Status::FalsePositive.value, now_us, arg, Status::Open.value)
        nil
      }
      bump_probe_generation
    end

    # Hard-delete one issue and durably suppress (code, host) so Active backfill / passive
    # re-hits cannot resurrect it after Project leave/re-open. Suppress + delete are one
    # writer transaction (no window where a concurrent upsert re-inserts mid-delete).
    def delete_probe_issue(id : Int64) : Nil
      ts = now_us
      exec_task ->(c : DB::Connection) {
        if row = c.query_one?("SELECT code, host FROM probe_issues WHERE id = ?", id, as: {String, String})
          code, host = row
          c.exec("INSERT OR IGNORE INTO probe_suppressions (code, host, created_at) VALUES (?,?,?)",
            code, host, ts)
          c.exec("DELETE FROM probe_issues WHERE id = ?", id)
        end
        nil
      }
      bump_probe_generation
    end

    # Wipe every issue AND every hard-delete suppression so a full rescan can re-discover.
    def clear_probe_issues : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM probe_issues")
        c.exec("DELETE FROM probe_suppressions")
        nil
      }
      bump_probe_generation
    end

    # (code, host) pairs hard-deleted this project — Analyzer reloads these on start.
    def probe_suppressions : Array({String, String})
      list = [] of {String, String}
      @db.query("SELECT code, host FROM probe_suppressions") do |rs|
        rs.each { list << {rs.read(String), rs.read(String)} }
      end
      list
    rescue
      [] of {String, String}
    end

    def probe_suppressed?(code : String, host : String) : Bool
      !@db.query_one?("SELECT 1 FROM probe_suppressions WHERE code = ? AND host = ?",
        code, host, as: Int64).nil?
    rescue
      false
    end

    private def bump_probe_generation : Nil
      @probe_generation += 1
    end

    def count_probe_issues : Int32
      @db.scalar("SELECT COUNT(*) FROM probe_issues").as(Int64).to_i
    rescue
      0
    end

    # Probe-issue count per Severity value (index 0=Info … 4=Critical). Small table — a
    # plain scan, GROUP BY on the severity column.
    def probe_severity_counts : StaticArray(Int64, 5)
      severity_tally("SELECT severity, COUNT(*) FROM probe_issues GROUP BY severity")
    end

    # Distinct (tech code, host, evidence) rows — the raw material for the project's
    # "representative technologies" summary (Probe.tech_summary maps them to labels).
    # The host is kept so scope-aware callers (Probe tab, Project AT A GLANCE) can drop
    # rows fingerprinted on out-of-scope hosts before summarizing.
    def probe_tech_rows : Array({String, String, String?})
      rows = [] of {String, String, String?}
      @db.query("SELECT DISTINCT code, host, evidence FROM probe_issues WHERE category = 'tech' ORDER BY code") do |rs|
        rs.each { rows << {rs.read(String), rs.read(String), rs.read(String?)} }
      end
      rows
    rescue
      [] of {String, String, String?}
    end

    def probe_tech_summary : Array(String)
      Probe.tech_summary(probe_tech_rows.map { |(code, _, ev)| {code, ev} })
    end

    private def read_probe_issue(rs : DB::ResultSet) : ProbeIssue
      ProbeIssue.new(
        rs.read(Int64), rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        Severity.new(rs.read(Int32)), Status.new(rs.read(Int32)), rs.read(Int64),
        parse_affected(rs.read(String)), rs.read(Int64?), rs.read(String?),
        rs.read(Int64), rs.read(Int64), rs.read(Int64?))
    end

    private def parse_affected(json : String) : Array(String)
      Array(String).from_json(json)
    rescue
      [] of String
    end
  end
end
