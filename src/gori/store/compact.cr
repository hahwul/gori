require "db"
require "sqlite3"
require "../capture_lock"
require "./schema"

# On-demand project compaction: drop the less-important, space-dominating data
# (captured bodies, the raw HTTP/2 frame log, WebSocket payloads, fuzzer result
# captures, optionally the oldest flows) and then VACUUM to hand the freed pages
# back to the OS — shrinking the on-disk `gori.db` while keeping each flow's
# projection (URL/method/status/sizes/headers), the sitemap, findings, notes,
# scope, repeaters and custom rules intact.
#
# This is the manual counterpart to the automatic one-time `reclaim_to_disk`
# (run on a schema upgrade). It runs against a project that is NOT open in this
# process — the ProjectPicker triggers it before any Store/session exists — so it
# opens its own short-lived connection. It takes the per-project CAPTURE LOCK for
# the duration, refusing (nil) if another live instance is capturing into the DB,
# the same guard `ProjectRegistry#delete` uses before wiping a project.
class Gori::Store
  # Which categories the operator chose to strip. `keep_flows` (when set) also
  # deletes whole flow rows older than the newest N — the only option that drops
  # history rows rather than just their heavy blobs; nil keeps every flow.
  record CompactPlan,
    response_bodies : Bool = false,
    request_bodies : Bool = false,
    h2_frames : Bool = false,
    ws_messages : Bool = false,
    fuzz_bodies : Bool = false,
    keep_flows : Int32? = nil do
    # VACUUM alone (no category selected) still reclaims already-freed pages, so a
    # plan is never a no-op; this just tells the UI whether any data is removed.
    def removes_data? : Bool
      response_bodies || request_bodies || h2_frames || ws_messages || fuzz_bodies || !keep_flows.nil?
    end
  end

  # Reclaimable byte estimates per category (summed blob lengths) plus the current
  # on-disk size and flow count — fed to the compress popup so each option shows
  # roughly how much it would free. Estimates ignore per-row/page overhead, so the
  # real post-VACUUM saving is usually a little larger.
  record CompactStats,
    db_bytes : Int64,
    response_body_bytes : Int64,
    request_body_bytes : Int64,
    h2_bytes : Int64,
    ws_bytes : Int64,
    fuzz_bytes : Int64,
    flow_count : Int64

  # On-disk size before and after a compaction, for the picker's result line. `vacuumed`
  # is false when the strip committed but VACUUM (which needs ~db-size scratch) failed — the
  # data WAS removed, only the OS-level reclaim was skipped, so the caller must not report
  # "compress failed".
  record CompactResult, before_bytes : Int64, after_bytes : Int64, vacuumed : Bool = true do
    def reclaimed_bytes : Int64
      {before_bytes - after_bytes, 0_i64}.max
    end
  end

  # SQLite connection URL for a project db (WAL, same pragmas as Store.open).
  private def self.compact_url(path : String) : String
    "sqlite3:#{path}?journal_mode=wal&synchronous=normal&busy_timeout=5000"
  end

  # Read-only measurement for the compress popup. Opens the db, sums the blob
  # lengths per category, closes. Each aggregate is guarded so a project on an
  # older schema (e.g. missing `ws_messages.repeater_id`) still measures the
  # columns it does have rather than raising.
  def self.measure(path : String) : CompactStats
    db_bytes = File.exists?(path) ? File.info(path).size : 0_i64
    return CompactStats.new(db_bytes, 0, 0, 0, 0, 0, 0) unless File.exists?(path)
    db = DB.open(compact_url(path))
    begin
      # One scan of the (large) flows table for both body sums + the count, instead of three.
      resp, req, flows = begin
        db.query_one("SELECT COALESCE(SUM(LENGTH(response_body)), 0), COALESCE(SUM(LENGTH(request_body)), 0), COUNT(*) FROM flows", as: {Int64, Int64, Int64})
      rescue
        {0_i64, 0_i64, 0_i64}
      end
      h2 = sum_len(db, "SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM h2_frames")
      ws = sum_len(db, "SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM ws_messages WHERE repeater_id IS NULL")
      fuzz = sum_len(db, "SELECT COALESCE(SUM(COALESCE(LENGTH(request), 0) + COALESCE(LENGTH(response_head), 0) + COALESCE(LENGTH(response_body), 0)), 0) FROM fuzz_results")
      CompactStats.new(db_bytes, resp, req, h2, ws, fuzz, flows)
    ensure
      db.close
    end
  end

  # A single-scalar aggregate that returns 0 when the table/column is absent
  # (old-schema project) instead of raising into the caller.
  private def self.sum_len(db : DB::Database, sql : String) : Int64
    db.scalar(sql).as(Int64)
  rescue
    0_i64
  end

  # Strip the selected data and VACUUM. Returns the before/after on-disk sizes, or
  # nil when another live instance holds the capture lock (the project is being
  # captured into — compaction would race its writer). The DELETE step is atomic:
  # every deletion runs in one transaction; a failure there rolls it back and re-raises
  # so the caller can surface it (the file is left fully usable). VACUUM runs AFTER that
  # commit (it is illegal inside a transaction) and CANNOT be rolled back, so its failure
  # is caught and reported via CompactResult#vacuumed=false rather than re-raised — the
  # data is already gone, only the disk reclaim was skipped.
  def self.compact(path : String, plan : CompactPlan) : CompactResult?
    return nil unless File.exists?(path)
    dir = File.dirname(path)
    lock = CaptureLock.try(dir)
    return nil unless lock # another live instance is capturing into this project
    begin
      before = File.info(path).size
      db = DB.open(compact_url(path))
      begin
        # Bring an older project up to the current schema so the table/column
        # names below (issues/probe/repeater renames, repeater_id, truncated
        # flags) are guaranteed present — same as opening it would.
        Schema.migrate!(db)
        db.transaction do |tx|
          apply_plan(tx.connection, plan)
        end
        # VACUUM rewrites the whole file to reclaim freed pages; it is ILLEGAL
        # inside a transaction (see schema.cr) so it runs after the commit. The strip
        # is now durable, so a VACUUM failure (e.g. SQLITE_FULL — it needs ~db-size
        # scratch) must NOT re-raise as "compress failed": the data is already removed.
        vacuumed = true
        begin
          db.exec("VACUUM")
        rescue
          vacuumed = false
        end
      ensure
        db.close
      end
      # VACUUM may recreate the -wal/-shm sidecars; re-tighten them to 0600.
      harden_permissions(path)
      CompactResult.new(before, File.info(path).size, vacuumed)
    ensure
      lock.close
    end
  end

  # Runs the chosen removals on `conn` inside the caller's transaction. Blobs are
  # emptied to X'' (keeping the row + its projection columns) rather than the
  # column nulled, so `*_body_truncated` reads as "captured but dropped".
  private def self.apply_plan(conn : DB::Connection, plan : CompactPlan) : Nil
    if plan.response_bodies
      conn.exec("UPDATE flows SET response_body = X'', response_body_truncated = 1 " \
                "WHERE response_body IS NOT NULL AND LENGTH(response_body) > 0")
    end
    if plan.request_bodies
      conn.exec("UPDATE flows SET request_body = X'', request_body_truncated = 1 " \
                "WHERE request_body IS NOT NULL AND LENGTH(request_body) > 0")
    end
    if plan.h2_frames
      # The raw h2 frame log is a detail-view-only diagnostic; each flow rebuilds
      # from its own request_head/response_head, so dropping it loses no traffic.
      conn.exec("DELETE FROM h2_frames")
      conn.exec("DELETE FROM h2_connections")
    end
    if plan.ws_messages
      # Only CAPTURED ws frames (repeater_id IS NULL); WebSocket-Repeater output
      # (keyed by repeater_id) is user-authored workbench state and is spared.
      conn.exec("DELETE FROM ws_messages WHERE repeater_id IS NULL")
    end
    if plan.fuzz_bodies
      # Drop the per-result captured bytes but keep status/length/words/lines/
      # matched/extracted — the fuzzer table stays useful, just without payloads.
      conn.exec("UPDATE fuzz_results SET request = X'', response_head = X'', response_body = X'' " \
                "WHERE (COALESCE(LENGTH(request), 0) + COALESCE(LENGTH(response_head), 0) + COALESCE(LENGTH(response_body), 0)) > 0")
    end
    if keep = plan.keep_flows
      prune_old_flows(conn, keep)
    end
  end

  # Keep only the newest `keep` flows (by id, which is monotonic), cascading to
  # their ws messages, FTS rows and orphaned h2 frames/connections — the same
  # cascade the retention sweep (`prune`) uses, but with an explicit keep count.
  private def self.prune_old_flows(conn : DB::Connection, keep : Int32) : Nil
    return if keep <= 0
    max_id = conn.query_one?("SELECT MAX(id) FROM flows", as: Int64?)
    return unless max_id
    cutoff = max_id - keep
    return if cutoff <= 0
    conn.exec("DELETE FROM ws_messages WHERE flow_id <= ? AND repeater_id IS NULL", cutoff)
    conn.exec("DELETE FROM flows_fts WHERE rowid <= ?", cutoff)
    conn.exec("DELETE FROM flows WHERE id <= ?", cutoff)
    # Reap a connection's raw log only once it is neither referenced by a surviving
    # flow nor still logging recent frames (identical guard to Store#prune).
    oldest = conn.query_one?("SELECT MIN(created_at) FROM flows", as: Int64?) || Int64::MAX
    stale = "id NOT IN (SELECT h2_conn_id FROM flows WHERE h2_conn_id IS NOT NULL) " \
            "AND id NOT IN (SELECT conn_id FROM h2_frames WHERE created_at >= ?)"
    conn.exec("DELETE FROM h2_frames WHERE conn_id IN (SELECT id FROM h2_connections WHERE #{stale})", oldest)
    conn.exec("DELETE FROM h2_connections WHERE #{stale}", oldest)
  end
end
