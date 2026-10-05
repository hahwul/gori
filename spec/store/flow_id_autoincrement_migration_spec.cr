# ponytail: on Windows these legacy-schema (pre-V39/V40) migrations hang when run after
# each other in one process, while any one alone passes in seconds. Off Windows until that
# is understood (#1510 follow-up); every POSIX job still runs them.
{% skip_file if flag?(:win32) %}

require "../spec_helper"

# V39 makes a flow id, and an h2 connection id, impossible to issue twice. Every example builds
# the PRE-V39 shape by replaying V1..V38 exactly as a released gori did, plants what an operator's
# project can already hold — gaps in the id space, FTS rows, references that outlived their flow —
# and drives the real upgrade through `Store.open`.

private V38 = 38

# `flows` columns, in table order, as V38 left them. The order is a performance property (every
# column after the body BLOBs is an overflow-chain walk), so V39 must not move one.
private FLOW_COLUMNS = %w[id created_at scheme host port method target http_version sni alpn tls_version
  request_head request_body response_head response_body status reason content_type request_size
  response_size state ttfb_us duration_us error h2_conn_id h2_stream_id request_body_truncated
  response_body_truncated unsent fts_dirty short_circuited advisory request_content_type
  connect_protocol source source_surface source_ref static_asset]

private FLOW_INDEXES = %w[idx_flows_created_at idx_flows_fts_dirty idx_flows_h2_conn idx_flows_list
  idx_flows_pending idx_flows_sitemap idx_flows_sitemap_nonstatic idx_flows_sizes idx_flows_status]

private def build_pre_v39(& : DB::Connection ->) : String
  path = File.tempname("gori-v39", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...V38].each { |statements| statements.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = #{V38}")
      yield c
    end
  end
  path
end

# A flow at an EXPLICIT id, so a fixture can leave gaps, with its response body in the FTS index
# the way the off-commit indexer leaves a finished row.
private def plant_flow(c : DB::Connection, id : Int64, target : String, body : String, h2_conn : Int64? = nil) : Nil
  c.exec("INSERT INTO flows (id, created_at, scheme, host, port, method, target, http_version, " \
         "request_head, response_head, response_body, status, state, h2_conn_id) " \
         "VALUES (?, ?, 'https', 'v39.test', 443, 'GET', ?, 'HTTP/1.1', ?, ?, ?, 200, 2, ?)",
    id, id * 1000, target, "GET #{target} HTTP/1.1\r\nHost: v39.test\r\n\r\n".to_slice,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice, h2_conn)
  c.exec("INSERT INTO flows_fts (rowid, req, resp) VALUES (?, '', ?)", id, body)
end

# The fixture most examples share: live flows 1, 5 and 9 (gaps), h2 connections 1..3, and a
# reference to a flow id ABOVE every live one in each kind of column that can hold one.
private def plant_project(c : DB::Connection) : Nil
  c.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (1,0,'v39.test',443,'h2'), " \
         "(2,0,'v39.test',443,'h2'), (3,0,'v39.test',443,'h2')")
  plant_flow(c, 1_i64, "/one", "alpha-body-one", 1_i64)
  plant_flow(c, 5_i64, "/five", "bravo-body-five")
  plant_flow(c, 9_i64, "/nine", "charlie-body-nine", 3_i64)
  # A frame log for a connection whose row is already gone, above every live connection id.
  c.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
         "VALUES (12, 0, 'out', 1, 0, 0, 0, X'')")
  c.exec("INSERT INTO issues (title, severity, host, created_at, updated_at, status) VALUES ('f', 3, 'v39.test', 0, 0, 0)")
  c.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', 1, 'flow', 40, 0)")
  c.exec("INSERT INTO probe_issues (code, category, host, title, severity, sample_flow_id, first_seen, last_seen) " \
         "VALUES ('x', 'x', 'v39.test', 't', 1, 30, 0, 0)")
  # A frozen copy whose source flow was deleted: its id is kept NEGATED, and it is the highest.
  c.exec("INSERT INTO issue_evidence (created_at, source_kind, source_id, method, url, request_head, " \
         "request_sha256, bytes) VALUES (0, 'flow', -60, 'GET', 'https://v39.test/', X'', '', 0)")
end

