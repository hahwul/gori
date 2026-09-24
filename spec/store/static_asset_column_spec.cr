require "../spec_helper"

# The hide-static lens's column (#1239, schema V30): decided once when a flow is written, and
# backfilled for the flows a project already holds, so `static:` and the lens read a column
# instead of calling a function per row on every reload.

# A V29 database with flows in each shape the backfill has to tell apart, as an existing
# project would hold them. Returns the path for `Store.open` to upgrade.
private def build_pre_v30 : String
  path = File.tempname("gori-v30", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...29].each { |stmts| stmts.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 29")
      {
        {"/logo.png", 200, "image/png"},      # 1: static by MIME
        {"/f/inter.woff2", 304, nil},         # 2: static by extension (no Content-Type)
        {"/gone.png", 404, "image/png"},      # 3: an error — never static
        {"/api/me", 200, "application/json"}, # 4: not an asset
        {"/icon.svg", 200, "image/svg+xml"},  # 5: SVG can carry script
        {"/pending.png", nil, nil},           # 6: pending — by extension
      }.each_with_index do |(target, status, ct), i|
        c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
               "request_head, request_size, state, status, content_type) " \
               "VALUES (?,'https','a.test',443,'GET',?,'HTTP/1.1',X'00',1,1,?,?)",
          i + 1, target, status, ct)
      end
    end
  end
  path
end

private def static_ids(store) : Array(Int64)
  ids = [] of Int64
  store.@db.query("SELECT id FROM flows WHERE static_asset = 1 ORDER BY id") { |rs| rs.each { ids << rs.read(Int64) } }
  ids
end

describe "Store::Schema V30" do
  it "backfills static_asset for the flows a project already holds" do
    path = build_pre_v30
    begin
      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        static_ids(store).should eq([1_i64, 2_i64, 6_i64])
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "serves the Sitemap's hide-static read from the partial covering index" do
    with_store do |store|
      sql = "SELECT DISTINCT host, method, target FROM flows WHERE (1) AND (#{Gori::QL.hide_static.sql}) " \
            "ORDER BY host, target, method LIMIT 10"
      plan = [] of String
      store.@db.query("EXPLAIN QUERY PLAN #{sql}") { |rs| rs.each { 3.times { rs.read }; plan << rs.read(String) } }
      plan.join(" ").should contain("COVERING INDEX idx_flows_sitemap_nonstatic")
    end
  end
end

describe "Store static_asset writes" do
  it "classifies a pending flow by its path, then again when the response lands" do
    with_store do |store|
      req = ->(target : String) {
        Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443, method: "GET",
          target: target, http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy)
      }
      png = store.insert_flow(req.call("/logo.png"))
      api = store.insert_flow(req.call("/api"))
      static_ids(store).should eq([png])

      # The response turns /api into an image, and /logo.png into a 404.
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: api, status: 200, content_type: "image/jpeg", head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: png, status: 404, content_type: "image/png", head: "HTTP/1.1 404 X\r\n\r\n".to_slice))
      static_ids(store).should eq([api])
    end
  end
end
