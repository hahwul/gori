require "../spec_helper"

# Schema V43 (#1371): a JavaScript reference is keyed by its ORIGIN. V35's
# `UNIQUE(host, path, flow_id)` kept one row per (host, path) per scanned flow, so a bundle naming
# `http://h:8080/p` and `https://h/p` lost one of them. The rebuild must keep every existing row,
# and a replay over the new shape (the index specs wind `user_version` back) must converge.

private def unique_columns(store : Gori::Store) : Array(String)
  index = store.@db.query_all("SELECT name FROM pragma_index_list('js_refs') WHERE \"unique\" = 1", as: String).first
  store.@db.query_all("SELECT name FROM pragma_index_info('#{index}') ORDER BY seqno", as: String)
end

private def ref(scheme : String, port : Int32) : Gori::Store::JsRef
  Gori::Store::JsRef.new(scheme, "h.test", port, "/p", "/p", "/p", 0, 1, 0, "page")
end

private def v42_project(path : String) : Int64
  store = Gori::Store.open(path)
  fid = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443, method: "GET", target: "/app.js",
    http_version: "HTTP/1.1", head: "GET /app.js HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.flush
  store.record_js_scan(fid, [ref("https", 443)], 1).should be_true
  # Wind the table back to its V35 shape, rows kept.
  db = store.@db
  db.exec("CREATE TABLE js_refs_old AS SELECT * FROM js_refs")
  db.exec("DROP TABLE js_refs")
  db.exec(Gori::Store::Schema::V35[0])
  db.exec("INSERT INTO js_refs SELECT * FROM js_refs_old")
  db.exec("DROP TABLE js_refs_old")
  db.exec(Gori::Store::Schema::V35[1])
  db.exec("PRAGMA user_version = 42")
  store.close
  fid
end

describe "js_refs origin key (schema V43)" do
  it "rebuilds the V35 table keyed by origin, keeping its rows, and replays cleanly" do
    path = File.tempname("gori-jsrefs-v43", ".db")
    begin
      fid = v42_project(path)
      store = Gori::Store.open(path)
      begin
        unique_columns(store).should eq(%w[host path scheme port flow_id])
        store.js_ref_sightings(host: "h.test").map { |r| {r.scheme, r.port} }.should eq([{"https", 443}])
        store.@db.query_all("SELECT name FROM pragma_index_list('js_refs')", as: String).should contain("idx_js_refs_flow")
        # Two origins of one path from one flow now both store.
        store.record_js_scan(fid, [ref("https", 443), ref("http", 8080)], 1).should be_true
        store.js_ref_sightings(host: "h.test").size.should eq(2)
        store.@db.exec("PRAGMA user_version = 42")
      ensure
        store.close
      end
      store = Gori::Store.open(path) # the replay over the V43 shape
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        unique_columns(store).should eq(%w[host path scheme port flow_id])
        store.js_ref_sightings(host: "h.test").size.should eq(2)
      ensure
        store.close
      end
    ensure
      {path, "#{path}-wal", "#{path}-shm", "#{path}.open.lock"}.each { |p| File.delete?(p) }
    end
  end
end