private def open_and(path : String, read_only : Bool = false, &)
  store = Gori::Store.open(path, read_only: read_only)
  begin
    yield store
  ensure
    store.close
  end
end

private def cleanup(path : String) : Nil
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

private def seq_of(store : Gori::Store, table : String) : Int64?
  store.@db.query_one?("SELECT seq FROM sqlite_sequence WHERE name = ?", table, as: Int64)
end

private def create_sql(store : Gori::Store, table : String) : String
  store.@db.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table).as(String)
end

private def request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: Time.utc.to_unix_ms * 1000_i64, scheme: "https", host: "v39.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: v39.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy)
end

# Make the stored CREATE text one the in-place edit was not written for (two spaces inside the
# rowid clause), so `migrate!` has to take the rebuild. Same statement shape the edit itself uses,
# DEFENSIVE lifted the same way (macOS's system SQLite has it on).
private def force_rebuild(c : DB::Connection) : Nil
  edit_flows_create(c, "INTEGER PRIMARY KEY", "INTEGER  PRIMARY KEY")
end

private def edit_flows_create(c : DB::Connection, from : String, to : String) : Nil
  c.as(SQLite3::Connection).gori_swap_defensive(false)
  cookie = c.scalar("PRAGMA schema_version").as(Int64)
  c.exec("PRAGMA writable_schema = ON")
  c.exec("UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE type = 'table' AND name = 'flows'", from, to)
  c.exec("PRAGMA schema_version = #{cookie + 1}")
  c.exec("PRAGMA writable_schema = OFF")
end

