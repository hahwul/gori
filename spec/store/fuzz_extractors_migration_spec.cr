require "../spec_helper"

# Schema V48 adds `fuzz_runs.extractors` and `fuzz_results.extracts` (#1592). An older run has
# neither, and reads back with its `extracted` as extractor 0 under that label.

private def build_v47_fuzz_db(path : String) : DB::Database
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema::MIGRATIONS[0...47].each do |statements|
    statements.each { |sql| db.exec(sql) }
  end
  db.exec("PRAGMA user_version = 47")
  db
end

private def drop_db(path : String) : Nil
  {"", "-wal", "-shm", ".open.lock"}.each { |ext| File.delete?("#{path}#{ext}") }
end

describe "fuzz extractors schema V48" do
  it "migrates a V47 project, reading an old run's `extracted` as extractor 0" do
    path = File.tempname("gori-fuzz-v48", ".db")
    db = build_v47_fuzz_db(path)
    legacy = begin
      db.exec("INSERT INTO fuzz_runs (created_at, target, mode, sent, matched, status, surface, " \
              "snapshot_version) VALUES (1, 'http://legacy', 'sniper', 1, 1, 'done', 'cli', 1)")
      run = db.scalar("SELECT last_insert_rowid()").as(Int64)
      db.exec(%(INSERT INTO fuzz_results (run_id, idx, payloads, matched, extracted) VALUES (?, 0, '["x"]', 1, 'tok')), run)
      run
    ensure
      db.close
    end

    store = Gori::Store.open(path)
    begin
      rec = store.get_fuzz_run(legacy).not_nil!
      rec.extractors.should be_nil
      row = store.get_fuzz_result(legacy, 0_i64).not_nil!
      r = Gori::Fuzz::Persistence.result(row, Gori::Fuzz::Extractor.of_run(rec.extractors))
      r.extracts.should eq(["tok"])
      r.extract_pairs.map { |(e, v)| {e.label, v} }.should eq([{"extracted", "tok"}])
      # A row with no value carries no labels, so no surface draws an empty `extracted` column.
      bare = Gori::Store::FuzzResultRecord.new(2_i64, legacy, 1_i64, %(["y"]), 200, 1_i64, 1, 1, 1_i64, nil, false, nil)
      Gori::Fuzz::Persistence.result(bare, Gori::Fuzz::Extractor.of_run(nil)).extractors.should be_nil
    ensure
      store.close
      drop_db(path)
    end
  end

  it "is replay-safe on a project that already has the columns" do
    path = File.tempname("gori-fuzz-v48-replay", ".db")
    Gori::Store.open(path).close
    DB.open("sqlite3:#{path}") { |db| db.exec("PRAGMA user_version = 47") }
    store = Gori::Store.open(path)
    begin
      store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
    ensure
      store.close
      drop_db(path)
    end
  end

  it "round-trips a run's extractors and every row's values, in order" do
    with_store do |store|
      list = Gori::Fuzz::Extractor.parse(["RID=header:x-request-id", "jsonpath:data.id", "regex:c=(\\d+)"]).as(Array(Gori::Fuzz::Extractor))
      p = Gori::Fuzz::Persistence.new(store, Gori::Fuzz::SavedRunMeta.new(nil, "http://t", "sniper", 1_i64,
        extractors: Gori::Fuzz::Extractor.to_json(list)))
      res = Gori::Fuzz::Result.new(0_i64, ["p"], 0, 200, 1_i64, 1, 1, 1_i64, nil, true, false, "r-1",
        extracts: ["r-1", nil, "9"], extractors: list)
      p.append(res).should be_true
      p.finish(1_i64, 1_i64, 0_i64, "done").should be_true

      rec = store.get_fuzz_run(p.run_id).not_nil!
      back = Gori::Fuzz::Extractor.of_run(rec.extractors)
      back.should eq(list)
      row = Gori::Fuzz::Persistence.result(store.get_fuzz_result(p.run_id, 0_i64).not_nil!, back)
      row.extracted.should eq("r-1")
      row.extracts.should eq(["r-1", nil, "9"])
      row.extract_pairs.map(&.[0].label).should eq(["RID", "data.id", "c=(\\d+)"])
    end
  end
end
