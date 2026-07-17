require "db"
require "sqlite3"
require "log"
require "json"
require "./store/models"
require "./store/safe_regexp"
require "./store/schema"
require "./store/compact"
require "./store/scope_rules"
require "./store/host_overrides"
require "./store/settings_kv"
require "./store/issues"
require "./store/entity_links"
require "./store/probe_issues"
require "./store/probe_rules"
require "./store/match_rules"
require "./store/repeater_sessions"
require "./store/fuzz_sessions"
require "./store/miner_sessions"
require "./store/oast_sessions"
require "./store/sequencer_sessions"
require "./store/fuzz_runs"
require "./store/event_log"
require "./store/intercept_bridge"
require "./store/h2_frames"
require "./store/reads"
require "./store/sitemap_tags"
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
      getter repeater_id : Int64?
      getter created_at : Int64
      getter direction : String
      getter opcode : Int32
      getter payload : Bytes
      getter reply : Channel(Nil)

      def initialize(@flow_id, @repeater_id, @created_at, @direction, @opcode, @payload, @reply)
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

    # Generic write (scope rules / settings / issues) run on the writer
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

    # Cap on @pending_req_fts (see initialize). Far above the in-flight (request sent,
    # response pending) flow count under any real load, since each entry lives only until
    # its response lands; overflow (a flood of never-answered requests) clears the memo so
    # update_one transparently falls back to the readback.
    PENDING_FTS_MAX = 8192

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
    # Second post-commit notification channel feeding the Probe analyzer. Separate from
    # `@events` because a Crystal Channel is single-consumer — the TUI history refresh and
    # Probe can't share one. Same best-effort drop-on-full semantics (see #publish).
    @probe_events : Channel(FlowEvent)?

    # Opens (and migrates) the database. `events`, when given, receives
    # best-effort post-commit notifications for the live TUI; pass nil in
    # headless mode (no consumer => nothing to publish). `probe_events` is the parallel
    # feed for the Probe analyzer (nil when Probe isn't running). `retention_flows` caps
    # the kept history (0 = unlimited).
    def self.open(path : String, events : Channel(FlowEvent)? = nil,
                  probe_events : Channel(FlowEvent)? = nil,
                  retention_flows : Int32 = RETENTION_DEFAULT) : Store
      url = "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
      db = DB.open(url)
      harden_permissions(path)
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
      new(db, events, probe_events, retention_flows)
    end

    # The db (and its WAL/SHM sidecars) hold captured request/response bytes — cookies,
    # Authorization headers, credentials in POST bodies. Lock them to 0600 so the secret
    # store isn't world-readable even if the enclosing dir's perms are ever loosened or the
    # file is copied out. Best-effort (the owner-only 0700 project dir is the primary guard,
    # and it covers a sidecar SQLite may (re)create later that we can't chmod here); mirrors
    # cert_authority.cr locking the CA key. `:memory:`/absent paths just no-op via the rescue.
    private def self.harden_permissions(path : String) : Nil
      File.chmod(path, 0o600) rescue nil
      File.chmod("#{path}-wal", 0o600) rescue nil
      File.chmod("#{path}-shm", 0o600) rescue nil
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
                   @probe_events : Channel(FlowEvent)? = nil,
                   @retention_flows : Int32 = RETENTION_DEFAULT,
                   @prune_interval : Int32 = PRUNE_INTERVAL)
      @writes = Channel(WriteOp).new(1024) # widened: h2 frames now queue fire-and-forget
      @done = Channel(Nil).new
      @write_failures = Atomic(Int32).new(0)
      @h2_frames_dropped = Atomic(Int32).new(0)
      @inserts_since_prune = 0
      # Writer-fiber-only memo of the request-side FTS text keyed by a just-inserted flow id,
      # so update_one (the response side) reuses it instead of reading the request head +
      # body back out of the row it just wrote. Populated ONLY post-commit (a rolled-back insert
      # never enters, so its id can't feed a stale response); bounded so abandoned Pending flows
      # (a request whose response never arrives) can't grow it without limit — an evicted id
      # simply falls back to the readback. Single writer fiber ⇒ no lock.
      @pending_req_fts = {} of Int64 => String
      # Bumped after every committed probe_issues mutation (upsert/delete/status).
      # The TUI polls this every main-loop tick — more reliable than PRAGMA data_version
      # (same-process writer visibility is flaky) or the droppable Probe event channel.
      @probe_generation = 0_i64
      spawn(name: "gori-store-writer") do
        writer_loop
        @done.send(nil)
      end
    end

    # Monotonic counter of committed probe_issues writes. Single-threaded fiber
    # scheduler: plain Int64 is enough (no -Dpreview_mt).
    def probe_generation : Int64
      @probe_generation
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
    def insert_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes, repeater_id : Int64? = nil) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(InsertWs.new(flow_id, repeater_id, now_us, direction, opcode, payload, reply))
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

    # --- shared read helper (used by both issues.cr and probe_issues.cr) ---

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
                  id, req_fts = insert_one(c, op.req)
                  # Remember the request-side FTS text so this flow's later response update
                  # skips the row readback. Merged only in the post-commit deferred block, so
                  # a rolled-back insert leaves no entry behind.
                  deferred << -> { remember_req_fts(id, req_fts); ins_reply.send(id); publish(FlowEvent.new(id, :inserted)) }
                when InsertImportBatch
                  batch_reply = op.reply
                  inserted = [] of {Int64, Bool}
                  op.pairs.each do |req, resp|
                    id, req_fts = insert_one(c, req)
                    has_resp = !resp.nil?
                    if r = resp
                      # Hand update_one the request FTS text we just computed so its memo
                      # lookup HITS instead of reading the row back (a per-entry SELECT +
                      # up-to-64KiB body re-materialization on every imported pair with a
                      # response). delete-on-read in update_one keeps the memo from growing.
                      remember_req_fts(id, req_fts)
                      update_one(c, Store::CapturedResponse.new(
                        flow_id: id, status: r.status, head: r.head,
                        body: r.body, reason: r.reason,
                        content_type: r.content_type,
                        content_encoding: r.content_encoding, ttfb_us: r.ttfb_us,
                        duration_us: r.duration_us, state: r.state,
                        error: r.error, body_truncated: r.body_truncated?,
                        body_size: r.body_size))
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
            # Count bulk-import rows too — an InsertImportBatch inserts many flows in ONE op,
            # so counting it as a single InsertFlow (or 0) let a large import bypass the
            # retention sweep, keeping the DB far over its cap until enough live captures accrue.
            @inserts_since_prune += ops.sum { |op| op.is_a?(InsertFlow) ? 1 : (op.is_a?(InsertImportBatch) ? op.pairs.size : 0) }
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
        # NOTE (known limitation): a WebSocket flow still streaming frames after `retention_flows`
        # newer flows push its id below the cutoff is reaped here mid-stream, which also stops
        # Probe WS scanning on it. A liveness guard like the h2 one below is the fix, but it must
        # compare ws_message.created_at against a WS-relative recency floor (flows.created_at and
        # ws_messages.created_at are set from different sources), so it is left for a focused
        # retention change rather than bundled here.
        # Only CAPTURED ws messages (repeater_id IS NULL, real flow_id) cascade with their
        # pruned flow. WebSocket-Repeater output rows (update_repeater_ws_messages) are stored
        # with the sentinel flow_id = 0 and keyed by repeater_id, so a bare `flow_id <= cutoff`
        # (cutoff is always > 0 here) matched EVERY repeater row and wiped saved repeater traffic
        # on each sweep. Gate on repeater_id so repeater-owned rows are never reaped by flow retention.
        c.exec("DELETE FROM ws_messages WHERE flow_id <= ? AND repeater_id IS NULL", cutoff)
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

    # Inserts the request row + its FTS entry, returning {id, req_fts} so the caller can
    # hand the already-computed request-side FTS text to update_one (post-commit) instead of
    # reading the head+body back out of the row.
    private def insert_one(conn : DB::Connection, req : CapturedRequest) : {Int64, String}
      # request_size is the TRUE wire size (body_size when the BLOB was truncated),
      # so the History size column stays honest even for a capped body.
      body_size = req.body_size || req.body.try(&.size.to_i64) || 0_i64
      res = conn.exec(
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
      # The INSERT's own result carries the rowid — no separate `SELECT last_insert_rowid()`.
      id = res.last_insert_id
      # Index the request body text now; the response side is filled in by
      # update_one. Same transaction, so FTS and the row commit together.
      req_fts = request_fts(req)
      conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, '')", id, req_fts)
      {id, req_fts}
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
      # row and re-INSERT with BOTH sides. The request text was computed at insert time and
      # memoized (@pending_req_fts) — reuse it rather than reading the head + (capped) body
      # back from the row on every response; a miss (evicted, an import, or a cross-process
      # write) falls back to that readback. DELETE is a cheap tombstone (contentless_delete=1)
      # and also makes a double update_response idempotent (last write wins).
      # Skip the FTS body text for a binary content type or a compressed (non-identity
      # Content-Encoding) body. Both markers now ride on CapturedResponse (extracted once
      # by the proxy where the headers are already parsed), so this no longer copies the
      # raw head into a String + scans it per flow. A body-less response (204/304/redirect)
      # has no text to index and short-circuits before the marker checks.
      resp_body = resp.body
      resp_fts = (resp_body.nil? || resp_body.empty? || binary_content?(resp.content_type) || encoded?(resp.content_encoding)) ? "" : fts_text(resp_body)
      req_fts = @pending_req_fts.delete(resp.flow_id) || request_fts_from_row(conn, resp.flow_id)
      conn.exec("DELETE FROM flows_fts WHERE rowid = ?", resp.flow_id)
      conn.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, ?)", resp.flow_id, req_fts, resp_fts)
    end

    # Record a flow's request-side FTS text for its pending response update (writer fiber
    # only). Clears the memo on overflow rather than growing unbounded — a burst of requests
    # whose responses never land would otherwise pin memory; after a clear, those responses
    # take the readback path.
    private def remember_req_fts(id : Int64, req_fts : String) : Nil
      @pending_req_fts.clear if @pending_req_fts.size >= PENDING_FTS_MAX
      @pending_req_fts[id] = req_fts
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
      # payload is BLOB NOT NULL; binding an empty Bytes binds SQL NULL (empty slice ⇒
      # null pointer) and violates the constraint, aborting the whole write batch. A
      # zero-length WS text/binary frame (valid per RFC 6455 — e.g. an empty heartbeat)
      # reaches here with an empty payload, so use the SQL literal X'' for it, mirroring
      # insert_h2_frame_one's empty-DATA handling.
      empty = op.payload.empty?
      args = [op.flow_id, op.repeater_id, op.created_at, op.direction, op.opcode] of DB::Any
      args << op.payload unless empty
      conn.exec(
        "INSERT INTO ws_messages (flow_id, repeater_id, created_at, direction, opcode, payload) " \
        "VALUES (?,?,?,?,?,#{empty ? "X''" : "?"})", args: args)
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
      # Precomputed SQL (one of two fixed texts) — this runs once per h2 frame on the writer
      # fiber, so string-interpolating the statement every call was pure churn on the shared core.
      conn.exec(data ? SQL_INSERT_H2_FRAME_DATA : SQL_INSERT_H2_FRAME_PAYLOAD, args: args)
    end

    private SQL_INSERT_H2_FRAME_DATA =
      "INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
      "VALUES (?,?,?,?,?,?,?,X'')"
    private SQL_INSERT_H2_FRAME_PAYLOAD =
      "INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
      "VALUES (?,?,?,?,?,?,?,?)"

    # Runs a write closure on the writer connection; returns last_insert_rowid.
    private def exec_task(run : DB::Connection -> Nil) : Int64
      reply = Channel(Int64).new(1) # buffered: the writer must never block sending a reply
      @writes.send(ExecTask.new(run, reply))
      reply.receive
    rescue Channel::ClosedError
      0_i64 # store closing — caller (settings/issues/flush) degrades, doesn't raise
    end

    private def read_issue(rs : DB::ResultSet) : Issue
      Issue.new(
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

    # Column order MUST match EVENT_COLS.
    private def read_event(rs : DB::ResultSet) : EventRow
      EventRow.new(
        rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(String),
        rs.read(String), rs.read(String), rs.read(String?), rs.read(Int64?),
        rs.read(Int64?), rs.read(String?))
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
      if probe = @probe_events
        select
        when probe.send(event)
        else
          # Probe analyzer behind / not running — drop (it re-reads via get_flow anyway)
        end
      end
    rescue Channel::ClosedError
      # a consumer (TUI / Probe) closed during shutdown — the writer must not die over it
    end
  end
end
