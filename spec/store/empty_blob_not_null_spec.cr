require "../spec_helper"

# An empty `Bytes` is a NULL POINTER, so the driver binds it as SQL NULL. Handed to a
# `BLOB NOT NULL` column that is either a raise (rolling back the WHOLE writer batch and, before
# the teardown guards, hanging `Store#close`) or — under `INSERT OR IGNORE` — a row that silently
# never appears. `insert_ws_one` and `insert_h2_frame_one` each found this and wrote their own
# `X''` branch; these are the columns that had not.
private def blob_store(&)
  path = File.tempname("gori-empty-blob", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
    # On a fiber against a timeout: a NOT NULL violation used to poison the writer's cached
    # statement, and the error surfaces at `close`. A regression must fail, not hang.
    done = Channel(Nil).new(1)
    spawn { store.close; done.send(nil) }
    select
    when done.receive then nil
    when timeout(20.seconds) then raise "store.close did not return"
    end
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def flow_with_head(head : Bytes) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
    target: "/", http_version: "HTTP/1.1", head: head, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

describe "a zero-length BLOB in a NOT NULL column" do
  it "stores a flow whose request head is empty instead of failing the batch" do
    blob_store do |store|
      id = store.insert_flow(flow_with_head(Bytes.empty))
      id.should be > 0
      store.flush
      store.count.should eq(1)
      store.write_failures.should eq(0) # the batch committed; nothing batched with it was lost
      store.get_flow(id).not_nil!.request_head.size.should eq(0)
    end
  end

  it "still round-trips a real request head byte for byte" do
    # The bind order is now built by hand, so this is the guard on it.
    blob_store do |store|
      head = "GET /x HTTP/1.1\r\nHost: a.test\r\nX-K: v\r\n\r\n".to_slice
      id = store.insert_flow(flow_with_head(head))
      store.flush
      detail = store.get_flow(id).not_nil!
      String.new(detail.request_head).should eq(String.new(head))
      row = detail.row
      row.host.should eq("a.test")
      row.method.should eq("GET")
      row.target.should eq("/")
      row.scheme.should eq("http")
      row.port.should eq(80)
      row.state.should eq(Gori::Store::FlowState::Pending)
    end
  end

  it "stores a Miner session with an empty request template" do
    blob_store do |store|
      id = store.insert_miner_session("http://a.test/", Bytes.empty, false, nil, "{}", nil, 0)
      id.should be > 0 # 0 is this method's "the write was dropped", which the caller reads as no session
      store.flush
      store.miner_sessions.size.should eq(1)
      store.write_failures.should eq(0)
    end
  end

  it "stores a Sequencer session with an empty request template" do
    blob_store do |store|
      id = store.insert_sequencer_session("http://a.test/", Bytes.empty, false, nil, "{}", nil, 0)
      id.should be > 0
      store.flush
      store.sequencer_sessions.size.should eq(1)
      store.write_failures.should eq(0)
    end
  end

  it "publishes a held zero-length WebSocket frame to the cross-process bridge" do
    blob_store do |store|
      # Valid per RFC 6455 — the empty heartbeat `insert_ws_one` already has a branch for. The
      # gate holds it like any other message, so every cross-process surface has to see it or
      # nothing there can forward or drop it.
      empty = Gori::Store::HeldRow.new("tok", 1_i64, "wsout", "GET", "a.test", 443, "wss",
        "/socket", Bytes.empty, 111_i64, nil, false, 0_i64, nil, false, false)
      full = Gori::Store::HeldRow.new("tok", 2_i64, "wsout", "GET", "a.test", 443, "wss",
        "/socket", "hi".to_slice, 112_i64, nil, false, 0_i64, nil, false, false)
      store.publish_intercept_held("tok", [empty, full])
      store.flush
      held = store.intercept_held("tok")
      held.map(&.item_id).should eq([1_i64, 2_i64])
      held.first.raw.size.should eq(0)
    end
  end

  it "persists an OAST callback that carries no raw request" do
    blob_store do |store|
      sid = store.insert_oast_session(nil, "interactsh", "https://oast.example", "corr", "secret", nil, nil)
      store.insert_oast_callback(sid, "uid-dns", "dns", nil, "1.2.3.4", "x.oast.example",
        Bytes.empty, nil, 1_000_i64)
      store.insert_oast_callback(sid, "uid-http", "http", "GET", "1.2.3.4", "y.oast.example",
        "GET / HTTP/1.1\r\n\r\n".to_slice, nil, 2_000_i64)
      store.flush
      # The operator was notified of both hits live; both have to survive a reload.
      store.oast_callbacks(sid).map(&.provider_uid).sort.should eq(["uid-dns", "uid-http"])
    end
  end
end
