require "db"
require "sqlite3"
require "./store/models"
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

    struct UpdateResp < WriteOp
      getter resp : CapturedResponse
      getter reply : Channel(Nil)

      def initialize(@resp, @reply)
      end
    end

    struct InsertWs < WriteOp
      getter flow_id : Int64
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes
      getter reply : Channel(Nil)

      def initialize(@flow_id, @created_at, @direction, @opcode, @payload, @reply)
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

    # Opens (and migrates) the database. `events`, when given, receives
    # best-effort post-commit notifications for the live TUI; pass nil in
    # headless mode (no consumer => nothing to publish). `retention_flows` caps
    # the kept history (0 = unlimited).
    def self.open(path : String, events : Channel(FlowEvent)? = nil,
                  retention_flows : Int32 = RETENTION_DEFAULT) : Store
      url = "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
      db = DB.open(url)
      Schema.migrate!(db)
      new(db, events, retention_flows)
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

    # Fills in the response side of an existing flow. Blocks until committed.
    def update_response(resp : CapturedResponse) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(UpdateResp.new(resp, reply))
      reply.receive
    rescue Channel::ClosedError
      nil
    end

    # Records one captured WebSocket message for a flow. Blocks until committed
    # (the forward already happened, so the peer is not delayed).
    def insert_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(InsertWs.new(flow_id, now_us, direction, opcode, payload, reply))
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

    def scope_rules : Array(String)
      rules = [] of String
      @db.query("SELECT pattern FROM scope_rules ORDER BY pattern") { |rs| rs.each { rules << rs.read(String) } }
      rules
    end

    def add_scope_rule(pattern : String) : Nil
      exec_task ->(c : DB::Connection) { c.exec("INSERT OR IGNORE INTO scope_rules (pattern) VALUES (?)", pattern); nil }
    end

    def remove_scope_rule(pattern : String) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM scope_rules WHERE pattern = ?", pattern); nil }
    end

    def setting(key : String) : String?
      @db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    end

    def set_setting(key : String, value : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", key, value, value)
        nil
      }
    end

    # --- findings ------------------------------------------------------------

    def insert_finding(title : String, severity : Severity, host : String?, flow_id : Int64?) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO findings (created_at, updated_at, title, severity, host, flow_id, notes) VALUES (?,?,?,?,?,?,'')",
          ts, ts, title, severity.value, host, flow_id)
        nil
      }
    end

    def update_finding(id : Int64, *, title : String? = nil, severity : Severity? = nil, notes : String? = nil) : Nil
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
      return if sets.empty?
      sets << "updated_at = ?"; args << now_us
      args << id
      sql = "UPDATE findings SET #{sets.join(", ")} WHERE id = ?"
      exec_task ->(c : DB::Connection) { c.exec(sql, args: args); nil }
    end

    def delete_finding(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM findings WHERE id = ?", id); nil }
    end

    def findings : Array(Finding)
      list = [] of Finding
      @db.query(<<-SQL) do |rs|
        SELECT id, created_at, updated_at, title, severity, host, flow_id, notes
        FROM findings ORDER BY severity DESC, created_at DESC
        SQL
        rs.each { list << read_finding(rs) }
      end
      list
    end

    def get_finding(id : Int64) : Finding?
      @db.query("SELECT id, created_at, updated_at, title, severity, host, flow_id, notes FROM findings WHERE id = ?", id) do |rs|
        return read_finding(rs) if rs.move_next
      end
      nil
    end

    def count_findings : Int32
      @db.scalar("SELECT COUNT(*) FROM findings").as(Int64).to_i
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

    def h2_frames(conn_id : Int64) : Array(H2Frame)
      list = [] of H2Frame
      @db.query(<<-SQL, conn_id) do |rs|
        SELECT id, conn_id, created_at, direction, stream_id, type, flags, length, payload
        FROM h2_frames WHERE conn_id = ? ORDER BY id
        SQL
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

    def ws_messages(flow_id : Int64) : Array(WsMessage)
      msgs = [] of WsMessage
      @db.query(<<-SQL, flow_id) do |rs|
        SELECT id, flow_id, created_at, direction, opcode, payload
        FROM ws_messages WHERE flow_id = ? ORDER BY id
        SQL
        rs.each do
          msgs << WsMessage.new(rs.read(Int64), rs.read(Int64), rs.read(Int64),
            rs.read(String), rs.read(Int32), rs.read(Bytes))
        end
      end
      msgs
    end

    # --- read API (go straight through the pool; WAL allows concurrent reads) -

    SELECT_ROW = <<-SQL
      SELECT id, created_at, scheme, method, host, port, target, status,
             request_size, response_size, state
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

    # Newest-first flows matching a compiled QL filter.
    def search(filter : QL::Filter, limit : Int32) : Array(FlowRow)
      rows = [] of FlowRow
      args = filter.args.dup
      args << limit
      @db.query("#{SELECT_ROW} WHERE #{filter.sql} ORDER BY id DESC LIMIT ?", args: args) do |rs|
        rs.each { rows << read_row(rs) }
      end
      rows
    rescue ex
      # A malformed FTS phrase (FTS5 operator syntax, stray characters) raises a
      # SQLite error; a live filter must never crash the TUI run loop — degrade to
      # no matches and let the user fix the query.
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
               request_size, response_size, state,
               http_version, request_head, request_body, response_head, response_body,
               h2_conn_id, h2_stream_id, request_body_truncated, response_body_truncated
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
        return FlowDetail.new(row, http_version, req_head, req_body, resp_head, resp_body,
          h2_conn, h2_stream, req_trunc, resp_trunc)
      end
      nil
    end

    def count : Int64
      @db.scalar("SELECT COUNT(*) FROM flows").as(Int64)
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

    def sitemap_entries(filter : QL::Filter = QL::EMPTY, limit : Int32 = SITEMAP_MAX) : Array({String, String, String})
      rows = [] of {String, String, String}
      args = filter.args.dup
      args << limit
      @db.query("SELECT DISTINCT host, method, target FROM flows WHERE #{filter.sql} ORDER BY host, target LIMIT ?",
        args: args) do |rs|
        rs.each { rows << {rs.read(String), rs.read(String), rs.read(String)} }
      end
      rows
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
        c.exec("DELETE FROM ws_messages WHERE flow_id <= ?", cutoff)
        c.exec("DELETE FROM flows_fts WHERE rowid <= ?", cutoff)
        c.exec("DELETE FROM flows WHERE id <= ?", cutoff)
        # h2 frames/connections key off conn_id, not flow id — drop those no longer
        # referenced by a surviving flow. Guard with `created_at < oldest-kept` so
        # an IN-FLIGHT connection (frames logged but its flow not yet projected)
        # isn't wiped: its raw log only goes once it's older than everything kept.
        # The subquery excludes NULLs so the NOT IN logic is well-defined.
        oldest = c.query_one?("SELECT MIN(created_at) FROM flows", as: Int64?) || Int64::MAX
        stale = "id NOT IN (SELECT h2_conn_id FROM flows WHERE h2_conn_id IS NOT NULL) AND created_at < ?"
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
      when InsertFlow then op.reply.send(0_i64)
      when UpdateResp then op.reply.send(nil)
      when InsertWs   then op.reply.send(nil)
      when ExecTask   then op.reply.send(0_i64)
      end
    rescue
      # caller gone / channel closed — nothing to unblock
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
      conn.exec(
        <<-SQL,
        UPDATE flows SET
          response_head = ?, response_body = ?, status = ?, reason = ?,
          content_type = ?, response_size = ?, state = ?,
          ttfb_us = ?, duration_us = ?, error = ?, response_body_truncated = ?
        WHERE id = ?
        SQL
        resp.head, resp.body, resp.status, resp.reason, resp.content_type,
        resp.head.size.to_i64 + body_size,
        resp.state.value, resp.ttfb_us, resp.duration_us, resp.error,
        resp.body_truncated? ? 1 : 0, resp.flow_id)
      resp_fts = binary_content?(resp.content_type) ? "" : fts_text(resp.body)
      conn.exec("UPDATE flows_fts SET resp = ? WHERE rowid = ?", resp_fts, resp.flow_id)
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
      binary_content?(head_content_type(req.head)) ? "" : fts_text(body)
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

    private def head_content_type(head : Bytes) : String?
      String.new(head).each_line do |raw|
        line = raw.chomp
        break if line.empty?
        idx = line.index(':')
        next unless idx
        return line[(idx + 1)..].strip if line[0...idx].strip.downcase == "content-type"
      end
      nil
    end

    private def insert_ws_one(conn : DB::Connection, op : InsertWs) : Nil
      conn.exec(
        "INSERT INTO ws_messages (flow_id, created_at, direction, opcode, payload) VALUES (?,?,?,?,?)",
        op.flow_id, op.created_at, op.direction, op.opcode, op.payload)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end

    # Same columns/casts the old synchronous insert used (so h2_frames readback /
    # to_bytes round-trips are unchanged).
    private def insert_h2_frame_one(conn : DB::Connection, op : InsertH2Frame) : Nil
      conn.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                "VALUES (?,?,?,?,?,?,?,?)",
        op.conn_id, op.created_at, op.direction, op.stream_id, op.type_octet, op.flags, op.payload.size, op.payload)
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
        Severity.new(rs.read(Int32)), rs.read(String?), rs.read(Int64?), rs.read(String))
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
      FlowRow.new(id, created_at, scheme, method, host, port, target,
        status, req_size + (resp_size || 0_i64), state)
    end

    # Non-blocking best-effort publish: if the TUI is behind and the channel is
    # full, drop (its periodic re-query of the authoritative projection covers
    # the gap, P5). Never stalls the writer/data path (P6).
    private def publish(event : FlowEvent) : Nil
      return unless events = @events
      select
      when events.send(event)
      else
        # dropped; authoritative state still in SQLite
      end
    rescue Channel::ClosedError
      # consumer (TUI) closed during shutdown — the writer must not die over it
    end
  end
end
