# ponytail: on Windows these legacy-schema (pre-V39/V40) migrations hang when run after
# each other in one process, while any one alone passes in seconds. Off Windows until that
# is understood (#1510 follow-up); every POSIX job still runs them.
{% skip_file if flag?(:win32) %}

require "../spec_helper"

# V40 makes an id on eight more tables impossible to issue twice. Every example builds the PRE-V40
# shape by replaying V1..V39 exactly as a released gori did, plants what an operator's project can
# already hold — gaps in the id space, a deleted top id, references that outlived their row — and
# drives the real upgrade through `Store.open`, on both paths: the in-place edit, and the verified
# rebuild a table takes when its stored CREATE text is not one gori wrote.

private V39 = 39

# How each example moves the tables: `true` makes every table's CREATE text ineligible first.
private PATHS = {"in place" => false, "by rebuild" => true}

private def build_pre_v40(& : DB::Connection ->) : String
  path = File.tempname("gori-v40-tables", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...V39].each { |statements| statements.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = #{V39}")
      yield c
    end
  end
  path
end

# Make the stored CREATE text of `tables` one the in-place edit was not written for (two spaces in
# the rowid clause), so V40 has to rebuild them. DEFENSIVE is lifted the way the edit lifts it.
private def force_rebuild(c : DB::Connection, tables : Enumerable(String) = ROW.keys) : Nil
  c.as(SQLite3::Connection).gori_swap_defensive(false)
  cookie = c.scalar("PRAGMA schema_version").as(Int64)
  c.exec("PRAGMA writable_schema = ON")
  c.exec("UPDATE sqlite_master SET sql = replace(sql, 'INTEGER PRIMARY KEY', 'INTEGER  PRIMARY KEY') " \
         "WHERE type = 'table' AND name IN (#{tables.join(", ") { |t| "'#{t}'" }})")
  c.exec("PRAGMA schema_version = #{cookie + 1}")
  c.exec("PRAGMA writable_schema = OFF")
end

private def create_sql(store : Gori::Store, table : String) : String
  store.@db.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table).as(String)
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

# One row at an EXPLICIT id, so a fixture can leave gaps. Every NOT NULL column without a default
# is filled, and each table gets at least one BLOB or free-text value that the copy must carry
# byte for byte.
private ROW = {
  "repeaters" => "INSERT INTO repeaters (id, created_at, updated_at, target, request, response_head, " \
                 "response_body, name, tags) VALUES (?1, ?1, ?1, 'https://v40.test/' || ?1, " \
                 "'GET /r/' || ?1 || ' HTTP/1.1', X'485454502f312e3120323030', X'00ff' || randomblob(?1), " \
                 "'tab ' || ?1, NULL)",
  "probe_custom_rules" => "INSERT INTO probe_custom_rules (id, title, side, region, kind, pattern, severity) " \
                          "VALUES (?1, 'rule ' || ?1, 'response', 'body', 'string', 'needle-' || ?1, 'low')",
  "probe_issues" => "INSERT INTO probe_issues (id, code, category, host, title, severity, affected, " \
                    "first_seen, last_seen) VALUES (?1, 'code_' || ?1, 'headers', 'v40.test', 't', 1, " \
                    "'[\"https://v40.test/' || ?1 || '\"]', ?1, ?1)",
  "issues" => "INSERT INTO issues (id, created_at, updated_at, title, severity, notes, cvss) " \
              "VALUES (?1, ?1, ?1, 'issue ' || ?1, 2, 'notes ' || ?1, NULL)",
  "match_rules" => "INSERT INTO match_rules (id, target, pattern, replacement, respond_args) " \
                   "VALUES (?1, 'request', 'p' || ?1, 'r' || ?1, '{}')",
  "scope_rules"    => "INSERT INTO scope_rules (id, kind, match_type, pattern) VALUES (?1, 'exclude', 'host', 'h' || ?1)",
  "host_overrides" => "INSERT INTO host_overrides (id, host, ip) VALUES (?1, 'h' || ?1 || '.test', '10.0.0.' || ?1)",
  "fuzz_runs"      => "INSERT INTO fuzz_runs (id, created_at, target, mode, source_ref, stop_idx) " \
                 "VALUES (?1, ?1, 'https://v40.test/', 'sniper', 'tui:' || ?1, NULL)",
}

private TABLES = ROW.keys

# Rows 1..6 existed; 2 and 5 were deleted mid-history and 6, the top id, too — so a pre-V40 insert
# would have been handed 5 again.
private LIVE = [1_i64, 3_i64, 4_i64]

