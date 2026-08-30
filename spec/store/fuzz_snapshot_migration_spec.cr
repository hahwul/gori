require "../spec_helper"

private def build_v23_fuzz_db(path : String) : {DB::Database, Int64}
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema::MIGRATIONS[0...23].each do |statements|
    statements.each { |sql| db.exec(sql) }
  end
  db.exec("PRAGMA user_version = 23")
  db.exec("INSERT INTO fuzz_sessions (created_at, updated_at, target, template, config, position) " \
          "VALUES (1, 1, 'http://migration', 'GET / HTTP/1.1', '{}', 0)")
  session = db.scalar("SELECT last_insert_rowid()").as(Int64)
  # A genuine pre-V24 row has no surface provenance and must stay snapshot version 0.
  db.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, status) " \
          "VALUES (?, 1, 'http://legacy', 'sniper', 'done')", session)
  {db, session}
end

describe "fuzz snapshot schema V25" do
  it "migrates V23 through V24/V25 without blessing legacy rows or retaining old compaction bytes" do
    path = File.tempname("gori-fuzz-v25", ".db")
    db, session = build_v23_fuzz_db(path)
    store = nil.as(Gori::Store?)
    begin
      # Stage V24 explicitly so these rows have the exact shape the released migration added.
      Gori::Store::Schema::V24.each { |sql| db.exec(sql) }
      db.exec("PRAGMA user_version = 24")
      db.scalar("PRAGMA user_version").as(Int64).should eq(24_i64)

      ids = {} of String => Int64
      {"tui", "cli", "mcp", "other"}.each do |surface|
        db.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, status, surface) " \
                "VALUES (?, 2, ?, 'sniper', 'done', ?)", session, "http://#{surface}", surface)
        ids[surface] = db.scalar("SELECT last_insert_rowid()").as(Int64)
      end

      # V24 compacted the first three columns to X'' but accidentally left wire behind.
      db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, request, response_head, response_body, wire) " \
              "VALUES (1, 0, '[]', X'', X'', X'', X'AABB')")
      # Near misses are not the old marker and must remain byte-for-byte unchanged.
      db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, request, response_head, response_body, wire) " \
              "VALUES (1, 1, '[]', X'', X'', NULL, X'CC')")
      db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, request, response_head, response_body, wire) " \
              "VALUES (1, 2, '[]', X'', X'', X'', NULL)")
      db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, request, response_head, response_body, wire) " \
              "VALUES (1, 3, '[]', X'', X'', X'00', X'DD')")

      Gori::Store::Schema.migrate!(db)
      db.scalar("PRAGMA user_version").as(Int64)
        .should eq(Gori::Store::Schema::VERSION.to_i64)

      db.scalar("SELECT snapshot_version FROM fuzz_runs WHERE id = 1").as(Int64).should eq(0_i64)
      {"tui", "cli", "mcp"}.each do |surface|
        db.scalar("SELECT snapshot_version FROM fuzz_runs WHERE id = ?", ids[surface])
          .as(Int64).should eq(1_i64)
      end
      db.scalar("SELECT snapshot_version FROM fuzz_runs WHERE id = ?", ids["other"])
        .as(Int64).should eq(0_i64)

      # The column default stays conservative even when a post-migration direct writer claims
      # a known surface; only Store's complete writer opts a row into version 1.
      db.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, status, surface) " \
              "VALUES (?, 3, 'http://default', 'sniper', 'done', 'tui')", session)
      defaulted = db.scalar("SELECT last_insert_rowid()").as(Int64)
      db.scalar("SELECT snapshot_version FROM fuzz_runs WHERE id = ?", defaulted)
        .as(Int64).should eq(0_i64)

      db.query_one(
        "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
        "FROM fuzz_results WHERE idx = 0", as: {String, String, String, String})
        .should eq({"null", "null", "null", "null"})
      db.query_one(
        "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
        "FROM fuzz_results WHERE idx = 2", as: {String, String, String, String})
        .should eq({"null", "null", "null", "null"})
      db.query_one(
        "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
        "FROM fuzz_results WHERE idx = 1", as: {String, String, String, String})
        .should eq({"blob", "blob", "null", "blob"})
      db.query_one("SELECT LENGTH(request), LENGTH(response_head), LENGTH(response_body), LENGTH(wire) " \
                   "FROM fuzz_results WHERE idx = 3", as: {Int64, Int64, Int64, Int64})
        .should eq({0_i64, 0_i64, 1_i64, 1_i64})

      store = Gori::Store.new(db, nil, background_index: false)
      store.get_fuzz_run(ids["tui"]).not_nil!.snapshot_version.should eq(1)
      # The newer `other` and direct-default rows are v0, so automatic restore skips them.
      store.latest_saved_fuzz_run(session).not_nil!.id.should eq(ids["mcp"])
    ensure
      store ? store.close : db.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