describe "Store::Schema V39" do
  {"in place" => false, "by rebuild" => true}.each do |how, rebuild|
    describe "upgrading a V38 project #{how}" do
      it "keeps every id, row, column position, index and FTS hit" do
        path = build_pre_v39 do |c|
          plant_project(c)
          force_rebuild(c) if rebuild
        end
        begin
          open_and(path) do |store|
            store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
            store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
            %w[flows h2_connections].each { |t| create_sql(store, t).should contain("AUTOINCREMENT") }
            # Which path ran: the edit keeps V1's text with the ADD COLUMNs appended, the rebuild
            # writes a CREATE of its own.
            create_sql(store, "flows").includes?(", unsent INTEGER").should eq(!rebuild)

            store.flow_rows([1_i64, 5_i64, 9_i64]).map { |r| {r.id, r.target} }.sort!
              .should eq([{1_i64, "/one"}, {5_i64, "/five"}, {9_i64, "/nine"}])
            store.get_flow(9_i64).not_nil!.h2_conn_id.should eq(3_i64)
            columns = [] of String
            store.@db.query("PRAGMA table_info(flows)") { |rs| rs.each { rs.read(Int64); columns << rs.read(String); 4.times { rs.read } } }
            columns.should eq(FLOW_COLUMNS)
            indexes = [] of String
            store.@db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'flows' ORDER BY name") do |rs|
              rs.each { indexes << rs.read(String) }
            end
            indexes.should eq(FLOW_INDEXES)

            # The contentless index is keyed by `flows.id`: a renumbered row would put this hit
            # on another flow.
            store.search(Gori::QL.parse("body:bravo-body"), 10).map(&.id).should eq([5_i64])
            store.search(Gori::QL.parse("body:charlie-body"), 10).map(&.id).should eq([9_i64])
          end
        ensure
          cleanup(path)
        end
      end

      it "seeds the sequences past every id something still references" do
        path = build_pre_v39 do |c|
          plant_project(c)
          force_rebuild(c) if rebuild
        end
        begin
          open_and(path) do |store|
            # MAX(flows.id) is 9; the negated evidence source (-60) is the highest reference.
            seq_of(store, "flows").should eq(60_i64)
            seq_of(store, "h2_connections").should eq(12_i64) # the orphaned frame log's conn_id
            store.insert_flow(request("/next")).should eq(61_i64)
            store.insert_h2_connection("v39.test", 443, "h2").should eq(13_i64)
          end
        ensure
          cleanup(path)
        end
      end
    end
  end

  # No rows to copy or to raise `MAX(id)`, so without the seed ids would restart at 1 — straight
  # under a link that outlived its flow.
  it "starts an EMPTY flows table past a stray reference" do
    path = build_pre_v39 do |c|
      c.exec("INSERT INTO issues (title, severity, host, created_at, updated_at, status) VALUES ('f', 3, 'v39.test', 0, 0, 0)")
      c.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', 1, 'flow', 3, 0)")
      c.exec("INSERT INTO repeaters (created_at, updated_at, target, request, http2, flow_id, position) " \
             "VALUES (0, 0, 'https://v39.test', X'', 0, 7, 0)")
    end
    begin
      open_and(path) do |store|
        store.count.should eq(0)
        fresh = store.insert_flow(request("/first-after-upgrade"))
        fresh.should be > 3_i64
        store.list_links(Gori::Store::LinkOwnerKind::Issue, 1_i64).first.ref_id.should eq(3_i64)
      end
    ensure
      cleanup(path)
    end
  end

  # What a crafted archive can carry in a reference column. Unfiltered, `ABS` of the lowest int64
  # aborted the upgrade (the project would not open), a value at the top of int64 became the
  # sequence (every capture failed with SQLITE_FULL), and one TEXT value won `MAX` over the real
  # references, so the stranded link at 40 was handed a new flow's id again.
  it "seeds past the real references when a crafted one is not an id" do
    path = build_pre_v39 do |c|
      plant_project(c)
      c.exec("INSERT INTO issue_evidence (created_at, source_kind, source_id, method, url, request_head, " \
             "request_sha256, bytes) VALUES (0, 'flow', -9223372036854775808, 'GET', 'https://v39.test/', X'', '', 0)")
      c.exec("INSERT INTO events (created_at, source, kind, level, message, flow_id) " \
             "VALUES (0, 'x', 'x', 'info', 'top', 9223372036854775807), (0, 'x', 'x', 'info', 'text', 'junk'), " \
             "(0, 'x', 'x', 'info', 'real', 1.5e300)")
      c.exec("INSERT INTO h2_frames (conn_id, created_at, direction, stream_id, type, flags, length, payload) " \
             "VALUES ('junk', 0, 'out', 1, 0, 0, 0, X'')")
    end
    begin
      open_and(path) do |store|
        seq_of(store, "flows").should eq(60_i64)
        seq_of(store, "h2_connections").should eq(12_i64)
        store.insert_flow(request("/next")).should eq(61_i64)
      end
    ensure
      cleanup(path)
    end
  end

  it "keeps ids growing through a history clear and a delete of the newest flows" do
    with_store do |store|
      ids = Array.new(3) { |i| store.insert_flow(request("/before-#{i}")) }
      store.delete_flows([ids.last]).should be_true
      after_delete = store.insert_flow(request("/after-delete"))
      after_delete.should be > ids.max

      store.clear_flows.should be_true
      store.count.should eq(0)
      after_clear = store.insert_flow(request("/after-clear"))
      after_clear.should be > after_delete
    end
  end

  # The bound MCP's `since` check reads: the highest id ever issued, not the newest survivor.
  it "reports the highest flow id ever issued, past a delete and a clear" do
    with_store do |store|
      store.flow_id_high_water.should eq(0)
      store.insert_flow(request("/a"))
      top = store.insert_flow(request("/b"))
      store.delete_flow(top).should be_true
      store.flow_id_high_water.should eq(top)
      store.clear_flows.should be_true
      store.flow_id_high_water.should eq(top)
      # Only gori writes an integer there; a crafted archive's TEXT still reads as its number.
      store.@db.exec("UPDATE sqlite_sequence SET seq = '40' WHERE name = 'flows'")
      store.flow_id_high_water.should eq(40)
      # With no sequence row, SQLite itself falls back to the largest rowid, and so does this.
      reissue_rowids(store)
      again = store.insert_flow(request("/c"))
      store.@db.exec("DELETE FROM sqlite_sequence WHERE name = 'flows'")
      store.flow_id_high_water.should eq(again)
    end
  end

  it "never hands out a reaped h2 connection's id again" do
    with_store do |store|
      first = store.insert_h2_connection("v39.test", 443, "h2")
      second = store.insert_h2_connection("v39.test", 443, "h2")
      store.clear_flows.should be_true
      # What the retention sweep's reap does once the connection goes quiet.
      store.@db.exec("DELETE FROM h2_connections")
      store.insert_h2_connection("v39.test", 443, "h2").should be > {first, second}.max
    end
  end

  it "takes the in-place path on a connection with SQLITE_DBCONFIG_DEFENSIVE on, and puts it back" do
    path = build_pre_v39 { |c| plant_project(c) }
    begin
      DB.open("sqlite3:#{path}") do |db|
        db.using_connection do |c|
          sqlite = c.as(SQLite3::Connection)
          sqlite.gori_swap_defensive(true)
          Gori::Store::Schema.autoincrement_in_place(sqlite).should be_true
          sqlite.gori_swap_defensive(true).should be_true # it was left on
          c.scalar("SELECT sql FROM sqlite_master WHERE name = 'flows'").as(String).should contain("AUTOINCREMENT")
        end
      end
    ensure
      cleanup(path)
    end
  end

  # The in-place edit is a schema change, so its cost must not grow with History. A check that
  # walked the table (`PRAGMA quick_check` once stood here) read every body's overflow chain:
  # 10-16 s on a 3.3 GB project, under the write lock a peer waits 5 s for. Proven by a body
  # whose overflow chain is cut short on disk: a walk of it fails, and the edit must not care.
  it "switches in place without reading a row, even one whose body it could not read" do
    path = build_pre_v39 do |c|
      plant_project(c)
      c.scalar("PRAGMA freelist_count").as(Int64).should eq(0) # new pages go on at the end of the file
      # Inserted last and outside the FTS index, so nothing is allocated after its body.
      c.exec("INSERT INTO flows (id, created_at, scheme, host, port, method, target, http_version, " \
             "request_head, response_body, state) VALUES (20, 0, 'https', 'v39.test', 443, 'GET', '/big', " \
             "'HTTP/1.1', X'00', zeroblob(64000), 2)")
    end
    begin
      File.open(path, "r+") do |f|
        page = f.seek(16) { f.read_bytes(UInt16, IO::ByteFormat::BigEndian) }.to_i64
        last = f.size // page
        # The body's last two overflow pages are the file's last two: the first names the second.
        f.seek((last - 2) * page) { f.read_bytes(UInt32, IO::ByteFormat::BigEndian).should eq(last) }
        f.seek((last - 2) * page) { f.write_bytes(0_u32, IO::ByteFormat::BigEndian) }
      end
      DB.open("sqlite3:#{path}") do |db|
        db.using_connection { |c| c.scalar("PRAGMA quick_check(flows)").as(String).should_not eq("ok") }
      end
      open_and(path) do |store|
        create_sql(store, "flows").should contain("INTEGER PRIMARY KEY AUTOINCREMENT")
        create_sql(store, "flows").starts_with?(%(CREATE TABLE "flows")).should be_false # not rebuilt
        store.flow_rows([1_i64, 5_i64, 9_i64]).map(&.target).sort!.should eq(["/five", "/nine", "/one"])
      end
    ensure
      cleanup(path)
    end
  end

  # The phrase the edit replaces sits only inside a CHECK here, with the real rowid clause in
  # lowercase: editing in place would fail every flow against its own CHECK.
  it "rebuilds a crafted History CREATE text instead of editing inside it" do
    path = build_pre_v39 do |c|
      plant_project(c)
      plant_crafted_create(c, "flows")
      Gori::Store::Schema.in_place_eligible?(c, "flows").should be_false
    end
    begin
      open_and(path) do |store|
        store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
        create_sql(store, "flows").should contain("INTEGER PRIMARY KEY AUTOINCREMENT")
        store.flow_rows([1_i64, 5_i64, 9_i64]).map { |r| {r.id, r.target} }.sort!
          .should eq([{1_i64, "/one"}, {5_i64, "/five"}, {9_i64, "/nine"}])
        store.search(Gori::QL.parse("body:bravo-body"), 10).map(&.id).should eq([5_i64])
      end
    ensure
      cleanup(path)
    end
  end

  # With the row check gone, eligibility is the whole guard: a WITHOUT ROWID table has no rowid
  # for AUTOINCREMENT to govern, and SQLite refuses the clause there.
  it "is not eligible for the in-place edit on a WITHOUT ROWID table" do
    DB.open("sqlite3::memory:") do |db|
      db.using_connection do |c|
        c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) WITHOUT ROWID")
        c.exec("CREATE TABLE u (id INTEGER PRIMARY KEY, x TEXT)")
        Gori::Store::Schema.in_place_eligible?(c, "t").should be_false
        Gori::Store::Schema.in_place_eligible?(c, "u").should be_true
      end
    end
  end

  it "refuses the in-place edit on a CREATE text it was not written for, changing nothing" do
    path = build_pre_v39 { |c| plant_project(c); force_rebuild(c) }
    begin
      DB.open("sqlite3:#{path}") do |db|
        db.using_connection do |c|
          before = c.scalar("SELECT sql FROM sqlite_master WHERE name = 'h2_connections'").as(String)
          Gori::Store::Schema.autoincrement_in_place(c.as(SQLite3::Connection)).should be_false
          # All or nothing: the eligible table is not edited on its own either.
          c.scalar("SELECT sql FROM sqlite_master WHERE name = 'h2_connections'").as(String).should eq(before)
        end
      end
    ensure
      cleanup(path)
    end
  end

  # `Store.open(read_only: true)` migrates a stale schema rather than refusing it (see
  # `Schema.migrate!`). That is only acceptable because V39 costs milliseconds in place.
  it "upgrades an old project from a read-only open and then reads it" do
    path = build_pre_v39 { |c| plant_project(c) }
    begin
      open_and(path, read_only: true) do |store|
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        create_sql(store, "flows").should contain("AUTOINCREMENT")
        store.recent_flows(10).map(&.id).sort!.should eq([1_i64, 5_i64, 9_i64])
      end
    ensure
      cleanup(path)
    end
  end

  # The cross-project search reads raw and read-only and never migrates, so it meets both shapes.
  it "is searchable across projects before and after the upgrade" do
    dir = File.tempname("gori-v39-search")
    Dir.mkdir_p(File.join(dir, "p"))
    project = Gori::Project.new("p", File.join(dir, "p", Gori::Project::DB_FILE))
    begin
      DB.open("sqlite3:#{project.db_path}?journal_mode=wal") do |db|
        db.using_connection do |c|
          Gori::Store::Schema::MIGRATIONS[0...V38].each { |statements| statements.each { |sql| c.exec(sql) } }
          c.exec("PRAGMA user_version = #{V38}")
          plant_project(c)
        end
      end
      Gori::ProjectSearch.search(project, "bravo-body").not_nil!.hits.map(&.flow_id).should eq([5_i64])
      open_and(project.db_path) { }
      Gori::ProjectSearch.search(project, "bravo-body").not_nil!.hits.map(&.flow_id).should eq([5_i64])
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

