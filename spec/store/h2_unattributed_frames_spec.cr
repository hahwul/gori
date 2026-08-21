require "../spec_helper"

# `FlowSink#on_h2_open` returns 0 for a sink that keeps no raw frame log, and
# `StoreSink#on_h2_open` returns 0 when `insert_h2_connection` did not commit — so 0 means
# "there is no connection row", never "connection number zero". Everything downstream has to
# read it that way: the frame writer, the flow projection, and both retention sweeps.
private def h2_store(retention = 2, prune_interval = 1, &)
  path = File.tempname("gori-h2-unattributed", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, retention_flows: retention, prune_interval: prune_interval)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def h2_request(target : String, conn : Int64?) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/2",
    head: "GET #{target} HTTP/2\r\nHost: acme.test\r\n\r\n".to_slice, body: nil,
    h2_conn_id: conn, h2_stream_id: 1_i64, source: Gori::FlowSource::Kind::Proxy)
end

describe "unattributed HTTP/2 frames" do
  it "does not store a frame that has no connection row" do
    h2_store do |store|
      4.times { |i| store.insert_h2_frame(0_i64, "out", 1_u8, 0_u8, (i + 1).to_u32, "hdr#{i}".to_slice) }
      store.flush
      # Nothing to reap later, because nothing was written. `h2_frames(0)` is what the History
      # detail pane called, and it must not be a window onto every connection that failed.
      store.h2_frames(0_i64).size.should eq(0)
      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0_i64)
    end
  end

  it "still stores frames for a real connection" do
    h2_store do |store|
      real = store.insert_h2_connection("acme.test", 443, "h2")
      real.should be > 0
      3.times { |i| store.insert_h2_frame(real, "out", 1_u8, 0_u8, (i + 1).to_u32, "real#{i}".to_slice) }
      store.flush
      store.h2_frames(real).size.should eq(3)
    end
  end

  it "stores a flow's missing connection id as NULL, not as 0" do
    h2_store(retention: Gori::Store::RETENTION_UNLIMITED) do |store|
      id = store.insert_flow(h2_request("/no-log", 0_i64))
      store.flush
      # `load_detail_logs` does `if cid = detail.h2_conn_id`, and 0_i64 is TRUTHY in Crystal,
      # so a stored 0 opened a frame log; two other guards read `.nil?` to decide whether the
      # flow is still streaming and re-read it on every poll tick.
      store.@db.query_one("SELECT h2_conn_id FROM flows WHERE id = ?", id, as: Int64?).should be_nil
      store.get_flow(id).not_nil!.h2_conn_id.should be_nil
    end
  end

  it "keeps a flow's real connection id" do
    h2_store(retention: Gori::Store::RETENTION_UNLIMITED) do |store|
      real = store.insert_h2_connection("acme.test", 443, "h2")
      id = store.insert_flow(h2_request("/logged", real))
      store.flush
      store.get_flow(id).not_nil!.h2_conn_id.should eq(real)
    end
  end

  it "reaps frames an older build already stranded under a missing connection" do
    h2_store do |store|
      # Written the way a pre-guard build wrote them: straight into the table, no connection.
      5.times do |i|
        store.@db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                       "VALUES (0,?,?,?,1,0,4,X'')", 1_000_i64 + i, "out", (i + 1).to_i64)
      end
      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(5_i64)

      # Churn past the cap so the sweep runs. It selects reclaimable frames THROUGH
      # h2_connections, so before the orphan reap it could never see these.
      12.times { |i| store.insert_flow(h2_request("/f#{i}", nil)) }
      store.flush

      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0_i64)
    end
  end
end

# The orphan reap used to sit BEHIND retention's early returns, so it never ran for the two
# commonest projects: an MCP server opens with RETENTION_UNLIMITED, and a TUI project under its
# cap returns at `cutoff <= 0`. The comment there promised such a db would heal itself.
describe "the unattributed-frame reap and retention" do
  it "runs with retention disabled" do
    h2_store(retention: Gori::Store::RETENTION_UNLIMITED, prune_interval: 1) do |store|
      3.times do |i|
        store.@db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                       "VALUES (0,?,?,?,1,0,4,X'')", 1_000_i64 + i, "out", (i + 1).to_i64)
      end
      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(3_i64)

      2.times { |i| store.insert_flow(h2_request("/keep#{i}", nil)) }
      store.flush

      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0_i64)
      store.count.should eq(2_i64) # and nothing was pruned — retention is off
    end
  end

  it "runs for a project still under its retention cap" do
    h2_store(retention: 1000, prune_interval: 1) do |store|
      store.@db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
                     "VALUES (0,1,'out',1,1,0,4,X'')")
      2.times { |i| store.insert_flow(h2_request("/keep#{i}", nil)) }
      store.flush
      store.@db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0_i64)
      store.count.should eq(2_i64)
    end
  end
end
