require "../spec_helper"

# V46 makes an id on the four rule tables V40 left alone impossible to issue twice: MCP, `gori run`
# and the TUI's OAST form all name those rows by id, so a reused one let a stale holder act on a
# peer's new row. Each example replays V1..V45 as a released gori did, deletes the top ids, and
# drives the real upgrade through `Store.open`, on both paths.

private V45 = 45

private TABLES = %w[extract_rules oast_providers color_rules display_columns]

private def build_pre_v46(& : DB::Connection ->) : String
  path = File.tempname("gori-v46-rules", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...V45].each { |statements| statements.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = #{V45}")
      yield c
    end
  end
  path
end

# A stored CREATE text the in-place edit was not written for, so V46 has to rebuild.
private def force_rebuild(c : DB::Connection) : Nil
  c.as(SQLite3::Connection).gori_swap_defensive(false)
  cookie = c.scalar("PRAGMA schema_version").as(Int64)
  c.exec("PRAGMA writable_schema = ON")
  c.exec("UPDATE sqlite_master SET sql = replace(sql, 'INTEGER PRIMARY KEY', 'INTEGER  PRIMARY KEY') " \
         "WHERE type = 'table' AND name IN ('extract_rules', 'oast_providers', 'color_rules', 'display_columns')")
  c.exec("PRAGMA schema_version = #{cookie + 1}")
  c.exec("PRAGMA writable_schema = OFF")
end

# Rows 1..3 in each table, then the top one deleted. One OAST session still names provider 7,
# which no longer exists.
private def plant(c : DB::Connection) : Nil
  (1..3).each do |i|
    c.exec("INSERT INTO extract_rules (id, name, kind) VALUES (?, ?, 'header')", i, "rule#{i}")
    c.exec("INSERT INTO oast_providers (id, created_at, updated_at, name, kind, host) VALUES (?, 0, 0, ?, 'interactsh', 'oast.test')", i, "p#{i}")
    c.exec("INSERT INTO color_rules (id, match_filter, position) VALUES (?, 'host:a', ?)", i, i)
    c.exec("INSERT INTO display_columns (id, label, kind, position) VALUES (?, ?, 'header', ?)", i, "c#{i}", i)
  end
  c.exec("INSERT INTO oast_sessions (created_at, provider_id, kind, server_url, correlation_id) VALUES (0, 7, 'interactsh', 'https://oast.test', 'c')")
  TABLES.each { |t| c.exec("DELETE FROM #{t} WHERE id = 3") }
end

describe "Store::Schema V46 (AUTOINCREMENT on the rule tables)" do
  {"in place" => false, "by rebuild" => true}.each do |how, rebuild|
    it "keeps every row and never hands a deleted top id out again #{how}" do
      path = build_pre_v46 do |c|
        plant(c)
        force_rebuild(c) if rebuild
      end
      begin
        store = Gori::Store.open(path)
        begin
          TABLES.each do |t|
            store.@db.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", t).as(String)
              .should contain("AUTOINCREMENT")
            store.@db.query_all("SELECT id FROM #{t} ORDER BY id", as: Int64).should eq([1_i64, 2_i64])
          end
          # A deleted top id was already gone before the upgrade, so it cannot be held back; from
          # here on, one deleted after issue never comes back.
          store.insert_extract_rule("fresh", "", Gori::ExtractKind::Header).should eq(3_i64)
          store.@db.exec("DELETE FROM extract_rules WHERE id = 3")
          store.insert_extract_rule("again", "", Gori::ExtractKind::Header).should eq(4_i64)
          store.insert_color_rule("host:b").should eq(3_i64)
          store.@db.exec("DELETE FROM color_rules WHERE id = 3")
          store.insert_color_rule("host:c").should eq(4_i64)
          store.insert_display_column("fresh", Gori::ExtractKind::Header).should eq(3_i64)
          store.@db.exec("DELETE FROM display_columns WHERE id = 3")
          store.insert_display_column("again", Gori::ExtractKind::Header).should eq(4_i64)
          # Seeded past the session that still names provider 7.
          store.insert_oast_provider("fresh", "interactsh", "oast.test", nil, true, 0).should eq(8_i64)
        ensure
          store.close
        end
      ensure
        delete_db_files(path)
      end
    end
  end
end
