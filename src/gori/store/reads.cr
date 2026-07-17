require "db"

module Gori
  class Store
    # --- read API (go straight through the pool; WAL allows concurrent reads) -

    SELECT_ROW = <<-SQL
      SELECT id, created_at, scheme, method, host, port, target, status,
             request_size, response_size, state, duration_us, content_type
      FROM flows
      SQL

    # Newest-first page of the History list. `before_id` is a cursor for paging
    # into older rows (stable as new rows append, unlike OFFSET). `since_id` is the
    # opposite FORWARD cursor (id > since_id, OLDEST-first) so a caller — e.g. the #124
    # MCP feed — can tail NEW flows exactly-once. The two are mutually exclusive; when
    # both are given since_id wins (the MCP layer rejects the combination up front).
    def recent_flows(limit : Int32, before_id : Int64? = nil, since_id : Int64? = nil) : Array(FlowRow)
      rows = [] of FlowRow
      sql, args = if since_id
                    {"#{SELECT_ROW} WHERE id > ? ORDER BY id ASC LIMIT ?", [since_id, limit] of DB::Any}
                  elsif before_id
                    {"#{SELECT_ROW} WHERE id < ? ORDER BY id DESC LIMIT ?", [before_id, limit] of DB::Any}
                  else
                    {"#{SELECT_ROW} ORDER BY id DESC LIMIT ?", [limit] of DB::Any}
                  end
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
    def search(filter : QL::Filter, limit : Int32, before_id : Int64? = nil, since_id : Int64? = nil, *,
               raise_on_error : Bool = false) : Array(FlowRow)
      rows = [] of FlowRow
      args = filter.args.dup
      if since_id
        args << since_id
        args << limit
        sql = "#{SELECT_ROW} WHERE (#{filter.sql}) AND id > ? ORDER BY id ASC LIMIT ?"
      elsif before_id
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

    EVENT_COLS = "id, created_at, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload"

    # #124 forward cursor: events with id strictly AFTER `since_id`, OLDEST-first, up to
    # `limit`. Mirrors ws_messages_after — the AI tails the feed exactly-once from a
    # monotonic high-water-mark (id is the never-reused AUTOINCREMENT key).
    def events_after(since_id : Int64, limit : Int32) : Array(EventRow)
      rows = [] of EventRow
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id > ? ORDER BY id ASC LIMIT ?",
        args: [since_id, limit.to_i64] of DB::Any) do |rs|
        rs.each { rows << read_event(rs) }
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

    # A representative flow id for a (host, method, target) Sitemap node — prefers a
    # completed flow (one with a response), newest first. Used by the Sitemap "Send to
    # Repeater" action, whose node carries no flow id (it's a distinct-tuple aggregate).
    def representative_flow_id(host : String, method : String, target : String) : Int64?
      @db.query("SELECT id FROM flows WHERE host = ? AND method = ? AND target = ? ORDER BY (status IS NOT NULL) DESC, id DESC LIMIT 1",
        host, method, target) do |rs|
        return rs.read(Int64) if rs.move_next
      end
      nil
    end

    # Full detail incl. raw BLOBs (the truth) for the detail view.
    # `body_max`, when set, caps request/response body BLOBs via SQLite `substr`
    # (byte-oriented on BLOBs) so list-preview paths never pull multi-MiB bodies
    # that they would immediately re-truncate. Heads stay whole (small). Pass
    # `body_max + 1` when the caller wants to detect "was larger than cap".
    def get_flow(id : Int64, *, body_max : Int32? = nil) : FlowDetail?
      if max = body_max
        @db.query(<<-SQL, max, max, id) do |rs|
          SELECT id, created_at, scheme, method, host, port, target, status,
                 request_size, response_size, state, duration_us, content_type,
                 http_version, request_head,
                 CASE WHEN request_body IS NULL THEN NULL ELSE substr(request_body, 1, ?) END,
                 response_head,
                 CASE WHEN response_body IS NULL THEN NULL ELSE substr(response_body, 1, ?) END,
                 h2_conn_id, h2_stream_id, request_body_truncated, response_body_truncated, error,
                 sni
          FROM flows WHERE id = ?
          SQL
          return read_flow_detail(rs)
        end
      else
        @db.query(<<-SQL, id) do |rs|
          SELECT id, created_at, scheme, method, host, port, target, status,
                 request_size, response_size, state, duration_us, content_type,
                 http_version, request_head, request_body, response_head, response_body,
                 h2_conn_id, h2_stream_id, request_body_truncated, response_body_truncated, error,
                 sni
          FROM flows WHERE id = ?
          SQL
          return read_flow_detail(rs)
        end
      end
      nil
    end

    private def read_flow_detail(rs : DB::ResultSet) : FlowDetail?
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
      FlowDetail.new(row, http_version, req_head, req_body, resp_head, resp_body,
        h2_conn, h2_stream, req_trunc, resp_trunc, err, sni)
    end

    def count : Int64
      @db.scalar("SELECT COUNT(*) FROM flows").as(Int64)
    end

    # Hard-delete one History flow and its captured dependents (WS messages, FTS row,
    # entity_links that pointed at it, and its h2 frame log when no sibling flow still shares
    # the connection). Issues/Probe/Repeater that referenced the id keep the dangling
    # cross-ref — their resolvers already surface "gone". Writer-fiber only so it races
    # cleanly with live capture.
    def delete_flow(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        delete_flow_one(c, id)
        nil
      }
    end

    # Wipe every captured History flow in this project (and their WS/FTS/h2 logs and
    # flow entity_links). Repeater-owned WS rows (repeater_id set) and workbench sessions
    # are left intact. Issues/Probe keep dangling sample flow ids.
    def clear_flows : Nil
      exec_task ->(c : DB::Connection) {
        # Captured WS only — WebSocket-Repeater output is keyed by repeater_id.
        c.exec("DELETE FROM ws_messages WHERE repeater_id IS NULL")
        # contentless FTS: per-row DELETE is a tombstone; wipe the whole index in one go
        # so a large clear doesn't leave a full-size tombstone table behind.
        c.exec("INSERT INTO flows_fts(flows_fts) VALUES('delete-all')")
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'flow'")
        c.exec("DELETE FROM flows")
        c.exec("DELETE FROM h2_frames")
        c.exec("DELETE FROM h2_connections")
        @pending_req_fts.clear
        nil
      }
    end

    # Cascade for one flow id (writer connection). Shared by delete_flow.
    private def delete_flow_one(conn : DB::Connection, id : Int64) : Nil
      conn.exec("DELETE FROM ws_messages WHERE flow_id = ? AND repeater_id IS NULL", id)
      conn.exec("DELETE FROM flows_fts WHERE rowid = ?", id)
      conn.exec("DELETE FROM entity_links WHERE ref_kind = 'flow' AND ref_id = ?", id)
      # The h2 frame log (often the flow's bulk bytes) — capture the conn BEFORE deleting
      # the flow row so we can reclaim it if this was the last flow on that connection.
      h2_conn = conn.query_one?("SELECT h2_conn_id FROM flows WHERE id = ?", id, as: Int64?)
      conn.exec("DELETE FROM flows WHERE id = ?", id)
      # An HTTP/2 connection multiplexes many flows/streams, so only drop its log once NO
      # surviving flow still references it. The retention prune's activity gate would keep
      # a recent flow's log unreclaimed until later captures advance the floor, so an
      # explicit user delete reclaims it directly here (no activity gate — this flow is gone).
      if cid = h2_conn
        conn.exec("DELETE FROM h2_frames WHERE conn_id = ? AND ? NOT IN (SELECT h2_conn_id FROM flows WHERE h2_conn_id IS NOT NULL)", cid, cid)
        conn.exec("DELETE FROM h2_connections WHERE id = ? AND id NOT IN (SELECT h2_conn_id FROM flows WHERE h2_conn_id IS NOT NULL)", cid, cid)
      end
      @pending_req_fts.delete(id)
    end

    # Distinct host values for History QL Tab-complete (`host:`). Prefix-filtered
    # (case-insensitive), hard-capped so a huge capture history never materialises
    # the full DISTINCT set on every keystroke. Uses idx_flows_sitemap's leading
    # host column; never raises into the TUI run loop.
    def distinct_hosts(*, prefix : String = "", limit : Int32 = 16) : Array(String)
      lim = limit.clamp(1, 64)
      hosts = [] of String
      if prefix.empty?
        @db.query("SELECT DISTINCT host FROM flows ORDER BY host LIMIT ?", lim) do |rs|
          rs.each { hosts << rs.read(String) }
        end
      else
        # Prefix match only (trailing %); escape LIKE metacharacters in the typed prefix.
        pat = "#{QL.like_escape(prefix.downcase)}%"
        @db.query("SELECT DISTINCT host FROM flows WHERE lower(host) LIKE ? ESCAPE '\\' ORDER BY host LIMIT ?",
          pat, lim) do |rs|
          rs.each { hosts << rs.read(String) }
        end
      end
      hosts
    rescue
      [] of String
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
    # another connection commits. In gori the long-lived writer fiber holds one
    # pool connection, and this read uses a different pool connection — so own
    # commits via exec_task/insert_flow/update_* ALSO bump the value seen here,
    # not only a second gori process. The TUI polls this for live refresh and
    # must treat bumps as "maybe us, maybe a peer": soft-sync and skip unchanged
    # session state (never full-restore on every tick).
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

    # A distinct sitemap endpoint keyed by TRANSPORT (scheme/port/http_version), not
    # just host/method/target — so the same path over http vs https vs h2 stays
    # separate instead of collapsing into one row. Carries the observed status set +
    # success/error counts + first/last-seen so the transport's health is visible.
    record SitemapEntry,
      scheme : String, host : String, port : Int32, http_version : String,
      method : String, target : String,
      statuses : String?, count : Int64, ok : Int64, errors : Int64,
      first_seen : Int64, last_seen : Int64

    def sitemap_entries_detailed(filter : QL::Filter = QL::EMPTY, limit : Int32 = SITEMAP_MAX, *,
                                 raise_on_error : Bool = false) : Array(SitemapEntry)
      rows = [] of SitemapEntry
      args = filter.args.dup
      args << limit
      sql = "SELECT scheme, host, port, http_version, method, target, " \
            "GROUP_CONCAT(DISTINCT status), COUNT(*), " \
            "SUM(CASE WHEN status BETWEEN 200 AND 399 THEN 1 ELSE 0 END), " \
            "SUM(CASE WHEN status = 0 OR status >= 400 THEN 1 ELSE 0 END), " \
            "MIN(created_at), MAX(created_at) " \
            "FROM flows WHERE #{filter.sql} " \
            "GROUP BY scheme, host, port, http_version, method, target " \
            "ORDER BY host, target LIMIT ?"
      @db.query(sql, args: args) do |rs|
        rs.each do
          rows << SitemapEntry.new(
            rs.read(String), rs.read(String), rs.read(Int32), rs.read(String),
            rs.read(String), rs.read(String),
            rs.read(String?), rs.read(Int64), rs.read(Int64), rs.read(Int64),
            rs.read(Int64), rs.read(Int64))
        end
      end
      rows
    rescue ex
      raise ex if raise_on_error
      STDERR.puts "gori: sitemap query failed (#{ex.message})"
      [] of SitemapEntry
    end

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

    # Passive-signal tags for a flow, fetched lazily per on-screen row (P8 pull,
    # not push). No tag producer exists this milestone, so this is always empty;
    # the call site is the seam.
    def flags_for(id : Int64) : Array(String)
      [] of String
    end
  end
end
