require "../spec_helper"

# Schema V38 widens `idx_flows_sitemap` so the grouped Sitemap reads (`sitemap_entries_detailed`
# for MCP list_sitemap / `gori run sitemap`, `endpoint_observations` for the retest diff) never
# read a `flows` row — the columns they aggregate sit after the body BLOBs. Two things can
# silently undo it: a GROUP BY spelled in another order (the planner then scans the table and
# sorts), or a column the queries read that the index lacks. These pin the plans, and that the
# reordered GROUP BY returns exactly the groups the old one did.

private def query_plan(store : Gori::Store, sql : String) : String
  plan = [] of String
  store.@db.query("EXPLAIN QUERY PLAN #{sql}") do |rs|
    rs.each { 3.times { rs.read }; plan << rs.read(String) }
  end
  plan.join(" | ")
end

# The statements `sitemap_entries_detailed` and `endpoint_observations` run (reads.cr).
private DETAILED_COLS = "scheme, host, port, http_version, method, target, " \
                        "GROUP_CONCAT(DISTINCT status), COUNT(*), " \
                        "SUM(CASE WHEN status BETWEEN 100 AND 399 THEN 1 ELSE 0 END), " \
                        "SUM(CASE WHEN status = 0 OR status >= 400 THEN 1 ELSE 0 END), " \
                        "MIN(created_at), MAX(created_at)"
private DETAILED_ORDER = "ORDER BY host, target, method, scheme, port, http_version"
private OBS_COLS       = "host, method, target, status, content_type, COUNT(*), " \
                         "MIN(response_size), MAX(response_size), MIN(created_at), MAX(created_at), MAX(id)"
private OBS_ORDER = "ORDER BY host, target, method, status, content_type"

private def detailed_sql(where : String, group : String = "host, target, method, scheme, port, http_version") : String
  "SELECT #{DETAILED_COLS} FROM flows WHERE #{where} GROUP BY #{group} #{DETAILED_ORDER} LIMIT 201 OFFSET 0"
end

private def obs_sql(where : String, group : String = "host, target, method, status, content_type") : String
  "SELECT #{OBS_COLS} FROM flows WHERE #{where} GROUP BY #{group} #{OBS_ORDER} LIMIT 40000"
end

private def seed_flow(store : Gori::Store, i : Int32) : Nil
  scheme = i % 5 == 0 ? "http" : "https"
  port = scheme == "http" ? (i % 10 == 0 ? 8080 : 80) : 443
  method = {"GET", "POST", "GET", "PUT"}[i % 4]
  target = {"/", "/a", "/a/b", "/img/logo.png", "/api?q=1"}[i % 5]
  host = "h#{i % 3}.test"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64 + i, scheme: scheme, host: host, port: port, method: method,
    target: target, http_version: i % 3 == 0 ? "HTTP/2" : "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  return if i % 11 == 0 # left Pending: a NULL status must group and count the same way
  status = {200, 404, 500, 101, 304, 200, 0}[i % 7]
  ctype = target.ends_with?(".png") ? "image/png" : {"application/json", "text/html", nil}[i % 3]
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, content_type: ctype,
    head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice, body: ("x" * (i % 17)).to_slice,
    state: Gori::Store::FlowState::Complete))
end

# A row of the old statement, with the GROUP_CONCAT's order normalised: the order inside
# `statuses` was never specified, only the set.
private def rows_of(store : Gori::Store, sql : String, width : Int32, concat_col : Int32? = nil) : Array(Array(String))
  out = [] of Array(String)
  store.@db.query(sql) do |rs|
    rs.each do
      row = (0...width).map { rs.read.to_s }
      if (c = concat_col) && !row[c].empty?
        row[c] = row[c].split(',').sort!.join(',')
      end
      out << row
    end
  end
  out
end

