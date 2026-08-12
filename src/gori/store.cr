require "db"
require "sqlite3"
require "log"
require "json"
require "./media_type"
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
require "./store/probe_oast"
require "./store/match_rules"
require "./store/color_rules"
require "./store/extract_rules"
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
require "./open_lock"

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
      # The new row IDS, in the order the pairs were given — not a count. A caller that has to
      # link each source record to the flow it became (Discover: a finding row → the request/
      # response it can then open) has no other way to learn them: the ids are assigned inside
      # the writer transaction, and looking them back up by created_at would race any other
      # import writing the same microsecond. `insert_import_batch` still answers a count.
      getter reply : Channel(Array(Int64))

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
      getter shape : WsShape

      def initialize(@flow_id, @repeater_id, @created_at, @direction, @opcode, @payload, @reply,
                     @shape : WsShape = WsShape::DEFAULT)
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

    # Like ExecTask, but its reply is a COMMITTED bool rather than a rowid. exec_task
    # signals failure only via last_insert_rowid()==0, which is meaningful for INSERTs
    # but NOT for UPDATE/DELETE (a committed UPDATE can also yield 0), so a rolled-back
    # UPDATE/DELETE was indistinguishable from a successful one — a busy/locked mutation
    # reported success. This variant carries an unambiguous commit/rollback signal so a
    # caller (e.g. an MCP mutation tool) can surface PROJECT_BUSY on a dropped write.
    struct ExecTaskChecked < WriteOp
      getter run : DB::Connection -> Nil
      getter reply : Channel(Bool)

      def initialize(@run, @reply)
      end
    end

    # Asks the writer to index one slice of the FTS backlog and report how many rows it did
    # (see Store#index_pending!). Deliberately NOT an ExecTask: an ExecTask body runs inside
    # the batch's shared transaction, and indexing needs its OWN — both so a nested
    # transaction isn't opened on the same connection, and so an index failure rolls back
    # only itself instead of the captured flows batched alongside it.
    struct IndexBatch < WriteOp
      getter reply : Channel(Int32)

      def initialize(@reply)
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

    # Flows re-indexed per idle indexing transaction (see index_pending_batch). Small
    # enough that a batch can't hold the writer long enough to delay a capture that
    # arrives mid-batch; large enough to amortize the transaction over many rows.
    FTS_BATCH = 32
    # How long the writer waits for capture work before spending the idle time on the FTS
    # backlog. FAST while there may be work (so a backlog drains at a useful rate), SLOW
    # once a batch comes back empty (so a quiet session isn't waking up 200×/s for nothing).
    FTS_IDLE_TICK_FAST = 5.milliseconds
    FTS_IDLE_TICK_SLOW = 250.milliseconds
    # Ceiling on the backlog probe (see #fts_backlog). The exact number stops mattering
    # once it's "lots"; capping it keeps the probe O(cap) instead of O(backlog).
    FTS_BACKLOG_PROBE_MAX = 10_000

    # Keep at most this many newest flows; older ones (and their ws/h2 rows) are
    # pruned so the DB plateaus instead of growing forever (freed pages are
    # reused by later inserts). 0 disables retention. Tunable per Store.open.
    #
    # This is the FACTORY value. A surface that owns capture must pass
    # `Settings.retention_flows` instead, so the operator's configured cap actually applies —
    # Store deliberately does not read Settings (it is the lower layer), so the value has to
    # arrive from the caller. `Settings::DEFAULT_RETENTION_FLOWS` references this constant, so
    # the number itself lives only here.
    RETENTION_DEFAULT = 100_000
    # Pass this for a store that must never delete history: a read-oriented or
    # count-only open, and the MCP server's own store. Named rather than a bare 0 so the
    # intent is legible at the call site and greppable across surfaces.
    #
    # NOTE it only matters where flows are actually INSERTED: `prune` runs solely from the
    # writer batch loop once PRUNE_INTERVAL inserts accumulate, so a purely reading open never
    # sweeps regardless of what it passes.
    RETENTION_UNLIMITED = 0
    # Inserts between retention sweeps — amortizes the prune cost.
    PRUNE_INTERVAL = 2_000
    # Ids per statement when a batch write binds an `IN (?,?,…)` list. SQLite caps bound
    # parameters at SQLITE_MAX_VARIABLE_NUMBER, which is 999 on anything built before 3.32 —
    # so a set larger than that does not merely run slower, the statement RAISES and the whole
    # write reports as failed. The multi-select verbs can hand over a full filtered page, so
    # any such statement chunks by this; the chunks stay inside one exec_task, so a batch is
    # still one transaction. Well under 999 to leave room for the SET/WHERE args beside them.
    ID_CHUNK = 400
    # Per-side ceiling on body text fed to the FTS index. Every byte becomes a 3-byte-window
    # token, so this is a WORK budget, measured at roughly 30µs per indexed KiB (SQLite 3.51,
    # arm64, one flow per transaction). Indexing runs off the capture commit (V4), so the cap
    # no longer bounds capture latency directly — it bounds how fast the backlog drains, and
    # how much index a burst leaves to catch up on. At 64 KiB one text response cost the
    # indexer ~2ms; 8 KiB keeps the common case (JSON APIs, small HTML) fully indexed at ~250µs.
    #
    # The trade is search RECALL, not correctness: `body:` (FTS) sees only the first
    # 8 KiB per side, while `body~<regex>` still scans the whole stored BLOB, so anything
    # past the cap stays findable — just with a table scan instead of an index hit. Raising
    # this affects only flows indexed AFTERWARDS; already-indexed rows keep their entries.
    FTS_INDEX_MAX = 8 * 1024

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
      refuse_non_database(path)
      # Announce that this process has the database open, for as long as it is (see OpenLock).
      # Taken BEFORE `DB.open` so the window in which a peer could delete the file out from
      # under a half-built store does not exist.
      open_lock = OpenLock.try_shared(path)
      db = begin
        DB.open(url)
      rescue ex
        open_lock.try(&.close)
        raise ex
      end
      # Everything between DB.open and handing the pool to `new` has to be unwound on
      # failure, because `db` is a live connection POOL and nothing else has a reference
      # to it yet: an escaping exception left the sqlite handle (plus its -wal/-shm)
      # open for the rest of the process. That is not a one-shot cost — every surface
      # that opens a project RECOVERS from a failed open and keeps running: the TUI
      # picker falls back to the project list with `open_failure_reason` (app.cr),
      # MCP `switch_project` answers an error and stays bound to the old project, and
      # both `delete_project`'s dry run and `gori run project delete`'s preview open a
      # short-lived handle they report `nil` counts for. Each retry against the same
      # unopenable project leaked another descriptor, so a session that repeatedly
      # bumped into one corrupt project ran the process out of fds.
      #
      # `compact`/`measure` next door already wrap their own DB.open in begin/ensure;
      # this was the one sibling without it.
      begin
        harden_permissions(path)
        # Make REGEXP byte-safe on every connection before any query runs (so a binary
        # body can't crash a `body~`/`header~` scan or a regex scope rule). See SafeRegexp.
        SafeRegexp.install(db)
        Schema.migrate!(db)
      rescue ex
        db.close rescue nil
        open_lock.try(&.close)
        raise ex
      end
      # Past this point the Store owns the pool and closes it in #close.
      new(db, events, probe_events, retention_flows, open_lock: open_lock)
    end

    # The 16-byte header every SQLite database file starts with: 15 ASCII bytes plus the
    # terminating NUL. Written as an escape — a raw NUL in a source literal is invisible.
    SQLITE_MAGIC = "SQLite format 3\u0000".to_slice

    # Refuse a path that exists but is not a SQLite database, BEFORE the driver is asked to
    # open it. Two independent reasons, both about this exact URL:
    #
    # 1. The driver LEAKS the fd on this input. `SQLite3::Connection#initialize` calls
    #    `sqlite3_open_v2` (which succeeds on any file — sqlite reads the header lazily) and
    #    then execs the pragmas this URL carries; `PRAGMA journal_mode=wal` is what actually
    #    reads page 1, fails SQLITE_NOTADB, and unwinds the constructor through a bare
    #    `rescue raise DB::ConnectionRefused` that never closes the handle it opened. Since
    #    `DB.open` eagerly builds the pool's first connection, the leak happens INSIDE
    #    DB.open — before `Store.open` holds anything it could close. Measured at exactly
    #    one descriptor per attempt, and every surface here retries: the TUI picker returns
    #    to the project list and lets the operator pick again, MCP `switch_project` stays
    #    bound and answers an error. The same URL WITHOUT pragmas leaks nothing, which is
    #    what pins the cause on the pragma exec rather than on the open.
    # 2. It is the only one of the unopenable cases whose real reason is knowable here.
    #    `DB::ConnectionRefused` carries a nil message, so "this file is not a database",
    #    "no read permission" and "that is a directory" arrive indistinguishable — which is
    #    why `Project#open_failure_reason` has to reconstruct a guess from the path. Naming
    #    it at the source means every surface (TUI picker, `gori run`, MCP bind) reports the
    #    same true sentence instead of three re-derivations of it.
    #
    # Only an EXISTING, NON-EMPTY REGULAR file is judged: a missing path and a zero-byte file
    # are both how a new project legitimately starts (sqlite creates/initialises them), and
    # `:memory:` is not a path at all.
    private def self.refuse_non_database(path : String) : Nil
      info = File.info?(path)
      return unless info # missing (a new project) or unstatable — the driver's problem
      raise Gori::Error.new("cannot open #{path}: that is a directory, not a database file") if info.directory?
      # Judged from the TYPE, before any open. A pipe/socket/device is not a database, and
      # deciding that from `stat` rather than from its contents means this never opens one:
      # a FIFO reports size 0 and yields nothing to read, so a content-based check would
      # either wave it through to the driver or block on the open waiting for a writer.
      unless info.file?
        raise Gori::Error.new("cannot open #{path}: not a regular file (#{info.type.to_s.downcase}), so not a database")
      end
      return if info.size.zero? # empty file: sqlite initialises it in place
      header = begin
        File.open(path) do |file|
          buf = Bytes.new(SQLITE_MAGIC.size)
          file.read_fully?(buf) ? buf : nil
        end
      rescue
        return # unreadable / vanished — let the driver produce the error, it does not leak on those
      end
      return if header == SQLITE_MAGIC
      # Same shape and the same key phrase as the five other surfaces that report an
      # unopenable db (`Project#open_failure_reason`, `gori run`, `gori run capture`, `gori
      # mcp`), so one failure keeps being described one way. "wrong file header" rather than
      # their "(or unreadable)": this path READ the file, so unreadability is ruled out.
      raise Gori::Error.new("cannot open #{path}: not a valid SQLite database (wrong file header)")
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
                   @prune_interval : Int32 = PRUNE_INTERVAL,
                   @open_lock : OpenLock? = nil)
      @writes = Channel(WriteOp).new(1024) # widened: h2 frames now queue fire-and-forget
      @done = Channel(Nil).new
      @closed = false # see #close: a second drain would park forever on @done
      @write_failures = Atomic(Int32).new(0)
      @h2_frames_dropped = Atomic(Int32).new(0)
      @inserts_since_prune = 0
      # Writer-fiber-only hint: does `flows.fts_dirty = 1` possibly have rows? Starts true so a
      # db reopened with a backlog (a killed process, or a batch dropped under saturation) gets
      # drained without waiting for a capture to hint at it; set false the moment an indexing
      # batch comes back empty, and true again whenever a committed batch dirtied a row. Only a
      # HINT — it decides how eagerly the writer wakes to index, never whether a row is indexed
      # (the `fts_dirty` column is the truth). Single writer fiber ⇒ no lock.
      @fts_backlog_hint = true
      # Bumped after every committed probe_issues mutation (upsert/delete/status).
      # The TUI polls this every main-loop tick — more reliable than PRAGMA data_version
      # (same-process writer visibility is flaky) or the droppable Probe event channel.
      @probe_generation = 0_i64
      # Set only when the writer's connection RELEASE raised (see writer_loop). It is the exact
      # predicate for "this connection is half-closed", which is what #close must not re-close.
      @writer_teardown_failed = false
      # Set by `writer_connection_loop` once its loop has returned, so `writer_loop`'s rescue can
      # tell "the connection release raised" from "the loop itself died".
      @writer_loop_exited = false
      spawn(name: "gori-store-writer") do
        # `ensure`, not a bare sequence. `#close` parks on `@done.receive` for a value this
        # fiber sends exactly once as it exits, so ANY escape from `writer_loop` leaves that
        # receive waiting on a sender that no longer exists — and that is a HANG, which no
        # `store.close rescue nil` guard can catch. `writer_loop` rescues around each batch for
        # this reason, but the batch rescue cannot cover the teardown of the connection the
        # loop borrowed, and that teardown is exactly where the escape came from (see the
        # rescue inside `writer_loop`). Making the send unconditional means a writer that dies
        # for any future reason degrades to "writes stop" instead of "gori never exits".

        writer_loop
      ensure
        @done.send(nil)
      end
    end

    # Monotonic counter of committed probe_issues writes. Single-threaded fiber
    # scheduler: plain Int64 is enough (no -Dpreview_mt).
    def probe_generation : Int64
      @probe_generation
    end

    # --- write API (called from proxy fibers) --------------------------------
    #
    # BARRIER NOTE: a returned flow write is committed and readable through every projection
    # query — but NOT necessarily through `body:`/free-text yet. Trigram indexing moved off the
    # commit path (V4/`fts_dirty`), so a caller that must see its own write in an FTS query
    # calls #flush (or #index_pending!) first; a live surface reports #fts_backlog instead.

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
      insert_import_batch_ids(pairs).size
    end

    # Same write, answering with the new flow ids in pair order (empty when the store is
    # closing or the batch rolled back). Blocks until committed.
    def insert_import_batch_ids(pairs : Array({CapturedRequest, CapturedResponse?})) : Array(Int64)
      reply = Channel(Array(Int64)).new(1)
      @writes.send(InsertImportBatch.new(pairs, reply))
      reply.receive
    rescue Channel::ClosedError
      [] of Int64
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
    def insert_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                          repeater_id : Int64? = nil,
                          shape : WsShape = WsShape::DEFAULT) : Nil
      reply = Channel(Nil).new(1) # buffered: the writer must never block sending a reply
      @writes.send(InsertWs.new(flow_id, repeater_id, now_us, direction, opcode, payload, reply, shape))
      reply.receive
    rescue Channel::ClosedError
      nil
    end

    # Blocks until every write enqueued before this call has committed AND the search index
    # has caught up with them. The single writer drains its channel FIFO, so a synchronous
    # round-trip also flushes the fire-and-forget h2-frame writes that precede it (a clean
    # read barrier).
    #
    # The index drain is part of the barrier on purpose: trigram indexing is off-commit
    # (V4/`fts_dirty`), so without it a caller that flushed and then ran a `body:` query
    # would silently under-report — the exact failure the flag exists to prevent. No hot path
    # calls this; it is the one-shot/`spec` barrier, where correctness beats latency. A live
    # surface (the TUI) must NOT use it — it reports #fts_backlog instead of stalling.
    def flush : Nil
      exec_task ->(_c : DB::Connection) { nil }
      index_pending!
    end

    # Indexes the whole FTS backlog, blocking until it is empty; returns the flows indexed.
    # Runs on the writer connection (one batch per round-trip) so it interleaves with capture
    # rather than locking it out.
    def index_pending! : Int32
      total = 0
      begin
        loop do
          reply = Channel(Int32).new(1) # buffered: the writer must never block sending a reply
          @writes.send(IndexBatch.new(reply))
          n = reply.receive
          break if n == 0
          total += n
        end
      rescue Channel::ClosedError
        # store closing — stop draining; the rows stay dirty and durable for the next open
      end
      total
    end

    # How many flows are waiting to be (re)indexed for `body:`/free-text search — i.e. how
    # far behind the search index is. Capped at FTS_BACKLOG_PROBE_MAX (a bigger number would
    # only ever be shown as "lots"), and answered from the partial index, so it is cheap
    # enough for a live surface to poll. 0 means every stored flow is searchable.
    def fts_backlog : Int32
      @db.scalar("SELECT COUNT(*) FROM (SELECT 1 FROM flows WHERE fts_dirty = 1 LIMIT #{FTS_BACKLOG_PROBE_MAX})")
        .as(Int64).to_i32
    rescue
      0 # a failed probe must never break a render/poll; it only understates the note
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
    #
    # Idempotent, and it has to be: `@done` is an unbuffered channel the writer fiber sends
    # exactly ONE value on as it exits, so a second `close` parked on `@done.receive` would
    # wait for a sender that no longer exists and hang the caller forever — not raise, HANG.
    # That distinction matters because two teardown paths guard this call with
    # `store.close rescue nil` (`Session.open`'s failure unwind among them), and a `rescue`
    # is no defence against a deadlock. It is the same hazard `writer_loop` already protects
    # against from the other side, where a failed batch must not kill the writer "or every
    # blocked caller (and close()) deadlocks".
    def close : Nil
      return if @closed
      @closed = true
      @writes.close
      @done.receive
      # LAST-DITCH GUARD, and it is about a segfault rather than an exception. `DB::Disposable`
      # documents that "if an exception is raised, the resource will not be marked as closed" —
      # but `SQLite3::Statement#do_close` has ALREADY called `sqlite3_finalize` (freeing the
      # stmt) before its `check` raises the deferred error, and `SQLite3::Connection#do_close`
      # aborts mid-cache leaving the connection unmarked and still in the pool. So `@db.close`
      # walks the pool and finalizes freed statements a second time: use-after-free, SIGSEGV,
      # measured. Every write gori issues into a UNIQUE-bearing table now goes through OR IGNORE
      # so nothing should poison a statement in the first place; if something ever does, leaking
      # one connection pool for the rest of the process beats crashing it, and the log line says
      # which happened.
      # Released on BOTH exits below, and last: while it is held, a peer's delete is refused,
      # so dropping it before the pool is done with the file would reopen the very window it
      # exists to close.
      if @writer_teardown_failed
        ::Log.warn { "store: leaving the connection pool open — the writer's connection did not tear down cleanly" }
        @open_lock.try(&.close)
        return
      end
      @db.close
      @open_lock.try(&.close)
    end

    # --- internals -----------------------------------------------------------

    private def writer_loop : Nil
      # Wrapped, because the RELEASE of the borrowed connection can raise and the per-batch
      # rescue below is inside the block, so it cannot see it. When a statement hits a
      # constraint (`UPDATE scope_rules` colliding with the table's UNIQUE triple is the
      # reachable one — `gori run project scope update` documents that very collision), sqlite
      # holds the error until the statement is FINALIZED, and the driver finalizes its cached
      # statements when `using_connection` gives the connection back. That finalize returns the
      # error code, `SQLite3::Statement#check` raises it, and it unwound straight out of this
      # fiber — past the batch rescue, which had already correctly rolled the batch back and
      # answered the caller `false`. So one colliding edit made `Store#close` hang FOREVER at
      # shutdown (measured: the process never exits), which in the TUI means gori does not quit
      # and leaves the terminal on the alternate screen. Logged, not raised: the loop is over by
      # then — every op has been answered — and there is nothing left to abort.

      writer_connection_loop
    rescue ex
      # gori.log, not STDERR (#411): in TUI mode STDERR is the alternate screen.
      #
      # WHICH failure this was decides what is safe to do next, and conflating them was wrong
      # in both directions. `@writer_loop_exited` is set inside the connection block after the
      # loop returns, so:
      #
      # * set ⇒ the LOOP finished and the RELEASE raised (the constraint-poisoned statement).
      #   Every op has been answered; the connection is half-closed, so `#close` must not
      #   re-close the pool (that is a use-after-free — see #close).
      # * clear ⇒ the loop itself died with `@writes` still OPEN and no reader. A caller that
      #   sends after this would park forever on its reply channel: the hang this rescue was
      #   added to prevent, moved from `close` to the next write. Close the channel so every
      #   caller takes its existing `rescue Channel::ClosedError` path (0 / false / dropped)
      #   instead, and leave the pool closable.
      if @writer_loop_exited
        ::Log.warn { "store writer connection teardown failed: #{ex.message}" }
        @writer_teardown_failed = true
      else
        ::Log.error { "store writer fiber died mid-loop: #{ex.message} — further writes will be refused" }
        @writes.close rescue nil
      end
    end

    private def writer_connection_loop : Nil
      @db.using_connection do |conn|
        # Reset per connection; `writer_loop` reads it to tell a loop death from a release failure.
        @writer_loop_exited = false
        # Bound the WAL file so it doesn't grow without limit under sustained
        # writes (the default is 1000 pages; set it explicitly on the writer).
        conn.exec("PRAGMA wal_autocheckpoint=1000") rescue nil
        loop do
          # Wait for capture work, but spend an idle wait on the FTS backlog instead of just
          # parking (see await_op). Capture ALWAYS wins: an op arriving mid-wait is taken
          # immediately, and indexing only ever runs between batches, never inside one.
          first = await_op(conn)
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
          # Index requests are pulled OUT of the batch: they need their own transaction (see
          # IndexBatch) and they must be answered whether or not the batch itself committed —
          # the rows they index were dirtied by EARLIER, already-committed batches.
          index_replies = ops.compact_map { |op| op.as?(IndexBatch).try(&.reply) }
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
                    # A response-less import pair is a reference placeholder that will never be
                    # sent — mark it `unsent` so abandon_pending! never fabricates an error for it (#408).
                    id = insert_one(c, req, unsent: resp.nil?)
                    has_resp = !resp.nil?
                    if r = resp
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
                    batch_reply.send(inserted.map { |(id, _)| id })
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
                when ExecTaskChecked
                  checked_reply = op.reply
                  op.run.call(c)
                  # Deferred until the batch commits (below), so `true` truthfully means
                  # persisted; a rollback routes through fail_reply → `false`.
                  deferred << -> { checked_reply.send(true) }
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
            # gori.log, not STDERR: in TUI mode STDERR is the alternate screen and a write there
            # garbles the frame (#411). The count below is what the TUI actually surfaces.
            ::Log.error { "store write batch failed (#{ops.size} op(s), rolled back): #{ex.message}" }
            @write_failures.add(ops.size) # surfaced in the TUI so the operator knows capture stopped
          end
          # publish never raises (see #publish); replies are buffered — so neither
          # branch can block or throw back into the loop.
          if committed
            deferred.each(&.call)
            # Any committed flow write left a row `fts_dirty` — tell the idle wait to start
            # looking again (see @fts_backlog_hint).
            @fts_backlog_hint = true if ops.any? { |op| dirties_fts?(op) }
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
          # Outside the batch transaction, and after it, so an explicit drain
          # (Store#index_pending!) also picks up rows this very batch just dirtied.
          index_replies.each(&.send(index_pending_batch(conn)))
        end
        @writer_loop_exited = true # the loop is done; anything that raises now is the release
      end
    end

    # Retention sweep: keep only the newest `@retention_flows` flows, cascading to their ws
    # messages and orphaned h2 frames/conns.
    # A failure here must not kill the writer or lose the just-committed batch, so
    # it runs in its own transaction and swallows errors (the next sweep, after
    # another PRUNE_INTERVAL inserts, simply tries again).
    #
    # The cutoff is the id of the OLDEST flow that SURVIVES, seeked from the rows that actually
    # exist — deliberately not `MAX(id) - @retention_flows`. `flows.id` is monotonic but NOT
    # gapless (INTEGER PRIMARY KEY without AUTOINCREMENT, and `delete_flow`/`delete_flows` remove
    # arbitrary mid-history ids from the History tab, MCP and `gori run history`), and that
    # arithmetic is "the newest N" only on a gap-free space. With 10 flows of which 6
    # mid-history ones were hand-deleted (1, 2, 9, 10 survive) and 15 more captured, a cap of 20
    # computed `cutoff = 25 - 20 = 5` and destroyed flows 1 and 2 — out of 19 rows, under a cap
    # of 20, where nothing at all should have been dropped. Irreversible, and reported as an
    # ordinary retention drop. `Compact.prune_old_flows` already documents and fixes this exact
    # arithmetic; the two sweeps now share one definition of "the newest N".
    private def prune(conn : DB::Connection) : Nil
      # BEFORE the retention early-returns. The reap below is not retention — it removes frames
      # whose connection row does not exist, which no cap has any opinion about — and putting it
      # after `@retention_flows <= 0` meant it never ran for the two commonest projects: an MCP
      # server opens with RETENTION_UNLIMITED, and a TUI project under its cap returns at
      # `cutoff <= 0`. The comment there promised a db carrying frames from an older build would
      # heal itself; for those it did not.
      #
      # Still on the prune cadence (once per PRUNE_INTERVAL inserts), so a project that never
      # inserts another flow heals only via `compact` — which reaps the same rows.
      reap_unattributed_h2_frames(conn)
      return if @retention_flows <= 0
      # Served by the primary key: a rightmost-leaf descending scan of @retention_flows rows.
      oldest_kept = conn.query_one?(
        "SELECT MIN(id) FROM (SELECT id FROM flows ORDER BY id DESC LIMIT ?)",
        @retention_flows, as: Int64?)
      return unless oldest_kept # no flows at all
      cutoff = oldest_kept - 1  # everything strictly below the oldest survivor goes
      return if cutoff <= 0
      dropped = 0_i64
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
        # Read changes() IMMEDIATELY after the flows delete — it reports the most recent
        # statement, so any query in between (including the h2 reaping below) would replace it.
        dropped = c.scalar("SELECT changes()").as(Int64)
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
      # Say that history was dropped. A sweep is otherwise completely silent, so a flow the
      # operator looked at an hour ago simply vanishing is indistinguishable from a bug. At most
      # one line per PRUNE_INTERVAL inserts, and only when flow rows actually went.
      log_retention_drop(dropped) if dropped > 0
    rescue ex
      ::Log.warn { "retention prune failed (will retry): #{ex.message}" } # gori.log, not STDERR (#411)
    end

    # Frames whose connection row does not exist at all. The guard in `insert_h2_frame` stops new
    # ones, but a db that ran an older build carries however many it wrote, and the retention
    # sweep can never reach them — it selects through `h2_connections`, and that is exactly the
    # row these frames do not have.
    #
    # `h2_connections.id` is an INTEGER PRIMARY KEY so the subquery yields no NULL, which is what
    # makes `NOT IN` safe here. Served by `idx_h2_frames_conn`. Its own transaction and its own
    # rescue, like the sweep it runs ahead of: this must never cost the batch that just committed.
    private def reap_unattributed_h2_frames(conn : DB::Connection) : Nil
      conn.exec("DELETE FROM h2_frames WHERE conn_id NOT IN (SELECT id FROM h2_connections)")
    rescue ex
      ::Log.warn { "unattributed h2-frame reap failed (will retry): #{ex.message}" } # gori.log (#411)
    end

    # One gori.log line per sweep that actually removed history, naming the setting that
    # controls it so the answer to "where did that flow go?" is in the message.
    private def log_retention_drop(dropped : Int64) : Nil
      ::Log.info { "retention: dropped #{dropped} oldest flow(s), keeping the newest #{@retention_flows} (settings retention.max_flows)" }
    end

    # Unblock a caller whose batch was rolled back, with a no-op fallback (no row
    # id, no event). The reply channels are buffered(1) so this never blocks.
    private def fail_reply(op : WriteOp) : Nil
      case op
      when InsertFlow        then op.reply.send(0_i64)
      when InsertImportBatch then op.reply.send([] of Int64)
      when UpdateResp        then op.reply.send(nil)
      when InsertWs          then op.reply.send(nil)
      when ExecTask          then op.reply.send(0_i64)
      when ExecTaskChecked   then op.reply.send(false)
      when AbandonPending    then op.reply.send(0_i32)
      end
    rescue
      # caller gone / channel closed — nothing to unblock
    end

    # Bulk-mark every Pending flow Error; returns the ids touched (for events). `unsent` rows
    # (import reference placeholders that were never sent) are EXCLUDED — they are permanently
    # Pending by design, not orphaned in-flight captures, so finalising them to Error would
    # fabricate a network failure for data the operator imported (#408).
    private def abandon_all_pending(conn : DB::Connection, message : String) : Array(Int64)
      ids = [] of Int64
      conn.query("SELECT id FROM flows WHERE state = ? AND unsent = 0", FlowState::Pending.value) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      return ids if ids.empty?
      conn.exec(
        "UPDATE flows SET state = ?, error = ?, status = 0 WHERE state = ? AND unsent = 0",
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

    # Blocking receive that puts an otherwise-idle writer to work on the FTS backlog.
    # Returns the next op, or nil when the channel closed.
    #
    # This is what makes trigram indexing off-commit affordable without a second connection:
    # SQLite has ONE writer, so the index work must still run on this fiber — the win is that
    # it no longer sits INSIDE the transaction a proxy fiber is blocked on. Capture keeps
    # strict priority (an op arriving during the wait is returned at once, and a batch is
    # never interrupted), so under sustained load indexing simply falls behind and the
    # backlog drains in the gaps — which is what `fts_backlog` exists to make visible.
    private def await_op(conn : DB::Connection) : WriteOp?
      loop do
        tick = @fts_backlog_hint ? FTS_IDLE_TICK_FAST : FTS_IDLE_TICK_SLOW
        select
        when op = @writes.receive
          return op
        when timeout(tick)
          # No capture work waiting: index a slice of the backlog and re-check.
          @fts_backlog_hint = false if index_pending_batch(conn) == 0
        end
      end
    rescue Channel::ClosedError
      nil # closing: the writer_loop exits; any remaining fts_dirty rows survive in the db
    end

    # Re-indexes up to FTS_BATCH dirty flows in one transaction; returns how many it did
    # (0 = backlog empty). Reads the text back out of the row rather than carrying it in
    # memory: that is what makes the backlog crash-safe and unbounded-in-size safe, and the
    # readback is cheap next to the tokenization it feeds (the body is SQL-capped to
    # FTS_INDEX_MAX before it ever crosses into Crystal).
    #
    # A failure here must not kill the writer or lose capture: it runs in its own
    # transaction and swallows errors, leaving the rows dirty for the next attempt.
    private def index_pending_batch(conn : DB::Connection) : Int32
      rows = [] of {Int64, Bytes, Bytes?, Bytes?, Bytes?, String?}
      begin
        # `content_type` comes from the COLUMN, not from re-parsing response_head: it is the
        # value the proxy already extracted from that head, and it is what the old on-commit
        # path skipped binary bodies on. A synthesised response (an import, a test double) can
        # carry a content type that never appeared in its head bytes, and deriving the marker
        # from the head would silently start indexing a binary body those callers marked.
        conn.query(
          "SELECT id, request_head, substr(request_body, 1, ?), response_head, substr(response_body, 1, ?), " \
          "content_type FROM flows WHERE fts_dirty = 1 ORDER BY id LIMIT ?",
          FTS_INDEX_MAX, FTS_INDEX_MAX, FTS_BATCH) do |rs|
          rs.each do
            rows << {rs.read(Int64), rs.read(Bytes), rs.read(Bytes?),
                     rs.read(Bytes?), rs.read(Bytes?), rs.read(String?)}
          end
        end
        return 0 if rows.empty?
        conn.transaction do |tx|
          c = tx.connection
          rows.each do |(id, req_head, req_body, resp_head, resp_body, resp_ct)|
            # The request side has no content_type column, so its marker comes from its head —
            # exactly what the old path did for the request body.
            req = body_fts_text(req_head, req_body)
            resp = resp_head.nil? ? "" : body_fts_text(resp_head, resp_body, resp_ct)
            # Contentless FTS5 forbids UPDATE, so a refresh is DELETE (a cheap tombstone under
            # contentless_delete=1) + INSERT. Unconditional rather than tracking whether this row
            # was ever indexed: it makes a re-index idempotent — and a double index pass, or one
            # racing a peer process, can't leave two entries matching the same rowid.
            c.exec("DELETE FROM flows_fts WHERE rowid = ?", id)
            c.exec("INSERT INTO flows_fts(rowid, req, resp) VALUES (?, ?, ?)", id, req, resp)
            c.exec("UPDATE flows SET fts_dirty = 0 WHERE id = ?", id)
          end
        end
        rows.size
      rescue ex
        # gori.log, not STDERR (#411). The rows stay dirty, so this self-heals; fts_backlog
        # keeps reporting them so a persistent failure is visible rather than silent.
        ::Log.warn { "FTS index batch failed (#{rows.size} flow(s), will retry): #{ex.message}" }
        0
      end
    end

    # The FTS text for one side, given that side's raw head and its already-capped body.
    # Skips a body that is binary by content type or compressed by Content-Encoding — the same
    # rule the old on-commit path applied. `ct`, when given (the response side), is the stored
    # content_type column and takes precedence over whatever the head says; the head is still
    # scanned for Content-Encoding, which has no column.
    private def body_fts_text(head : Bytes, body : Bytes?, ct : String? = nil) : String
      return "" if body.nil? || body.empty?
      return "" if ct && binary_content?(ct)
      skip_body_fts?(head) ? "" : String.new(body)
    end

    # Does this op leave a flow row `fts_dirty`? (Only flow writes touch the index.)
    private def dirties_fts?(op : WriteOp) : Bool
      op.is_a?(InsertFlow) || op.is_a?(UpdateResp) || op.is_a?(InsertImportBatch)
    end

    # Inserts the request row, marked `fts_dirty` for the off-commit indexer.
    private def insert_one(conn : DB::Connection, req : CapturedRequest, unsent : Bool = false) : Int64
      # request_size is the TRUE wire size (body_size when the BLOB was truncated),
      # so the History size column stays honest even for a capped body.
      body_size = req.body_size || req.body.try(&.size.to_i64) || 0_i64
      # 0 is not an id, it is the "no raw frame log for this connection" sentinel — that is what
      # `FlowSink#on_h2_open`'s default returns, and what `StoreSink#on_h2_open` hands back when
      # `insert_h2_connection` did not commit. Stored as-is it becomes a NON-NULL id pointing at
      # no row, and two History guards read this column with `.nil?` / a truthiness check:
      # `load_detail_logs` does `if cid = detail.h2_conn_id` — and `0_i64` is truthy in Crystal —
      # so the frame-log pane opened `h2_frames(0)`, which is the merged pile of EVERY
      # unattributed connection's frames shown under one flow. The other two treat a non-nil
      # value as "a streaming h2 flow, keep re-reading it", so a complete, immutable flow
      # re-fetched and re-split its body on every poll tick forever. NULL says the one true
      # thing: this flow has no frame log.
      h2_conn_id = req.h2_conn_id.try { |cid| cid > 0 ? cid : nil }
      # Built as an args array, in the column order listed below, so `request_head` can take the
      # `X\'\'` slot when it is empty (see Store.blob_slot — an empty slice would otherwise bind
      # SQL NULL and violate `BLOB NOT NULL`, rolling back this whole capture batch).
      args = [req.created_at, req.scheme, req.host, req.port, req.method, req.target,
              req.http_version, req.sni, req.alpn, req.tls_version] of DB::Any
      head_slot = Store.blob_slot(args, req.head)
      args << req.body
      args << req.head.size.to_i64 + body_size
      args << FlowState::Pending.value
      args << h2_conn_id
      args << req.h2_stream_id
      args << (req.body_truncated? ? 1 : 0)
      args << (unsent ? 1 : 0)
      args << (req.short_circuited? ? 1 : 0)
      args << req.advisory
      # Lifted off the head at CAPTURE time, beside the response's `content_type`. `Proto`
      # classifies a flow's application protocol from the content type and had only the
      # response's, so a gRPC call was gRPC exactly when it SUCCEEDED — a Pending one, an
      # aborted one, and one answered with a proxy's `text/html` 502 all read as plain HTTP,
      # which is the set an operator is looking through. `QL.proto_cond` compiles `proto:` to
      # SQL against this table, so the fact has to be a COLUMN or the label and the filter drift.
      args << MediaType.of(req.head)
      res = conn.exec(
        "INSERT INTO flows " \
        "(created_at, scheme, host, port, method, target, http_version, " \
        " sni, alpn, tls_version, request_head, request_body, request_size, state, " \
        " h2_conn_id, h2_stream_id, request_body_truncated, unsent, short_circuited, advisory, " \
        " request_content_type, fts_dirty) " \
        "VALUES (?,?,?,?,?,?,?,?,?,?,#{head_slot},?,?,?,?,?,?,?,?,?,?,1)", args: args)
      # The INSERT's own result carries the rowid — no separate `SELECT last_insert_rowid()`.
      # No flows_fts write here: `fts_dirty = 1` hands the trigram work to the off-commit
      # indexer, so a capture commit no longer pays for tokenization (see V4 / await_op).
      res.last_insert_id
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
            ttfb_us = ?, duration_us = ?, error = ?, response_body_truncated = ?,
            -- nil means "the response side has nothing to add", NOT "clear it": the request
            -- side may already have written an advisory on this row and a bare `advisory = ?`
            -- would erase it. COALESCE keeps whatever is stored when the DTO carries nothing.
            advisory = COALESCE(?, advisory),
            fts_dirty = 1
          WHERE id = ?
          SQL
        resp.head, resp.body, resp.status, resp.reason, resp.content_type,
        response_size,
        resp.state.value, resp.ttfb_us, resp.duration_us, resp.error,
        resp.body_truncated? ? 1 : 0, resp.advisory, resp.flow_id)
      # `fts_dirty = 1` again: the response side just appeared (or changed), so whatever the
      # indexer wrote for this row is stale. Re-dirtying an already-dirty row is a no-op, so
      # the common case — response landing before the indexer ever reached the row — is
      # indexed exactly ONCE, with both sides, instead of the old empty-insert + delete +
      # re-insert. That also makes a double update_response idempotent (last write wins).
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
      args = [op.flow_id, op.repeater_id, op.created_at, op.direction, op.opcode] of DB::Any
      # `Store.blob_slot` — the site that first found this trap, now using the one helper that
      # owns it, so the rule has a single implementation rather than this copy plus that one.
      slot = Store.blob_slot(args, op.payload)
      Store.bind_ws_shape(args, op.shape)
      conn.exec(
        "INSERT INTO ws_messages (flow_id, repeater_id, created_at, direction, opcode, payload, " \
        "fin, rsv, masked, mask_key, frames, declared_len) " \
        "VALUES (?,?,?,?,?,#{slot},?,?,?,?,?,?)", args: args)
    end

    # Append `value` to `args` and answer the placeholder to write in its slot — `X''` for an
    # EMPTY slice, `?` otherwise.
    #
    # An empty `Bytes` is a NULL POINTER, and the driver binds a null pointer as SQL NULL, so a
    # zero-length blob handed to a `BLOB NOT NULL` column violates the constraint instead of
    # storing nothing. `insert_ws_one` and `insert_h2_frame_one` each discovered this and each
    # wrote their own `X''` branch; the remaining NOT NULL BLOB columns (`flows.request_head`,
    # `miner_sessions.request`, `sequencer_sessions.request`) did not, and measured, an empty
    # value there did not merely drop its own row — the violation RAISES inside the writer
    # transaction, so the whole BATCH rolls back, taking every captured flow the writer had
    # grouped with it, and (before the teardown guards) poisoned the connection into hanging
    # `Store#close`. One helper now, so a fourth column cannot rediscover it.
    def self.blob_slot(args : Array(DB::Any), value : Bytes) : String
      return "X''" if value.empty?
      args << value
      "?"
    end

    # The six V7 shape columns, in the order every `ws_messages` INSERT lists them. Shared
    # by the capture writer and `update_repeater_ws_messages` so a captured frame and the
    # repeater row seeded from it cannot drift apart.
    #
    # An empty `mask_key` binds SQL NULL (an empty Bytes is a null pointer — the same trap
    # `payload` has), which would read back as "no key" rather than "the all-zero key". A
    # zero-length key is not a shape anything produces, so it is normalised to NULL here
    # rather than given an X'' branch of its own.
    def self.bind_ws_shape(args : Array(DB::Any), shape : WsShape) : Nil
      args << (shape.fin ? 1_i64 : 0_i64)
      args << shape.rsv.to_i64
      args << shape.masked.try { |m| m ? 1_i64 : 0_i64 }
      key = shape.mask_key
      args << (key && !key.empty? ? key : nil)
      args << shape.frames.to_i64
      args << shape.declared_len.try(&.to_i64)
    end

    # The same six columns read back. `masked` stays nilable: a pre-V7 row genuinely does
    # not know whether the frame was masked, which is not the same as knowing it was not.
    def self.read_ws_shape(rs : DB::ResultSet) : WsShape
      fin = rs.read(Int64) != 0
      rsv = rs.read(Int64).to_i
      masked = rs.read(Int64?).try { |m| m != 0 }
      mask_key = rs.read(Bytes?)
      frames = rs.read(Int64).to_i
      declared = rs.read(Int64?).try(&.to_i)
      WsShape.new(fin: fin, rsv: rsv, masked: masked, mask_key: mask_key,
        frames: frames, declared_len: declared)
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

    # Runs a write closure and returns whether its batch COMMITTED (true) or was
    # rolled back / the store is closing (false). Use for UPDATE/DELETE mutations where
    # a caller must know the write actually persisted (last_insert_rowid can't tell a
    # committed non-INSERT from a rollback). A false is transient (cross-process SQLite
    # busy/lock) → the caller surfaces PROJECT_BUSY (retryable).
    private def exec_task_ok(run : DB::Connection -> Nil) : Bool
      reply = Channel(Bool).new(1) # buffered: the writer must never block sending a reply
      @writes.send(ExecTaskChecked.new(run, reply))
      reply.receive
    rescue Channel::ClosedError
      false # store closing — treat as a failed write
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
      short_circuited = rs.read(Int32) != 0
      advisory = rs.read(String?)
      request_content_type = rs.read(String?)
      FlowRow.new(id, created_at, scheme, method, host, port, target,
        status, req_size + (resp_size || 0_i64), state, resp_size, duration_us, content_type,
        short_circuited, advisory, request_content_type)
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