# Everything a History reader can observe of `flows`, read raw: every column of every row (by
# `quote()`, so a BLOB compares byte for byte), what a set of FTS queries resolve to, and the index
# definitions.
private record FlowsSnapshot, rows : Array(String), fts : Array(Array(Int64)), indexes : Array(String)

private FTS_TERMS = ["common-word", "payload-3", "row-17", "row-2999", "tok-gap"]

private def snapshot(path : String) : FlowsSnapshot
  row_expr = Gori::Store::Schema::V39_FLOW_COLUMNS.split(", ").join(" || '|' || ") { |c| "quote(#{c})" }
  DB.open("sqlite3:#{path}") do |db|
    rows = db.query_all("SELECT #{row_expr} FROM flows ORDER BY id", as: String)
    fts = FTS_TERMS.map do |term|
      db.query_all("SELECT rowid FROM flows_fts WHERE flows_fts MATCH ? ORDER BY rowid", %("#{term}"), as: Int64)
    end
    indexes = db.query_all("SELECT name || ': ' || sql FROM sqlite_master " \
                           "WHERE type = 'index' AND tbl_name = 'flows' ORDER BY name", as: String)
    FlowsSnapshot.new(rows, fts, indexes)
  end
end

private def plant_body(c : DB::Connection, id : Int64, body : String) : Nil
  plant_flow(c, id, "/r/#{id}", body, id.odd? ? 1_i64 : nil)
