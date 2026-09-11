require "db"

module Gori
  class Store
    # --- frozen issue evidence (V26, #1038) ----------------------------------

    # Why a freeze did not happen. `Ok` carries the new row's id in the tuple beside it.
    enum FreezeStatus
      Ok
      IssueGone # the issue was deleted between the operator's pick and the write
      Quota     # this copy would push the project past `Evidence::QUOTA_BYTES`
      Busy      # the batch never committed (SQLite busy/locked, or the store is closing)
    end

    # Freeze one exchange as evidence linked to `issue_id`. ONE transaction for the copy,
    # its Issue membership, AND the optional live source link (`link:` — the picker's
    # "link & freeze"), so a partial failure can leave none of the three half-written.
    #
    # The two refusals are decided INSIDE the writer's transaction, against the rows as they
    # are when the write lands, rather than pre-checked by the caller: a `get_issue` a moment
    # earlier says nothing about the issue still existing when the batch commits, and a quota
    # summed on a pool connection races every other freeze. Refusing by not writing — never by
    # raising — matters too: the writer batches ops from every fiber into one transaction, and
    # a raise here would roll back a neighbour's unrelated write.
    #
    # Returns `{id, status}`; `id` is 0 unless the status is Ok. Like `insert_issue`, the id is
    # trusted only once the batch reports COMMITTED — the rowid read inside the closure belongs
    # to a row that may yet roll back.
    def freeze_evidence(issue_id : Int64, snap : Evidence::Snapshot, *, link : Bool = false,
                        quota : Int64 = Evidence::QUOTA_BYTES) : {Int64, FreezeStatus}
      ts = now_us
      row_id = 0_i64
      status = FreezeStatus::Busy
      ok = exec_task_ok ->(c : DB::Connection) {
        # A proc has no early `next`, so the two refusals fall through one `if` ladder.
        exists = c.scalar("SELECT COUNT(*) FROM issues WHERE id = ?", issue_id).as(Int64) > 0
        used = c.scalar("SELECT COALESCE(SUM(bytes), 0) FROM issue_evidence").as(Int64)
        if !exists
          status = FreezeStatus::IssueGone
        elsif used + snap.bytes > quota
          status = FreezeStatus::Quota
        else
          row_id = write_evidence(c, issue_id, ts, snap, link)
          status = FreezeStatus::Ok
        end
        nil
      }
      return {0_i64, FreezeStatus::Busy} unless ok
      status.ok? ? {row_id, status} : {0_i64, status}
    end

    # The INSERT pair, on an open connection inside the writer's transaction; answers the
    # evidence row's id. That id is read BEFORE the link insert, which would otherwise
    # overwrite last_insert_rowid — the trap `insert_issue` names.
    private def write_evidence(c : DB::Connection, issue_id : Int64, ts : Int64,
                               snap : Evidence::Snapshot, link : Bool) : Int64
      # An EMPTY head binds SQL NULL under crystal-sqlite3 (a null-pointer slice) and the
      # column is NOT NULL — see `insert_ws_one`, which stores `X''` for the same reason. A
      # raise here would roll back a neighbour's write in the shared batch.
      head_empty = snap.request_head.empty?
      args = [ts, snap.source_kind.label, snap.source_id, snap.method, snap.url,
              snap.protocol, snap.status, snap.duration_us, snap.error] of DB::Any
      args << snap.request_head unless head_empty
      args.concat([snap.request_body, snap.response_head, snap.response_body,
                   snap.request_truncated? ? 1 : 0, snap.response_truncated? ? 1 : 0,
                   snap.request_sha256, snap.response_sha256, snap.bytes] of DB::Any)
      c.exec(
        "INSERT INTO issue_evidence (created_at, source_kind, source_id, method, url, " \
        "protocol, status, duration_us, error, request_head, request_body, response_head, " \
        "response_body, request_truncated, response_truncated, request_sha256, response_sha256, bytes) " \
        "VALUES (?,?,?,?,?,?,?,?,?,#{head_empty ? "X''" : "?"},?,?,?,?,?,?,?,?)", args: args)
      id = c.scalar("SELECT last_insert_rowid()").as(Int64)
      c.exec(
        "INSERT INTO evidence_issue_links (evidence_id, issue_id, created_at) VALUES (?, ?, ?)",
        id, issue_id, ts)
      if link
        c.exec(
          "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', ?, ?, ?, ?)",
          issue_id, snap.source_kind.label, snap.source_id, ts)
      end
      id
    end

    # An issue's snapshots, oldest first — the order they were taken in is the story they
    # tell ("confirmed before the fix, still present after the retest").
    def issue_evidence(issue_id : Int64) : Array(IssueEvidenceMeta)
      list = [] of IssueEvidenceMeta
      @db.query(
        "SELECT #{EVIDENCE_META_COLS} FROM issue_evidence " \
        "WHERE id IN (SELECT evidence_id FROM evidence_issue_links WHERE issue_id = ?) " \
        "ORDER BY created_at, id",
        issue_id) do |rs|
        rs.each { try_read_evidence_meta(rs).try { |m| list << m } }
      end
      list
    end

    # Every snapshot in the project, newest first — the Evidence tab's archive. Metadata
    # only; selecting one is the point where the byte BLOBs are read.
    def evidence : Array(IssueEvidenceMeta)
      list = [] of IssueEvidenceMeta
      @db.query("SELECT #{EVIDENCE_META_COLS} FROM issue_evidence ORDER BY created_at DESC, id DESC") do |rs|
        rs.each { try_read_evidence_meta(rs).try { |m| list << m } }
      end
      list
    end

    def get_evidence_meta(id : Int64) : IssueEvidenceMeta?
      @db.query("SELECT #{EVIDENCE_META_COLS} FROM issue_evidence WHERE id = ?", id) do |rs|
        return try_read_evidence_meta(rs) if rs.move_next
      end
      nil
    end

    # The full snapshot, bytes included — the read-only viewer and the raw export.
    def get_evidence(id : Int64) : IssueEvidence?
      @db.query(
        "SELECT #{EVIDENCE_META_COLS}, request_head, request_body, response_head, response_body " \
        "FROM issue_evidence WHERE id = ?", id) do |rs|
        if rs.move_next
          meta = try_read_evidence_meta(rs) || return nil
          return IssueEvidence.new(meta, rs.read(Bytes), rs.read(Bytes?), rs.read(Bytes?), rs.read(Bytes?))
        end
      end
      nil
    end

    # Returns whether the write committed (false = store busy/locked/closing). Membership
    # rows go first in the same transaction so no dangling reference can survive the delete.
    def delete_evidence(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM evidence_issue_links WHERE evidence_id = ?", id)
        c.exec("DELETE FROM issue_evidence WHERE id = ?", id)
        nil
      }
    end

    # Attach/detach a finding without touching one byte or hash of the snapshot. Both ends
    # are checked inside the writer transaction; a peer deleting either between picker and
    # commit therefore produces a clean false rather than a dangling membership row.
    def link_evidence(id : Int64, issue_id : Int64) : Bool
      linked = false
      ok = exec_task_ok ->(c : DB::Connection) {
        ev = c.scalar("SELECT COUNT(*) FROM issue_evidence WHERE id = ?", id).as(Int64) > 0
        issue = c.scalar("SELECT COUNT(*) FROM issues WHERE id = ?", issue_id).as(Int64) > 0
        if ev && issue
          c.exec("INSERT OR IGNORE INTO evidence_issue_links (evidence_id, issue_id, created_at) VALUES (?, ?, ?)",
            id, issue_id, now_us)
          linked = true
        end
        nil
      }
      ok && linked
    end

    def unlink_evidence(id : Int64, issue_id : Int64) : Bool
      unlinked = false
      ok = exec_task_ok ->(c : DB::Connection) {
        exists = c.scalar(
          "SELECT COUNT(*) FROM evidence_issue_links WHERE evidence_id = ? AND issue_id = ?",
          id, issue_id).as(Int64) > 0
        if exists
          c.exec("DELETE FROM evidence_issue_links WHERE evidence_id = ? AND issue_id = ?", id, issue_id)
          unlinked = true
        end
        nil
      }
      ok && unlinked
    end

    # How many frozen copies exist of one live source — the History detail's and the
    # Repeater's marker, which says "a frozen copy exists", never "this is immutable".
    #
    # A Repeater id is REUSED: `repeaters.id` has no AUTOINCREMENT and the newest tab is the
    # one closed most often, so a fresh tab can inherit the id of a closed one whose copies
    # deliberately outlive it (`delete_repeater` leaves `issue_evidence` alone). Counting by
    # id alone would badge that new tab with an exchange it never had. A copy is taken from
    # a tab that already exists, so only copies frozen AT OR AFTER the current row's
    # `created_at` can be this tab's; the rest belong to a predecessor. Flow ids never
    # return (both prune paths delete from the bottom), so the flow count needs no such guard.
    def evidence_count_for(kind : LinkRefKind, source_id : Int64) : Int32
      if kind.repeater?
        return @db.scalar(
          "SELECT COUNT(*) FROM issue_evidence e WHERE e.source_kind = 'repeater' AND e.source_id = ? " \
          "AND e.created_at >= (SELECT created_at FROM repeaters WHERE id = ?)",
          source_id, source_id).as(Int64).to_i
      end
      @db.scalar("SELECT COUNT(*) FROM issue_evidence WHERE source_kind = ? AND source_id = ?",
        kind.label, source_id).as(Int64).to_i
    end

    # Bytes the project's evidence currently holds against `Evidence::QUOTA_BYTES`.
    def evidence_bytes : Int64
      @db.scalar("SELECT COALESCE(SUM(bytes), 0) FROM issue_evidence").as(Int64)
    end

    def count_evidence : Int32
      @db.scalar("SELECT COUNT(*) FROM issue_evidence").as(Int64).to_i
    end

    private EVIDENCE_META_COLS = "id, COALESCE((SELECT group_concat(issue_id, ',') FROM " \
                                 "(SELECT issue_id FROM evidence_issue_links WHERE evidence_id = issue_evidence.id ORDER BY issue_id)), ''), " \
                                 "created_at, source_kind, source_id, method, url, protocol, " \
                                 "status, duration_us, error, request_truncated, response_truncated, " \
                                 "request_sha256, response_sha256, bytes"

    # nil on a `source_kind` this build cannot name — the same skip `try_read_entity_link`
    # makes, so a row a newer gori wrote is left alone rather than crashing the detail.
    private def try_read_evidence_meta(rs : DB::ResultSet) : IssueEvidenceMeta?
      id = rs.read(Int64)
      issue_ids = rs.read(String).split(',').compact_map(&.to_i64?)
      created_at = rs.read(Int64)
      kind = LinkRefKind.parse(rs.read(String))
      source_id = rs.read(Int64)
      method = rs.read(String)
      url = rs.read(String)
      protocol = rs.read(String?)
      status = rs.read(Int32?)
      duration_us = rs.read(Int64?)
      error = rs.read(String?)
      req_trunc = rs.read(Int64) != 0
      resp_trunc = rs.read(Int64) != 0
      req_sha = rs.read(String)
      resp_sha = rs.read(String?)
      bytes = rs.read(Int64)
      return nil unless kind
      IssueEvidenceMeta.new(id, issue_ids, created_at, kind, source_id, method, url, protocol,
        status, duration_us, error, req_trunc, resp_trunc, req_sha, resp_sha, bytes)
    end
  end
end
