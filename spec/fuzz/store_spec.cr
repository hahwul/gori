require "../spec_helper"

private def with_store(&)
  path = File.tempname("gori-fuzz-test", ".db")
  store = Gori::Store.open(path, retention_flows: 0)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def fuzz_write(idx : Int64, request : Bytes? = nil, response_head : Bytes? = nil,
                       response_body : Bytes? = nil, wire : Bytes? = nil,
                       matched : Bool = false) : Gori::Store::FuzzResultWrite
  Gori::Store::FuzzResultWrite.new(idx, %(["p#{idx}"]), nil, 200, idx + 10, 2, 1,
    100_i64, nil, matched, false, nil, request, response_head, response_body, wire: wire)
end

describe "Gori::Store fuzz persistence" do
  it "round-trips a fuzz session" do
    with_store do |store|
      id = store.insert_fuzz_session("http://h", "GET /?x=§1§ HTTP/1.1\r\n\r\n", false, nil,
        %({"mode":"sniper"}), 42_i64, 0, "s1")
      (id > 0).should be_true

      s = store.fuzz_sessions.first
      s.target.should eq("http://h")
      s.template.should contain("§1§")
      s.config.should eq(%({"mode":"sniper"}))
      s.flow_id.should eq(42_i64)
      s.http2?.should be_false
      s.name.should eq("s1")

      store.update_fuzz_session(id, "http://h2", "GET / HTTP/1.1\r\n\r\n", true, "sni.example",
        %({"mode":"clusterbomb"}), "renamed")
      s2 = store.fuzz_sessions.first
      s2.target.should eq("http://h2")
      s2.http2?.should be_true
      s2.sni.should eq("sni.example")
      s2.name.should eq("renamed")

      store.delete_fuzz_session(id)
      store.fuzz_sessions.should be_empty
    end
  end

  it "set_fuzz_session_name sets/clears the custom name without touching the template" do
    with_store do |store|
      id = store.insert_fuzz_session("http://h", "GET /?x=§1§ HTTP/1.1\r\n\r\n", false, nil,
        %({"mode":"sniper"}), nil, 0)
      store.fuzz_sessions.first.name.should be_nil

      store.set_fuzz_session_name(id, "auth fuzz")
      s = store.fuzz_sessions.first
      s.name.should eq("auth fuzz")
      s.template.should contain("§1§") # the rename must not rewrite the template/config
      s.config.should eq(%({"mode":"sniper"}))

      store.set_fuzz_session_name(id, nil) # blank clears the custom name
      store.fuzz_sessions.first.name.should be_nil
    end
  end

  it "round-trips a run + its results, with paging" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://h", "sniper", 3_i64)
      (run > 0).should be_true
      3.times do |i|
        store.insert_fuzz_result(run, i.to_i64, %(["p#{i}"]), 200, 10_i64, 2, 1, 1000_i64,
          nil, i == 1, i == 1 ? "tok" : nil)
      end
      store.finish_fuzz_run(run, 3_i64, 1_i64, 0_i64, "done", 999_i64).should be_true

      r = store.fuzz_runs.first
      r.sent.should eq(3)
      r.matched.should eq(1)
      r.status.should eq("done")
      r.finished_at.should eq(999_i64)
      r.total.should eq(3_i64)
      r.snapshot_version.should eq(1)

      all = store.fuzz_results(run)
      all.map(&.idx).should eq([0_i64, 1, 2])
      all[1].matched?.should be_true
      all[1].extracted.should eq("tok")

      store.fuzz_results(run, limit: 2, offset: 1).map(&.idx).should eq([1_i64, 2])
      store.fuzz_result_counts([run, 99_999_i64]).should eq({run => 3_i64})
    end
  end

  it "selects the latest successfully saved run for one session" do
    with_store do |store|
      first_session = store.insert_fuzz_session("http://one", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      second_session = store.insert_fuzz_session("http://two", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 1)

      older = store.insert_fuzz_run(first_session, "http://one", "sniper", 1_i64,
        status: "done")
      store.insert_fuzz_run(first_session, "http://one", "sniper", 1_i64,
        status: "running")
      store.insert_fuzz_run(first_session, "http://one", "sniper", 1_i64,
        status: "saving")
      store.insert_fuzz_run(first_session, "http://one", "sniper", 1_i64,
        status: "save_failed")
      newest = store.insert_fuzz_run(first_session, "http://one", "race ×5", 5_i64,
        status: "error")
      other = store.insert_fuzz_run(second_session, "http://two", "sniper", 1_i64,
        status: "done")

      selected = store.latest_saved_fuzz_run(first_session).not_nil!
      selected.id.should eq(newest)
      selected.id.should_not eq(older)
      selected.id.should_not eq(other)
      store.latest_saved_fuzz_run(second_session).not_nil!.id.should eq(other)
      store.latest_saved_fuzz_run(99_999_i64).should be_nil
    end
  end

  it "returns no automatic restore candidate when a session has only incomplete saves" do
    with_store do |store|
      session = store.insert_fuzz_session("http://h", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      {"running", "saving", "save_failed"}.each do |status|
        store.insert_fuzz_run(session, "http://h", "sniper", 1_i64, status: status)
      end
      store.latest_saved_fuzz_run(session).should be_nil
    end
  end

  it "captures optional response bytes for kept results" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://h", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, %(["x"]), 500, 4_i64, 1, 1, 50_i64, nil, true, nil,
        request: "GET / HTTP/1.1\r\n\r\n".to_slice,
        response_head: "HTTP/1.1 500\r\n\r\n".to_slice,
        response_body: "boom".to_slice)
      r = store.fuzz_results(run).first
      r.request.should_not be_nil
      String.new(r.response_body.as(Bytes)).should eq("boom")
    end
  end

  it "round-trips the complete current result shape in a checked batch" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "https://h", "clusterbomb", nil,
        created_at: 123_i64, status: "saving", http2: true, sni: "sni.h",
        tls_preset: "chrome", websocket: true, surface: "tui", source_ref: "fz_7")
      request = Bytes[0x47, 0x45, 0x54, 0x20, 0xff, 0x0d, 0x0a]
      wire = Bytes[0x47, 0x45, 0x54, 0x20, 0xfe, 0x0d, 0x0a]
      rows = [Gori::Store::FuzzResultWrite.new(
        9_i64, %(["payload"]), 2, 101, 7_i64, 2, 1, 44_i64, "closed", true,
        true, "token", request, Bytes[0x48, 0x00], Bytes[0xff, 0x00], true,
        "chain failed", 7, "denied", true, 3, wire, 1008, 4)]

      store.insert_fuzz_results(run, rows).should be_true
      store.finish_fuzz_run(run, 1_i64, 1_i64, 3_i64, "stopped", 456_i64).should be_true

      saved = store.get_fuzz_run(run).not_nil!
      saved.created_at.should eq(123_i64)
      saved.finished_at.should eq(456_i64)
      saved.http2?.should be_true
      saved.websocket?.should be_true
      saved.sni.should eq("sni.h")
      saved.tls_preset.should eq("chrome")
      saved.surface.should eq("tui")
      saved.source_ref.should eq("fz_7")
      saved.snapshot_version.should eq(1)

      result = store.get_fuzz_result(run, 9_i64).not_nil!
      result.position.should eq(2)
      result.incomplete?.should be_true
      result.retried?.should be_true
      result.chain_error.should eq("chain failed")
      result.grpc_status.should eq(7)
      result.grpc_message.should eq("denied")
      result.timed_out?.should be_true
      result.resent_count.should eq(3)
      result.ws_close_code.should eq(1008)
      result.ws_frames_in.should eq(4)
      result.request.should eq(request)
      result.wire.should eq(wire)
      result.response_body.should eq(Bytes[0xff, 0x00])
      store.fuzz_result_count(run).should eq(1_i64)
    end
  end

  it "preserves nil, empty, and non-empty values in every nullable BLOB" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://blob", "sniper", 3_i64, status: "saving")
      empty = Bytes.empty
      request = Bytes[0x47, 0x00]
      head = Bytes[0x48, 0xff]
      body = Bytes[0x42, 0x00]
      wire = Bytes[0x57, 0xfe]
      store.insert_fuzz_results(run, [
        fuzz_write(0_i64),
        fuzz_write(1_i64, empty, empty, empty, empty),
        fuzz_write(2_i64, request, head, body, wire),
      ]).should be_true

      store.@db.query_one(
        "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
        "FROM fuzz_results WHERE run_id = ? AND idx = 0", run,
        as: {String, String, String, String}).should eq({"null", "null", "null", "null"})
      store.@db.query_one(
        "SELECT TYPEOF(request), TYPEOF(response_head), TYPEOF(response_body), TYPEOF(wire) " \
        "FROM fuzz_results WHERE run_id = ? AND idx = 1", run,
        as: {String, String, String, String}).should eq({"blob", "blob", "blob", "blob"})

      rows = store.fuzz_results(run)
      {rows[0].request, rows[0].response_head, rows[0].response_body, rows[0].wire}
        .should eq({nil, nil, nil, nil})
      rows[1].request.not_nil!.should be_empty
      rows[1].response_head.not_nil!.should be_empty
      rows[1].response_body.not_nil!.should be_empty
      rows[1].wire.not_nil!.should be_empty
      rows[2].request.should eq(request)
      rows[2].response_head.should eq(head)
      rows[2].response_body.should eq(body)
      rows[2].wire.should eq(wire)
    end
  end

  it "provides scalar-only pages and bounded full/scalar iterators" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://rows", "sniper", 5_i64, status: "saving")
      store.insert_fuzz_results(run, [
        fuzz_write(4_i64, Bytes[4], matched: true),
        fuzz_write(1_i64, Bytes[1]),
        fuzz_write(3_i64, Bytes[3], matched: true),
        fuzz_write(0_i64, Bytes[0]),
        fuzz_write(2_i64, Bytes[2]),
      ]).should be_true
      store.finish_fuzz_run(run, 5_i64, 2_i64, 0_i64, "done").should be_true

      summaries = store.fuzz_result_summaries(run, limit: 2, offset: 1)
      summaries.map(&.idx).should eq([1_i64, 2_i64])
      summaries.each do |row|
        {row.request, row.response_head, row.response_body, row.wire}
          .should eq({nil, nil, nil, nil})
      end
      store.get_fuzz_result(run, 1_i64).not_nil!.request.should eq(Bytes[1])

      full = [] of Gori::Store::FuzzResultRecord
      store.each_fuzz_result(run, batch_size: 2) { |row| full << row }
      full.map(&.idx).should eq([0_i64, 1_i64, 2_i64, 3_i64, 4_i64])
      full.map(&.request).should eq([Bytes[0], Bytes[1], Bytes[2], Bytes[3], Bytes[4]])

      scalar = [] of Gori::Store::FuzzResultRecord
      store.each_fuzz_result_summary(run, batch_size: 1, matched_only: true) { |row| scalar << row }
      scalar.map(&.idx).should eq([3_i64, 4_i64])
      scalar.each { |row| row.request.should be_nil }
      expect_raises(ArgumentError) { store.each_fuzz_result(run, batch_size: 0) { |_| } }
    end
  end

  it "auto-restores only current snapshot versions" do
    with_store do |store|
      session = store.insert_fuzz_session("http://h", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      current = store.insert_fuzz_run(session, "http://h", "sniper", 1_i64, status: "done")
      legacy = store.insert_fuzz_run(session, "http://h", "sniper", 1_i64, status: "done")
      store.@db.exec("UPDATE fuzz_runs SET snapshot_version = 0 WHERE id = ?", legacy)

      store.latest_saved_fuzz_run(session).not_nil!.id.should eq(current)
      store.get_fuzz_run(legacy).not_nil!.snapshot_version.should eq(0)
      store.@db.exec("UPDATE fuzz_runs SET snapshot_version = 0 WHERE id = ?", current)
      store.latest_saved_fuzz_run(session).should be_nil
    end
  end

  it "finishes exactly one active run row" do
    with_store do |store|
      store.finish_fuzz_run(99_999_i64, 1_i64, 0_i64, 0_i64, "done").should be_false
      terminal = store.insert_fuzz_run(nil, "http://done", "sniper", 1_i64, status: "done")
      store.finish_fuzz_run(terminal, 9_i64, 9_i64, 9_i64, "error").should be_false
      store.get_fuzz_run(terminal).not_nil!.sent.should eq(0_i64)

      active = store.insert_fuzz_run(nil, "http://active", "sniper", 1_i64)
      store.finish_fuzz_run(active, 1_i64, 0_i64, 0_i64, "done").should be_true
      store.finish_fuzz_run(active, 2_i64, 0_i64, 0_i64, "error").should be_false
      store.get_fuzz_run(active).not_nil!.sent.should eq(1_i64)
    end
  end

  it "returns a typed atomic run deletion result with the committed row count" do
    with_store do |store|
      run = store.insert_fuzz_run(nil, "http://h", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, %(["x"]), 200, 1_i64, 1, 1, 1_i64, nil, true, nil)
      active = store.delete_fuzz_run_result(run)
      active.status.should eq(Gori::Store::FuzzRunDeleteStatus::Active)
      active.deleted_results.should eq(0_i64)
      active.deleted?.should be_false

      stale = store.insert_fuzz_run(nil, "http://stale", "sniper", 2_i64, status: "saving")
      2.times do |i|
        store.insert_fuzz_result(stale, i.to_i64, %(["x"]), 200, 1_i64, 1, 1, 1_i64,
          nil, true, nil)
      end
      deleted = store.delete_fuzz_run_result(stale, allow_active: true)
      deleted.status.should eq(Gori::Store::FuzzRunDeleteStatus::Deleted)
      deleted.deleted_results.should eq(2_i64)
      deleted.deleted?.should be_true
      store.get_fuzz_run(stale).should be_nil

      store.finish_fuzz_run(run, 1_i64, 1_i64, 0_i64, "done").should be_true
      store.delete_fuzz_run(run).should be_true # retained compatibility wrapper
      store.delete_fuzz_run_result(run).status.should eq(Gori::Store::FuzzRunDeleteStatus::NotFound)
    end
  end
end
