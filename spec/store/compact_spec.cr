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
    body: big_body(120_000))
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
