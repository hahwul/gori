require "../spec_helper"

# Builds a database at the PRE-V10 shape by running V1..V9 exactly as a released gori would
# have, plants what an operator's existing project already contains, and returns the path so
# `Store.open` can drive the real V9 -> V10 upgrade over it.
private def build_pre_v10(kind : String, sessions : Array(Int64), orphan_ref : Int64?) : String
  path = File.tempname("gori-v10", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...9].each { |statements| statements.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 9")
      sessions.each do |id|
        if kind == "fuzz"
          c.exec("INSERT INTO fuzz_sessions (id, created_at, updated_at, target, template, config, position) " \
                 "VALUES (?,0,0,'https://kept.test','GET / HTTP/1.1\r\n\r\n','',0)", id)
        else
          c.exec("INSERT INTO miner_sessions (id, created_at, updated_at, target, request, config, position) " \
                 "VALUES (?,0,0,'https://kept.test',?,'',0)", id, "GET / HTTP/1.1\r\n\r\n".to_slice)
        end
      end
      if ref = orphan_ref
        # An issue the operator linked to a session they later closed — exactly the link row
        # the pre-#574 delete path left behind.
        c.exec("INSERT INTO issues (title, severity, host, created_at, updated_at, status) " \
               "VALUES ('finding', 3, 'kept.test', 0, 0, 0)")
        c.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) " \
               "VALUES ('issue', 1, ?, ?, 0)", kind, ref)
      end
    end
  end
  path
end

private def migrate_and_open(path : String, &)
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
  end
end

private def cleanup(path : String)
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

# V10 makes rowid reuse impossible on the two tables an `entity_links` row can name.
#
# Before it, closing the highest-id sub-tab freed that id, the next ^N was handed it back, and
# a link the pre-#574 delete path had stranded silently re-bound — `stale: false` — to a
# session against a DIFFERENT target, so an issue's evidence named traffic nobody attached.
# #574 stopped NEW strays being created; this is the half that reaches databases already
# carrying them, and it does so WITHOUT deleting the operator's link: seeding `sqlite_sequence`
# past every referenced id leaves the stray resolving to nothing, which `Links` already renders
# as `(gone)` with `stale: true`.
describe "Store::Schema V10" do
  it "upgrades a V9 database and stops a reused fuzz id from re-pointing an issue's evidence" do
    # Sessions 1 and 2 live; 3 was closed and its link survived. max(id) is 2, so pre-V10 the
    # next insert was handed exactly 3.
    path = build_pre_v10("fuzz", [1_i64, 2_i64], 3_i64)
    begin
      migrate_and_open(path) do |store|
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)

        # PRESERVED, not swept: deleting it would discard a fact the operator put there.
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, 1_i64)
        links.size.should eq(1)
        links.first.ref_id.should eq(3_i64)

        fresh = store.insert_fuzz_session("https://unrelated.test", "GET /x HTTP/1.1\r\n\r\n",
          false, nil, "{}", nil, 0, "unrelated")
        fresh.should_not eq(3_i64)
        store.get_fuzz_session(3_i64).should be_nil # the stray still resolves to nothing
      end
    ensure
      cleanup(path)
    end
  end

  it "covers the empty-table case that defeats AUTOINCREMENT on its own" do
    # No rows to copy, so the rebuild creates no sqlite_sequence row and ids would restart at
    # 1 — straight onto the stray. The explicit seed is the only thing that closes this.
    path = build_pre_v10("fuzz", [] of Int64, 1_i64)
    begin
      migrate_and_open(path) do |store|
        fresh = store.insert_fuzz_session("https://unrelated.test", "GET /x HTTP/1.1\r\n\r\n",
          false, nil, "{}", nil, 0, "unrelated")
        fresh.should_not eq(1_i64)
        store.list_links(Gori::Store::LinkOwnerKind::Issue, 1_i64).size.should eq(1)
      end
    ensure
      cleanup(path)
    end
  end

  it "does the same for miner sessions" do
    path = build_pre_v10("miner", [1_i64, 2_i64], 3_i64)
    begin
      migrate_and_open(path) do |store|
        fresh = store.insert_miner_session("https://unrelated.test", "GET /x HTTP/1.1\r\n\r\n".to_slice,
          false, nil, "{}", nil, 0, "unrelated")
        fresh.should_not eq(3_i64)
        store.get_miner_session(3_i64).should be_nil
      end
    ensure
      cleanup(path)
    end
  end

  it "preserves existing rows, their ids and their data through the rebuild" do
    path = build_pre_v10("fuzz", [1_i64, 2_i64], nil)
    begin
      migrate_and_open(path) do |store|
        kept = store.get_fuzz_session(2_i64)
        kept.should_not be_nil
        kept.not_nil!.target.should eq("https://kept.test")
        # Ids are dense and unchanged, so the sequence simply continues.
        store.insert_fuzz_session("https://next.test", "GET / HTTP/1.1\r\n\r\n",
          false, nil, "{}", nil, 0, "next").should eq(3_i64)
      end
    ensure
      cleanup(path)
    end
  end

  it "leaves a fresh database consistent and at the current version" do
    path = File.tempname("gori-v10-fresh", ".db")
    begin
      migrate_and_open(path) do |store|
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
        # V1 creates these with a plain PK and V10 rebuilds them in the same transaction, so
        # even a brand-new database lands on the AUTOINCREMENT definition.
        %w[fuzz_sessions miner_sessions].each do |t|
          store.@db.scalar("SELECT sql FROM sqlite_master WHERE name = ?", t).as(String)
            .should contain("AUTOINCREMENT")
        end
        # The position index survived the rebuild.
        store.@db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' " \
                         "AND name='idx_fuzz_sessions_position'").as(Int64).should eq(1_i64)
      end
    ensure
      cleanup(path)
    end
  end
end