end

private OLD_PROJECTS = {
  "an empty table"                  => ->(_c : DB::Connection) { nil },
  "ids with gaps and a deleted top" => ->(c : DB::Connection) do
    c.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (1, 0, 'v39.test', 443, 'h2')")
    (1_i64..25_i64).each { |id| plant_body(c, id, "tok-gap row-#{id} common-word") }
    [3_i64, 7_i64, 24_i64, 25_i64].each do |id|
      c.exec("DELETE FROM flows WHERE id = ?", id)
      c.exec("DELETE FROM flows_fts WHERE rowid = ?", id)
    end
    nil
  end,
  "a few thousand rows with bodies and FTS content" => ->(c : DB::Connection) do
    c.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (1, 0, 'v39.test', 443, 'h2')")
    c.exec("BEGIN")
    (1_i64..3000_i64).each { |id| plant_body(c, id, "row-#{id} common-word payload-#{id % 17} " + "x" * (id % 900)) }
    # Rows the indexer has not reached yet, and a truncated body: columns past the BLOBs.
    c.exec("UPDATE flows SET fts_dirty = 1 WHERE id > 2990")
    c.exec("UPDATE flows SET response_body_truncated = 1, static_asset = 1 WHERE id % 97 = 0")
    c.exec("COMMIT")
    nil
  end,
  "a stray reference beyond MAX(id)" => ->(c : DB::Connection) do
    (1_i64..4_i64).each { |id| plant_body(c, id, "row-#{id} common-word") }
    c.exec("INSERT INTO issues (title, severity, host, created_at, updated_at, status, flow_id) " \
           "VALUES ('f', 3, 'v39.test', 0, 0, 0, 90)")
    nil
  end,
}

