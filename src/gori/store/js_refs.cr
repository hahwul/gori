require "db"

module Gori
  class Store
    # --- endpoints referenced in captured JavaScript (V35, #1243) --------------

    # One reference as the scan hands it over: where it points (`host` lowercased, `path` the
    # query-less Sitemap node path, `target` the path + query as the literal wrote it) and where
    # it was read (`literal` clipped, `offset` a byte offset into the decoded response body).
    # `base` is a `JsRefs::Base` label, kept a String so the store does not depend on the engine.
    record JsRef, scheme : String, host : String, port : Int32, path : String, target : String,
      literal : String, offset : Int32, line : Int32, flags : Int32, base : String

    # One referenced endpoint ORIGIN for the Sitemap tree: every row for one (scheme, host, port,
    # path), with how many flows referenced it. Keyed by the whole origin so the URL a scope
    # question is asked about is one a reference really named (a MIN per column could pair one
    # reference's scheme with another's port). `host_captured` — the project holds traffic for
    # this host, so a tree missing it has it hidden by a lens, not unknown.
    record JsRefNode, scheme : String, host : String, port : Int32, path : String, flows : Int32,
      host_captured : Bool = false

    # One stored reference WITH its source flow's URL (nil when the flow row is gone, which a
    # cascade makes a race, not a state).
    record JsRefSighting, flow_id : Int64, scheme : String, host : String, port : Int32,
      path : String, target : String, literal : String, offset : Int32, line : Int32,
      flags : Int32, base : String, created_at : Int64, source_url : String?

    # Hard ceiling on the rows one read materializes. A project can hold 4096 references per
    # scanned body times thousands of bodies; the surfaces page a list, and the tree is bounded
    # by `SITEMAP_MAX` like the traffic it sits beside.
    JS_REF_READ_MAX = 50_000

    # Replace flow `flow_id`'s references with `refs` and mark it scanned by extractor
    # `version` — ONE transaction, so a rolled-back batch leaves the flow UNSCANNED (and a later
    # scan retries it) rather than marked done with its references missing. Idempotent: a
    # rescan, or two gori scanning the same flow, converge on the same rows. Answers whether it
    # committed (`exec_task_ok`; see `delete_flows` for why that is the only honest answer).
    #
    # `OR IGNORE` on every insert under a constraint: a statement that RAISES poisons the
    # writer's cached statement, and a flow whose row was deleted between the read and this
    # write must not be able to do that. The marker for a flow that no longer exists is then a
    # harmless orphan the next delete sweep never sees — so it is not written at all (the
    # `WHERE EXISTS`).
    def record_js_scan(flow_id : Int64, refs : Array(JsRef), version : Int32) : Bool
      now = now_us
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM js_refs WHERE flow_id = ?", flow_id)
        c.exec("DELETE FROM js_ref_scans WHERE flow_id = ?", flow_id)
        if c.query_one?("SELECT 1 FROM flows WHERE id = ?", flow_id, as: Int32)
          refs.each do |r|
            c.exec("INSERT OR IGNORE INTO js_refs (flow_id, scheme, host, port, path, target, literal, " \
                   "body_offset, line, flags, base, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
              flow_id, r.scheme, r.host, r.port, r.path, r.target, r.literal, r.offset, r.line,
              r.flags, r.base, now)
          end
          c.exec("INSERT OR IGNORE INTO js_ref_scans (flow_id, version, refs, scanned_at) VALUES (?,?,?,?)",
            flow_id, version, refs.size, now)
        end
        nil
      }
    end

    # The SQL predicate "this flow has not been scanned by extractor `version` or newer", for a
    # scan's candidate filter. A subquery on the marker table's primary key, so it composes
    # with any QL filter without a join.
    def self.js_unscanned_filter(version : Int32) : QL::Filter
      QL::Filter.new("id NOT IN (SELECT flow_id FROM js_ref_scans WHERE version >= ?)", [version.to_i64] of DB::Any)
    end

    # Every referenced endpoint origin with its flow count, for the Sitemap tree. Capped at
    # `limit` rows; the second value says the cap was hit.
    #
    # The Sitemap reloads on every data_version tick while capture runs, and this aggregate
    # scans the whole table — so it is memoized on a fingerprint that moves whenever the rows
    # can have: the marker count (a flow deleted with its references), the newest marker time
    # (a flow scanned, references or not) and the newest reference id (rows inserted). A count
    # over the per-flow marker table (one row per scanned flow, not per reference) plus two
    # index-end reads, instead of a GROUP BY over every reference per tick (P6).
    def js_ref_nodes(limit : Int32 = SITEMAP_MAX) : {Array(JsRefNode), Bool}
      print = js_ref_fingerprint
      if (memo = @js_ref_nodes_memo) && memo[0] == {print, limit}
        return memo[1]
      end
      out = [] of JsRefNode
      @db.query("SELECT scheme, host, port, path, COUNT(DISTINCT flow_id), " \
                "EXISTS (SELECT 1 FROM flows f WHERE f.host = js_refs.host) FROM js_refs " \
                "GROUP BY host, path, scheme, port ORDER BY host, path, scheme, port LIMIT ?", limit + 1) do |rs|
        rs.each do
          out << JsRefNode.new(rs.read(String), rs.read(String), rs.read(Int64).to_i32, rs.read(String),
            rs.read(Int64).to_i32, rs.read(Int64) != 0)
        end
      end
      capped = out.size > limit
      out.pop if capped
      result = {out, capped}
      @js_ref_nodes_memo = { {print, limit}, result }
      result
    rescue
      # Never crash a Sitemap poll over a read (mirrors sitemap_tags / sitemap_entries).
      {[] of JsRefNode, false}
    end

    @js_ref_nodes_memo : { { {Int64, Int64, Int64}, Int32 }, {Array(JsRefNode), Bool} }? = nil

    private def js_ref_fingerprint : {Int64, Int64, Int64}
      scans = @db.scalar("SELECT COUNT(*) FROM js_ref_scans").as(Int64)
      newest = @db.query_one("SELECT COALESCE(MAX(scanned_at), 0) FROM js_ref_scans", as: Int64)
      top = @db.query_one("SELECT COALESCE(MAX(id), 0) FROM js_refs", as: Int64)
      {scans, newest, top}
    end

    # Forget that the flows matching `filter` were scanned, so the next scan reads them again
    # (`JsRefs.scan`'s rescan). Their references stay until that scan replaces them. Answers
    # whether the write committed.
    def forget_js_scans(filter : QL::Filter) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM js_ref_scans WHERE flow_id IN (SELECT id FROM flows WHERE #{filter.sql})", args: filter.args)
        nil
      }
    end

    # Distinct referenced (host, path) pairs — what a scan reports as "new" by comparing the
    # count before and after.
    def js_ref_endpoint_count : Int32
      @db.scalar("SELECT COUNT(*) FROM (SELECT 1 FROM js_refs GROUP BY host, path)").as(Int64).to_i32
    rescue
      0
    end

    # How many flows carry a scan marker from extractor `version` or newer.
    def js_scanned_count(version : Int32) : Int32
      @db.scalar("SELECT COUNT(*) FROM js_ref_scans WHERE version >= ?", version).as(Int64).to_i32
    rescue
      0
    end

    # Stored references with their source flow's URL, newest source first within one
    # (host, path). `host` is exact (hosts are stored lowercased), `path` narrows to one node.
    # Raises on a read error when asked to, so a headless surface can tell "none" from "failed".
    def js_ref_sightings(*, host : String? = nil, path : String? = nil, limit : Int32 = JS_REF_READ_MAX,
                         raise_on_error : Bool = false) : Array(JsRefSighting)
      where = [] of String
      args = [] of DB::Any
      if h = host
        where << "r.host = ?"
        args << h.downcase
      end
      if p = path
        where << "r.path = ?"
        args << p
      end
      args << limit.clamp(1, JS_REF_READ_MAX).to_i64
      sql = "SELECT r.flow_id, r.scheme, r.host, r.port, r.path, r.target, r.literal, r.body_offset, " \
            "r.line, r.flags, r.base, r.created_at, f.scheme, f.host, f.port, f.target " \
            "FROM js_refs r LEFT JOIN flows f ON f.id = r.flow_id " \
            "#{where.empty? ? "" : "WHERE #{where.join(" AND ")} "}" \
            "ORDER BY r.host, r.path, r.flow_id DESC LIMIT ?"
      out = [] of JsRefSighting
      @db.query(sql, args: args) do |rs|
        rs.each do
          flow_id = rs.read(Int64)
          scheme = rs.read(String)
          rhost = rs.read(String)
          port = rs.read(Int64).to_i32
          rpath = rs.read(String)
          target = rs.read(String)
          literal = rs.read(String)
          offset = rs.read(Int64).to_i32
          line = rs.read(Int64).to_i32
          flags = rs.read(Int64).to_i32
          base = rs.read(String)
          created = rs.read(Int64)
          fscheme = rs.read(String?)
          fhost = rs.read(String?)
          fport = rs.read(Int64?)
          ftarget = rs.read(String?)
          source = (fscheme && fhost && fport && ftarget) ? FlowRow.url_of(fscheme, fhost, fport.to_i32, ftarget) : nil
          out << JsRefSighting.new(flow_id, scheme, rhost, port, rpath, target, literal, offset, line,
            flags, base, created, source)
        end
      end
      out
    rescue ex
      raise ex if raise_on_error
      [] of JsRefSighting
    end
  end
end
