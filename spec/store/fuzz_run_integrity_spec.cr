require "../spec_helper"

private def with_two_fuzz_stores(&)
  path = File.tempname("gori-fuzz-integrity", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=5000"
  first_db = DB.open(url)
  Gori::Store::Schema.migrate!(first_db)
  second_db = DB.open(url)
  first = Gori::Store.new(first_db, nil, background_index: false)
  second = Gori::Store.new(second_db, nil, background_index: false)
  begin
    yield first, second
  ensure
    first.close
    second.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def integrity_row(idx : Int64 = 0_i64) : Gori::Store::FuzzResultWrite
  Gori::Store::FuzzResultWrite.new(idx, %(["x"]), nil, 200, 1_i64, 1, 1, 1_i64,
    nil, false, false, nil)
end

describe "Gori::Store fuzz parent/status transactions" do
  it "refuses an unknown or concurrently deleted session parent" do
    with_two_fuzz_stores do |first, second|
      first.insert_fuzz_run(99_999_i64, "http://missing", "sniper", 1_i64).should eq(0_i64)

      session = first.insert_fuzz_session("http://gone", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      second.delete_fuzz_session(session).should be_true
      first.insert_fuzz_run(session, "http://gone", "sniper", 1_i64).should eq(0_i64)
      first.fuzz_run_count.should eq(0_i64)
    end
  end

  it "refuses result batches after another Store finishes or deletes the run" do
    with_two_fuzz_stores do |first, second|
      first.insert_fuzz_results(99_999_i64, [integrity_row]).should be_false
      first.insert_fuzz_results(99_999_i64, [] of Gori::Store::FuzzResultWrite).should be_false
      first.insert_fuzz_result(99_999_i64, 0_i64, "[]", 200, 1_i64, 1, 1, 1_i64,
        nil, false, nil).should eq(0_i64)

      run = first.insert_fuzz_run(nil, "http://finished", "sniper", 1_i64)
      second.finish_fuzz_run(run, 0_i64, 0_i64, 0_i64, "done").should be_true
      first.insert_fuzz_results(run, [integrity_row]).should be_false
      first.fuzz_result_count(run).should eq(0_i64)

      doomed = first.insert_fuzz_run(nil, "http://deleted", "sniper", 1_i64)
      second.delete_fuzz_run(doomed, allow_active: true).should be_true
      first.insert_fuzz_results(doomed, [integrity_row]).should be_false
      first.fuzz_result_count(doomed).should eq(0_i64)
    end
  end

  it "refuses session deletion until the active child commits terminal status" do
    with_two_fuzz_stores do |first, second|
      session = first.insert_fuzz_session("http://active", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      run = first.insert_fuzz_run(session, "http://active", "sniper", 1_i64)
      first.insert_fuzz_results(run, [integrity_row]).should be_true

      second.delete_fuzz_session(session).should be_false
      first.get_fuzz_session(session).should_not be_nil
      first.get_fuzz_run(run).should_not be_nil
      first.fuzz_result_count(run).should eq(1_i64)

      second.finish_fuzz_run(run, 1_i64, 0_i64, 0_i64, "done").should be_true
      second.delete_fuzz_session(session).should be_true
      first.get_fuzz_session(session).should be_nil
      first.get_fuzz_run(run).should be_nil
      first.fuzz_result_count(run).should eq(0_i64)
    end
  end
end