# The rebuild's copy step, run by hand so the copy can be damaged before the check sees it.
private def with_v39_copy(&)
  path = build_pre_v39 do |c|
    (1_i64..40_i64).each { |id| plant_body(c, id, "row-#{id} common-word") }
  end
  begin
    DB.open("sqlite3:#{path}") do |db|
      db.using_connection do |c|
        Gori::Store::Schema::V39_COPY.each { |sql| c.exec(sql) }
        yield c
      end
    end
  ensure
    cleanup(path)
  end
end

describe "Store::Schema V39 on an old project" do
  OLD_PROJECTS.each do |shape, plant|
    {"in place" => false, "by rebuild" => true}.each do |how, rebuild|
      it "leaves #{shape} exactly as it was when upgrading #{how}" do
        path = build_pre_v39 do |c|
          plant.call(c)
          force_rebuild(c) if rebuild
        end
        begin
          before = snapshot(path)
          next_id = 0_i64
          open_and(path) do |store|
            store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
            next_id = store.insert_flow(request("/after-upgrade"))
            store.delete_flow(next_id).should be_true
          end
          after = snapshot(path)
          after.rows.should eq(before.rows)
          after.fts.should eq(before.fts)
          after.indexes.should eq(before.indexes)
          # And the next id clears every id the project ever held or referenced.
          next_id.should be > (before.rows.empty? ? 0_i64 : before.rows.last.split('|').first.to_i64)
          next_id.should be > 90_i64 if shape.includes?("stray")
        ensure
          cleanup(path)
        end
      end
    end
  end

  describe ".verify_v39_copy" do
    it "passes a faithful copy" do
      with_v39_copy { |c| Gori::Store::Schema.verify_v39_copy(c) }
    end

    {
      "a lost row"            => "DELETE FROM flows_v39 WHERE id = 20",
      "a renumbered row"      => "UPDATE flows_v39 SET id = 99 WHERE id = 40",
      "a shortened body"      => "UPDATE flows_v39 SET response_body = X'00' WHERE id = 5",
      "a changed plain field" => "UPDATE flows_v39 SET target = '/elsewhere' WHERE id = 1",
      "a lost h2 connection"  => "DELETE FROM h2_connections_v39",
    }.each do |damage, sql|
      it "refuses #{damage}" do
        with_v39_copy do |c|
          c.exec("INSERT INTO h2_connections (id, created_at, host, port, alpn) VALUES (1, 0, 'v39.test', 443, 'h2')")
          c.exec("INSERT INTO h2_connections_v39 SELECT * FROM h2_connections")
          c.exec(sql)
          expect_raises(Gori::Error, /does not match the original/) { Gori::Store::Schema.verify_v39_copy(c) }
        end
      end
    end
  end
end

