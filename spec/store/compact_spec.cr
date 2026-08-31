require "../spec_helper"
require "file_utils"

# A block of `n` printable bytes, big enough that dropping it visibly shrinks the file.
private def big_body(n : Int32) : Bytes
  Bytes.new(n) { |i| ((i % 26) + 65).to_u8 }
end

# Store.compact takes the per-project capture lock (`<dir>/.capture.lock`), so each
# case needs its OWN dir — a bare tempfile would share one lock across the temp dir.
private def with_project(&)
  dir = File.tempname("gori-compact")
  Dir.mkdir_p(dir)
  path = File.join(dir, "gori.db")
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def req_for(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "acme.test", port: 80,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: "POST #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    body: big_body(120_000), source: Gori::FlowSource::Kind::Proxy)
end

private def seed_flow_with_bodies(store : Gori::Store, target : String) : Int64
  id = store.insert_flow(req_for(target))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".to_slice,
    body: big_body(300_000), content_type: "application/octet-stream"))
  id
end

private def blob_len(store : Gori::Store, col : String, id : Int64) : Int64
  store.@db.scalar("SELECT LENGTH(#{col}) FROM flows WHERE id = ?", id).as(Int64)
end

describe "Gori::Store.compact" do
  it "strips selected data + VACUUMs while keeping the flow rows and their projection" do
    with_project do |path|
      ids = [] of Int64
      store = Gori::Store.open(path)
      begin
        3.times { |i| ids << seed_flow_with_bodies(store, "/big/#{i}") }
        store.insert_ws_message(ids.first, "out", 1, big_body(60_000)) # captured (repeater_id IS NULL)
        # A raw h2 frame log to prove the h2 option clears it.
        store.@db.exec("INSERT INTO h2_connections (created_at, host, port, alpn) VALUES (1, 'acme.test', 443, 'h2')")
        cid = store.@db.scalar("SELECT last_insert_rowid()").as(Int64)
        store.@db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                       "VALUES (?, 1, 'out', 1, 0, 0, 3, X'414243')", cid)
      ensure
        store.close
      end

      before = File.info(path).size
      plan = Gori::Store::CompactPlan.new(
        response_bodies: true, request_bodies: true, h2_frames: true, ws_messages: true)
      result = Gori::Store.compact(path, plan).not_nil!

      result.before_bytes.should eq(before)
      result.after_bytes.should be < before
      result.reclaimed_bytes.should be > 0
      File.info(path).size.should eq(result.after_bytes)

      store = Gori::Store.open(path)
      begin
        store.count.should eq(3) # rows preserved — only the heavy blobs went
        ids.each do |id|
          blob_len(store, "response_body", id).should eq(0)
          blob_len(store, "request_body", id).should eq(0)
          store.@db.scalar("SELECT response_body_truncated FROM flows WHERE id = ?", id).as(Int64).should eq(1)
          store.@db.scalar("SELECT request_body_truncated FROM flows WHERE id = ?", id).as(Int64).should eq(1)
          # True wire size + status projection survive the drop.
          store.@db.scalar("SELECT response_size FROM flows WHERE id = ?", id).as(Int64).should be > 300_000
          store.@db.scalar("SELECT status FROM flows WHERE id = ?", id).as(Int64).should eq(200)
        end
        store.@db.scalar("SELECT COUNT(*) FROM ws_messages WHERE repeater_id IS NULL").as(Int64).should eq(0)
        store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0)
        store.@db.scalar("SELECT COUNT(*) FROM h2_connections").as(Int64).should eq(0)
      ensure
        store.close
      end
    end
  end

  it "measure reports reclaimable byte estimates per category" do
    with_project do |path|
      store = Gori::Store.open(path)
      begin
        2.times { |i| seed_flow_with_bodies(store, "/m/#{i}") }
      ensure
        store.close
      end

      stats = Gori::Store.measure(path)
      stats.flow_count.should eq(2)
      stats.response_body_bytes.should be >= 600_000
      stats.request_body_bytes.should be >= 240_000
      stats.db_bytes.should be > 0
    end
  end

  it "keep_flows deletes the oldest flows (cascading), keeping only the newest N" do
    with_project do |path|
      ids = [] of Int64
      store = Gori::Store.open(path)
      begin
        10.times { |i| ids << store.insert_flow(req_for("/f/#{i}")) }
      ensure
        store.close
      end

      Gori::Store.compact(path, Gori::Store::CompactPlan.new(keep_flows: 3)).not_nil!

      store = Gori::Store.open(path)
      begin
        store.count.should eq(3)
        # The three newest ids survive; the oldest are gone.
        store.get_flow(ids.last).should_not be_nil
        store.get_flow(ids.first).should be_nil
      ensure
        store.close
      end
    end
  end

  it "measures and NULLs all four fuzz capture BLOBs, including wire" do
    with_project do |path|
      run = 0_i64
      store = Gori::Store.open(path)
      begin
        run = store.insert_fuzz_run(nil, "http://fuzz", "sniper", 3_i64, status: "saving")
        store.insert_fuzz_results(run, [
          Gori::Store::FuzzResultWrite.new(
            0_i64, %(["all"]), nil, 200, 100_000_i64, 1, 1, 1_i64, nil, false,
            false, nil, big_body(10_000), big_body(20_000), big_body(30_000),
            wire: big_body(40_000)),
          Gori::Store::FuzzResultWrite.new(
            1_i64, %(["wire"]), nil, 200, 5_000_i64, 1, 1, 1_i64, nil, false,
            false, nil, wire: big_body(5_000)),
          Gori::Store::FuzzResultWrite.new(
            2_i64, %(["empty"]), nil, 200, 0_i64, 0, 0, 1_i64, nil, false,
            false, nil, Bytes.empty, Bytes.empty, Bytes.empty, wire: Bytes.empty),
        ]).should be_true
        store.finish_fuzz_run(run, 3_i64, 0_i64, 0_i64, "done").should be_true
      ensure
        store.close
      end

      Gori::Store.measure(path).fuzz_bytes.should eq(105_000_i64)
      Gori::Store.compact(path, Gori::Store::CompactPlan.new(fuzz_bodies: true)).not_nil!
      Gori::Store.measure(path).fuzz_bytes.should eq(0_i64)

      store = Gori::Store.open(path)
      begin
        rows = store.fuzz_results(run, limit: 10)
        rows.size.should eq(3)
        rows.each do |row|
          {row.request, row.response_head, row.response_body, row.wire}
            .should eq({nil, nil, nil, nil})
        end
        rows[0].length.should eq(100_000_i64) # scalar projection survives compaction
        store.@db.query_one(
          "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
          "FROM fuzz_results WHERE run_id = ? AND idx = 2", run,
          as: {String, String, String, String}).should eq({"null", "null", "null", "null"})
      ensure
        store.close
      end
    end
  end

  it "measures pre-V24 fuzz BLOBs even though the wire column is absent" do
    path = File.tempname("gori-compact-v23", ".db")
    begin
      DB.open("sqlite3:#{path}") do |db|
        Gori::Store::Schema::MIGRATIONS[0...23].each do |statements|
          statements.each { |sql| db.exec(sql) }
        end
        db.exec("PRAGMA user_version = 23")
        db.exec("INSERT INTO fuzz_runs (created_at, target, mode, status) " \
                "VALUES (1, 'http://old', 'sniper', 'done')")
        run = db.scalar("SELECT last_insert_rowid()").as(Int64)
        db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, request, response_head, response_body) " \
                "VALUES (?, 0, '[]', X'0102', X'030405', X'06')", run)
      end
      Gori::Store.measure(path).fuzz_bytes.should eq(6_i64)
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "refuses (returns nil) when another live instance holds the capture lock" do
    with_project do |path|
      store = Gori::Store.open(path)
      begin
        seed_flow_with_bodies(store, "/x")
      ensure
        store.close
      end

      lock = Gori::CaptureLock.try(File.dirname(path)).not_nil!
      begin
        Gori::Store.compact(path, Gori::Store::CompactPlan.new(response_bodies: true)).should be_nil
        # The body is untouched because the run was refused.
        Gori::Store.measure(path).response_body_bytes.should be > 0
      ensure
        lock.close
      end
    end
  end
end
