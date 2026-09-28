require "../spec_helper"

# V41 makes a Sequencer session id impossible to issue twice. Each example builds the PRE-V41
# shape by replaying V1..V40 exactly as a released gori did, plants sessions with a deleted top id
# and the references a project can still hold to one, and drives the real upgrade through
# `Store.open`, on both paths: the in-place edit, and the verified rebuild.

private V40 = 40

private def build_pre_v41(& : DB::Connection ->) : String
  path = File.tempname("gori-v41-sequencer", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...V40].each { |statements| statements.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = #{V40}")
      yield c
    end
  end
  path
end

# Make the stored CREATE text one the in-place edit was not written for (two spaces in the rowid
# clause), so V41 has to rebuild it. DEFENSIVE is lifted the way the edit lifts it.
private def force_rebuild(c : DB::Connection) : Nil
  c.as(SQLite3::Connection).gori_swap_defensive(false)
  cookie = c.scalar("PRAGMA schema_version").as(Int64)
  c.exec("PRAGMA writable_schema = ON")
  c.exec("UPDATE sqlite_master SET sql = replace(sql, 'INTEGER PRIMARY KEY', 'INTEGER  PRIMARY KEY') " \
         "WHERE type = 'table' AND name = 'sequencer_sessions'")
  c.exec("PRAGMA schema_version = #{cookie + 1}")
  c.exec("PRAGMA writable_schema = OFF")
end

private def cleanup(path : String) : Nil
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

private def open_and(path : String, &)
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
  end
end

# Sessions 1..6 existed; 2, 5 and the top id 6 were deleted, so a pre-V41 insert got 5 again.
private def plant_sessions(c : DB::Connection) : Nil
  (1_i64..6_i64).each do |id|
    c.exec("INSERT INTO sequencer_sessions (id, created_at, updated_at, target, request, config, flow_id, position, name) " \
           "VALUES (?1, ?1, ?1, 'https://v41.test', X'474554202f' || randomblob(?1), '{\"n\":' || ?1 || '}', ?1, ?1, 'tab ' || ?1)", id)
  end
  c.exec("DELETE FROM sequencer_sessions WHERE id IN (2, 5, 6)")
end

private def rows(c : DB::Connection) : Array(String)
  c.query_all("SELECT quote(id) || quote(created_at) || quote(updated_at) || quote(target) || quote(request) || " \
              "quote(http2) || quote(sni) || quote(config) || quote(flow_id) || quote(position) || quote(name) " \
              "FROM sequencer_sessions ORDER BY id", as: String)
end

private def create_sql(store : Gori::Store) : String
  store.@db.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'sequencer_sessions'").as(String)
end

private def seq_of(store : Gori::Store) : Int64?
  store.@db.query_one?("SELECT seq FROM sqlite_sequence WHERE name = 'sequencer_sessions'", as: Int64)
end

private def new_session(store : Gori::Store) : Int64
  store.insert_sequencer_session("https://v41.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, nil, "", nil, 0)
end

private def goto_event(tab : String, session_id : Int64) : String
  "INSERT INTO events (created_at, source, kind, level, message, goto_tab, goto_session_id) " \
  "VALUES (0, '#{tab}', 'job_done', 'info', 'done', '#{tab}', #{session_id})"
end

describe "Store::Schema V41 (AUTOINCREMENT on sequencer_sessions)" do
  {"in place" => false, "by rebuild" => true}.each do |how, rebuild|
    it "keeps every row and the position index, and never hands a deleted top id out again #{how}" do
      path = build_pre_v41 do |c|
        plant_sessions(c)
        force_rebuild(c) if rebuild
      end
      begin
        before = DB.open("sqlite3:#{path}") { |db| db.using_connection { |c| rows(c) } }
        before.size.should eq(3)
        open_and(path) do |store|
          store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
          store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
          create_sql(store).should match(/INTEGER +PRIMARY KEY AUTOINCREMENT/)
          # Which path ran: a rebuild's RENAME quotes the name in the CREATE text it keeps.
          create_sql(store).starts_with?(%(CREATE TABLE "sequencer_sessions")).should eq(rebuild)
          store.@db.scalar("SELECT sql FROM sqlite_master WHERE name = 'idx_sequencer_sessions_position'").as(String)
            .should eq("CREATE INDEX idx_sequencer_sessions_position ON sequencer_sessions (position, id)")
          seq_of(store).should eq(4_i64)

          # Close the newest tab and open another: before V41 the new one took the closed one's id.
          store.delete_sequencer_session(4_i64).should be_true
          first = new_session(store)
          first.should eq(5_i64)
          store.delete_sequencer_session(first).should be_true
          new_session(store).should eq(6_i64)
        end
        after = DB.open("sqlite3:#{path}") { |db| db.using_connection { |c| rows(c) } }
        after[0, 2].should eq(before[0, 2])
      ensure
        cleanup(path)
      end
    end
  end

  it "seeds past an Activity row that points at a closed session, and only a Sequencer one" do
    path = build_pre_v41 do |c|
      plant_sessions(c)
      c.exec(goto_event("sequencer", 17))
      c.exec(goto_event("fuzzer", 99))
    end
    begin
      open_and(path) do |store|
        seq_of(store).should eq(17_i64)
        new_session(store).should eq(18_i64)
      end
    ensure
      cleanup(path)
    end
  end

  # No rows to copy, so without the seed ids would restart at 1, under the references.
  it "seeds an EMPTY table past a sequencer link" do
    path = build_pre_v41 do |c|
      c.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) " \
             "VALUES ('issue', 1, 'sequencer', 23, 0)")
    end
    begin
      open_and(path) do |store|
        seq_of(store).should eq(23_i64)
        new_session(store).should eq(24_i64)
      end
    ensure
      cleanup(path)
    end
  end

  it "neither aborts on nor seeds past a reference no gori could have issued" do
    path = build_pre_v41 do |c|
      plant_sessions(c)
      c.exec(goto_event("sequencer", 9223372036854775807))
      c.exec("INSERT INTO events (created_at, source, kind, level, message, goto_tab, goto_session_id) " \
             "VALUES (0, 'sequencer', 'job_done', 'info', 'done', 'sequencer', 'x')")
      c.exec(goto_event("sequencer", 11))
    end
    begin
      open_and(path) do |store|
        seq_of(store).should eq(11_i64)
        new_session(store).should eq(12_i64)
      end
    ensure
      cleanup(path)
    end
  end

  it "a fresh store never reuses a session id" do
    with_store do |store|
      store.@db.scalar("SELECT sql FROM sqlite_master WHERE name = 'sequencer_sessions'").as(String)
        .should contain("AUTOINCREMENT")
      a = new_session(store)
      b = new_session(store)
      store.delete_sequencer_session(b).should be_true
      new_session(store).should eq(b + 1)
      store.get_sequencer_session(a).should_not be_nil
    end
  end
end
