require "../spec_helper"

# Schema V34 adds `fuzz_runs.stop_idx` — the result a saved run's `stop_on` tripped on (#1270).
#
# The one thing the migration can get wrong is inventing a value. A `condition_met` run saved
# before this column genuinely does not know its stop row: the per-row `stop_hit` flag was never
# stored, an `after_matches` stop trips on a row that flag would not mark, and concurrency lets
# later in-flight rows meet the condition too. NULL — "not recorded" — is the honest answer.

private def build_v33_fuzz_db(path : String) : DB::Database
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema::MIGRATIONS[0...33].each do |statements|
    statements.each { |sql| db.exec(sql) }
  end
  db.exec("PRAGMA user_version = 33")
  db
end

describe "fuzz stop row schema V34" do
  it "migrates a V33 project, leaving an old condition_met run's stop row NULL rather than guessing" do
    path = File.tempname("gori-fuzz-v34", ".db")
    db = build_v33_fuzz_db(path)
    legacy = begin
      db.exec("INSERT INTO fuzz_runs (created_at, target, mode, sent, matched, status, surface, " \
              "snapshot_version) VALUES (1, 'http://legacy', 'sniper', 3, 1, 'condition_met', 'cli', 1)")
      run = db.scalar("SELECT last_insert_rowid()").as(Int64)
      # A matched row sits right there — and it still must not be promoted to the stop row.
      db.exec("INSERT INTO fuzz_results (run_id, idx, payloads, matched) VALUES (?, 2, '[\"x\"]', 1)", run)
      run
    ensure
      db.close
    end

    store = Gori::Store.open(path)
    begin
      store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
      rec = store.get_fuzz_run(legacy).not_nil!
      rec.status.should eq("condition_met")
      rec.stop_idx.should be_nil
      store.fuzz_result_count(legacy).should eq(1_i64) # byte-preserving, like every ALTER here

      # A run finished after the upgrade records it.
      run = store.insert_fuzz_run(nil, "http://new", "sniper", 2_i64)
      store.insert_fuzz_results(run, [Gori::Store::FuzzResultWrite.new(1_i64, %(["y"]), nil, 200,
        1_i64, 1, 1, 1_i64, nil, false, false, nil)]).should be_true
      store.finish_fuzz_run(run, 2_i64, 0_i64, 0_i64, "condition_met", stop_idx: 1_i64).should be_true
      store.get_fuzz_run(run).not_nil!.stop_idx.should eq(1_i64)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
