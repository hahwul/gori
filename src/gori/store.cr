require "db"
require "sqlite3"
require "log"
require "json"
require "./store/models"
require "./store/safe_regexp"
require "./store/schema"
require "./ql"

module Gori
  # SQLite-primary storage (P5/P7): raw request/response BYTES are the truth
  # (BLOBs); parsed columns are a queryable projection. SQLite allows a single
  # writer, so all writes funnel through one writer fiber fed by a Channel,
  # while reads go straight through the WAL connection pool.
  class Store
    # Write commands enqueued to the writer fiber.
    abstract struct WriteOp
    end

    struct InsertFlow < WriteOp
      getter req : CapturedRequest
      getter reply : Channel(Int64)

      def initialize(@req, @reply)
      end
    end

    # Atomic bulk import (palette import:har/urls/oas) — every pair commits in one
    # writer transaction so a mid-batch failure rolls back the whole import.
    struct InsertImportBatch < WriteOp
      getter pairs : Array({CapturedRequest, CapturedResponse?})
      getter reply : Channel(Int32)

      def initialize(@pairs, @reply)
      end
    end

    struct UpdateResp < WriteOp
      getter resp : CapturedResponse
      getter reply : Channel(Nil)

      def initialize(@resp, @reply)
      end
    end

    struct InsertWs < WriteOp
      getter flow_id : Int64
      getter replay_id : Int64?
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes
      getter reply : Channel(Nil)

      def initialize(@flow_id, @replay_id, @created_at, @direction, @opcode, @payload, @reply)
      end
    end

    # Fire-and-forget raw h2 frame capture — NO reply channel. The h2 relay must
    # never block on the DB: a per-frame commit round-trip on the forward path
    # throttled browsing to DB-write speed. These queue to the writer (batched
    # there) and are dropped under saturation (best-effort raw log). created_at is
    # stamped at enqueue (caller side), preserving the old timestamp semantics.
    struct InsertH2Frame < WriteOp
      getter conn_id : Int64
      getter created_at : Int64
      getter direction : String
      getter type_octet : Int32
      getter flags : Int32
      getter stream_id : Int64
      getter payload : Bytes

      def initialize(@conn_id, @created_at, @direction, @type_octet, @flags, @stream_id, @payload)
      end
    end

    # Generic write (scope rules / settings / findings) run on the writer
    # connection; reply carries last_insert_rowid (meaningful for INSERTs).
    struct ExecTask < WriteOp
      getter run : DB::Connection -> Nil
      getter reply : Channel(Int64)

      def initialize(@run, @reply)
      end
    end

    # Marks every Pending flow Error (e.g. proxy shutdown before a response landed).
    struct AbandonPending < WriteOp
      getter message : String
      getter reply : Channel(Int32)

      def initialize(@message, @reply)
      end
    end

    BATCH_MAX = 128

    # Keep at most this many newest flows; older ones (and their ws/h2 rows) are
    # pruned so the DB plateaus instead of growing forever (freed pages are
    # reused by later inserts). 0 disables retention. Tunable per Store.open.
    RETENTION_DEFAULT = 100_000
    # Inserts between retention sweeps — amortizes the prune cost.
    PRUNE_INTERVAL = 2_000
    # Per-side ceiling on body text fed to the FTS index (keeps the index small;
    # must match the substr() length in Schema V8's backfill).
    FTS_INDEX_MAX = 64 * 1024

    @events : Channel(FlowEvent)?
    # Second post-commit notification channel feeding the Prism analyzer. Separate from
    # `@events` because a Crystal Channel is single-consumer — the TUI history refresh and
    # Prism can't share one. Same best-effort drop-on-full semantics (see #publish).
    @prism_events : Channel(FlowEvent)?

    # Opens (and migrates) the database. `events`, when given, receives
    # best-effort post-commit notifications for the live TUI; pass nil in
    # headless mode (no consumer => nothing to publish). `prism_events` is the parallel
    # feed for the Prism analyzer (nil when Prism isn't running). `retention_flows` caps
    # the kept history (0 = unlimited).
    def self.open(path : String, events : Channel(FlowEvent)? = nil,
                  prism_events : Channel(FlowEvent)? = nil,
                  retention_flows : Int32 = RETENTION_DEFAULT) : Store
      url = "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
      db = DB.open(url)
      # Make REGEXP byte-safe on every connection before any query runs (so a binary
      # body can't crash a `body~`/`header~` scan or a regex scope rule). See SafeRegexp.
      SafeRegexp.install(db)
      pre_version = db.scalar("PRAGMA user_version").as(Int64).to_i
      Schema.migrate!(db)
      # V25 empties duplicated h2 DATA payloads (often ~40% of the DB), freeing pages but not
      # shrinking the file — reclaim to disk once, only when an EXISTING db (pre_version >= 1)
      # just crossed into the reclaim version. A fresh db (0) has nothing to reclaim; a db
      # already at/after it won't re-run.
      reclaim_to_disk(db) if pre_version >= 1 && pre_version < Schema::RECLAIM_VERSION
      new(db, events, prism_events, retention_flows)
    end

    # Ceiling on the db we auto-VACUUM on the boot path. VACUUM rewrites the WHOLE file
    # (disk-bandwidth-bound) and holds an exclusive lock, so above this we SKIP it rather than
    # freeze startup on a huge project — the freed pages are still reused by later writes, and
    # the operator can VACUUM manually.
    VACUUM_MAX_BYTES = 512_i64 * 1024 * 1024

    # One-time disk reclaim after the V25 payload-emptying migration. NOT run inside migrate!'s
    # transaction (VACUUM is illegal there). Best-effort: a failure (disk full, or a concurrent
    # instance holding the db past busy_timeout) leaves the db fully usable, just un-shrunk.
    private def self.reclaim_to_disk(db : DB::Database) : Nil
      bytes = db.scalar("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()").as(Int64)
      if bytes > VACUUM_MAX_BYTES
        Log.info { "store: skipping post-migration VACUUM (#{bytes // (1024 * 1024)} MiB > #{VACUUM_MAX_BYTES // (1024 * 1024)} MiB cap); freed pages will be reused, or VACUUM manually to reclaim disk" }
        return
      end
      db.exec("VACUUM")
    rescue ex
      Log.warn(exception: ex) { "store: post-migration VACUUM failed (non-fatal; db un-shrunk)" }
    end

    # Count of write batches that failed (e.g. disk full) — surfaced in the TUI
    # so the operator knows capture stopped persisting.
    def write_failures : Int32
      @write_failures.get
    end

    # Raw h2 frames dropped because the writer was saturated. Capture of the raw
    # frame log is best-effort under load; the reconstructed flows stay complete
    # (the assembler accumulates bodies in memory, independent of this log).
    def h2_frames_dropped : Int32
      @h2_frames_dropped.get
    end

    def initialize(@db : DB::Database, @events : Channel(FlowEvent)? = nil,
                   @prism_events : Channel(FlowEvent)? = nil,
                   @retention_flows : Int32 = RETENTION_DEFAULT,
                   @prune_interval : Int32 = PRUNE_INTERVAL)
      @writes = Channel(WriteOp).new(1024) # widened: h2 frames now queue fire-and-forget
      @done = Channel(Nil).new
      @write_failures = Atomic(Int32).new(0)
      @h2_frames_dropped = Atomic(Int32).new(0)
      @inserts_since_prune = 0
      spawn(name: "gori-store-writer") do
        writer_loop
        @done.send(nil)
      end
    end

    # --- write API (called from proxy fibers) --------------------------------

    # Inserts a Pending flow (request captured) and returns its new id.
    # Blocks the caller until the row is committed.
    # The blocking writers tolerate a shutdown race: a proxy fiber may still be
    # capturing when Store#close closes @writes, and a send/receive on a closed
    # channel would otherwise raise into (and tear down) that fiber. Dropping the
    # late row on shutdown is the right degradation (mirrors insert_h2_frame).
    def insert_flow(req : CapturedRequest) : Int64
      reply = Channel(Int64).new(1) # buffered: the writer must never block sending a reply
      @writes.send(InsertFlow.new(req, reply))
      reply.receive
    rescue Channel::ClosedError
      0_i64 # store closing — drop the late row instead of raising into the proxy fiber
    end

    # Insert many flows atomically (one writer transaction). Returns the committed
    # count, or 0 when the store is closing or the batch was rolled back.
    def insert_import_batch(pairs : Array({CapturedRequest, CapturedResponse?})) : Int32
      reply = Channel(Int32).new(1)
      @writes.send(InsertImportBatch.new(pairs, reply))
      reply.receive
    rescue Channel::ClosedError
      0_i32
    end

    # Fills in the response side of an existing flow. Blocks until committed.
    def update_response(resp : CapturedResponse) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(UpdateResp.new(resp, reply))
      reply.receive
    rescue Channel::ClosedError
      nil
    end

    # Finalizes every still-Pending flow as Error. Called on proxy shutdown so
    # in-flight captures don't linger as orphan Pending rows. Returns the count
    # abandoned. No-op (0) when the store is already closing.
    def abandon_pending!(message : String) : Int32
      reply = Channel(Int32).new(1)
      @writes.send(AbandonPending.new(message, reply))
      reply.receive
    rescue Channel::ClosedError
      0_i32
    end

    # Records one captured WebSocket message for a flow. Blocks until committed
    # (the forward already happened, so the peer is not delayed).
    def insert_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes, replay_id : Int64? = nil) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(InsertWs.new(flow_id, replay_id, now_us, direction, opcode, payload, reply))
      reply.receive
    rescue Channel::ClosedError
      nil
    end

    # Blocks until every write enqueued before this call has committed. The single
    # writer drains its channel FIFO, so a synchronous round-trip also flushes the
    # fire-and-forget h2-frame writes that precede it (a clean read barrier).
    def flush : Nil
      exec_task ->(_c : DB::Connection) { nil }
    end

    # --- scope rules + settings (display lens) -------------------------------

    # Each rule: {id, kind (include|exclude), match_type (host|string|regex), pattern}.
    # ORDER BY id so the TUI list is stable (insertion order); Scope owns the semantics.
    def scope_rules : Array({Int64, String, String, String})
      rules = [] of {Int64, String, String, String}
      @db.query("SELECT id, kind, match_type, pattern FROM scope_rules ORDER BY id") do |rs|
        rs.each { rules << {rs.read(Int64), rs.read(String), rs.read(String), rs.read(String)} }
      end
      rules
    end

    def add_scope_rule(kind : String, match_type : String, pattern : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO scope_rules (kind, match_type, pattern) VALUES (?, ?, ?)", kind, match_type, pattern); nil
      }
    end

    def update_scope_rule(id : Int64, kind : String, match_type : String, pattern : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE scope_rules SET kind = ?, match_type = ?, pattern = ? WHERE id = ?", kind, match_type, pattern, id); nil
      }
    end

    def remove_scope_rule(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM scope_rules WHERE id = ?", id); nil }
    end

    # --- hostname overrides (per-project /etc/hosts) -------------------------

    # Each override: {id, host (lowercased), ip}. ORDER BY id so the TUI list is
    # stable (insertion order); HostOverrides owns the lookup semantics.
    def host_overrides : Array({Int64, String, String})
      rows = [] of {Int64, String, String}
      @db.query("SELECT id, host, ip FROM host_overrides ORDER BY id") do |rs|
        rs.each { rows << {rs.read(Int64), rs.read(String), rs.read(String)} }
      end
      rows
    end

    # INSERT OR IGNORE — the UNIQUE(host) constraint makes re-adding the same host a
    # no-op (the model dedupes first and surfaces it to the user as a duplicate).
    def add_host_override(host : String, ip : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO host_overrides (host, ip) VALUES (?, ?)", host, ip); nil
      }
    end

    def update_host_override(id : Int64, host : String, ip : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE host_overrides SET host = ?, ip = ? WHERE id = ?", host, ip, id); nil
      }
    end

    def remove_host_override(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM host_overrides WHERE id = ?", id); nil }
    end

    # Key under which the TUI records what the user is currently viewing (active tab,
    # focus pane, selected flow, sub-tab) so a separate `gori mcp` process can report it
    # via get_current_context. Written cross-process through the shared settings table.
    UI_STATE_KEY = "ui_state"

    def setting(key : String) : String?
      @db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    end

    def set_setting(key : String, value : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", key, value, value)
        nil
      }
    end

    # Drop a per-project setting so `setting(key)` reads nil again (the Project settings pane
    # clears a network override this way — reverting the field to inherit the global value).
    def delete_setting(key : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM settings WHERE key = ?", key)
        nil
      }
    end

    # --- findings ------------------------------------------------------------

    def insert_finding(title : String, severity : Severity, host : String?, flow_id : Int64?) : Int64
      ts = now_us
      finding_id = 0_i64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO findings (created_at, updated_at, title, severity, host, flow_id, notes) VALUES (?,?,?,?,?,?,'')",
          ts, ts, title, severity.value, host, flow_id)
        # Capture the finding's own id BEFORE the entity_links insert below overwrites
        # last_insert_rowid: exec_task's generic reply reads it AFTER the closure, so with
        # a flow_id it would otherwise return the link row's id, not the finding's.
        finding_id = c.scalar("SELECT last_insert_rowid()").as(Int64)
        if fid = flow_id
          c.exec(
            "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('finding', ?, 'flow', ?, ?)",
            finding_id, fid, ts)
        end
        nil
      }
      finding_id
    end

    def update_finding(id : Int64, *, title : String? = nil, severity : Severity? = nil,
                       notes : String? = nil, status : Status? = nil) : Nil
      sets = [] of String
      args = [] of DB::Any
      if t = title
        sets << "title = ?"; args << t
      end
      if s = severity
        sets << "severity = ?"; args << s.value
      end
      if n = notes
        sets << "notes = ?"; args << n
      end
      if st = status
        sets << "status = ?"; args << st.value
      end
      return if sets.empty?
      sets << "updated_at = ?"; args << now_us
      args << id
      sql = "UPDATE findings SET #{sets.join(", ")} WHERE id = ?"
      exec_task ->(c : DB::Connection) { c.exec(sql, args: args); nil }
    end

    def delete_finding(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE owner_kind = 'finding' AND owner_id = ?", id)
        c.exec("DELETE FROM findings WHERE id = ?", id)
        nil
      }
    end

    def findings : Array(Finding)
      list = [] of Finding
      @db.query(<<-SQL) do |rs|
        SELECT id, created_at, updated_at, title, severity, host, flow_id, notes, status
        FROM findings ORDER BY severity DESC, created_at DESC
        SQL
        rs.each { list << read_finding(rs) }
      end
      list
    end

    def get_finding(id : Int64) : Finding?
      @db.query("SELECT id, created_at, updated_at, title, severity, host, flow_id, notes, status FROM findings WHERE id = ?", id) do |rs|
        return read_finding(rs) if rs.move_next
      end
      nil
    end

    def count_findings : Int32
      @db.scalar("SELECT COUNT(*) FROM findings").as(Int64).to_i
    end

    # Finding count per Severity value (index 0=Info … 4=Critical) for the Project tab's
    # severity breakdown. Backed by idx_findings_severity.
    def findings_severity_counts : StaticArray(Int64, 5)
      severity_tally("SELECT severity, COUNT(*) FROM findings GROUP BY severity")
    end

    # --- entity links (V21) --------------------------------------------------

    # Insert a link; returns the row id, or nil when the link already exists.
    def add_link(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Int64?
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec(
          "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES (?,?,?,?,?)",
          owner_kind.label, owner_id, ref_kind.label, ref_id, ts)
        nil
      }
      @db.query(
        "SELECT id, created_at FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
        owner_kind.label, owner_id, ref_kind.label, ref_id) do |rs|
        return nil unless rs.move_next
        id = rs.read(Int64)
        created_at = rs.read(Int64)
        return id if created_at == ts
      end
      nil
    end

    def link_id(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Int64?
      @db.query(
        "SELECT id FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
        owner_kind.label, owner_id, ref_kind.label, ref_id) do |rs|
        return rs.read(Int64) if rs.move_next
      end
      nil
    end

    def list_links(owner_kind : LinkOwnerKind, owner_id : Int64) : Array(EntityLink)
      list = [] of EntityLink
      @db.query(
        "SELECT id, owner_kind, owner_id, ref_kind, ref_id, created_at FROM entity_links " \
        "WHERE owner_kind = ? AND owner_id = ? ORDER BY created_at, id",
        owner_kind.label, owner_id) do |rs|
        rs.each { try_read_entity_link(rs).try { |link| list << link } }
      end
      list
    end

    def remove_link(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM entity_links WHERE id = ?", id); nil }
    end

    def remove_link(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec(
          "DELETE FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
          owner_kind.label, owner_id, ref_kind.label, ref_id)
        nil
      }
    end

    def delete_links_for_owner(owner_kind : LinkOwnerKind, owner_id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE owner_kind = ? AND owner_id = ?", owner_kind.label, owner_id)
        nil
      }
    end

    # --- prism scan issues (V20) ---------------------------------------------

    # Cap on distinct affected URLs kept per grouped issue (newest accumulate; once full,
    # further hits still bump hit_count but the URL list stops growing).
    PRISM_AFFECTED_CAP = 50
    # Cap on distinct evidence labels accumulated per issue group (see merge_evidence).
    PRISM_EVIDENCE_CAP = 12

    PRISM_COLS = "id, code, category, host, title, severity, status, hit_count, affected, " \
                 "sample_flow_id, evidence, first_seen, last_seen"

    # Group-merge upsert keyed by (code, host): a read-modify-write run INSIDE the writer
    # closure (atomic — the writer is the only writer), which a plain ON CONFLICT can't do
    # because it must dedup+cap the affected-URL JSON and raise severity to the max seen.
    def upsert_prism_issue(d : Prism::Detection) : Nil
      ts = now_us
      exec_task ->(c : DB::Connection) {
        existing = c.query_one?(
          "SELECT id, affected, severity, evidence FROM prism_issues WHERE code = ? AND host = ?",
          d.code, d.host, as: {Int64, String, Int32, String?})
        if existing
          id, aff_json, sev, prev_evidence = existing
          urls = parse_affected(aff_json)
          urls << d.url if !urls.includes?(d.url) && urls.size < PRISM_AFFECTED_CAP
          new_sev = sev > d.severity.value ? sev : d.severity.value
          # For the type-labeled infoleak codes, accumulate every distinct type seen
          # for this (code, host) group so a later flow's different secret/error type
          # isn't masked by the first-wins COALESCE. Other codes keep their first
          # representative sample.
          new_evidence = accumulate_evidence?(d.code) ? merge_evidence(prev_evidence, d.evidence) : (prev_evidence || d.evidence)
          c.exec("UPDATE prism_issues SET hit_count = hit_count + 1, affected = ?, severity = ?, " \
                 "evidence = ?, last_seen = ? WHERE id = ?",
            urls.to_json, new_sev, new_evidence, ts, id)
        else
          c.exec("INSERT INTO prism_issues (code, category, host, title, severity, status, hit_count, " \
                 "affected, sample_flow_id, evidence, first_seen, last_seen) VALUES (?,?,?,?,?,0,1,?,?,?,?,?)",
            d.code, d.category, d.host, d.title, d.severity.value,
            [d.url].to_json, d.flow_id, d.evidence, ts, ts)
        end
        nil
      }
    end

    # Codes whose evidence is a TYPE label (not a one-off sample), so a (code, host)
    # group should list every distinct type seen rather than pin to the first.
    private def accumulate_evidence?(code : String) : Bool
      code == "secret_in_body" || code == "error_stack_leak"
    end

    # Union of distinct evidence labels for one issue group, ", "-joined and capped.
    private def merge_evidence(existing : String?, incoming : String?) : String?
      return existing if incoming.nil? || incoming.empty?
      return incoming if existing.nil? || existing.empty?
      parts = existing.split(", ").map(&.strip).reject(&.empty?)
      return existing if parts.includes?(incoming) || parts.size >= PRISM_EVIDENCE_CAP
      (parts << incoming).join(", ")
    end

    def prism_issues(category : String? = nil, host : String? = nil,
                     min_severity : Severity? = nil) : Array(PrismIssue)
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
      list = [] of PrismIssue
      @db.query("SELECT #{PRISM_COLS} FROM prism_issues#{where} ORDER BY severity DESC, last_seen DESC",
        args: args) do |rs|
        rs.each { list << read_prism_issue(rs) }
      end
      list
    rescue
      [] of PrismIssue # never crash the run loop over a read
    end

    def get_prism_issue(id : Int64) : PrismIssue?
      @db.query("SELECT #{PRISM_COLS} FROM prism_issues WHERE id = ?", id) do |rs|
        return read_prism_issue(rs) if rs.move_next
      end
      nil
    end

    def update_prism_issue_status(id : Int64, status : Status) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE prism_issues SET status = ?, last_seen = ? WHERE id = ?", status.value, now_us, id)
        nil
      }
    end

    # Bulk-mute every OPEN issue sharing this code (or host) — mark false-positive so the
    # whole group leaves the default open-only view and stays muted across re-hits. A plain
    # delete can't durably mute: `upsert_prism_issue` resurrects the row as `open` on the
    # next matching observation. Already-triaged rows (confirmed/fp/resolved) are left as-is.
    def dismiss_prism_by_code(code : String) : Nil
      bulk_dismiss_prism("code = ?", code)
    end

    def dismiss_prism_by_host(host : String) : Nil
      bulk_dismiss_prism("host = ?", host)
    end

    # `clause` is a fixed internal predicate ("code = ?" / "host = ?"), never user text.
    private def bulk_dismiss_prism(clause : String, arg : DB::Any) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE prism_issues SET status = ?, last_seen = ? WHERE #{clause} AND status = ?",
          Status::FalsePositive.value, now_us, arg, Status::Open.value)
        nil
      }
    end

    def delete_prism_issue(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM prism_issues WHERE id = ?", id); nil }
    end

    def clear_prism_issues : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM prism_issues"); nil }
    end

    def count_prism_issues : Int32
      @db.scalar("SELECT COUNT(*) FROM prism_issues").as(Int64).to_i
    rescue
      0
    end

    # Prism-issue count per Severity value (index 0=Info … 4=Critical). Small table — a
    # plain scan, GROUP BY on the severity column.
    def prism_severity_counts : StaticArray(Int64, 5)
      severity_tally("SELECT severity, COUNT(*) FROM prism_issues GROUP BY severity")
    end

    # Shared fold for the severity-tally queries: a 5-slot array keyed by the Severity
    # enum value (0=Info … 4=Critical). Out-of-range rows are ignored; never crashes a
    # poll (returns zeros on error).
    private def severity_tally(sql : String) : StaticArray(Int64, 5)
      out = StaticArray(Int64, 5).new(0_i64)
      @db.query(sql) do |rs|
        rs.each do
          sev = rs.read(Int32)
          cnt = rs.read(Int64)
          out[sev] = cnt if 0 <= sev < 5
        end
      end
      out
    rescue
      StaticArray(Int64, 5).new(0_i64)
    end

    # Per-project Prism MODE, stored in the generic settings table (key "prism_mode").
    def prism_mode : Prism::Mode
      Prism::Mode.from_setting(setting(Prism::MODE_SETTING_KEY))
    end

    def set_prism_mode(mode : Prism::Mode) : Nil
      set_setting(Prism::MODE_SETTING_KEY, mode.label)
    end

    # Distinct (tech code, host, evidence) rows — the raw material for the project's
    # "representative technologies" summary (Prism.tech_summary maps them to labels).
    # The host is kept so scope-aware callers (Prism tab, Project AT A GLANCE) can drop
    # rows fingerprinted on out-of-scope hosts before summarizing.
    def prism_tech_rows : Array({String, String, String?})
      rows = [] of {String, String, String?}
      @db.query("SELECT DISTINCT code, host, evidence FROM prism_issues WHERE category = 'tech' ORDER BY code") do |rs|
        rs.each { rows << {rs.read(String), rs.read(String), rs.read(String?)} }
      end
      rows
    rescue
      [] of {String, String, String?}
    end

    def prism_tech_summary : Array(String)
      Prism.tech_summary(prism_tech_rows.map { |(code, _, ev)| {code, ev} })
    end

    private def read_prism_issue(rs : DB::ResultSet) : PrismIssue
      PrismIssue.new(
        rs.read(Int64), rs.read(String), rs.read(String), rs.read(String), rs.read(String),
        Severity.new(rs.read(Int32)), Status.new(rs.read(Int32)), rs.read(Int64),
        parse_affected(rs.read(String)), rs.read(Int64?), rs.read(String?),
        rs.read(Int64), rs.read(Int64))
    end

    private def parse_affected(json : String) : Array(String)
      Array(String).from_json(json)
    rescue
      [] of String
    end

    # --- match&replace rules (in-flight head rewrite lens) -------------------

    def match_rules : Array(MatchRule)
      list = [] of MatchRule
      @db.query("SELECT id, enabled, target, pattern, replacement FROM match_rules ORDER BY position, id") do |rs|
        rs.each do
          list << MatchRule.new(
            rs.read(Int64), rs.read(Int32) != 0,
            RuleTarget.from_label(rs.read(String)), rs.read(String), rs.read(String))
        end
      end
      list
    end

    def insert_rule(target : RuleTarget, pattern : String, replacement : String) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO match_rules (enabled, target, pattern, replacement) VALUES (1, ?, ?, ?)",
          target.label, pattern, replacement)
        nil
      }
    end

    def set_rule_enabled(id : Int64, enabled : Bool) : Nil
      exec_task ->(c : DB::Connection) { c.exec("UPDATE match_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    def delete_rule(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM match_rules WHERE id = ?", id); nil }
    end

    # --- Replay workbench tabs (persisted + cross-session synced) -------------
    # All writes route through exec_task (the single writer connection): this keeps
    # them INVISIBLE to our own PRAGMA data_version poll (which only sees other
    # connections), so a session never reconciles its own replay saves — only a
    # peer's. A separate connection would break that and cause self-clobber.

    # Full replay rows INCLUDING the persisted response BLOBs. Used once at project
    # open to seed each tab's last response (V11). NOT for the recurring reconcile
    # poll — use `replays_meta` there to avoid re-materializing every tab's
    # (potentially multi-MB) response on each cross-session commit.
    def replays : Array(ReplayRecord)
      list = [] of ReplayRecord
      @db.query("SELECT id, target, request, http2, auto_content_length, flow_id, position, response_head, response_body, response_error, response_duration_us, name, sni, mark_transform FROM replays ORDER BY position, id") do |rs|
        rs.each do
          list << ReplayRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            rs.read(Bytes?), rs.read(Bytes?), rs.read(String?), rs.read(Int64?), rs.read(String?), rs.read(String?),
            mark_transform: rs.read(Int32) != 0)
        end
      end
      list
    end

    # Request-side metadata only (no response BLOBs) — for the 750ms reconcile poll,
    # which only converges target/request/flags/position and never reads the
    # response (responses are personal per session). Response fields stay nil.
    def get_replay(id : Int64) : ReplayRecord?
      @db.query(
        "SELECT id, target, request, http2, auto_content_length, flow_id, position, sni, mark_transform, name FROM replays WHERE id = ?",
        id) do |rs|
        return ReplayRecord.new(
          rs.read(Int64), rs.read(String), rs.read(String),
          rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
          sni: rs.read(String?), mark_transform: rs.read(Int32) != 0, name: rs.read(String?)) if rs.move_next
      end
      nil
    end

    def replays_meta : Array(ReplayRecord)
      list = [] of ReplayRecord
      @db.query("SELECT id, target, request, http2, auto_content_length, flow_id, position, sni, mark_transform FROM replays ORDER BY position, id") do |rs|
        rs.each do
          list << ReplayRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?), mark_transform: rs.read(Int32) != 0)
        end
      end
      list
    end

    # Persisted replay tabs for MCP: request-side fields plus the last response HEAD
    # (no response body — keeps the tool lightweight).
    def replays_mcp : Array(ReplayRecord)
      list = [] of ReplayRecord
      @db.query(
        "SELECT id, target, request, http2, auto_content_length, flow_id, position, sni, mark_transform, " \
        "name, response_head, response_error, response_duration_us FROM replays ORDER BY position, id") do |rs|
        rs.each do
          list << ReplayRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String),
            rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(Int64?), rs.read(Int32),
            sni: rs.read(String?), mark_transform: rs.read(Int32) != 0, name: rs.read(String?),
            response_head: rs.read(Bytes?), response_error: rs.read(String?), response_duration_us: rs.read(Int64?))
        end
      end
      list
    end

    # Returns the new row id (or 0 if the store is closing — the caller normalizes
    # 0 → nil so a later update never targets a bogus row).
    def insert_replay(target : String, request : String, http2 : Bool,
                      auto_cl : Bool, flow_id : Int64?, position : Int32, sni : String? = nil,
                      mark_transform : Bool = false) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO replays (created_at, updated_at, target, request, http2, auto_content_length, flow_id, position, sni, mark_transform) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, flow_id, position, sni, mark_transform ? 1 : 0)
        nil
      }
    end

    def update_replay(id : Int64, target : String, request : String, http2 : Bool, auto_cl : Bool,
                      sni : String? = nil, mark_transform : Bool = false) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE replays SET target = ?, request = ?, http2 = ?, auto_content_length = ?, sni = ?, mark_transform = ?, updated_at = ? WHERE id = ?",
          target, request, http2 ? 1 : 0, auto_cl ? 1 : 0, sni, mark_transform ? 1 : 0, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a replay tab's custom name — its own UPDATE, separate
    # from the request-side update_replay so a rename never rewrites the request.
    def set_replay_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE replays SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Persist a replay tab's LAST send result (V11) so it survives a reopen. Kept
    # separate from update_replay (the request side) — called once each send
    # completes. `head` is the response head bytes (empty on error), `error` is set
    # only when the send failed. Routes through exec_task like the other replay
    # writes, so it stays invisible to our own data_version poll.
    def update_replay_response(id : Int64, head : Bytes, body : Bytes?, error : String?, duration_us : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE replays SET response_head = ?, response_body = ?, response_error = ?, response_duration_us = ?, updated_at = ? WHERE id = ?",
          head, body, error, duration_us, now_us, id)
        nil
      }
    end

    def delete_replay(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM ws_messages WHERE replay_id = ?", id)
        c.exec("DELETE FROM replays WHERE id = ?", id)
        nil
      }
    end

    def update_replay_ws_messages(id : Int64, messages : Array(String)) : Nil
      exec_task ->(conn : DB::Connection) {
        conn.exec("DELETE FROM ws_messages WHERE replay_id = ?", id)
        messages.each do |msg_text|
          masked_msg = Env.mask_secrets(msg_text)
          ts = now_us
          conn.exec(
            "INSERT INTO ws_messages (flow_id, replay_id, created_at, direction, opcode, payload) VALUES (?,?,?,?,?,?)",
            0_i64, id, ts, "out", 1, masked_msg.to_slice
          )
        end
        nil
      }
    end

    # --- Fuzzer / Intruder (V16) ---------------------------------------------
    # All writes route through exec_task (the single writer fiber), so they stay
    # invisible to our own data_version poll — same as the replay writes.

    def fuzz_sessions : Array(FuzzSessionRecord)
      list = [] of FuzzSessionRecord
      @db.query("SELECT id, target, template, http2, sni, config, flow_id, position, name FROM fuzz_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << FuzzSessionRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_fuzz_session(id : Int64) : FuzzSessionRecord?
      @db.query(
        "SELECT id, target, template, http2, sni, config, flow_id, position, name FROM fuzz_sessions WHERE id = ?",
        id) do |rs|
        return FuzzSessionRecord.new(
          rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int32) != 0,
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
    # (mirrors set_replay_name).
    def set_fuzz_session_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    def delete_fuzz_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM fuzz_sessions WHERE id = ?", id); nil }
    end

    # --- miner sessions (mirror fuzz_sessions; request is a byte-exact BLOB) ---

    def miner_sessions : Array(MinerSessionRecord)
      list = [] of MinerSessionRecord
      @db.query("SELECT id, target, request, http2, sni, config, flow_id, position, name FROM miner_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << MinerSessionRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_miner_session(id : Int64) : MinerSessionRecord?
      @db.query(
        "SELECT id, target, request, http2, sni, config, flow_id, position, name FROM miner_sessions WHERE id = ?",
        id) do |rs|
        return MinerSessionRecord.new(
          rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
          rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?)) if rs.move_next
      end
      nil
    end

    def insert_miner_session(target : String, request : Bytes, http2 : Bool, sni : String?,
                             config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO miner_sessions (created_at, updated_at, target, request, http2, sni, config, flow_id, position, name) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, sni, config, flow_id, position, name)
        nil
      }
    end

    def update_miner_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                             sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE miner_sessions SET target=?, request=?, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?",
          target, request, http2 ? 1 : 0, sni, config, name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a miner session's custom sub-tab name — its own UPDATE so a
    # rename never rewrites the request/config (mirrors set_fuzz_session_name).
    def set_miner_session_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE miner_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    def delete_miner_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM miner_sessions WHERE id = ?", id); nil }
    end

    def insert_fuzz_run(session_id : Int64?, target : String, mode : String, total : Int64?) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, total, sent, matched, errors, status) VALUES (?,?,?,?,?,0,0,0,'running')",
          session_id, now_us, target, mode, total)
        nil
      }
    end

    def update_fuzz_run(id : Int64, sent : Int64, matched : Int64, errors : Int64,
                        status : String, finished_at : Int64? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_runs SET sent=?, matched=?, errors=?, status=?, finished_at=? WHERE id=?",
          sent, matched, errors, status, finished_at, id)
        nil
      }
    end

    def fuzz_runs(session_id : Int64? = nil) : Array(FuzzRunRecord)
      list = [] of FuzzRunRecord
      cols = "id, session_id, created_at, finished_at, target, mode, total, sent, matched, errors, status"
      if session_id
        @db.query("SELECT #{cols} FROM fuzz_runs WHERE session_id = ? ORDER BY id DESC", session_id) { |rs| rs.each { list << read_fuzz_run(rs) } }
      else
        @db.query("SELECT #{cols} FROM fuzz_runs ORDER BY id DESC") { |rs| rs.each { list << read_fuzz_run(rs) } }
      end
      list
    end

    def insert_fuzz_result(run_id : Int64, idx : Int64, payloads : String, status : Int32?,
                           length : Int64, words : Int32, lines : Int32, duration_us : Int64,
                           error : String?, matched : Bool, extracted : String?,
                           request : Bytes? = nil, response_head : Bytes? = nil, response_body : Bytes? = nil) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_results (run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, extracted, request, response_head, response_body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          run_id, idx, payloads, status, length, words, lines, duration_us, error, matched ? 1 : 0, extracted, request, response_head, response_body)
        nil
      }
    end

    def fuzz_results(run_id : Int64, limit : Int32 = 200, offset : Int32 = 0) : Array(FuzzResultRecord)
      list = [] of FuzzResultRecord
      @db.query("SELECT id, run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, extracted, request, response_head, response_body FROM fuzz_results WHERE run_id = ? ORDER BY idx LIMIT ? OFFSET ?", run_id, limit, offset) do |rs|
        rs.each { list << read_fuzz_result(rs) }
      end
      list
    end

    private def read_fuzz_run(rs : DB::ResultSet) : FuzzRunRecord
      FuzzRunRecord.new(
        rs.read(Int64), rs.read(Int64?), rs.read(Int64), rs.read(Int64?), rs.read(String),
        rs.read(String), rs.read(Int64?), rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String))
    end

    private def read_fuzz_result(rs : DB::ResultSet) : FuzzResultRecord
      FuzzResultRecord.new(
        rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(Int32?),
        rs.read(Int64), rs.read(Int32), rs.read(Int32), rs.read(Int64), rs.read(String?),
        rs.read(Int32) != 0, rs.read(String?), rs.read(Bytes?), rs.read(Bytes?), rs.read(Bytes?))
    end

    # --- HTTP/2 raw-frame log ------------------------------------------------

    def insert_h2_connection(host : String, port : Int32, alpn : String) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO h2_connections (created_at, host, port, alpn) VALUES (?,?,?,?)", ts, host, port, alpn)
        nil
      }
    end

    # Records one raw h2 frame, FIRE-AND-FORGET — never blocks the caller (the h2
    # relay pump). The frame queues to the writer (batched there); if the writer is
    # saturated it is DROPPED and a counter bumped, rather than backpressuring the
    # relay's forwarding loop. No reply is awaited (the relay never needs the id).
    def insert_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                        stream_id : UInt32, payload : Bytes) : Nil
      op = InsertH2Frame.new(conn_id, now_us, direction, type.to_i32, flags.to_i32,
        stream_id.to_i64, payload)
      select
      when @writes.send(op)
        # queued
      else
        @h2_frames_dropped.add(1) # writer saturated — drop the raw frame, keep the flow
      end
    rescue Channel::ClosedError
      # store closing (Store#close closed @writes) — drop the late frame instead of
      # raising on the relay fiber mid-shutdown
    end

    # The connection's raw frame log. With `limit`, returns the MOST RECENT `limit`
    # frames (still ascending for display) so the detail view can bound memory on a
    # pathological connection — the caller shows a count-based "older not loaded"
    # note (see count_h2_frames). nil limit = all (the prior behaviour).
    def h2_frames(conn_id : Int64, limit : Int32? = nil) : Array(H2Frame)
      list = [] of H2Frame
      cols = "id, conn_id, created_at, direction, stream_id, type, flags, length, payload"
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM h2_frames WHERE conn_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [conn_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM h2_frames WHERE conn_id = ? ORDER BY id", [conn_id] of DB::Any}
                end
      @db.query(q, args: args) do |rs|
        rs.each do
          list << H2Frame.new(
            rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String),
            rs.read(Int64), rs.read(Int32), rs.read(Int32), rs.read(Int32), rs.read(Bytes))
        end
      end
      list
    end

    def count_h2_frames(conn_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM h2_frames WHERE conn_id = ?", conn_id).as(Int64).to_i
    end

    # The flow's captured WS message log. With `limit`, returns the MOST RECENT
    # `limit` messages (ascending for display) to bound the detail view; nil = all.
    def ws_messages(flow_id : Int64, limit : Int32? = nil) : Array(WsMessage)
      msgs = [] of WsMessage
      cols = "id, flow_id, replay_id, created_at, direction, opcode, payload"
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM ws_messages WHERE flow_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [flow_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM ws_messages WHERE flow_id = ? ORDER BY id", [flow_id] of DB::Any}
                end
      @db.query(q, args: args) do |rs|
        rs.each do
          msgs << WsMessage.new(rs.read(Int64), rs.read(Int64), rs.read(Int64?), rs.read(Int64),
            rs.read(String), rs.read(Int32), rs.read(Bytes))
        end
      end
      msgs
    end

    def ws_messages_for_replay(replay_id : Int64, limit : Int32? = nil) : Array(WsMessage)
      msgs = [] of WsMessage
      cols = "id, flow_id, replay_id, created_at, direction, opcode, payload"
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM ws_messages WHERE replay_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [replay_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM ws_messages WHERE replay_id = ? ORDER BY id", [replay_id] of DB::Any}
                end
      @db.query(q, args: args) do |rs|
        rs.each do
          msgs << WsMessage.new(rs.read(Int64), rs.read(Int64), rs.read(Int64?), rs.read(Int64),
            rs.read(String), rs.read(Int32), rs.read(Bytes))
        end
      end
      msgs
    end

    def count_ws_messages(flow_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM ws_messages WHERE flow_id = ?", flow_id).as(Int64).to_i
    end

    # --- read API (go straight through the pool; WAL allows concurrent reads) -

    SELECT_ROW = <<-SQL
      SELECT id, created_at, scheme, method, host, port, target, status,
             request_size, response_size, state, duration_us, content_type
      FROM flows
      SQL

    # Newest-first page of the History list. `before_id` is a cursor for paging
    # into older rows (stable as new rows append, unlike OFFSET).
    def recent_flows(limit : Int32, before_id : Int64? = nil) : Array(FlowRow)
      rows = [] of FlowRow
      sql = before_id ? "#{SELECT_ROW} WHERE id < ? ORDER BY id DESC LIMIT ?" : "#{SELECT_ROW} ORDER BY id DESC LIMIT ?"
      args = before_id ? [before_id, limit] of DB::Any : [limit] of DB::Any
      @db.query(sql, args: args) do |rs|
        rs.each { rows << read_row(rs) }
      end
      rows
    end

    # Newest-first flows matching a compiled QL filter. `before_id` is a cursor for
    # paging into older matches (stable as new rows append, unlike OFFSET).
    # `raise_on_error` propagates a SQLite execution failure (a malformed FTS phrase,
    # or a pathological query hitting SQLite's expression-tree-depth limit) instead of
    # degrading to no matches. The TUI keeps the default (never crash the live run
    # loop); one-shot CLI callers pass true so a failed query is reported distinctly
    # from a genuinely empty result rather than as a clean "no flows match".
    def search(filter : QL::Filter, limit : Int32, before_id : Int64? = nil, *,
               raise_on_error : Bool = false) : Array(FlowRow)
      rows = [] of FlowRow
      args = filter.args.dup
      if before_id
        args << before_id
        args << limit
        sql = "#{SELECT_ROW} WHERE (#{filter.sql}) AND id < ? ORDER BY id DESC LIMIT ?"
      else
        args << limit
        sql = "#{SELECT_ROW} WHERE #{filter.sql} ORDER BY id DESC LIMIT ?"
      end
      @db.query(sql, args: args) do |rs|
        rs.each { rows << read_row(rs) }
      end
      rows
    rescue ex
      raise ex if raise_on_error
      STDERR.puts "gori: search failed (#{ex.message})"
      [] of FlowRow
    end

    # Single-row projection, e.g. to refresh a row after an :inserted/:updated
    # event without re-reading the whole page.
    def flow_row(id : Int64) : FlowRow?
      @db.query("#{SELECT_ROW} WHERE id = ?", id) do |rs|
        return read_row(rs) if rs.move_next
      end
      nil
    end

    # Full detail incl. raw BLOBs (the truth) for the detail view.
    def get_flow(id : Int64) : FlowDetail?
      @db.query(<<-SQL, id) do |rs|
        SELECT id, created_at, scheme, method, host, port, target, status,
               request_size, response_size, state, duration_us, content_type,
               http_version, request_head, request_body, response_head, response_body,
               h2_conn_id, h2_stream_id, request_body_truncated, response_body_truncated, error,
               sni
        FROM flows WHERE id = ?
        SQL
        return nil unless rs.move_next
        row = read_row(rs)
        http_version = rs.read(String)
        req_head = rs.read(Bytes)
        req_body = rs.read(Bytes?)
        resp_head = rs.read(Bytes?)
        resp_body = rs.read(Bytes?)
        h2_conn = rs.read(Int64?)
        h2_stream = rs.read(Int64?)
        req_trunc = rs.read(Int64) != 0
        resp_trunc = rs.read(Int64) != 0
        err = rs.read(String?)
        sni = rs.read(String?)
        return FlowDetail.new(row, http_version, req_head, req_body, resp_head, resp_body,
          h2_conn, h2_stream, req_trunc, resp_trunc, err, sni)
      end
      nil
    end

    def count : Int64
      @db.scalar("SELECT COUNT(*) FROM flows").as(Int64)
    end

    # Per-status flow counts (e.g. {200 => n, 404 => n, nil => pending}) for the Project
    # tab's status-distribution chart. Backed by idx_flows_status (V8) so it stays cheap
    # on a full history. A nil status is a still-pending flow (no response yet). Never
    # crashes a poll (returns [] on error).
    def flow_status_counts : Array({Int32?, Int64})
      rows = [] of {Int32?, Int64}
      @db.query("SELECT status, COUNT(*) FROM flows GROUP BY status") do |rs|
        rs.each { rows << {rs.read(Int32?), rs.read(Int64)} }
      end
      rows
    rescue
      [] of {Int32?, Int64}
    end

    # SQLite's per-connection change counter (PRAGMA data_version): it bumps when
    # ANOTHER connection — including a second gori instance on the SAME project DB
    # file — commits, but NOT for our own writes through this pool. The TUI polls
    # it to live-refresh when another instance captures into the same project.
    def data_version : Int64
      @db.scalar("PRAGMA data_version").as(Int64)
    rescue
      0_i64 # never crash the run loop over a poll
    end

    # Earliest flow timestamp (unix MICROSECONDS — the flows.created_at unit) for
    # the "project creation" fallback in the Project tab (min(created_at) of
    # captured traffic; nil for brand new). Callers must divide by 1_000_000 for
    # Time.unix (which expects seconds).
    def earliest_created_at : Int64?
      @db.query_one?("SELECT MIN(created_at) FROM flows", as: Int64?)
    end

    # Sum of all captured wire sizes (request + response) across flows. Used for
    # Project tab overview of total data volume (distinct from on-disk DB size).
    def total_size : Int64
      sql = "SELECT COALESCE(SUM(request_size + COALESCE(response_size, 0)), 0) FROM flows"
      @db.scalar(sql).as(Int64)
    end

    # Distinct (host, method, target) endpoints for building the Sitemap tree,
    # honouring an optional filter (the Scope lens). Bounded by `limit` so a huge
    # history can't materialize an unbounded DISTINCT set into memory (a sitemap
    # with thousands of endpoints is already past human-scannable).
    SITEMAP_MAX = 10_000

    def sitemap_entries(filter : QL::Filter = QL::EMPTY, limit : Int32 = SITEMAP_MAX, *,
                        raise_on_error : Bool = false) : Array({String, String, String})
      rows = [] of {String, String, String}
      args = filter.args.dup
      args << limit
      @db.query("SELECT DISTINCT host, method, target FROM flows WHERE #{filter.sql} ORDER BY host, target LIMIT ?",
        args: args) do |rs|
        rs.each { rows << {rs.read(String), rs.read(String), rs.read(String)} }
      end
      rows
    rescue ex
      # The Sitemap's `/` filter feeds user QL here; a malformed FTS phrase or a query
      # too complex for SQLite raises. The live TUI must never crash (degrade to no
      # matches, mirrors #search); the one-shot CLI passes raise_on_error so a failed
      # query reads distinctly from a genuinely empty tree.
      raise ex if raise_on_error
      STDERR.puts "gori: sitemap query failed (#{ex.message})"
      [] of {String, String, String}
    end

    # --- sitemap tags (V17) --------------------------------------------------

    # All path tags as a (host, path) ⇒ tag map, loaded once per Sitemap reload so the
    # tree stamp is an O(1) hash lookup per node (not a query per row).
    def sitemap_tags : Hash({String, String}, String)
      tags = Hash({String, String}, String).new
      @db.query("SELECT host, path, tag FROM sitemap_tags") do |rs|
        rs.each { tags[{rs.read(String), rs.read(String)}] = rs.read(String) }
      end
      tags
    rescue
      Hash({String, String}, String).new # never crash the run loop over a read (mirrors sitemap_entries)
    end

    # Upsert a node's tag; a blank tag clears it (DELETE) so the row never lingers empty.
    def set_sitemap_tag(host : String, path : String, tag : String) : Nil
      exec_task ->(c : DB::Connection) {
        if tag.blank?
          c.exec("DELETE FROM sitemap_tags WHERE host = ? AND path = ?", host, path)
        else
          c.exec("INSERT INTO sitemap_tags (host, path, tag) VALUES (?, ?, ?) " \
                 "ON CONFLICT(host, path) DO UPDATE SET tag = ?", host, path, tag, tag)
        end
        nil
      }
    end

    # Passive-signal tags for a flow, fetched lazily per on-screen row (P8 pull,
    # not push). No tag producer exists this milestone, so this is always empty;
    # the call site is the seam.
    def flags_for(id : Int64) : Array(String)
      [] of String
    end

    # Drains outstanding writes, stops the writer fiber, then closes the DB.
    def close : Nil
      @writes.close
      @done.receive
      @db.close
    end

    # --- internals -----------------------------------------------------------

    private def writer_loop : Nil
      @db.using_connection do |conn|
        # Bound the WAL file so it doesn't grow without limit under sustained
        # writes (the default is 1000 pages; set it explicitly on the writer).
        conn.exec("PRAGMA wal_autocheckpoint=1000") rescue nil
        loop do
          first = @writes.receive?
          break if first.nil? # channel closed: drained, exit

          ops = [first]
          while ops.size < BATCH_MAX && (extra = drain_one)
            ops << extra
          end

          # Batch the burst into one transaction (amortize fsync, P6), then fire
          # replies + events only AFTER commit so nothing observes uncommitted
          # rows (P5). A failed batch must NOT kill the writer fiber — otherwise
          # every blocked caller (and close()) deadlocks. On failure we roll back
          # and unblock each caller with a fallback so the app degrades, not hangs.
          deferred = [] of -> Nil
          committed = false
          begin
            conn.transaction do |tx|
              c = tx.connection
              ops.each do |op|
                case op
                when InsertFlow
                  ins_reply = op.reply
                  id = insert_one(c, op.req)
                  deferred << -> { ins_reply.send(id); publish(FlowEvent.new(id, :inserted)) }
                when InsertImportBatch
                  batch_reply = op.reply
                  inserted = [] of {Int64, Bool}
                  op.pairs.each do |req, resp|
                    id = insert_one(c, req)
                    has_resp = !resp.nil?
                    if resp
                      update_one(c, Store::CapturedResponse.new(
                        flow_id: id, status: resp.not_nil!.status, head: resp.not_nil!.head,
                        body: resp.not_nil!.body, reason: resp.not_nil!.reason,
                        content_type: resp.not_nil!.content_type, ttfb_us: resp.not_nil!.ttfb_us,
                        duration_us: resp.not_nil!.duration_us, state: resp.not_nil!.state,
                        error: resp.not_nil!.error, body_truncated: resp.not_nil!.body_truncated?,
                        body_size: resp.not_nil!.body_size))
                    end
                    inserted << {id, has_resp}
                  end
                  deferred << -> {
                    batch_reply.send(inserted.size.to_i32)
                    inserted.each do |(id, has_resp)|
                      publish(FlowEvent.new(id, :inserted))
                      publish(FlowEvent.new(id, :updated)) if has_resp
                    end
                  }
                when UpdateResp
                  upd_reply = op.reply
                  fid = op.resp.flow_id
                  update_one(c, op.resp)
                  deferred << -> { upd_reply.send(nil); publish(FlowEvent.new(fid, :updated)) }
                when InsertWs
                  ws_reply = op.reply
                  ws_fid = op.flow_id
                  insert_ws_one(c, op)
                  deferred << -> { ws_reply.send(nil); publish(FlowEvent.new(ws_fid, :updated)) }
                when InsertH2Frame
                  insert_h2_frame_one(c, op) # fire-and-forget: no reply, no event
                when ExecTask
                  task_reply = op.reply
                  op.run.call(c)
                  rowid = c.scalar("SELECT last_insert_rowid()").as(Int64)
                  deferred << -> { task_reply.send(rowid) }
                when AbandonPending
                  ab_reply = op.reply
                  ids = abandon_all_pending(c, op.message)
                  deferred << -> {
                    ab_reply.send(ids.size.to_i32)
                    ids.each { |id| publish(FlowEvent.new(id, :updated)) }
                  }
                end
              end
            end
            committed = true
          rescue ex
            STDERR.puts "gori: store write batch failed (#{ops.size} op(s), rolled back): #{ex.message}"
            @write_failures.add(ops.size) # surfaced in the TUI so the operator knows capture stopped
          end
          # publish never raises (see #publish); replies are buffered — so neither
          # branch can block or throw back into the loop.
          if committed
            deferred.each(&.call)
            @inserts_since_prune += ops.count(&.is_a?(InsertFlow))
            if @inserts_since_prune >= @prune_interval
              prune(conn)
              @inserts_since_prune = 0
            end
          else
            ops.each { |op| fail_reply(op) }
          end
        end
      end
    end

    # Retention sweep: keep only the newest `@retention_flows` flows (by id, which
    # is monotonic), cascading to their ws messages and orphaned h2 frames/conns.
    # A failure here must not kill the writer or lose the just-committed batch, so
    # it runs in its own transaction and swallows errors (the next sweep, after
    # another PRUNE_INTERVAL inserts, simply tries again).
    private def prune(conn : DB::Connection) : Nil
      return if @retention_flows <= 0
      max_id = conn.query_one?("SELECT MAX(id) FROM flows", as: Int64?)
      return unless max_id
      cutoff = max_id - @retention_flows
      return if cutoff <= 0
      conn.transaction do |tx|
        c = tx.connection
        # Only CAPTURED ws messages (replay_id IS NULL, real flow_id) cascade with their
        # pruned flow. WebSocket-Replay output rows (update_replay_ws_messages) are stored
        # with the sentinel flow_id = 0 and keyed by replay_id, so a bare `flow_id <= cutoff`
        # (cutoff is always > 0 here) matched EVERY replay row and wiped saved replay traffic
        # on each sweep. Gate on replay_id so replay-owned rows are never reaped by flow retention.
        c.exec("DELETE FROM ws_messages WHERE flow_id <= ? AND replay_id IS NULL", cutoff)
        c.exec("DELETE FROM flows_fts WHERE rowid <= ?", cutoff)
        c.exec("DELETE FROM flows WHERE id <= ?", cutoff)
        # h2 frames/connections key off conn_id, not flow id. Reap a connection's raw
        # log only once it's (a) not referenced by any surviving flow AND (b) INACTIVE
        # — its newest frame is older than the oldest kept flow. Keying (b) on frame
        # recency, not the connection's OPEN time, is the fix: a long-lived in-flight
        # stream (flow not projected yet, but still logging frames) has recent frames,
        # so it's never wiped. The old `h2_connections.created_at < oldest` guard
        # deleted exactly such a stream once retention churn advanced the window past
        # its open time, leaving a dangling h2_conn_id + empty frame log. (b)'s absence
        # of any recent frame still lets genuinely-orphaned connections be reaped.
        oldest = c.query_one?("SELECT MIN(created_at) FROM flows", as: Int64?) || Int64::MAX
        stale = "id NOT IN (SELECT h2_conn_id FROM flows WHERE h2_conn_id IS NOT NULL) " \
                "AND id NOT IN (SELECT conn_id FROM h2_frames WHERE created_at >= ?)"
        c.exec("DELETE FROM h2_frames WHERE conn_id IN (SELECT id FROM h2_connections WHERE #{stale})", oldest)
        c.exec("DELETE FROM h2_connections WHERE #{stale}", oldest)
      end
    rescue ex
      STDERR.puts "gori: retention prune failed (will retry): #{ex.message}"
    end

    # Unblock a caller whose batch was rolled back, with a no-op fallback (no row
    # id, no event). The reply channels are buffered(1) so this never blocks.
    private def fail_reply(op : WriteOp) : Nil
      case op
      when InsertFlow        then op.reply.send(0_i64)
      when InsertImportBatch then op.reply.send(0_i32)
      when UpdateResp        then op.reply.send(nil)
      when InsertWs          then op.reply.send(nil)
      when ExecTask          then op.reply.send(0_i64)
      when AbandonPending    then op.reply.send(0_i32)
      end
    rescue
      # caller gone / channel closed — nothing to unblock
    end

    # Bulk-mark every Pending flow Error; returns the ids touched (for events).
    private def abandon_all_pending(conn : DB::Connection, message : String) : Array(Int64)
      ids = [] of Int64
      conn.query("SELECT id FROM flows WHERE state = ?", FlowState::Pending.value) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      return ids if ids.empty?
      conn.exec(
        "UPDATE flows SET state = ?, error = ?, status = 0 WHERE state = ?",
        FlowState::Error.value, message, FlowState::Pending.value)
      ids
    end

    # Non-blocking receive for batching a burst (no `try_receive?` in stdlib).
    # Returns the next immediately-available op, or nil if none/closed.
    private def drain_one : WriteOp?
      select
      when op = @writes.receive
        op
      else
        nil
      end
    rescue Channel::ClosedError
      nil
    end

    private def insert_one(conn : DB::Connection, req : CapturedRequest) : Int64
      # request_size is the TRUE wire size (body_size when the BLOB was truncated),
      # so the History size column stays honest even for a capped body.
      body_size = req.body_size || req.body.try(&.size.to_i64) || 0_i64
      conn.exec(
        <<-SQL,
        INSERT INTO flows
          (created_at, scheme, host, port, method, target, http_version,
           sni, alpn, tls_version, request_head, request_body, request_size, state,
           h2_conn_id, h2_stream_id, request_body_truncated)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        SQL
        req.created_at, req.scheme, req.host, req.port, req.method, req.target,
        req.http_version, req.sni, req.alpn, req.tls_version,
        req.head, req.body,
        req.head.size.to_i64 + body_size,
        FlowState::Pending.value, req.h2_conn_id, req.h2_stream_id,
        req.body_truncated? ? 1 : 0)
      id = conn.scalar("SELECT last_insert_rowid()").as(Int64)
      # Index the request body text now; the response side is filled in by
      # update_one. Same transaction, so FTS and the row commit together.
      conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, '')", id, request_fts(req))
      id
    end

    private def update_one(conn : DB::Connection, resp : CapturedResponse) : Nil
      body_size = resp.body_size || resp.body.try(&.size.to_i64) || 0_i64
      # No response actually landed (upstream error / human drop build an empty head +
      # nil body): keep response_size NULL so the History SIZE column reads "—", not a
      # misleading "0B" that looks like a real zero-length response.
      response_size = (resp.head.empty? && resp.body.nil?) ? nil : resp.head.size.to_i64 + body_size
      conn.exec(
        <<-SQL,
        UPDATE flows SET
          response_head = ?, response_body = ?, status = ?, reason = ?,
          content_type = ?, response_size = ?, state = ?,
          ttfb_us = ?, duration_us = ?, error = ?, response_body_truncated = ?
        WHERE id = ?
        SQL
        resp.head, resp.body, resp.status, resp.reason, resp.content_type,
        response_size,
        resp.state.value, resp.ttfb_us, resp.duration_us, resp.error,
        resp.body_truncated? ? 1 : 0, resp.flow_id)
      # flows_fts is contentless (V24): FTS5 forbids UPDATE there, so re-write the whole
      # row. insert_one indexed the request side (searchable while Pending); DELETE that
      # row and re-INSERT with BOTH sides. The request text is re-derived from the stored
      # row (update_one only carries the response), capped in SQL so a multi-MB upload
      # isn't pulled back whole. DELETE is a cheap tombstone (contentless_delete=1) and
      # also makes a double update_response idempotent (last write wins).
      resp_fts = (binary_content?(resp.content_type) || encoded?(head_markers(resp.head)[1])) ? "" : fts_text(resp.body)
      req_fts = request_fts_from_row(conn, resp.flow_id)
      conn.exec("DELETE FROM flows_fts WHERE rowid = ?", resp.flow_id)
      conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, ?)", resp.flow_id, req_fts, resp_fts)
    end

    # The request-side FTS text for an already-stored flow, recomputed the same way
    # request_fts does but reading the head + (SQL-capped) body back from the row —
    # update_one has only the response, and contentless FTS can't keep the old req
    # column across a rewrite. A bodyless request (the common GET) reads just the small
    # head; a binary body is skipped (empty), matching request_fts.
    private def request_fts_from_row(conn : DB::Connection, flow_id : Int64) : String
      row = conn.query_one?(
        "SELECT request_head, substr(request_body, 1, ?) FROM flows WHERE id = ?",
        FTS_INDEX_MAX, flow_id, as: {Bytes, Bytes?})
      return "" unless row
      head, body = row
      return "" if body.nil? || body.empty?
      skip_body_fts?(head) ? "" : String.new(body)
    end

    # Body text fed to the FTS index, capped per side so a large body can't bloat
    # the index.
    private def fts_text(bytes : Bytes?) : String
      return "" unless bytes
      String.new(bytes[0, {bytes.size, FTS_INDEX_MAX}.min])
    end

    # The request body's FTS text, skipping the (synchronous, on-commit) trigram
    # tokenization for a clearly-binary body. The head is scanned for Content-Type
    # only when a body actually exists (bodyless GETs cost nothing).
    private def request_fts(req : CapturedRequest) : String
      body = req.body
      return "" if body.nil? || body.empty?
      skip_body_fts?(req.head) ? "" : fts_text(body)
    end

    # Skip body FTS for clearly-binary content types (images/media/archives/
    # octet-stream/protobuf) — never usefully body-searched and the dominant byte
    # volume. Text AND unknown types are still indexed so search isn't quietly lost.
    private def binary_content?(ct : String?) : Bool
      return false unless ct
      c = ct.downcase
      c.starts_with?("image/") || c.starts_with?("video/") || c.starts_with?("audio/") ||
        c.starts_with?("font/") || c.includes?("octet-stream") || c.includes?("pdf") ||
        c.includes?("zip") || c.includes?("protobuf") || c.includes?("grpc") ||
        c.starts_with?("application/wasm")
    end

    # Skip FTS for a body that is binary by content type OR compressed by Content-Encoding —
    # both markers read in ONE pass over the head. A non-identity Content-Encoding means the
    # body is stored in COMPRESSED wire form: high-entropy bytes that explode the trigram
    # index while being unsearchable for readable text (you can't `body:` a gzip stream).
    private def skip_body_fts?(head : Bytes) : Bool
      ct, ce = head_markers(head)
      binary_content?(ct) || encoded?(ce)
    end

    # {Content-Type, Content-Encoding} header values from a raw head BLOB (either nil), read
    # in a single pass so a skip decision costs one scan, not one per header.
    private def head_markers(head : Bytes) : {String?, String?}
      ct = nil.as(String?)
      ce = nil.as(String?)
      String.new(head).each_line do |raw|
        line = raw.chomp
        break if line.empty?
        idx = line.index(':')
        next unless idx
        case line[0...idx].strip.downcase
        when "content-type"     then ct = line[(idx + 1)..].strip
        when "content-encoding" then ce = line[(idx + 1)..].strip
        end
      end
      {ct, ce}
    end

    # A non-identity Content-Encoding ⇒ the body is compressed (skip it from FTS). `ce` comes
    # from head_markers already stripped, so downcase alone suffices.
    private def encoded?(ce : String?) : Bool
      return false unless ce
      c = ce.downcase
      !c.empty? && c != "identity"
    end

    private def insert_ws_one(conn : DB::Connection, op : InsertWs) : Nil
      conn.exec(
        "INSERT INTO ws_messages (flow_id, replay_id, created_at, direction, opcode, payload) VALUES (?,?,?,?,?,?)",
        op.flow_id, op.replay_id, op.created_at, op.direction, op.opcode, op.payload)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end

    # Same columns/casts the old synchronous insert used (so h2_frames readback /
    # to_bytes round-trips are unchanged).
    private def insert_h2_frame_one(conn : DB::Connection, op : InsertH2Frame) : Nil
      # DATA frames (type 0) duplicate flows.response_body / request_body byte-for-byte and
      # are the dominant h2_frames byte cost. The frame-log detail view renders the `length`
      # COLUMN, never the payload, so store an EMPTY payload for them while keeping the TRUE
      # byte count in `length` (op.payload.size). HEADERS/CONTINUATION/SETTINGS/etc keep their
      # payload — tiny, and their bytes exist nowhere else. For DATA use the SQL literal X''
      # (a non-null zero-length BLOB the NOT NULL column accepts): binding Bytes.empty would
      # bind SQL NULL (empty slice ⇒ null pointer) and violate the constraint.
      data = op.type_octet.zero?
      args = [op.conn_id, op.created_at, op.direction, op.stream_id,
              op.type_octet, op.flags, op.payload.size] of DB::Any
      args << op.payload unless data
      conn.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                "VALUES (?,?,?,?,?,?,?,#{data ? "X''" : "?"})", args: args)
    end

    # Runs a write closure on the writer connection; returns last_insert_rowid.
    private def exec_task(run : DB::Connection -> Nil) : Int64
      reply = Channel(Int64).new(1) # buffered: the writer must never block sending a reply
      @writes.send(ExecTask.new(run, reply))
      reply.receive
    rescue Channel::ClosedError
      0_i64 # store closing — caller (settings/findings/flush) degrades, doesn't raise
    end

    private def read_finding(rs : DB::ResultSet) : Finding
      Finding.new(
        rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String),
        Severity.new(rs.read(Int32)), rs.read(String?), rs.read(Int64?), rs.read(String),
        Status.new(rs.read(Int32)))
    end

    private def try_read_entity_link(rs : DB::ResultSet) : EntityLink?
      id = rs.read(Int64)
      owner = LinkOwnerKind.parse(rs.read(String))
      owner_id = rs.read(Int64)
      ref = LinkRefKind.parse(rs.read(String))
      ref_id = rs.read(Int64)
      created_at = rs.read(Int64)
      return nil unless owner && ref
      EntityLink.new(id, owner, owner_id, ref, ref_id, created_at)
    end

    private def read_row(rs : DB::ResultSet) : FlowRow
      id = rs.read(Int64)
      created_at = rs.read(Int64)
      scheme = rs.read(String)
      method = rs.read(String)
      host = rs.read(String)
      port = rs.read(Int32)
      target = rs.read(String)
      status = rs.read(Int32?)
      req_size = rs.read(Int64)
      resp_size = rs.read(Int64?)
      state = FlowState.new(rs.read(Int32))
      duration_us = rs.read(Int64?)
      content_type = rs.read(String?)
      FlowRow.new(id, created_at, scheme, method, host, port, target,
        status, req_size + (resp_size || 0_i64), state, resp_size, duration_us, content_type)
    end

    # Non-blocking best-effort publish: if the TUI is behind and the channel is
    # full, drop (its periodic re-query of the authoritative projection covers
    # the gap, P5). Never stalls the writer/data path (P6).
    private def publish(event : FlowEvent) : Nil
      if events = @events
        select
        when events.send(event)
        else
          # dropped; authoritative state still in SQLite
        end
      end
      if prism = @prism_events
        select
        when prism.send(event)
        else
          # Prism analyzer behind / not running — drop (it re-reads via get_flow anyway)
        end
      end
    rescue Channel::ClosedError
      # a consumer (TUI / Prism) closed during shutdown — the writer must not die over it
    end
  end
end
