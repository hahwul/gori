require "../spec_helper"

private def with_spool_root(&)
  base = File.tempname("gori-fuzz-spool-spec")
  root = File.join(base, "spool")
  Dir.mkdir_p(base)
  begin
    yield root
  ensure
    FileUtils.rm_rf(base)
  end
end

private def spool_result(idx : Int64, request : Bytes) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx, [String.new(Bytes[0xff, idx.to_u8])], idx.to_i32, 201,
    2_i64, 1, 1, 42_i64, nil, idx.even?, true, "hit",
    Bytes[0x48, 0x00], Bytes[0xfe, idx.to_u8], request, true,
    "chain", 7, "denied", true, 2, Bytes[0x47, 0xfd, idx.to_u8],
    ws_close_code: 1008, ws_frames_in: 3)
end

describe Gori::Fuzz::Spool do
  it "reaps only old unlocked crash leftovers" do
    with_spool_root do |root|
      Gori::Paths.ensure_dir(root)
      stale = File.join(root, "#{Gori::Fuzz::Spool::DIR_PREFIX}stale")
      fresh = File.join(root, "#{Gori::Fuzz::Spool::DIR_PREFIX}fresh")
      Dir.mkdir(stale, Gori::Paths::DIR_MODE)
      Dir.mkdir(fresh, Gori::Paths::DIR_MODE)
      File.write(File.join(stale, Gori::Fuzz::Spool::DB_NAME), "")
      File.write(File.join(fresh, Gori::Fuzz::Spool::DB_NAME), "")
      old = Time.utc - 2.days
      File.utime(old, old, stale)

      spool = Gori::Fuzz::Spool.new(root)
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://cleanup.test", "sniper", 0_i64))
      run.finish(0_i64, 0_i64, 0_i64, "done").should be_true
      Dir.exists?(stale).should be_false
      Dir.exists?(fresh).should be_true
      spool.close
    end
  end

  it "refuses rows past the run's byte budget and reports the reason once" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      # A budget one row wide: the first append fits, the second is what the ceiling exists
      # to stop. The pane and the queue were already bounded; the DISK was not, and with
      # `keep_bodies: :all` a cluster bomb writes every response body it gets.
      first = spool_result(1_i64, Bytes[0x47, 0xff])
      budget = Gori::Fuzz::Persistence.row_bytes(Gori::Fuzz::Persistence.write_row(first))
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://budget.test", "sniper", 2_i64), byte_budget: budget)

      run.append(first).should be_true
      run.append(spool_result(2_i64, Bytes[0x47, 0xfe])).should be_false
      run.failed?.should be_true
      run.error.not_nil!.should contain("budget exhausted")
      # Refused, not silently dropped: the run can never claim to be a complete archive.
      run.append(spool_result(3_i64, Bytes[0x47, 0xfd])).should be_false
      run.accepted_rows.should eq(1)
      spool.close
    end
  end

  it "closes without waiting out a writer that is still inside the database" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://teardown.test", "sniper", 1_i64))
      run.append(spool_result(1_i64, Bytes[0x47, 0xff])).should be_true
      # Never finished — close has to abort the stream itself rather than block on a terminal
      # that is never coming. On the Runner fiber this is a repaint that does not happen.
      directory = spool.directory.not_nil!
      elapsed = Time.measure { spool.close }
      elapsed.should be < Gori::Fuzz::Spool::CLEANUP_DEADLINE
      Dir.exists?(directory).should be_false
    end
  end

  it "opens one private Store lazily and isolates multiple run handles by run id" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      spool.directory.should be_nil
      Dir.exists?(root).should be_false

      first = spool.start(Gori::Fuzz::SavedRunMeta.new(99_i64,
        "https://one.test", "sniper", 1_i64, surface: "tui", source_ref: "first"))
      directory = spool.directory.not_nil!
      second = spool.start(Gori::Fuzz::SavedRunMeta.new(100_i64,
        "https://two.test", "pitchfork", 1_i64, surface: "tui", source_ref: "second"))

      second.run_id.should_not eq(first.run_id)
      spool.directory.should eq(directory)
      Dir.children(root).should eq([File.basename(directory)])
      first.append(spool_result(1_i64, Bytes[0x47, 0xff])).should be_true
      second.append(spool_result(2_i64, Bytes[0x50, 0xfe])).should be_true
      first.finish(1_i64, 0_i64, 0_i64, "done").should be_true
      second.finish(1_i64, 1_i64, 0_i64, "done").should be_true

      first_rows = [] of Gori::Store::FuzzResultRecord
      second_rows = [] of Gori::Store::FuzzResultRecord
      first.each_result { |row| first_rows << row }
      second.each_result { |row| second_rows << row }
      first_rows.map(&.idx).should eq([1_i64])
      second_rows.map(&.idx).should eq([2_i64])
      first_rows.first.run_id.should eq(first.run_id)
      second_rows.first.run_id.should eq(second.run_id)

      # The temporary database has no fuzz_sessions parent; injected session ids are stripped.
      inspect_db = DB.open("sqlite3:#{File.join(directory, Gori::Fuzz::Spool::DB_NAME)}")
      begin
        inspect_db.query_one("SELECT session_id FROM fuzz_runs WHERE id = ?", first.run_id,
          as: Int64?).should be_nil
        inspect_db.query_one("SELECT session_id FROM fuzz_runs WHERE id = ?", second.run_id,
          as: Int64?).should be_nil
      ensure
        inspect_db.close
      end

      spool.close
    end
  end

  it "streams every stored field without normalizing malformed bytes" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://bytes.test", "sniper", 1_i64))
      original = spool_result(3_i64, Bytes[0x47, 0xff, 0x00])
      run.append(original).should be_true
      run.finish(1_i64, 0_i64, 0_i64, "done").should be_true

      rows = [] of Gori::Store::FuzzResultRecord
      run.each_result(batch_size: 1) { |row| rows << row }
      rows.size.should eq(1)
      rebuilt = Gori::Fuzz::Persistence.result(rows.first)
      rebuilt.payloads.first.to_slice.should eq(Bytes[0xff, 0x03])
      rebuilt.request.should eq(Bytes[0x47, 0xff, 0x00])
      rebuilt.head.should eq(Bytes[0x48, 0x00])
      rebuilt.body.should eq(Bytes[0xfe, 0x03])
      rebuilt.wire.should eq(Bytes[0x47, 0xfd, 0x03])
      rebuilt.chain_error.should eq("chain")
      rebuilt.grpc_message.should eq("denied")
      rebuilt.ws_close_code.should eq(1008)
      spool.close
    end
  end

  it "creates a 0700 directory and lets Store enforce private database modes" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://mode.test", "sniper", 0_i64))
      run.finish(0_i64, 0_i64, 0_i64, "done").should be_true
      directory = spool.directory.not_nil!
      db_path = File.join(directory, Gori::Fuzz::Spool::DB_NAME)

      (File.info(directory).permissions.value & 0o777).should eq(0o700)
      (File.info(db_path).permissions.value & 0o777).should eq(0o600)
      spool.close
    end
  end

  it "deletes a replaced run without closing the controller-wide spool" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      first = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://first.test", "sniper", 1_i64))
      first.append(spool_result(0_i64, Bytes[0x47])).should be_true
      first.finish(1_i64, 0_i64, 0_i64, "done").should be_true
      first.accepted_rows.should eq(1_i64)
      first.accepted_bytes.should be > 0_i64

      spool.delete(first).should be_true
      second = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://second.test", "sniper", 0_i64))
      second.finish(0_i64, 0_i64, 0_i64, "done").should be_true
      second.each_result { |_| fail "second run should be empty" }
      spool.close
    end
  end

  it "interleaves bounded cleanup with another live spool run" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      first = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://large.test", "sniper", 260_i64))
      260.times do |i|
        first.append(spool_result((i % 256).to_i64, Bytes.new(256, (i % 256).to_u8))).should be_true
        Fiber.yield
      end
      first.finish(260_i64, 0_i64, 0_i64, "done").should be_true
      spool.delete(first).should be_true

      second = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://live.test", "sniper", 32_i64))
      32.times do |i|
        second.append(spool_result(i.to_i64, Bytes[0x47, i.to_u8])).should be_true
        Fiber.yield
      end
      second.finish(32_i64, 0_i64, 0_i64, "done").should be_true
      second.written.should eq(32_i64)
      second.failed?.should be_false
      spool.close
    end
  end

  it "closes SQLite before removing the whole directory and is idempotent" do
    with_spool_root do |root|
      spool = Gori::Fuzz::Spool.new(root)
      run = spool.start(Gori::Fuzz::SavedRunMeta.new(nil,
        "https://cleanup.test", "sniper", 1_i64))
      run.append(spool_result(0_i64, Bytes[0x47])).should be_true
      directory = spool.directory.not_nil!
      Dir.exists?(directory).should be_true

      # Closing an unfinished run aborts/drains its accepted prefix before deleting the DB.
      spool.close
      Dir.exists?(directory).should be_false
      spool.directory.should be_nil
      spool.close
      expect_raises(Gori::Error, "fuzz spool is closed") do
        spool.start(Gori::Fuzz::SavedRunMeta.new(nil, "https://late.test", "sniper", 0_i64))
      end
    end
  end
end