private def user_version(path : String) : Int64
  DB.open("sqlite3:#{path}") { |db| db.scalar("PRAGMA user_version").as(Int64) }
end

private def raw_create_sql(path : String, name : String) : String?
  DB.open("sqlite3:#{path}") do |db|
    db.query_one?("SELECT sql FROM sqlite_master WHERE name = ?", name, as: String)
  end
end

describe "Store::Schema V39 when a path fails part-way" do
  # Eligible for the edit (one rowid clause, no AUTOINCREMENT), but `PRIMARY KEY AUTOINCREMENT
  # ASC` does not parse: the UPDATE lands, the reparse after the cookie bump fails, and the
  # savepoint has to put the old text back before the rebuild can run on it.
  it "rolls a landed edit back and rebuilds when the edited text does not reparse" do
    path = build_pre_v39 do |c|
      plant_project(c)
      edit_flows_create(c, "id                      INTEGER PRIMARY KEY,", "id                      INTEGER PRIMARY KEY ASC,")
    end
    begin
      raw_create_sql(path, "flows").not_nil!.should contain("INTEGER PRIMARY KEY ASC,")
      before = snapshot(path)
      open_and(path) do |store|
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
        store.insert_flow(request("/after")).should eq(61_i64)
      end
      # The rebuild's own CREATE (RENAME TO quotes the name), not the edited one.
      sql = raw_create_sql(path, "flows").not_nil!
      sql.should start_with(%(CREATE TABLE "flows"))
      sql.should contain("INTEGER PRIMARY KEY AUTOINCREMENT,")
      sql.should_not contain("ASC")
      after = snapshot(path)
      after.rows[0...before.rows.size].should eq(before.rows) # plus the one inserted above
      after.fts.should eq(before.fts)
      after.indexes.should eq(before.indexes)
    ensure
      cleanup(path)
    end
  end

  # A copy that differs from its original must never be committed. `port` declared BLOB keeps a
  # TEXT '443' as text; the rebuilt table's INTEGER column converts it to 443, and `'443' IS 443`
  # is false — exactly the kind of silent rewrite the full-column check exists to catch.
  it "leaves the project at v38 and intact when the copy does not verify" do
    path = build_pre_v39 do |c|
      plant_project(c)
      edit_flows_create(c, "port                    INTEGER NOT NULL", "port                    BLOB    NOT NULL")
      force_rebuild(c)
      c.exec("UPDATE flows SET port = '443' WHERE id = 5")
    end
    begin
      before = snapshot(path)
      create_before = raw_create_sql(path, "flows")
      expect_raises(Gori::Error, /does not match the original.*rows differ outside the bodies/) do
        Gori::Store.open(path)
      end
      user_version(path).should eq(38_i64)
      raw_create_sql(path, "flows").should eq(create_before)
      raw_create_sql(path, "flows_v39").should be_nil
      raw_create_sql(path, "h2_connections").not_nil!.should_not contain("AUTOINCREMENT")
      snapshot(path).should eq(before)
    ensure
      cleanup(path)
    end
  end

  it "says how much free space the rebuild needs when the disk fills" do
    path = build_pre_v39 do |c|
      plant_project(c)
      c.exec("BEGIN")
      (100_i64...400_i64).each { |id| plant_flow(c, id, "/fill/#{id}", "fill " * 800) }
      c.exec("COMMIT")
      force_rebuild(c)
    end
    begin
      before = snapshot(path)
      db = DB.open("sqlite3:#{path}?max_pool_size=1")
      begin
        db.using_connection do |c|
          # A disk with room for a few more pages than the project already has.
          c.exec("PRAGMA max_page_count = #{c.scalar("PRAGMA page_count").as(Int64) + 8}")
        end
        expect_raises(Gori::Error, /not enough free disk space.*about \d+ MB free/) do
          Gori::Store::Schema.migrate!(db)
        end
      ensure
        # `sqlite3_finalize` hands back the failed step's SQLITE_FULL once more when the cached
        # statement is closed; `Store.open` closes a failed pool the same way (`rescue nil`).
        db.close rescue nil
      end
      user_version(path).should eq(38_i64)
      raw_create_sql(path, "flows_v39").should be_nil
      snapshot(path).should eq(before)
    ensure
      cleanup(path)
    end
  end
end
