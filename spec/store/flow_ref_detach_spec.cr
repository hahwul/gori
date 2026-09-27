require "../spec_helper"

private def ref_flow(store : Gori::Store, target : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: Time.utc.to_unix_ms * 1000_i64, scheme: "http", host: "ref.test", port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: ref.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def retest_run_for_flow(store : Gori::Store, flow_id : Int64) : Int64
  issue_id = store.insert_issue("flow reference", Gori::Store::Severity::High, "ref.test", nil)
  repeater_id = store.insert_repeater(target: "http://ref.test/", request: "GET / HTTP/1.1\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: store.next_repeater_position)
  step_id, status = store.add_retest_step(issue_id, :baseline, Gori::Store::LinkRefKind::Repeater, repeater_id)
  status.ok?.should be_true
  step = store.get_retest_step(step_id).not_nil!
  planned = Gori::Retest::Planned.new(step, "GET", "http://ref.test/", "repeater tab")
  observed = Gori::Retest::Observation.new(status: 200, duration_us: 1_i64, bytes: 2_i64, flow_id: flow_id)
  result = Gori::Retest::StepResult.new(planned, Gori::Store::RetestOutcome::Pass, "ok", observed)
  run_id, status = store.record_retest_run(issue_id, 1_i64, 2_i64,
    Gori::Store::RetestVerdict::Pass, Gori::Retest::Tally.new(1, 1, 0, 0, 0, 0, 0), [result])
  status.ok?.should be_true
  run_id
end

describe "Store flow references after deletion" do
  it "detaches retest results before a deleted flow id can be reused" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      run_id = retest_run_for_flow(store, flow_id)

      store.delete_flow(flow_id).should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      store.retest_run_steps(run_id).first.flow_id.should be_nil
    end
  end

  it "detaches frozen evidence when one History flow is deleted" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      issue_id = store.insert_issue("frozen flow", Gori::Store::Severity::Low, "ref.test", nil)
      snapshot = Gori::Evidence.from_flow(store.get_flow(flow_id).not_nil!)
      evidence_id, status = store.freeze_evidence(issue_id, snapshot)
      status.ok?.should be_true

      store.delete_flow(flow_id).should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      meta = store.get_evidence_meta(evidence_id).not_nil!
      meta.source_id.should eq(-flow_id)
      store.evidence_source_alive?(meta).should be_false
      store.evidence_count_for(Gori::Store::LinkRefKind::Flow, flow_id).should eq(0)
    end
  end

  it "detaches retest results and frozen evidence during History clear" do
    with_store do |store|
      flow_id = ref_flow(store, "/recorded")
      run_id = retest_run_for_flow(store, flow_id)
      issue_id = store.insert_issue("frozen flow", Gori::Store::Severity::Low, "ref.test", nil)
      snapshot = Gori::Evidence.from_flow(store.get_flow(flow_id).not_nil!)
      evidence_id, status = store.freeze_evidence(issue_id, snapshot)
      status.ok?.should be_true

      store.clear_flows.should be_true
      store.flush
      ref_flow(store, "/unrelated").should eq(flow_id)
      store.flush

      store.retest_run_steps(run_id).first.flow_id.should be_nil
      meta = store.get_evidence_meta(evidence_id).not_nil!
      meta.source_id.should be < 0
      meta.source_label.should eq("hist ##{flow_id} (deleted)")
      store.evidence_source_alive?(meta).should be_false
      store.evidence_count_for(Gori::Store::LinkRefKind::Flow, flow_id).should eq(0)
      String.new(store.get_evidence(evidence_id).not_nil!.request_head).should contain("GET /recorded")
    end
  end
end

# A raw-SQL harness for the table sweep below: rows are planted straight into every table that
# names a flow, so the spec keeps covering a table added later without being told about it.
private def raw_detach_store(&)
  path = File.tempname("gori-detach", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store, db
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# One row in `table` with `col` = `value`; every other NOT NULL column without a default gets a
# type-appropriate filler, unique per `n` so a UNIQUE or composite key never collides.
private def plant_ref(db : DB::Database, table : String, col : String, value : Int64, n : Int32,
                      extra : Hash(String, DB::Any) = {} of String => DB::Any) : Nil
  cols = [] of {String, String}
  db.query("PRAGMA table_info(#{table})") do |rs|
    rs.each do
      rs.read(Int64)
      name = rs.read(String)
      type = rs.read(String)
      notnull = rs.read(Int64) == 1
      dflt = rs.read(String?)
      rs.read(Int64)
      next if name == col || name == "id" || extra.has_key?(name)
      cols << {name, type} if notnull && dflt.nil?
    end
  end
  names = [col] + extra.keys + cols.map(&.[0])
  vals = [value.as(DB::Any)] + extra.values +
         cols.map { |(_, t)| t.upcase.includes?("INT") ? n.to_i64.as(DB::Any) : "v#{n}".as(DB::Any) }
  db.exec("INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{Array.new(names.size, "?").join(", ")})", args: vals)
end

# Every live table with a column that holds a flow id, found from the schema itself.
private def flow_ref_columns(db : DB::Database) : Array({String, String})
  tables = db.query_all("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' " \
                        "AND name NOT LIKE 'flows_fts%'", as: String)
  tables.flat_map do |t|
    db.query_all("SELECT name FROM pragma_table_info(?) WHERE name IN ('flow_id', 'sample_flow_id')", t, as: String)
      .map { |c| {t, c} }
  end
end

describe "Store#delete_flows detaching references" do
  it "detaches or deletes every row naming a deleted flow, in every table, for a multi-id delete" do
    raw_detach_store do |store, db|
      gone_a = ref_flow(store, "/a")
      gone_b = ref_flow(store, "/b")
      kept = ref_flow(store, "/kept")
      store.flush

      refs = flow_ref_columns(db)
      refs.map(&.[0]).should contain("events")
      refs.map(&.[0]).should contain("probe_issues")
      seq = (1..).each # unique filler per planted row
      refs.each do |(table, col)|
        [gone_a, gone_b, kept].each { |fid| plant_ref(db, table, col, fid, seq.next.as(Int32)) }
      end
      # A repeater-owned WS row keeps its (NOT NULL) flow id by design; its session carries
      # the provenance instead.
      plant_ref(db, "ws_messages", "flow_id", gone_a, seq.next.as(Int32), {"repeater_id" => 7_i64.as(DB::Any)})
      [gone_a, gone_b, kept].each do |fid|
        plant_ref(db, "issue_evidence", "source_id", fid, seq.next.as(Int32), {"source_kind" => "flow".as(DB::Any)})
        plant_ref(db, "entity_links", "ref_id", fid, seq.next.as(Int32), {"ref_kind" => "flow".as(DB::Any)})
      end

      # A repeated id, as a marked set built from two overlapping selections could carry.
      store.delete_flows([gone_a, gone_b, gone_a]).should be_true
      store.flush

      # {table, column, rows still naming a deleted flow, rows naming the survivor}
      counts = refs.map do |(table, col)|
        captured = table == "ws_messages" ? " AND repeater_id IS NULL" : ""
        {table, col,
         db.scalar("SELECT COUNT(*) FROM #{table} WHERE #{col} IN (?, ?)#{captured}", gone_a, gone_b).as(Int64),
         db.scalar("SELECT COUNT(*) FROM #{table} WHERE #{col} = ?#{captured}", kept).as(Int64)}
      end
      counts.should eq(refs.map { |(table, col)| {table, col, 0_i64, 1_i64} })
      db.scalar("SELECT COUNT(*) FROM ws_messages WHERE repeater_id = 7").as(Int64).should eq(1)
      db.query_all("SELECT source_id FROM issue_evidence ORDER BY id", as: Int64)
        .should eq([-gone_a, -gone_b, kept]) # negated exactly once despite the repeated id
      db.query_all("SELECT ref_id FROM entity_links WHERE ref_kind = 'flow'", as: Int64).should eq([kept])
      db.query_all("SELECT id FROM flows", as: Int64).should eq([kept])
    end
  end

  it "reclaims an h2 connection's frames only once no surviving flow still uses it, keeping its row" do
    raw_detach_store do |store, db|
      shared_a = ref_flow(store, "/shared-a")
      shared_b = ref_flow(store, "/shared-b")
      solo = ref_flow(store, "/solo")
      store.flush
      db.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) " \
              "VALUES (1, 0, 'h', 443, 'h2'), (2, 0, 'h', 443, 'h2')")
      db.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
              "VALUES (1, 0, 'c2s', 1, 0, 0, 0, X''), (2, 0, 'c2s', 1, 0, 0, 0, X'')")
      db.exec("UPDATE flows SET h2_conn_id = 1 WHERE id IN (?, ?)", shared_a, shared_b)
      db.exec("UPDATE flows SET h2_conn_id = 2 WHERE id = ?", solo)

      store.delete_flows([shared_a, solo]).should be_true
      store.flush
      db.query_all("SELECT conn_id FROM h2_frames", as: Int64).should eq([1_i64])

      store.delete_flow(shared_b).should be_true
      store.flush
      db.scalar("SELECT COUNT(*) FROM h2_frames").as(Int64).should eq(0)
      # The rows stay for the retention sweep's activity-gated reap: the connection may still be
      # open, and a dropped INTEGER PRIMARY KEY id is handed to the next connection, which would
      # then inherit every frame the live one logs afterwards.
      db.query_all("SELECT id FROM h2_connections ORDER BY id", as: Int64).should eq([1_i64, 2_i64])
    end
  end
end
