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

    # Generic write (scope rules / settings / findings) run on the writer
    # connection; reply carries last_insert_rowid (meaningful for INSERTs).
    struct ExecTask < WriteOp
      getter run : DB::Connection -> Nil
      getter reply : Channel(Int64)

      def initialize(@run, @reply)
      end
    end

    BATCH_MAX = 128

    @events : Channel(FlowEvent)?

    # Opens (and migrates) the database. `events`, when given, receives
    # best-effort post-commit notifications for the live TUI; pass nil in
    # headless mode (no consumer => nothing to publish).
    def self.open(path : String, events : Channel(FlowEvent)? = nil) : Store
      url = "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
      db = DB.open(url)
      Schema.migrate!(db)
      new(db, events)
    end

    def initialize(@db : DB::Database, @events : Channel(FlowEvent)? = nil)
      @writes = Channel(WriteOp).new(256)
      @done = Channel(Nil).new
      spawn(name: "gori-store-writer") do
        writer_loop
        @done.send(nil)
      end
    end

    # --- write API (called from proxy fibers) --------------------------------

    # Inserts a Pending flow (request captured) and returns its new id.
    # Blocks the caller until the row is committed.
    def insert_flow(req : CapturedRequest) : Int64
      reply = Channel(Int64).new
      @writes.send(InsertFlow.new(req, reply))
      reply.receive
    end

    # Fills in the response side of an existing flow. Blocks until committed.
    def update_response(resp : CapturedResponse) : Nil
      reply = Channel(Nil).new
      @writes.send(UpdateResp.new(resp, reply))
      reply.receive
    end

    # Records one captured WebSocket message for a flow. Blocks until committed
    # (the forward already happened, so the peer is not delayed).
    def insert_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
      reply = Channel(Nil).new
      @writes.send(InsertWs.new(flow_id, now_us, direction, opcode, payload, reply))
      reply.receive
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

    def insert_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                        stream_id : UInt32, payload : Bytes) : Nil
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
               "VALUES (?,?,?,?,?,?,?,?)",
          conn_id, ts, direction, stream_id.to_i64, type.to_i32, flags.to_i32, payload.size, payload)
        nil
      }
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
               h2_conn_id, h2_stream_id
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
        return FlowDetail.new(row, http_version, req_head, req_body, resp_head, resp_body, h2_conn, h2_stream)
      end
      nil
    end

    def count : Int64
      @db.scalar("SELECT COUNT(*) FROM flows").as(Int64)
    end

    # Distinct (host, method, target) endpoints for building the Sitemap tree,
    # honouring an optional filter (the Scope lens).
    def sitemap_entries(filter : QL::Filter = QL::EMPTY) : Array({String, String, String})
      rows = [] of {String, String, String}
      @db.query("SELECT DISTINCT host, method, target FROM flows WHERE #{filter.sql} ORDER BY host, target",
        args: filter.args) do |rs|
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
        loop do
          first = @writes.receive?
          break if first.nil? # channel closed: drained, exit

          ops = [first]
          while ops.size < BATCH_MAX && (extra = drain_one)
            ops << extra
          end

          # Batch the burst into one transaction (amortize fsync, P6), then fire
          # replies + events only AFTER commit so nothing observes uncommitted
          # rows (P5).
          deferred = [] of -> Nil
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
              when ExecTask
                task_reply = op.reply
                op.run.call(c)
                rowid = c.scalar("SELECT last_insert_rowid()").as(Int64)
                deferred << -> { task_reply.send(rowid) }
              end
            end
          end
          deferred.each(&.call)
        end
      end
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
      conn.exec(
        <<-SQL,
        INSERT INTO flows
          (created_at, scheme, host, port, method, target, http_version,
           sni, alpn, tls_version, request_head, request_body, request_size, state,
           h2_conn_id, h2_stream_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        SQL
        req.created_at, req.scheme, req.host, req.port, req.method, req.target,
        req.http_version, req.sni, req.alpn, req.tls_version,
        req.head, req.body,
        req.head.size.to_i64 + (req.body.try(&.size.to_i64) || 0_i64),
        FlowState::Pending.value, req.h2_conn_id, req.h2_stream_id)
      conn.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    private def update_one(conn : DB::Connection, resp : CapturedResponse) : Nil
      conn.exec(
        <<-SQL,
        UPDATE flows SET
          response_head = ?, response_body = ?, status = ?, reason = ?,
          content_type = ?, response_size = ?, state = ?,
          ttfb_us = ?, duration_us = ?, error = ?
        WHERE id = ?
        SQL
        resp.head, resp.body, resp.status, resp.reason, resp.content_type,
        resp.head.size.to_i64 + (resp.body.try(&.size.to_i64) || 0_i64),
        resp.state.value, resp.ttfb_us, resp.duration_us, resp.error, resp.flow_id)
    end

    private def insert_ws_one(conn : DB::Connection, op : InsertWs) : Nil
      conn.exec(
        "INSERT INTO ws_messages (flow_id, created_at, direction, opcode, payload) VALUES (?,?,?,?,?)",
        op.flow_id, op.created_at, op.direction, op.opcode, op.payload)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end

    # Runs a write closure on the writer connection; returns last_insert_rowid.
    private def exec_task(run : DB::Connection -> Nil) : Int64
      reply = Channel(Int64).new
      @writes.send(ExecTask.new(run, reply))
      reply.receive
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
    end
  end
end
