require "db"

module Gori
  class Store
    # --- read API (go straight through the pool; WAL allows concurrent reads) -

    SELECT_ROW = <<-SQL
      SELECT id, created_at, scheme, method, host, port, target, status,
             request_size, response_size, state, duration_us, content_type,
             short_circuited, advisory, request_content_type
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
      # Degrade to no matches (the live TUI must never crash the render loop). Route to gori.log
      # via Log, NOT STDERR: in TUI mode STDERR is the alternate screen, so a write there prints
      # ON TOP of the frame and garbles it until a resize (#411). The CLI passes raise_on_error.
      ::Log.warn { "search failed: #{ex.message}" }
      [] of FlowRow
    end

    # Which of `ids` satisfy `filter` — the id-scoped form of `search`, for a caller that already
    # HAS its rows and needs an answer the row projection cannot give (Colormarker asking
    # `body:`/`header:`/`size:` of a screenful of History rows). Bounded by the caller's window,
    # never by the table: the id list IS the scan.
    #
    # nil — not an empty set — when the query could not run, because the two mean opposite things
    # to the caller. An empty set is "none of these match" and is worth caching; a failure is "no
    # answer", and caching it as "no match" would silently unpaint rows for the rest of the
    # session. Same degrade-and-log contract `search` has (the live render loop must never crash),
    # with the one distinction its Array return could not express.
    def ids_matching(filter : QL::Filter, ids : Array(Int64)) : Set(Int64)?
      # NOT named `out`: `out` is a Crystal keyword, and `return out if …` parses as an out-param.
      hits = Set(Int64).new
      return hits if ids.empty?
      args = filter.args.dup
      ids.each { |i| args << i }
      placeholders = Array.new(ids.size, "?").join(',')
      @db.query("SELECT id FROM flows WHERE (#{filter.sql}) AND id IN (#{placeholders})",
        args: args) do |rs|
        rs.each { hits << rs.read(Int64) }
      end
      hits
    rescue ex
      # Routed to gori.log, never STDERR: in TUI mode STDERR is the alternate screen (see `search`).
      ::Log.warn { "id-scoped match failed: #{ex.message}" }
      nil
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
    # completed flow (one with a response), newest first. Used by the Sitemap "Open flow" /
    # "Send to Repeater" / "Send to Sequencer" / "Discover here" actions, whose node carries
    # no flow id (it's a distinct-tuple aggregate).
    #
    # `target` arrives NORMALIZED: `Sitemap.build` runs every `flows.target` through
    # `Sitemap.normalize_path` before stamping it on a node, so an absolute-form capture
    # ("http://h:19501/crtest") becomes the bare path ("/crtest"). The column it is compared
    # against is not normalized, and this used to be a bare `target = ?` — so the two agreed
    # only when the capture happened to store origin-form: HTTPS (inside a CONNECT tunnel)
    # or a request gori itself rewrote. A proxy client sends ABSOLUTE-form for plaintext
    # HTTP, so every ordinary `http://` capture was unreachable from the tree that was
    # displaying it, and the refusal blamed the operator ("capture it" — it was captured).
    #
    # Two statements rather than one normalizing predicate, because normalizing in SQL means
    # a `LIKE '%…'` that no index can serve and that matches on a bare suffix ("/panel"
    # would resolve "/admin/panel"). The exact match stays the fast path and is served by
    # `idx_flows_sitemap`; only when it misses does the fallback scan this host+method's
    # ABSOLUTE-form rows (the only ones that can normalize to something else) and compare
    # through the very function that built the tree — one definition of "same endpoint",
    # used by both sides.
    def representative_flow_id(host : String, method : String, target : String) : Int64?
      @db.query("SELECT id FROM flows WHERE host = ? AND method = ? AND target = ? ORDER BY (status IS NOT NULL) DESC, id DESC LIMIT 1",
        host, method, target) do |rs|
        return rs.read(Int64) if rs.move_next
      end
      # Capped like its sibling `flow_id_for_url` (URL_LOOKUP_SCAN_CAP), which was capped and
      # this was not. It normalises each row in Crystal until one matches, so on a
      # plaintext-HTTP-heavy host — where absolute-form targets are the norm — it walked every
      # row that host ever produced, on the TUI fiber, for a keypress. The ORDER BY puts
      # answered flows and the newest first, so the representative is in the first handful if
      # it is anywhere; scanning past that was finding nothing, slowly.
      @db.query("SELECT id, target FROM flows WHERE host = ? AND method = ? AND instr(target, '://') > 0 ORDER BY (status IS NOT NULL) DESC, id DESC LIMIT #{URL_LOOKUP_SCAN_CAP}",
        host, method) do |rs|
        rs.each do
          id = rs.read(Int64)
          return id if Sitemap.normalize_path(rs.read(String)) == target
        end
      end
      nil
    end

    # How many same-(host, target) rows the URL lookup below RETURNS. A URL polled every few
    # seconds leaves tens of thousands of them, and this runs inline on the TUI's fiber
    # (AGENTS.md §3) — the ordering puts the answer at the head, so the tail is rows that would
    # lose the ranking anyway.
    #
    # It bounds what crosses into Crystal, NOT what SQLite touches: `LIMIT` is applied after
    # `ORDER BY`, and the ranking is over expressions no index covers, so the engine still sorts
    # every matching row before handing back the first 256. What keeps THAT set small is the
    # WHERE clause — `host` rides `idx_flows_sitemap`'s leading column and the `target` equality
    # narrows it to one endpoint — plus the fact that this fires on a keypress, not on a frame.
    # Making the cap cover the scan would mean `LIMIT`ing before the sort and doing the ranking
    # in Crystal over an arbitrary 256 rows, which is exactly what the ORDER BY exists to
    # prevent (see the method note below on why the method is the first key).
    URL_LOOKUP_SCAN_CAP = 256

    # The captured flow an absolute URL came from — a REVERSE match against `FlowRow#url`, for
    # a surface that holds the URL as a bare string and nothing else. A Probe issue's AFFECTED
    # list is the one: `upsert_probe_issue` accumulates `Detection#url` into a JSON array and
    # keeps no per-URL flow id, so the URLs outlive every id that could have pointed back at a
    # row. Storing the id beside each URL would make this exact and is the better shape; it
    # needs a `probe_issues` migration and a second array kept index-aligned across the store,
    # the headless `Probe::Group` fold and both export surfaces, so it is not this change.
    #
    # `host` narrows the scan to `idx_flows_sitemap`'s leading column, and the caller always
    # has it — a probe issue group is keyed by (code, host), so every URL on its list is on
    # that host. The `target` predicate covers both capture shapes at once (absolute-form rows
    # store the whole URL, origin-form rows store the bare path), and the survivors are then
    # re-derived through `FlowRow.url_of` rather than trusted: `/x` captured on http:8080 and
    # on https:443 share a target and mean two different URLs, and only the full rebuild —
    # default port, IPv6 brackets and all — tells them apart.
    #
    # THE METHOD IS THE FIRST SORT KEY, and it is why `prefer_method` exists. A URL is not an
    # endpoint: `GET /v1/me` and `POST /v1/me` are one (host, target) pair and two exchanges,
    # and a finding that fired on one must not open the other — `representative_flow_id` keys
    # on the method for exactly this reason, and a probe group records none, so the caller
    # passes the method of the sample flow that produced the finding. Response-bearing and
    # newest break the remaining ties, as they do one screen up: opening a finding onto an
    # aborted request shows nothing of what the finding is about.
    def flow_id_for_url(url : String, host : String, prefer_method : String? = nil) : Int64?
      @db.query("SELECT id, scheme, host, port, target FROM flows WHERE host = ? AND (target = ? OR target = ?) " \
                "ORDER BY (method = ?) DESC, (status IS NOT NULL) DESC, id DESC LIMIT ?",
        host, url, Url.origin_path(url), prefer_method || "", URL_LOOKUP_SCAN_CAP) do |rs|
        rs.each do
          id = rs.read(Int64)
          scheme, h, port, target = rs.read(String), rs.read(String), rs.read(Int32), rs.read(String)
          return id if FlowRow.url_of(scheme, h, port, target) == url
        end
      end
      nil
    rescue ex
      # Degrade to "not found" (the live TUI must never crash the render loop) but LEAVE A
      # TRACE, the way `Store#search` does 90 lines up. The caller turns nil into "no captured
      # flow for that URL" — a positive claim about a specific URL — so a busy or corrupt DB
      # answering silently would send the operator hunting for a retention setting.
      ::Log.warn { "flow_id_for_url failed: #{ex.message}" }
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
                 short_circuited, advisory, request_content_type,
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
                 short_circuited, advisory, request_content_type,
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
    # `exec_task_ok`, for `delete_flows`' reason below: a DELETE reports nothing through
    # last_insert_rowid, so a batch rolled back by an unrelated co-submitted write is
    # indistinguishable from success — and the CLI printed "Flow #N deleted." / MCP returned
    # `{"deleted": true}` with the row still there. The batch form got this and the singular
    # did not. Returns whether the delete actually committed.
    def delete_flow(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        delete_flow_one(c, id)
        nil
      }
    end

    # Batch form of delete_flow — the History list's multi-select delete (#442). ONE
    # exec_task_ok, so 20 marked flows cost one transaction and one fsync instead of 20
    # (P6 — never stall the data path). Same per-id cascade, so a batch of one is
    # byte-identical to delete_flow.
    #
    # exec_task_OK, not exec_task: a DELETE reports nothing through last_insert_rowid, so a
    # batch rolled back by an unrelated co-submitted write (the writer loop batches ops into one
    # transaction) would be indistinguishable from success — and the caller would drop the marks
    # that identified those rows while every one of them reappeared in the list. Returns whether
    # the delete actually committed.
    def delete_flows(ids : Array(Int64)) : Bool
      return true if ids.empty?
      exec_task_ok ->(c : DB::Connection) {
        ids.each { |id| delete_flow_one(c, id) }
        nil
      }
    end

    # Wipe every captured History flow in this project (and their WS/FTS/h2 logs and
    # flow entity_links). Repeater-owned WS rows (repeater_id set) and workbench sessions
    # are left intact, and so are `sitemap_tags`: a tag is the OPERATOR'S memo on a path, in
    # the same class as a note or an issue, and `history clear` clears captured traffic rather
    # than the operator's own annotations. It is keyed by `(host, path)` and not by a flow id,
    # so it survives correctly and re-attaches if that path is captured again — it is simply
    # unreachable from the Sitemap tree meanwhile, and `sitemap tag --list` is where to find
    # it. Spelled out because this list is what a reader checks, and tags were the one spared
    # table it did not name.
    # Returns whether the wipe committed; see `delete_flow`. A rolled-back clear reported as
    # done is the worst of the three, because the operator moves on believing the project is
    # empty.
    def clear_flows : Bool
      exec_task_ok ->(c : DB::Connection) {
        # Captured WS only — WebSocket-Repeater output is keyed by repeater_id.
        c.exec("DELETE FROM ws_messages WHERE repeater_id IS NULL")
        # contentless FTS: per-row DELETE is a tombstone; wipe the whole index in one go
        # so a large clear doesn't leave a full-size tombstone table behind.
        c.exec("INSERT INTO flows_fts(flows_fts) VALUES('delete-all')")
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'flow'")
        detach_flow_refs(c, nil)
        c.exec("DELETE FROM flows")
        c.exec("DELETE FROM h2_frames")
        c.exec("DELETE FROM h2_connections")
        # No index backlog bookkeeping to undo: a pending re-index is the row's own
        # `fts_dirty` flag, so deleting the rows deletes the backlog with them.
        nil
      }
    end

    # Cascade for one flow id (writer connection). Shared by delete_flow.
    private def delete_flow_one(conn : DB::Connection, id : Int64) : Nil
      conn.exec("DELETE FROM ws_messages WHERE flow_id = ? AND repeater_id IS NULL", id)
      conn.exec("DELETE FROM flows_fts WHERE rowid = ?", id)
      conn.exec("DELETE FROM entity_links WHERE ref_kind = 'flow' AND ref_id = ?", id)
      detach_flow_refs(conn, id)
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
    end

    # The newest flow id, or nil in an empty project. A rightmost-leaf seek on the primary
    # key — measured at ~6 ms including process startup on a 50k-flow / 3.4 GB project, so it
    # is free enough to run per cursored read.
    def max_flow_id : Int64?
      @db.query_one?("SELECT MAX(id) FROM flows", as: Int64?)
    rescue
      nil
    end

    # Every table that cross-references a flow by id, in one place. `id` nil = every flow is
    # going (a clear), so every reference is dangling.
    #
    # `flows.id` is a plain `INTEGER PRIMARY KEY`, i.e. the rowid, which SQLite REUSES: delete
    # the newest flow (or clear the project) and the next capture is handed the same id. These
    # columns were deliberately left dangling on the assumption that they would resolve to
    # "gone" — they do not, they re-point at whatever traffic takes the id next. Measured: a
    # probe finding promoted to an Issue after a clear cited a flow captured afterwards, and
    # `get_repeater_context` reported a session as seeded from an unrelated request. On a tool
    # whose product is evidence, silently wrong evidence is the worst outcome available;
    # NULLing turns it into absent evidence, which every one of these surfaces already renders
    # honestly.
    #
    # `entity_links` is DELETED rather than kept-and-marked-stale (`links.cr` renders a
    # dangling ref as `(stale)`, which reads better) for the same reason: while ids are
    # reusable, a kept pointer re-binds, and re-binding is strictly worse than losing the
    # pointer. Marking stale becomes the right answer only once ids are monotonic — which
    # needs a `flows` table rebuild, measured at 16.1 s on a 50k-flow project against a 5 s
    # `busy_timeout`, i.e. a hard `database is locked` for every other gori process. That
    # belongs in an opt-in maintenance command, not on open.
    #
    # `ws_messages.flow_id` is NOT NULL, so a repeater-owned WS row (`repeater_id` set, which
    # `delete_flow_one` deliberately spares) keeps its id. Its session is covered instead:
    # `repeaters.flow_id` is nulled here, which is where a surface reads the provenance from.
    # `probe_oast_probes` belongs here even though nothing READS its `flow_id` for display: it
    # COPIES it into a new finding. An outstanding out-of-band probe deliberately outlives the
    # scan that planted it (that is the whole point of the table), so a `history clear` leaves the
    # row while resetting the rowid counter — and when the payload finally calls home,
    # `Probe::OutOfBand.detection_for` passes `p.flow_id` into the `Detection`, which
    # `upsert_probe_issue` writes as `probe_issues.sample_flow_id`. So the very failure the note
    # above records as MEASURED — "a probe finding promoted to an Issue after a clear cited a flow
    # captured afterwards" — came back one hop upstream: nulling `sample_flow_id` at clear time
    # does not help when the value is re-supplied afterwards from a row that kept it. This table
    # arrived in a later migration than the list, which is how it came to be missing from a
    # comment that says "every table".
    private def detach_flow_refs(conn : DB::Connection, id : Int64?) : Nil
      {"issues", "repeaters", "fuzz_sessions", "miner_sessions", "sequencer_sessions",
       "events", "intercept_held", "probe_oast_probes"}.each do |table|
        if fid = id
          conn.exec("UPDATE #{table} SET flow_id = NULL WHERE flow_id = ?", fid)
        else
          conn.exec("UPDATE #{table} SET flow_id = NULL WHERE flow_id IS NOT NULL")
        end
      end
      if fid = id
        conn.exec("UPDATE probe_issues SET sample_flow_id = NULL WHERE sample_flow_id = ?", fid)
      else
        conn.exec("UPDATE probe_issues SET sample_flow_id = NULL WHERE sample_flow_id IS NOT NULL")
      end
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

    # ORDER BY names every GROUP BY column, so the ordering is TOTAL and the `LIMIT` cut is
    # deterministic. Six columns key a group and only two ordered it, so `GET /x` and
    # `POST /x` — and https:443 vs http:80 vs HTTP/2 on one path — tied completely, and which
    # survived the cut was unspecified. With no cursor on this read, a group that loses an
    # arbitrary tiebreak is not on a later page; it is unreachable.
    #
    # The success bucket starts at 100, not 200: status 101 is exactly what `proto:ws` means
    # (see ql.cr), so every WebSocket endpoint reported "N attempts, 0 successes, 0 errors".
    # A NULL status stays in neither bucket on purpose — a Pending flow has no outcome yet —
    # so ok + errors can legitimately be less than count.
    def sitemap_entries_detailed(filter : QL::Filter = QL::EMPTY, limit : Int32 = SITEMAP_MAX, *,
                                 raise_on_error : Bool = false) : Array(SitemapEntry)
      rows = [] of SitemapEntry
      args = filter.args.dup
      args << limit
      sql = "SELECT scheme, host, port, http_version, method, target, " \
            "GROUP_CONCAT(DISTINCT status), COUNT(*), " \
            "SUM(CASE WHEN status BETWEEN 100 AND 399 THEN 1 ELSE 0 END), " \
            "SUM(CASE WHEN status = 0 OR status >= 400 THEN 1 ELSE 0 END), " \
            "MIN(created_at), MAX(created_at) " \
            "FROM flows WHERE #{filter.sql} " \
            "GROUP BY scheme, host, port, http_version, method, target " \
            "ORDER BY host, target, method, scheme, port, http_version LIMIT ?"
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
      ::Log.warn { "sitemap query failed: #{ex.message}" } # gori.log, not STDERR (see #search, #411)
      [] of SitemapEntry
    end

    def sitemap_entries(filter : QL::Filter = QL::EMPTY, limit : Int32 = SITEMAP_MAX, *,
                        raise_on_error : Bool = false) : Array({String, String, String})
      rows = [] of {String, String, String}
      args = filter.args.dup
      args << limit
      # `method` is SELECTed, so it must ORDER too, or the LIMIT cut between two rows that
      # differ only by method is arbitrary — and with no cursor here the loser is unreachable.
      @db.query("SELECT DISTINCT host, method, target FROM flows WHERE #{filter.sql} " \
                "ORDER BY host, target, method LIMIT ?",
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
      ::Log.warn { "sitemap query failed: #{ex.message}" } # gori.log, not STDERR (see #search, #411)
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
