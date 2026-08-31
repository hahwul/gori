require "../spec_helper"

private def with_persistence_store(&)
  path = File.tempname("gori-fuzz-persistence", ".db")
  store = Gori::Store.open(path, retention_flows: 0, background_index: false)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
    File.delete?("#{path}.open.lock")
  end
end

private def with_contended_persistence_store(&)
  path = File.tempname("gori-fuzz-persistence-locked", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1000"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil, background_index: false)
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    store.close
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def persistence_result(idx : Int64, request : Bytes? = nil,
                               body : Bytes? = nil) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx, ["p#{idx}"], nil, 200, (body.try(&.size) || 0).to_i64, 1, 1,
    10_i64, nil, false, false, nil, Bytes[0x48, 0x00], body, request)
end

describe Gori::Fuzz::Persistence do
  it "persists and rebuilds a full engine result without normalizing bytes" do
    with_persistence_store do |store|
      meta = Gori::Fuzz::SavedRunMeta.new(nil, "https://example.test", "sniper", 1_i64,
        created_at: 77_i64, http2: true, sni: "edge.example.test", tls_preset: "chrome",
        surface: "cli", source_ref: "fz_1")
      saved = Gori::Fuzz::Persistence.new(store, meta, batch_size: 1)
      result = Gori::Fuzz::Result.new(
        3_i64, [String.new(Bytes[0xff])], 0, 200, 2_i64, 1, 1, 99_i64, nil, true, true, "hit",
        Bytes[0x48, 0x00], Bytes[0xff, 0x00], Bytes[0x47, 0xff], true,
        "transform failed", 7, "denied", true, 2, Bytes[0x47, 0xfe],
        ws_close_code: 1008, ws_frames_in: 5)

      saved.append(result).should be_true
      saved.finish(1_i64, 1_i64, 2_i64, "done", 88_i64).should be_true
      saved.written.should eq(1_i64)

      row = store.get_fuzz_result(saved.run_id, 3_i64).not_nil!
      rebuilt = Gori::Fuzz::Persistence.result(row)
      rebuilt.index.should eq(3_i64)
      rebuilt.payloads.first.to_slice.should eq(Bytes[0xff])
      rebuilt.position.should eq(0)
      rebuilt.request.should eq(Bytes[0x47, 0xff])
      rebuilt.wire.should eq(Bytes[0x47, 0xfe])
      rebuilt.body.should eq(Bytes[0xff, 0x00])
      rebuilt.incomplete?.should be_true
      rebuilt.retried?.should be_true
      rebuilt.timed_out?.should be_true
      rebuilt.resent_count.should eq(2)
      rebuilt.grpc_status.should eq(7)
      rebuilt.ws_close_code.should eq(1008)
    end
  end

  it "uses the fixed row and byte transaction ceilings" do
    Gori::Fuzz::Persistence::BATCH_SIZE.should eq(128)
    Gori::Fuzz::Persistence::BATCH_BYTES.should eq(8_i64 * 1024 * 1024)
    Gori::Fuzz::Persistence::MAX_QUEUED_BATCHES.should eq(4)

    row = Gori::Store::FuzzResultWrite.new(1_i64, %(["é"]), nil, 200, 1_i64, 1, 1,
      1_i64, "err", false, false, "x", Bytes[0xff], Bytes[0x01, 0x02], Bytes.empty,
      chain_error: "chain", grpc_message: "denied", wire: Bytes[0xfe])
    expected = Gori::Fuzz::Persistence::ROW_METADATA_BYTES + row.payloads.bytesize +
               "err".bytesize + "x".bytesize + 1 + 2 + 0 + "chain".bytesize +
               "denied".bytesize + 1
    Gori::Fuzz::Persistence.row_bytes(row).should eq(expected)
  end

  it "writes a row over the byte ceiling alone and keeps following rows" do
    with_persistence_store do |store|
      saved = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://large.test", "sniper", 2_i64),
        batch_bytes: 256_i64)
      oversized = persistence_result(0_i64, Bytes.new(400, 0xff_u8), Bytes[0x00])

      Gori::Fuzz::Persistence.row_bytes(Gori::Fuzz::Persistence.write_row(oversized))
        .should be > 256_i64
      saved.append(oversized).should be_true
      saved.append(persistence_result(1_i64, Bytes[0x47])).should be_true
      saved.finish(2_i64, 0_i64, 0_i64, "done").should be_true
      store.fuzz_results(saved.run_id).map(&.idx).should eq([0_i64, 1_i64])
    end
  end

  it "rejects rather than waiting when all four live batch slots are occupied" do
    with_persistence_store do |store|
      saved = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://busy.test", "sniper", 5_i64),
        batch_size: 1)

      4.times { |i| saved.append(persistence_result(i.to_i64)).should be_true }
      saved.append(persistence_result(4_i64)).should be_false
      saved.error.to_s.should contain("queue saturated")

      # finish drains the accepted prefix before recording the honest incomplete status.
      saved.finish(5_i64, 0_i64, 0_i64, "done").should be_false
      saved.written.should eq(4_i64)
      store.fuzz_result_count(saved.run_id).should eq(4_i64)
      store.get_fuzz_run(saved.run_id).not_nil!.status.should eq("save_failed")
    end
  end

  it "does not wait on a locked SQLite writer from live append" do
    with_contended_persistence_store do |store, peer|
      saved = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://locked.test", "sniper", 1_i64),
        batch_size: 1)
      lock = peer.checkout
      lock.exec("BEGIN IMMEDIATE")
      begin
        started = Time.instant
        saved.append(persistence_result(0_i64)).should be_true
        (Time.instant - started).should be < 50.milliseconds
      ensure
        lock.exec("ROLLBACK")
        lock.release
      end
      saved.finish(1_i64, 0_i64, 0_i64, "done").should be_true
    end
  end

  it "makes flush and finish FIFO barriers and finish idempotent" do
    with_persistence_store do |store|
      saved = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://barrier.test", "sniper", 2_i64))
      saved.append(persistence_result(0_i64)).should be_true
      saved.append(persistence_result(1_i64)).should be_true

      saved.flush.should be_true
      store.fuzz_result_count(saved.run_id).should eq(2_i64)
      saved.finish(2_i64, 0_i64, 0_i64, "done", 123_i64).should be_true
      saved.finish(99_i64, 99_i64, 99_i64, "error", 999_i64).should be_true
      run = store.get_fuzz_run(saved.run_id).not_nil!
      run.sent.should eq(2_i64)
      run.status.should eq("done")
      run.finished_at.should eq(123_i64)
    end
  end

  it "aborts after draining accepted rows and lands save_failed" do
    with_persistence_store do |store|
      saved = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://abort.test", "sniper", 1_i64))
      saved.append(persistence_result(0_i64)).should be_true

      saved.abort(1_i64, 0_i64, 0_i64, 321_i64).should be_true
      store.fuzz_result_count(saved.run_id).should eq(1_i64)
      run = store.get_fuzz_run(saved.run_id).not_nil!
      run.status.should eq("save_failed")
      run.finished_at.should eq(321_i64)
      saved.abort.should be_true
    end
  end

  it "copies a Store record field-for-field through the blocking post-run append" do
    with_persistence_store do |store|
      source = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://source.test", "sniper", 1_i64))
      original = Gori::Fuzz::Result.new(
        7_i64, [String.new(Bytes[0xff])], 2, 206, 3_i64, 2, 1, 55_i64, "partial", true,
        true, "token", Bytes[0x48, 0xff], Bytes[0x00, 0xfe], Bytes[0x47, 0xfd], true,
        "chain", 13, "internal", true, 4, Bytes[0x47, 0xfc],
        ws_close_code: 1002, ws_frames_in: 9)
      source.append(original).should be_true
      source.finish(1_i64, 1_i64, 5_i64, "done").should be_true
      source_record = store.get_fuzz_result(source.run_id, 7_i64).not_nil!

      copy = Gori::Fuzz::Persistence.new(store,
        Gori::Fuzz::SavedRunMeta.new(nil, "http://copy.test", "sniper", 1_i64))
      copy.append(source_record).should be_true
      copy.finish(1_i64, 1_i64, 5_i64, "done").should be_true
      copied = store.get_fuzz_result(copy.run_id, 7_i64).not_nil!

      Gori::Fuzz::Persistence.write_row(copied).should eq(
        Gori::Fuzz::Persistence.write_row(source_record))
    end
  end

  it "answers a terminal waiter if the Store was closed under the worker" do
    path = File.tempname("gori-fuzz-persistence-worker", ".db")
    store = Gori::Store.open(path, retention_flows: 0, background_index: false)
    saved = Gori::Fuzz::Persistence.new(store,
      Gori::Fuzz::SavedRunMeta.new(nil, "http://closed.test", "sniper", 1_i64),
      batch_size: 1)
    saved.append(persistence_result(0_i64)).should be_true
    store.close

    answer = Channel(Bool).new(1)
    spawn { answer.send(saved.finish(1_i64, 0_i64, 0_i64, "done")) }
    receive_within(answer, 5, "persistence terminal failure").should be_false
  ensure
    store.try(&.close)
    if saved_path = path
      File.delete?(saved_path)
      File.delete?("#{saved_path}-wal")
      File.delete?("#{saved_path}-shm")
      File.delete?("#{saved_path}.open.lock")
    end
  end

  it "reports a closed store instead of raising" do
    path = File.tempname("gori-fuzz-persistence-closed", ".db")
    store = Gori::Store.open(path, retention_flows: 0, background_index: false)
    store.close
    saved = Gori::Fuzz::Persistence.new(store,
      Gori::Fuzz::SavedRunMeta.new(nil, "http://example.test", "sniper", 1_i64))
    saved.failed?.should be_true
    saved.run_id.should eq(0_i64)
  ensure
    if saved_path = path
      File.delete?(saved_path)
      File.delete?("#{saved_path}-wal")
      File.delete?("#{saved_path}-shm")
      File.delete?("#{saved_path}.open.lock")
    end
  end
end
