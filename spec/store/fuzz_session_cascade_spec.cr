require "../spec_helper"

# `fuzz_sessions` (1) → `fuzz_runs.session_id` (N) → `fuzz_results.run_id` (N), and
# `fuzz_results` carries the request/response BLOBs. Deleting a session used to remove only the
# session row, so closing a Fuzzer tab stranded every run and every result — unreachable from any
# read (they all filter by session), untouched by the retention sweep (it walks flows/ws/h2), and
# unbounded.
private def fuzz_store(&)
  path = File.tempname("gori-fuzz-cascade", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
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

private def seed_fuzz(store : Gori::Store, target : String, results : Int32 = 3) : {Int64, Int64}
  sid = store.insert_fuzz_session(target, "GET /?q=FUZZ HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
  run = store.insert_fuzz_run(sid, target, "sniper", results.to_i64)
  results.times do |i|
    store.insert_fuzz_result(run, i, %(["p#{i}"]), 200, 1_000_i64, 10, 5, 1_000_i64, nil, false, nil,
      "GET /?q=p#{i} HTTP/1.1\r\n\r\n".to_slice,
      "HTTP/1.1 200 OK\r\n\r\n".to_slice,
      ("BIGRESPONSE" * 500).to_slice)
  end
  store.finish_fuzz_run(run, results.to_i64, 0_i64, 0_i64, "done").should be_true
  store.flush
  {sid, run}
end

private def counts(store : Gori::Store) : {Int64, Int64, Int64}
  {store.@db.scalar("SELECT COUNT(*) FROM fuzz_sessions").as(Int64),
   store.@db.scalar("SELECT COUNT(*) FROM fuzz_runs").as(Int64),
   store.@db.scalar("SELECT COUNT(*) FROM fuzz_results").as(Int64)}
end

describe "deleting a Fuzz session" do
  it "atomically refuses an active child run" do
    fuzz_store do |store|
      sid = store.insert_fuzz_session("http://active.test/", "GET / HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0)
      run = store.insert_fuzz_run(sid, "http://active.test/", "sniper", 1_i64)
      store.insert_fuzz_result(run, 0_i64, %(["x"]), 200, 1_i64, 1, 1, 1_i64,
        nil, false, nil)

      store.delete_fuzz_session(sid).should be_false
      counts(store).should eq({1_i64, 1_i64, 1_i64})

      store.finish_fuzz_run(run, 1_i64, 0_i64, 0_i64, "done").should be_true
      store.delete_fuzz_session(sid).should be_true
      counts(store).should eq({0_i64, 0_i64, 0_i64})
    end
  end

  it "answers false for an unknown session without affecting live rows" do
    fuzz_store do |store|
      seed_fuzz(store, "http://kept.test/", results: 1)
      store.delete_fuzz_session(99_999_i64).should be_false
      counts(store).should eq({1_i64, 1_i64, 1_i64})
    end
  end

  it "takes its runs and results with it" do
    fuzz_store do |store|
      sid, _run = seed_fuzz(store, "http://a.test/")
      counts(store).should eq({1_i64, 1_i64, 3_i64})

      store.delete_fuzz_session(sid).should be_true
      store.flush
      counts(store).should eq({0_i64, 0_i64, 0_i64})
      store.@db.scalar("SELECT COALESCE(SUM(LENGTH(response_body)), 0) FROM fuzz_results")
        .as(Int64).should eq(0_i64)
    end
  end

  it "leaves another session's runs and results alone" do
    fuzz_store do |store|
      doomed, _ = seed_fuzz(store, "http://a.test/")
      kept, kept_run = seed_fuzz(store, "http://b.test/", results: 2)

      store.delete_fuzz_session(doomed).should be_true
      store.flush

      counts(store).should eq({1_i64, 1_i64, 2_i64})
      store.fuzz_sessions.map(&.id).should eq([kept])
      store.fuzz_runs(kept).map(&.id).should eq([kept_run])
      store.fuzz_results(kept_run).size.should eq(2)
    end
  end

  it "reaps rows an older build already stranded" do
    fuzz_store do |store|
      stranded_sid, stranded_run = seed_fuzz(store, "http://old.test/")
      # Exactly what the pre-cascade delete left behind: the session row gone, its runs and
      # results still there. So a project heals on the next tab close instead of needing a compact.
      store.@db.exec("DELETE FROM fuzz_sessions WHERE id = ?", stranded_sid)
      counts(store).should eq({0_i64, 1_i64, 3_i64})

      live, live_run = seed_fuzz(store, "http://new.test/", results: 1)
      store.delete_fuzz_session(live).should be_true
      store.flush

      counts(store).should eq({0_i64, 0_i64, 0_i64})
      store.fuzz_results(stranded_run).size.should eq(0)
      store.fuzz_results(live_run).size.should eq(0)
    end
  end

  it "answers false when the store can no longer be written" do
    fuzz_store do |store|
      sid, _ = seed_fuzz(store, "http://a.test/")
      store.close # every write from here answers false
      # The tab-close paths use this to warn that the saved tab will reappear.
      store.delete_fuzz_session(sid).should be_false
      store.delete_miner_session(1_i64).should be_false
      store.delete_sequencer_session(1_i64).should be_false
    end
  end
end
