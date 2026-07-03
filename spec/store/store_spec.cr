require "../spec_helper"

private def with_store(events : Channel(Gori::Store::FlowEvent)? = nil, &)
  path = File.tempname("gori-test", ".db")
  store = Gori::Store.open(path, events)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def sample_request(method = "GET", host = "acme.test", target = "/")
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64,
    scheme: "http",
    host: host,
    port: 80,
    method: method,
    target: target,
    http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: nil,
  )
end

describe Gori::Store do
  it "applies the v1 migration (user_version = 1)" do
    with_store do |store|
      # count works => schema exists
      store.count.should eq(0)
    end
  end

  it "upgrades a pre-sitemap_tags DB (V18+ migrations) and persists tags" do
    path = File.tempname("gori-v18", ".db")
    begin
      # Simulate a DB last migrated before V18: drop the post-V17 tables and roll
      # user_version back to 17 (e.g. a project created on the hostname-overrides branch).
      store = Gori::Store.open(path)
      store.@db.exec("DROP TABLE sitemap_tags")                        # V18
      store.@db.exec("DROP TABLE miner_sessions")                      # V19
      store.@db.exec("DROP TABLE prism_issues")                        # V20
      store.@db.exec("DROP TABLE entity_links")                        # V21
      store.@db.exec("ALTER TABLE replays DROP COLUMN mark_transform") # V22 (added a column to a pre-V17 table)
      store.@db.exec("PRAGMA user_version = 17")
      store.close

      # Reopen: the V18 migration must recreate sitemap_tags so tags persist again, and
      # the migration runner climbs to the current schema version.
      store = Gori::Store.open(path)
      store.@db.scalar("PRAGMA user_version").should eq(Gori::Store::Schema::VERSION)
      store.set_sitemap_tag("acme.test", "/api", "memo")
      store.sitemap_tags[{"acme.test", "/api"}]?.should eq("memo")
      store.close
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "inserts a Pending flow and lists it newest-first with nil status" do
    with_store do |store|
      id1 = store.insert_flow(sample_request(target: "/first"))
      id2 = store.insert_flow(sample_request(target: "/second"))
      id2.should be > id1

      rows = store.recent_flows(10)
      rows.size.should eq(2)
      rows[0].id.should eq(id2) # newest first
      rows[0].target.should eq("/second")
      rows[0].status.should be_nil
      rows[0].state.should eq(Gori::Store::FlowState::Pending)
    end
  end

  it "round-trips raw request/response BLOBs byte-exact through get_flow (P7)" do
    with_store do |store|
      req = sample_request(method: "POST", target: "/api")
      id = store.insert_flow(req)

      resp_head = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n".to_slice
      resp_body = %({"ok":true}).to_slice
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 201, head: resp_head, body: resp_body,
        reason: "Created", content_type: "application/json", duration_us: 4200_i64))

      detail = store.get_flow(id).not_nil!
      detail.request_head.should eq(req.head)
      detail.response_head.should eq(resp_head)
      detail.response_body.should eq(resp_body)
      detail.row.status.should eq(201)
      detail.row.state.should eq(Gori::Store::FlowState::Complete)
      detail.request_body_truncated?.should be_false
      detail.response_body_truncated?.should be_false
    end
  end

  it "records a truncated body flag while keeping the TRUE wire size" do
    with_store do |store|
      stored = Bytes.new(8) { |i| (65 + i).to_u8 } # the capped 8-byte capture
      req = Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/up", http_version: "HTTP/1.1",
        head: "POST /up HTTP/1.1\r\n\r\n".to_slice, body: stored,
        body_truncated: true, body_size: 5_000_000_i64)
      id = store.insert_flow(req)
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
        body: stored, body_truncated: true, body_size: 9_000_000_i64))

      detail = store.get_flow(id).not_nil!
      detail.request_body_truncated?.should be_true
      detail.response_body_truncated?.should be_true
      detail.request_body.should eq(stored) # only the capped bytes are stored
      # the list size column reflects the TRUE wire size, not the truncated BLOB
      detail.row.size.should eq(("POST /up HTTP/1.1\r\n\r\n".bytesize + 5_000_000) +
                                ("HTTP/1.1 200 OK\r\n\r\n".bytesize + 9_000_000))
    end
  end

  it "publishes :inserted then :updated events after commit" do
    events = Channel(Gori::Store::FlowEvent).new(16)
    with_store(events) do |store|
      id = store.insert_flow(sample_request)
      inserted = events.receive
      inserted.kind.should eq(:inserted)
      inserted.id.should eq(id)

      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      updated = events.receive
      updated.kind.should eq(:updated)
      updated.id.should eq(id)
    end
  end

  it "prunes the oldest flows (and their ws messages) once retention is exceeded" do
    path = File.tempname("gori-ret", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    Gori::Store::Schema.migrate!(db)
    store = Gori::Store.new(db, nil, retention_flows: 5, prune_interval: 10)
    begin
      ids = [] of Int64
      ids << store.insert_flow(sample_request(target: "/1"))
      store.insert_ws_message(ids[0], "out", 1, "x".to_slice) # belongs to a soon-pruned flow
      (2..12).each { |i| ids << store.insert_flow(sample_request(target: "/#{i}")) }
      # the prune fired after the 10th insert (cutoff = 10 - 5): kept ids 6-10,
      # then ids 11-12 were inserted → ~7 rows; the oldest are gone.
      store.count.should eq(7_i64)
      store.flow_row(ids[0]).should be_nil      # flow 1 pruned
      store.ws_messages(ids[0]).should be_empty # cascade removed its ws message
      store.flow_row(ids[11]).should_not be_nil # flow 12 kept
      store.write_failures.should eq(0)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "backfills the body FTS index for rows that predate the V8 migration" do
    path = File.tempname("gori-bf", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal")
    begin
      # bring the schema only up to V7, then plant a pre-existing flow with a body
      Gori::Store::Schema::MIGRATIONS[0..6].each_with_index do |stmts, i|
        db.transaction do |tx|
          stmts.each { |s| tx.connection.exec(s) }
          tx.connection.exec("PRAGMA user_version = #{i + 1}")
        end
      end
      db.exec(<<-SQL, "GET /x HTTP/1.1\r\n\r\n".to_slice, "secret=backfilltoken".to_slice)
        INSERT INTO flows (created_at, scheme, host, port, method, target, http_version,
                           request_head, request_body, request_size, state)
        VALUES (1, 'http', 'h.test', 80, 'GET', '/x', 'HTTP/1.1', ?, ?, 30, 0)
        SQL

      Gori::Store::Schema.migrate!(db) # runs V8 (index + FTS + backfill), then any later migrations
      db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION)
      hits = db.scalar(%(SELECT count(*) FROM flows_fts WHERE flows_fts MATCH '"backfilltoken"')).as(Int64)
      hits.should eq(1)
    ensure
      db.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "bounds sitemap_entries by the limit so a huge history can't materialize unbounded" do
    with_store do |store|
      5.times { |i| store.insert_flow(sample_request(host: "h#{i}.test", target: "/p#{i}")) }
      store.sitemap_entries(limit: 2).size.should eq(2)
      store.sitemap_entries.size.should eq(5) # default limit is generous
    end
  end

  it "pages older rows via the before_id cursor" do
    with_store do |store|
      ids = (1..5).map { |i| store.insert_flow(sample_request(target: "/#{i}")) }
      page1 = store.recent_flows(2)
      page1.map(&.id).should eq([ids[4], ids[3]])
      page2 = store.recent_flows(2, before_id: page1.last.id)
      page2.map(&.id).should eq([ids[2], ids[1]])
    end
  end
end