describe "Sitemap covering index (schema V38)" do
  it "groups the detailed sitemap straight off the index, lens on or off" do
    with_store do |store|
      ["1", "(1) AND (#{Gori::QL.hide_static.sql})", "(#{Gori::QL.parse("status:5xx").sql.gsub("?", "500")})"].each do |where|
        plan = query_plan(store, detailed_sql(where))
        plan.should contain("COVERING INDEX idx_flows_sitemap")
        plan.should_not contain("TEMP B-TREE FOR GROUP BY")
        plan.should_not contain("TEMP B-TREE FOR ORDER BY")
      end
    end
  end

  it "reads endpoint observations from the index without touching a row" do
    with_store do |store|
      query_plan(store, obs_sql("1")).should contain("COVERING INDEX idx_flows_sitemap")
    end
  end

  it "keeps the tree, host completion and endpoint lookups on a covering read" do
    with_store do |store|
      query_plan(store, "SELECT DISTINCT host, method, target FROM flows WHERE 1 ORDER BY host, target, method LIMIT 10")
        .should contain("COVERING INDEX idx_flows_sitemap")
      query_plan(store, "SELECT DISTINCT host, method, target FROM flows WHERE (1) AND (#{Gori::QL.hide_static.sql}) " \
                        "ORDER BY host, target, method LIMIT 10")
        .should contain("COVERING INDEX idx_flows_sitemap_nonstatic")
      query_plan(store, "SELECT DISTINCT host FROM flows ORDER BY host LIMIT 16")
        .should contain("COVERING INDEX idx_flows_sitemap")
      query_plan(store, "SELECT id FROM flows WHERE host = 'a' AND method = 'GET' AND target = '/' " \
                        "ORDER BY (status IS NOT NULL) DESC, id DESC LIMIT 1")
        .should contain("COVERING INDEX idx_flows_sitemap (host=? AND target=? AND method=?)")
    end
  end

  # #1371: the origin-keyed tree read (`sitemap_origin_entries`) is the one the Sitemap tab runs
  # on every poll, so it must stay a covering read with no sort, lens on or off, and the
  # origin-narrowed endpoint lookup must stay one index seek.
  it "keeps the origin-keyed tree read and the origin-narrowed lookup on the index" do
    with_store do |store|
      ["1", "(1) AND (#{Gori::QL.hide_static.sql})"].each do |where|
        plan = query_plan(store, "SELECT DISTINCT host, target, method, scheme, port FROM flows WHERE #{where} " \
                                 "ORDER BY host, target, method, scheme, port LIMIT 10 OFFSET 0")
        plan.should contain("COVERING INDEX idx_flows_sitemap")
        plan.should_not contain("TEMP B-TREE")
      end
      query_plan(store, "SELECT id FROM flows WHERE host = 'a' AND method = 'GET' AND target = '/' " \
                        "AND scheme = 'http' AND port = 8080 ORDER BY (status IS NOT NULL) DESC, id DESC LIMIT 1")
        .should contain("COVERING INDEX idx_flows_sitemap (host=? AND target=? AND method=? AND scheme=? AND port=?)")
    end
  end

  it "returns exactly the groups the old GROUP BY order did" do
    with_store do |store|
      120.times { |i| seed_flow(store, i) }
      store.flush
      ["1", "(1) AND (#{Gori::QL.hide_static.sql})"].each do |where|
        old = rows_of(store, detailed_sql(where, "scheme, host, port, http_version, method, target"), 12, 6)
        old.should_not be_empty
        filter = Gori::QL::Filter.new(where, [] of DB::Any)
        now = store.sitemap_entries_detailed(filter, 201, raise_on_error: true).map do |e|
          [e.scheme, e.host, e.port.to_s, e.http_version, e.method, e.target,
           (e.statuses || "").split(',').sort!.join(','), e.count.to_s, e.ok.to_s, e.errors.to_s,
           e.first_seen.to_s, e.last_seen.to_s]
        end
        now.should eq(old)

        old_obs = rows_of(store, obs_sql(where, "host, method, target, status, content_type"), 11)
        now_obs = store.endpoint_observations(filter, raise_on_error: true).map do |o|
          [o.host, o.method, o.target, o.status.to_s, o.content_type.to_s, o.count.to_s,
           o.min_size.to_s, o.max_size.to_s, o.first_seen.to_s, o.last_seen.to_s, o.flow_id.to_s]
        end
        now_obs.should eq(old_obs)
      end
      # Paging walks the same set.
      all = store.sitemap_entries_detailed(Gori::QL::EMPTY, 10_000, raise_on_error: true)
      paged = (0...all.size).step(7).to_a.flat_map do |off|
        store.sitemap_entries_detailed(Gori::QL::EMPTY, 7, offset: off, raise_on_error: true)
      end
      paged.should eq(all)
    end
  end

  it "migrates a V37 project to the wide index" do
    path = File.tempname("gori-sitemap-v38", ".db")
    begin
      store = Gori::Store.open(path)
      12.times { |i| seed_flow(store, i) }
      store.flush
      before = store.sitemap_entries_detailed(raise_on_error: true)
      store.@db.exec("DROP INDEX idx_flows_sitemap")
      store.@db.exec("CREATE INDEX idx_flows_sitemap ON flows (host, target, method)")
      store.@db.exec("PRAGMA user_version = 37")
      store.close

      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        store.@db.query_all("SELECT name FROM pragma_index_info('idx_flows_sitemap') ORDER BY seqno", as: String)
          .should eq(%w[host target method scheme port http_version status created_at content_type response_size static_asset])
        store.sitemap_entries_detailed(raise_on_error: true).should eq(before)
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
