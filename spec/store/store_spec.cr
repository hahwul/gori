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

  it "appends events and tails them with a forward id cursor (list_events backing)" do
    with_store do |store|
      a = store.insert_event("miner", "job_done", "success", "found 3", goto_tab: "miner", goto_session_id: 7_i64)
      b = store.insert_event("agent", "agent_action", "info", "send_request ok", payload: "send_request")
      c = store.insert_event("fuzzer", "job_done", "error", "boom")
      a.should be > 0
      (b > a && c > b).should be_true # monotonic ids

      all = store.events_after(0, 100)
      all.map(&.id).should eq([a, b, c])                    # oldest-first
      all.map(&.source).should eq(["miner", "agent", "fuzzer"])
      all[0].goto_session_id.should eq(7_i64)
      all[1].payload.should eq("send_request")

      store.events_after(a, 100).map(&.id).should eq([b, c]) # strictly after the cursor
      store.events_after(c, 100).should be_empty             # nothing past the newest
    end
  end

  it "never reuses an event id after the newest row is deleted (AUTOINCREMENT)" do
    with_store do |store|
      x = store.insert_event("probe", "issue_found", "success", "one")
      store.@db.exec("DELETE FROM events WHERE id = ?", x)
      y = store.insert_event("probe", "issue_found", "success", "two")
      y.should be > x # a since_id watermark can never silently skip a new row
    end
  end

  it "mirrors held intercept items and round-trips the command queue (#123 bridge)" do
    with_store do |store|
      tok = "sess-abc"
      raw = "GET /a HTTP/1.1\r\nHost: x.test\r\n\r\n".to_slice
      store.publish_intercept_held(tok, [Gori::Store::HeldRow.new(tok, 1_i64, "request", "GET", "x.test", 80, "http", "/a", raw, 1_000_i64, nil, false)])
      held = store.intercept_held(tok)
      held.size.should eq(1)
      held[0].item_id.should eq(1)
      held[0].host.should eq("x.test")
      held[0].raw.should eq(raw)
      store.intercept_held("other-token").should be_empty

      # A fresh session (different token) wipes the prior session's mirror on publish.
      store.publish_intercept_held("sess-two", [Gori::Store::HeldRow.new("sess-two", 1_i64, "request", "GET", "y.test", 80, "http", "/b", raw, 2_000_i64, nil, false)])
      store.intercept_held(tok).should be_empty
      store.intercept_held("sess-two").size.should eq(1)

      # Command queue: enqueue -> forward-cursor drain -> ack -> status.
      cid = store.enqueue_intercept_command("sess-two", "forward", item_id: 1_i64)
      cid.should be > 0
      store.latest_intercept_command_id.should eq(cid)
      cmds = store.intercept_commands_after(0_i64, 10)
      cmds.size.should eq(1)
      cmds[0].verb.should eq("forward")
      cmds[0].item_id.should eq(1)
      cmds[0].session_token.should eq("sess-two")
      store.intercept_commands_after(cid, 10).should be_empty # forward cursor: nothing past it
      store.command_status(cid).not_nil![0].should eq("pending")
      store.ack_intercept_command(cid, "forwarded", "GET y.test/b")
      st = store.command_status(cid).not_nil!
      st[0].should eq("forwarded")
      st[1].should eq("GET y.test/b")

      # Empty publish clears the mirror; clear_intercept_state! wipes both tables.
      store.publish_intercept_held("sess-two", [] of Gori::Store::HeldRow)
      store.intercept_held("sess-two").should be_empty
      store.clear_intercept_state!
      store.intercept_commands_after(0_i64, 10).should be_empty
    end
  end

  it "never reuses an intercept_commands id after a delete (AUTOINCREMENT watermark safety)" do
    with_store do |store|
      a = store.enqueue_intercept_command("t", "forward", item_id: 1_i64)
      store.@db.exec("DELETE FROM intercept_commands WHERE id = ?", a)
      b = store.enqueue_intercept_command("t", "drop", item_id: 2_i64)
      b.should be > a # the TUI drain watermark can never silently skip a command
    end
  end

  it "abandon_pending! marks every Pending flow Error and leaves Complete rows alone" do
    with_store do |store|
      pending1 = store.insert_flow(sample_request(target: "/hang"))
      pending2 = store.insert_flow(sample_request(target: "/stuck"))
      done = store.insert_flow(sample_request(target: "/ok"))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: done, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))

      store.abandon_pending!("proxy stopped before response").should eq(2)

      store.get_flow(pending1).not_nil!.row.state.should eq(Gori::Store::FlowState::Error)
      store.get_flow(pending1).not_nil!.error.should eq("proxy stopped before response")
      store.get_flow(pending2).not_nil!.row.state.should eq(Gori::Store::FlowState::Error)
      store.get_flow(done).not_nil!.row.state.should eq(Gori::Store::FlowState::Complete)
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

  it "delete_flow removes one flow and its captured WS/FTS/link dependents" do
    with_store do |store|
      keep = store.insert_flow(sample_request(target: "/keep"))
      gone = store.insert_flow(sample_request(target: "/gone"))
      store.insert_ws_message(gone, "client", 1, "hi".to_slice)
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, gone)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, keep)

      store.delete_flow(gone)

      store.get_flow(gone).should be_nil
      store.get_flow(keep).should_not be_nil
      store.count.should eq(1)
      store.count_ws_messages(gone).should eq(0)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        .map(&.ref_id).should eq([keep])
    end
  end

  it "clear_flows wipes every History flow while sparing repeater-owned WS rows" do
    with_store do |store|
      a = store.insert_flow(sample_request(target: "/a"))
      b = store.insert_flow(sample_request(target: "/b"))
      store.insert_ws_message(a, "client", 1, "cap".to_slice)
      # WebSocket-Repeater output: sentinel flow_id=0, keyed by repeater_id.
      store.insert_ws_message(0_i64, "client", 1, "rep".to_slice, repeater_id: 9_i64)
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Flow, a)

      store.clear_flows

      store.count.should eq(0)
      store.get_flow(a).should be_nil
      store.get_flow(b).should be_nil
      store.count_ws_messages(a).should eq(0)
      # Repeater-owned WS row survives (not keyed by a History flow).
      store.@db.scalar("SELECT COUNT(*) FROM ws_messages WHERE repeater_id = 9").as(Int64).should eq(1)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty
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

  it "retention prune spares saved WebSocket-Repeater messages (flow_id=0 sentinel, keyed by repeater_id)" do
    path = File.tempname("gori-wsret", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    Gori::Store::Schema.migrate!(db)
    store = Gori::Store.new(db, nil, retention_flows: 5, prune_interval: 10)
    begin
      rid = store.insert_repeater("wss://acme.test/ws", "GET /ws HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)
      store.update_repeater_ws_messages(rid, ["client frame 1", "client frame 2"])
      # Churn flows well past retention so prune fires (cutoff = max_id - 5 > 0). The bug:
      # DELETE ... WHERE flow_id <= cutoff also matched the repeater rows (flow_id = 0), wiping them.
      12.times { |i| store.insert_flow(sample_request(target: "/#{i}")) }
      store.flush
      store.ws_messages_for_repeater(rid).size.should eq(2) # repeater traffic survives flow retention
      store.write_failures.should eq(0)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "stores a zero-length WebSocket frame without aborting the write batch (empty payload → X'', not NULL)" do
    with_store do |store|
      fid = store.insert_flow(sample_request(target: "/ws"))
      # A valid empty WS text frame (RFC 6455): payload BLOB NOT NULL used to bind SQL
      # NULL from an empty slice, aborting the whole transaction and losing the
      # co-batched non-empty frame too. Both must survive with write_failures == 0.
      store.insert_ws_message(fid, "out", 1, Bytes.empty)
      store.insert_ws_message(fid, "in", 1, "hello".to_slice)
      store.flush
      msgs = store.ws_messages(fid)
      msgs.size.should eq(2)
      msgs[0].payload.empty?.should be_true
      msgs[1].payload.should eq("hello".to_slice)
      store.write_failures.should eq(0)
    end
  end

  it "update_repeater_ws_messages stores an empty frame text without aborting the batch" do
    with_store do |store|
      rid = store.insert_repeater("wss://acme.test/ws", "GET /ws HTTP/1.1\r\n\r\n".to_slice, false, false, nil, 0)
      store.update_repeater_ws_messages(rid, ["", "frame"])
      store.flush
      store.ws_messages_for_repeater(rid).size.should eq(2)
      store.write_failures.should eq(0)
    end
  end

  it "insert_issue returns the issue's own id, not the entity_links row id, when linked to a flow" do
    with_store do |store|
      fid = store.insert_flow(sample_request(target: "/f"))
      # An unlinked issue first (issues id 1, no entity_links row), so the linked
      # issue's id (2) diverges from its link row's id (1) — exposing the old bug
      # that returned last_insert_rowid AFTER the entity_links insert.
      store.insert_issue("no-link", Gori::Store::Severity::Low, "acme.test", nil)
      linked_id = store.insert_issue("linked", Gori::Store::Severity::High, "acme.test", fid)
      linked_id.should eq(2)
      store.issues.find { |f| f.id == linked_id }.not_nil!.title.should eq("linked")
    end
  end

  it "migrate! serializes concurrent openers: a second opener sees the migrated version" do
    path = File.tempname("gori-migrace", ".db")
    db1 = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    db2 = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    begin
      Gori::Store::Schema.migrate!(db1)
      # The second opener re-reads user_version UNDER the write lock and finds nothing
      # to do — rather than racing the same CREATE/ALTER and crashing on "table exists".
      Gori::Store::Schema.migrate!(db2)
      db2.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION)
    ensure
      db1.close
      db2.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "V2 migration recovers a pre-existing repeaters.request value that the OLD read path truncated at an embedded NUL" do
    # Recreates exactly what a pre-fix (V1-only) gori install left on disk: the V1
    # CREATE TABLE only (no V2 UPDATE), with a `request` row inserted the OLD way — a bound
    # Crystal String. sqlite3_bind_text takes an explicit byte count (not NUL-terminated),
    # so the write already stored the full bytes; the bug was purely in the OLD read path
    # (sqlite3_column_text + a NUL-terminated String.new), which the untyped Bytes read
    # below does NOT use — this proves the migration recovers what was already on disk for
    # any existing user, not just what a fresh insert produces going forward.
    path = File.tempname("gori-repeater-migrate", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    begin
      Gori::Store::Schema::V1.each { |sql| db.exec(sql) }
      db.exec("PRAGMA user_version = 1")

      with_nul = "GET /x HTTP/1.1\r\nHost: h\r\n\r\n".to_slice + Bytes[0_u8] + "BINARYTAIL".to_slice
      normal = "GET /y HTTP/1.1\r\n\r\n"
      ts = 1_i64
      db.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, auto_content_length, position) VALUES (?,?,?,?,?,?,?)",
        ts, ts, "https://a.test", String.new(with_nul), 0, 1, 0)
      db.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, auto_content_length, position) VALUES (?,?,?,?,?,?,?)",
        ts, ts, "https://b.test", normal, 0, 1, 1)

      # Pre-migration: the OLD read shape (untyped `read` dispatches TEXT-storage-class
      # values through sqlite3_column_text) truncates at the embedded NUL, exactly
      # reproducing the original bug.
      db.query_one("SELECT request FROM repeaters WHERE target = 'https://a.test'", as: String)
        .should eq("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")

      Gori::Store::Schema.migrate!(db)
      db.scalar("PRAGMA user_version").as(Int64).should eq(2_i64)

      recovered = db.query_one("SELECT request FROM repeaters WHERE target = 'https://a.test'", as: Bytes)
      recovered.should eq(with_nul) # full byte-for-byte recovery, embedded NUL and all

      unaffected = db.query_one("SELECT request FROM repeaters WHERE target = 'https://b.test'", as: Bytes)
      String.new(unaffected).should eq(normal) # a normal (no-NUL) row is untouched
    ensure
      db.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "retention prune keeps an in-flight h2 connection's frame log but reaps orphaned ones" do
    path = File.tempname("gori-h2ret", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    Gori::Store::Schema.migrate!(db)
    store = Gori::Store.new(db, nil, retention_flows: 5, prune_interval: 10)
    begin
      # IN-FLIGHT: a RECENT frame, no flow references it yet (flow not projected).
      db.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (1, 1, 'h', 443, 'h2')")
      db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) VALUES (1, 999999, 'in', 1, 0, 0, 3, ?)", "abc".to_slice)
      # ORPHANED: old frames, no flow, no recent activity.
      db.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (2, 1, 'h', 443, 'h2')")
      db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) VALUES (2, 1, 'in', 1, 0, 0, 3, ?)", "old".to_slice)

      12.times { |i| store.insert_flow(sample_request(target: "/#{i}")) } # trigger prune

      store.count_h2_frames(1_i64).should eq(1) # in-flight: survives (was silently deleted → dangling FK)
      store.count_h2_frames(2_i64).should eq(0) # orphaned: reaped
      db.scalar("SELECT COUNT(*) FROM h2_connections WHERE id = 1").as(Int64).should eq(1)
      db.scalar("SELECT COUNT(*) FROM h2_connections WHERE id = 2").as(Int64).should eq(0)
    ensure
      store.close
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

  it "distinct_hosts returns prefix-filtered hosts for QL Tab-complete" do
    with_store do |store|
      %w(api.example.com app.example.com cdn.other.com).each do |h|
        store.insert_flow(sample_request(host: h, target: "/"))
      end
      store.distinct_hosts(limit: 10).sort.should eq(
        ["api.example.com", "app.example.com", "cdn.other.com"])
      store.distinct_hosts(prefix: "api", limit: 10).should eq(["api.example.com"])
      store.distinct_hosts(prefix: "ap", limit: 10).sort.should eq(
        ["api.example.com", "app.example.com"])
      store.distinct_hosts(prefix: "API", limit: 10).should eq(["api.example.com"]) # case-insensitive
      store.distinct_hosts(prefix: "nope", limit: 10).should be_empty
      store.distinct_hosts(prefix: "a", limit: 1).size.should eq(1) # hard cap
    end
  end

  it "recent_flows / search return metadata-only rows (no body BLOBs on the list path)" do
    with_store do |store|
      big = Bytes.new(200_000) { |i| ((i % 26) + 65).to_u8 }
      id = store.insert_flow(sample_request(method: "POST", target: "/big"))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".to_slice,
        body: big, content_type: "application/octet-stream"))

      rows = store.recent_flows(10)
      rows.size.should eq(1)
      rows.first.id.should eq(id)
      # FlowRow has no body fields — list model is projections only (compile-time shape).
      rows.first.responds_to?(:request_body).should be_false
      rows.first.responds_to?(:response_body).should be_false
      rows.first.size.should be > 200_000 # true wire size still on the row

      filtered = store.search(Gori::QL.parse("status:200"), 10)
      filtered.size.should eq(1)
      filtered.first.responds_to?(:response_body).should be_false
    end
  end

  it "get_flow body_max caps BLOB reads for list-preview (full get_flow still whole)" do
    with_store do |store|
      body = Bytes.new(100_000) { |i| ((i % 26) + 97).to_u8 }
      id = store.insert_flow(sample_request(method: "POST", target: "/cap"))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
        body: body, content_type: "text/plain"))

      full = store.get_flow(id).not_nil!
      full.response_body.not_nil!.size.should eq(100_000)

      cap = 64 * 1024 + 1
      prev = store.get_flow(id, body_max: cap).not_nil!
      prev.response_body.not_nil!.size.should eq(cap)
      prev.response_body.not_nil!.should eq(body[0, cap])
      # heads and metadata remain complete
      prev.response_head.not_nil!.should eq(full.response_head)
      prev.row.id.should eq(id)
      prev.row.status.should eq(200)
    end
  end

  it "list path stays page-limited under multi-thousand rows" do
    with_store do |store|
      2_500.times { |i| store.insert_flow(sample_request(target: "/p/#{i}")) }
      page = store.recent_flows(1000)
      page.size.should eq(1000)
      # cursor into older pages — still bounded
      older = store.recent_flows(1000, before_id: page.last.id)
      older.size.should eq(1000)
      older.first.id.should be < page.last.id
      store.recent_flows(1000, before_id: older.last.id).size.should eq(500)
    end
  end
end