private def plant_rows(c : DB::Connection, table : String) : Nil
  (1_i64..6_i64).each { |id| c.exec(ROW[table], id) }
  [2_i64, 5_i64, 6_i64].each { |id| c.exec("DELETE FROM #{table} WHERE id = ?", id) }
end

# Everything a reader can observe of a table, read raw: every column of every row by `quote()` (a
# BLOB compares byte for byte), the column declarations, and each index with its definition.
private def snapshot(c : DB::Connection, table : String) : {Array(String), Array(String), Array(String)}
  cols = c.query_all("SELECT name FROM pragma_table_info(?) ORDER BY cid", table, as: String)
  rows = c.query_all("SELECT #{cols.join(" || '|' || ") { |col| "quote(#{col})" }} FROM #{table} ORDER BY id", as: String)
  decl = c.query_all("SELECT cid || name || type || \"notnull\" || quote(dflt_value) || pk " \
                     "FROM pragma_table_info(?) ORDER BY cid", table, as: String)
  indexes = c.query_all("SELECT l.name || ' unique=' || l.\"unique\" || ' ' || l.origin || ' ' || " \
                        "COALESCE((SELECT sql FROM sqlite_master m WHERE m.name = l.name), '') || ' (' || " \
                        "(SELECT group_concat(i.name) FROM pragma_index_info(l.name) i) || ')' " \
                        "FROM pragma_index_list(?) l ORDER BY l.name", table, as: String)
  {rows, decl, indexes}
end

private def snapshot_file(path : String, table : String)
  DB.open("sqlite3:#{path}") { |db| db.using_connection { |c| snapshot(c, table) } }
end

private def seq_of(store : Gori::Store, table : String) : Int64?
  store.@db.query_one?("SELECT seq FROM sqlite_sequence WHERE name = ?", table, as: Int64)
end

# Delete the newest row and insert another the way the table's own statement does; the new id.
private def delete_newest_then_insert(store : Gori::Store, table : String) : Int64
  db = store.@db
  top = db.scalar("SELECT MAX(id) FROM #{table}").as(Int64?)
  db.exec("DELETE FROM #{table} WHERE id = ?", top) if top
  db.using_connection do |c|
    c.exec(ROW[table].sub("VALUES (?1", "VALUES (NULL"), 77_i64)
    c.scalar("SELECT last_insert_rowid()").as(Int64)
  end
end

# A reference to an id ABOVE every live one, in each place V40 seeds from, with the value it must
# seed. Negative values are DETACHED references, seeded by magnitude.
private STRAYS = {
  "repeaters" => {
    "a WebSocket frame of a deleted tab" => {"INSERT INTO ws_messages (flow_id, created_at, direction, opcode, payload, repeater_id) VALUES (0, 0, 'out', 1, X'', 41)", 41},
    "an entity link"                     => {"INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', 1, 'repeater', 42, 0)", 42},
    "a detached retest step"             => {"INSERT INTO issue_retest_steps (issue_id, position, role, ref_kind, ref_id, created_at, updated_at) VALUES (1, 1, 'variant', 'repeater', -43, 0, 0)", 43},
    "a recorded retest run step"         => {"INSERT INTO issue_retest_run_steps (run_id, position, role, ref_kind, ref_id, label, method, url, assertion, outcome, detail) VALUES (1, 1, 'variant', 'repeater', 44, '', 'GET', '', '', 'pass', '')", 44},
    "a frozen evidence source"           => {"INSERT INTO issue_evidence (created_at, source_kind, source_id, method, url, request_head, request_sha256, bytes) VALUES (0, 'repeater', 45, 'GET', 'https://v40.test/', X'', '', 0)", 45},
    "a Probe finding's sample tab"       => {"INSERT INTO probe_issues (code, category, host, title, severity, sample_repeater_id, first_seen, last_seen) VALUES ('x', 'x', 'v40.test', 't', 1, 46, 0, 0)", 46},
    "a session slot's refresh step"      => { %(INSERT INTO settings (key, value) VALUES ('authorize_identities', '[{"name":"a","refresh":[3,-47]},"junk",{"name":"b"}]')), 47 },
    "a Repeater send's flow provenance"  => {"INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, request_head, state, source, source_ref) VALUES (0, 'https', 'v40.test', 443, 'GET', '/', 'HTTP/1.1', X'', 2, 'repeater', '48')", 48},
  },
  "probe_custom_rules" => {
    "a finding's code"               => {"INSERT INTO probe_issues (code, category, host, title, severity, first_seen, last_seen) VALUES ('custom_p_51', 'custom', 'v40.test', 't', 1, 0, 0)", 51},
    "a suppression"                  => {"INSERT INTO probe_suppressions (code, host, created_at) VALUES ('custom_p_52', 'v40.test', 0)", 52},
    "an OAST probe"                  => {"INSERT INTO probe_oast_probes (created_at, token, payload, session_id, rule_id, code, category, title, severity, host, url) VALUES (0, 't', 'p', 1, 'custom_p_53', 'custom_p_53', 'custom', 't', 1, 'v40.test', 'u')", 53},
    "the disabled-rule set"          => { %(INSERT INTO settings (key, value) VALUES ('probe_disabled_rules', '["missing_hsts","custom_p_54",7]')), 54 },
    "a global rule's code (ignored)" => {"INSERT INTO probe_issues (code, category, host, title, severity, first_seen, last_seen) VALUES ('custom_g_99', 'custom', 'v40.test', 't', 1, 0, 0)", 4},
  },
  "issues" => {
    "a link it owns"                            => {"INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', 61, 'flow', 1, 0)", 61},
    "an evidence link"                          => {"INSERT INTO evidence_issue_links (evidence_id, issue_id, created_at) VALUES (1, 62, 0)", 62},
    "a retest step"                             => {"INSERT INTO issue_retest_steps (issue_id, position, role, ref_kind, ref_id, created_at, updated_at) VALUES (63, 1, 'variant', 'flow', 1, 0, 0)", 63},
    "a retest run"                              => {"INSERT INTO issue_retest_runs (issue_id, started_at, finished_at, verdict, total, passed, failed, inconclusive, errored, blocked, skipped) VALUES (64, 0, 0, 'pass', 0, 0, 0, 0, 0, 0, 0)", 64},
    "a retest's flow"                           => {"INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, request_head, state, source, source_ref) VALUES (0, 'https', 'v40.test', 443, 'GET', '/', 'HTTP/1.1', X'', 2, 'retest', 'issue #65 step 2')", 65},
    "an imported file named like one (ignored)" => {"INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, request_head, state, source, source_ref) VALUES (0, 'https', 'v40.test', 443, 'GET', '/', 'HTTP/1.1', X'', 2, 'import', 'issue #99999999999999999999.har')", 4},
    "a note's link (not an issue)"              => {"INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('note', 99, 'flow', 1, 0)", 4},
  },
  "match_rules" => {
    "a mocked flow's provenance" => {"INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, request_head, state, short_circuited, source_ref) VALUES (0, 'https', 'v40.test', 443, 'GET', '/', 'HTTP/1.1', X'', 2, 1, 'project rule #71 · inline')", 71},
    "a global rule's (ignored)"  => {"INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, request_head, state, short_circuited, source_ref) VALUES (0, 'https', 'v40.test', 443, 'GET', '/', 'HTTP/1.1', X'', 2, 1, 'global rule #99 · inline')", 4},
  },
  "fuzz_runs" => {
    "a result of a deleted run" => {"INSERT INTO fuzz_results (run_id, idx, payloads) VALUES (81, 0, '[]')", 81},
  },
}

describe "Store::Schema V40 (AUTOINCREMENT on eight tables)" do
  TABLES.each do |table|
    describe table do
      PATHS.each do |how, rebuild|
        it "keeps every row, column declaration and index, and moves to AUTOINCREMENT #{how}" do
          path = build_pre_v40 do |c|
            plant_rows(c, table)
            force_rebuild(c) if rebuild
          end
          begin
            before = snapshot_file(path, table)
            before[0].size.should eq(LIVE.size)
            open_and(path) do |store|
              store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
              store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
              create_sql(store, table).should match(/INTEGER +PRIMARY KEY AUTOINCREMENT/)
              # Which path ran: a rebuild's RENAME quotes the name in the CREATE text it keeps.
              create_sql(store, table).starts_with?(%(CREATE TABLE "#{table}")).should eq(rebuild)
              store.@db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%_autoinc'").as(Int64).should eq(0)
            end
            after = snapshot_file(path, table)
            after[0].should eq(before[0])
            # The declaration differs only in AUTOINCREMENT, which PRAGMA table_info does not show.
            after[1].should eq(before[1])
            added = after[2].select(&.starts_with?("idx_probe_issues_sample_repeater "))
            added.size.should eq(table == "probe_issues" ? 1 : 0)
            (after[2] - added).should eq(before[2])
          ensure
            cleanup(path)
          end
        end

        it "never hands a deleted top id out again #{how}" do
          path = build_pre_v40 do |c|
            plant_rows(c, table)
            force_rebuild(c) if rebuild
          end
          begin
            open_and(path) do |store|
              # MAX(id) was 4 and 6 is gone for good; the seed starts from what is still there.
              seq_of(store, table).should eq(4_i64)
              first = delete_newest_then_insert(store, table)
              first.should eq(5_i64)
              # 5 is the newest now. Delete it: before V40 the next row was handed 5 again.
              delete_newest_then_insert(store, table).should eq(6_i64)
              store.@db.exec("DELETE FROM #{table}")
              delete_newest_then_insert(store, table).should eq(7_i64)
            end
          ensure
            cleanup(path)
          end
        end
      end

      STRAYS[table]?.try &.each do |what, (sql, want)|
        it "seeds past #{what}" do
          path = build_pre_v40 do |c|
            plant_rows(c, table)
            c.exec(sql)
          end
          begin
            open_and(path) do |store|
              seq_of(store, table).should eq(want.to_i64)
              delete_newest_then_insert(store, table).should be > want.to_i64
            end
          ensure
            cleanup(path)
          end
        end

        # No rows to copy, so without the seed ids would restart at 1, under the reference.
        it "seeds an EMPTY table past #{what}" do
          path = build_pre_v40(&.exec(sql))
          begin
            open_and(path) do |store|
              want_empty = want > LIVE.max ? want.to_i64 : 0_i64
              seq_of(store, table).should eq(want_empty)
            end
          ensure
            cleanup(path)
          end
        end
      end
    end
  end

  PATHS.each do |how, rebuild|
    it "upgrades a project carrying every table's rows and strays at once #{how}" do
      path = build_pre_v40 do |c|
        TABLES.each { |t| plant_rows(c, t) }
        STRAYS.each_value { |cases| cases.each_value { |(sql, _)| c.exec(sql) } }
        force_rebuild(c) if rebuild
      end
      begin
        before = TABLES.map { |t| snapshot_file(path, t)[0..1] } # rows and declarations
        open_and(path) do |store|
          store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
          seq_of(store, "repeaters").should eq(48_i64)
          seq_of(store, "probe_custom_rules").should eq(54_i64)
          seq_of(store, "issues").should eq(65_i64)
          seq_of(store, "match_rules").should eq(71_i64)
          seq_of(store, "fuzz_runs").should eq(81_i64)
          {"probe_issues", "scope_rules", "host_overrides"}.each do |t|
            seq_of(store, t).should eq(store.@db.scalar("SELECT MAX(id) FROM #{t}").as(Int64))
          end
        end
        TABLES.map { |t| snapshot_file(path, t)[0..1] }.should eq(before)
      ensure
        cleanup(path)
      end
    end
  end

  # One table whose CREATE text gori did not write does not cost the others their in-place edit.
  # A CREATE text gori did not write must never be edited in place: here the only uppercase
  # rowid phrase sits inside a CHECK, where a blind edit would break every row.
  it "rebuilds a crafted CREATE text instead of editing inside it" do
    path = build_pre_v40 do |c|
      TABLES.each { |t| plant_rows(c, t) }
      plant_crafted_create(c, "scope_rules")
      c.scalar("PRAGMA integrity_check").as(String).should eq("ok")
    end
    begin
      before = snapshot_file(path, "scope_rules")[0]
      open_and(path) do |store|
        store.@db.scalar("PRAGMA integrity_check").as(String).should eq("ok")
        create_sql(store, "scope_rules").should contain("INTEGER PRIMARY KEY AUTOINCREMENT")
        create_sql(store, "scope_rules").starts_with?(%(CREATE TABLE "scope_rules")).should be_true # rebuilt
        create_sql(store, "issues").starts_with?(%(CREATE TABLE "issues")).should be_false          # others in place
      end
      snapshot_file(path, "scope_rules")[0].should eq(before)
      open_and(path) { |store| delete_newest_then_insert(store, "scope_rules").should eq(5_i64) }
    ensure
      cleanup(path)
    end
  end

  it "rebuilds only the tables it cannot edit in place" do
    path = build_pre_v40 do |c|
      TABLES.each { |t| plant_rows(c, t) }
      force_rebuild(c, {"issues"})
    end
    begin
      DB.open("sqlite3:#{path}") do |db|
        db.using_connection do |c|
          c.exec("BEGIN IMMEDIATE")
          Gori::Store::Schema.move_to_autoincrement(c.as(SQLite3::Connection), Gori::Store::Schema::ID_REBUILDS, 40).should eq(["issues"])
          c.exec("COMMIT")
          TABLES.each do |t|
            c.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", t).as(String)
              .starts_with?(%(CREATE TABLE "#{t}")).should eq(t == "issues")
          end
        end
      end
    ensure
      cleanup(path)
    end
  end

  # Each odd value is dropped on its own, before its column's maximum is taken: beside it sits a
  # real reference in the same column, and that one still counts.
  it "neither aborts on nor seeds past a reference no gori could have issued" do
    path = build_pre_v40 do |c|
      plant_rows(c, "repeaters")
      c.exec(%(INSERT INTO settings (key, value) VALUES ('authorize_identities', '{not json')))
      c.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) " \
             "VALUES ('issue', 1, 'repeater', 9223372036854775807, 0), ('issue', 1, 'repeater', 42, 0)")
      c.exec("INSERT INTO ws_messages (flow_id, created_at, direction, opcode, payload, repeater_id) " \
             "VALUES (0, 0, 'out', 1, X'', 'not-an-id'), (0, 0, 'out', 1, X'', 12.5), (0, 0, 'out', 1, X'', 9)")
      # `ABS` raises on the one int64 it cannot negate.
      c.exec("INSERT INTO issue_retest_steps (issue_id, position, role, ref_kind, ref_id, created_at, updated_at) " \
             "VALUES (1, 1, 'variant', 'repeater', -9223372036854775808, 0, 0)")
    end
    begin
      open_and(path) do |store|
        seq_of(store, "repeaters").should eq(42_i64)
        delete_newest_then_insert(store, "repeaters").should eq(43_i64)
      end
    ensure
      cleanup(path)
    end
  end

  it "reads flow provenance from the covering list index, not the flows table" do
    with_store do |store|
      Gori::Store::Schema::ID_REBUILDS.each do |r|
        r.refs.select(&.includes?("FROM flows")).each do |sql|
          plan = store.@db.query_all("EXPLAIN QUERY PLAN #{sql}", as: {Int64, Int64, Int64, String}).map(&.[3])
          plan.join(" ").should contain("COVERING INDEX idx_flows_list")
        end
      end
    end
  end

  describe ".verify_rebuilt_copies" do
    # The copy step run by hand, so a copy can be damaged before the check sees it.
    with_copy = ->(damage : String?) do
      path = build_pre_v40 { |c| TABLES.each { |t| plant_rows(c, t) } }
      begin
        DB.open("sqlite3:#{path}") do |db|
          db.using_connection do |c|
            Gori::Store::Schema::V40_COPY.each { |sql| c.exec(sql) }
            c.exec(damage) if damage
            Gori::Store::Schema.verify_rebuilt_copies(c, Gori::Store::Schema::ID_REBUILDS, 40)
          end
        end
      ensure
        cleanup(path)
      end
    end

    it "passes faithful copies" do
      with_copy.call(nil)
    end

    {
      "a lost row"             => "DELETE FROM issues_autoinc WHERE id = 3",
      "a renumbered row"       => "UPDATE scope_rules_autoinc SET id = 99 WHERE id = 4",
      "a changed BLOB byte"    => "UPDATE repeaters_autoinc SET response_head = X'485454502f312e3120323031' WHERE id = 1",
      "a swapped pair of rows" => "UPDATE match_rules_autoinc SET pattern = CASE id WHEN 1 THEN 'p3' WHEN 3 THEN 'p1' END WHERE id IN (1, 3)",
      "a NULL for a value"     => "UPDATE fuzz_runs_autoinc SET source_ref = NULL WHERE id = 4",
      "a text/blob swap"       => "UPDATE probe_custom_rules_autoinc SET pattern = CAST(pattern AS BLOB) WHERE id = 1",
    }.each do |damage, sql|
      it "refuses #{damage}" do
        expect_raises(Gori::Error, /schema v40: the rebuilt \w+ table does not match the original/) do
          with_copy.call(sql)
        end
      end
    end

    it "refuses a copy that lost a column" do
      expect_raises(Gori::Error, /host_overrides_autoinc has columns/) do
        with_copy.call("ALTER TABLE host_overrides_autoinc DROP COLUMN ip")
      end
    end
  end
end

describe "Gori::Store::Schema.autoincrement_tables" do
  # Derived from the migrations rather than listed, so a table a later migration moves to
  # AUTOINCREMENT joins the archive's exhausted-counter check without anyone adding it. Held
  # equal to what the migrations actually produce, both ways.
  it "names exactly the tables a fresh store keeps AUTOINCREMENT" do
    with_store do |store|
      live = store.@db.query_all("SELECT name FROM sqlite_master WHERE type = 'table' " \
                                 "AND sql LIKE '%AUTOINCREMENT%'", as: String).to_set
      live.should contain("events")
      live.should contain("fuzz_sessions")
      Gori::Store::Schema.autoincrement_tables.should eq(live)
    end
  end
end
