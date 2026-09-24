require "../spec_helper"

# The hide-static lens's column (#1239, schema V31): decided once when a flow is written, and
# backfilled for the flows a project already holds, so `static:` and the lens read a column
# instead of calling a function per row on every reload.

# A V30 database with flows in each shape the backfill has to tell apart, as an existing
# project would hold them. Returns the path for `Store.open` to upgrade.
private def build_pre_v31 : String
  path = File.tempname("gori-v31", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...30].each { |stmts| stmts.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 30")
      rows = [] of {String, Gori::Store::FlowState, Int32?, String?}
      rows << {"/logo.png", Gori::Store::FlowState::Complete, 200, "image/png"}      # 1: static by MIME
      rows << {"/f/inter.woff2", Gori::Store::FlowState::Complete, 304, nil}         # 2: static by extension
      rows << {"/gone.png", Gori::Store::FlowState::Complete, 404, "image/png"}      # 3: failed status
      rows << {"/api/me", Gori::Store::FlowState::Complete, 200, "application/json"} # 4: not an asset
      rows << {"/icon.svg", Gori::Store::FlowState::Complete, 200, "image/svg+xml"}  # 5: SVG can carry script
      rows << {"/pending.png", Gori::Store::FlowState::Pending, nil, nil}            # 6: pending — never static
      rows.each_with_index do |(target, state, status, ct), i|
        c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
               "request_head, request_size, state, status, content_type) " \
               "VALUES (?,'https','a.test',443,'GET',?,'HTTP/1.1',X'00',1,?,?,?)",
          i + 1, target, state.value, status, ct)
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

describe "Store::Schema V31" do
  it "backfills static_asset for the flows a project already holds" do
    path = build_pre_v31
    begin
      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        static_ids(store).should eq([1_i64, 2_i64])
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

private def build_v31_static_rows : String
  path = File.tempname("gori-v31-static", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...31].each { |stmts| stmts.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 31")
      rows = [] of {String, Gori::Store::FlowState, Int32?, String?}
      rows << {"/logo.png", Gori::Store::FlowState::Complete, 200, "image/png"}
      rows << {"/unsafe/300x200/https://internal.example/a.jpg", Gori::Store::FlowState::Complete, 200, "image/jpeg"}
      rows << {"/resize?src=//169.254.169.254/x.png", Gori::Store::FlowState::Complete, 200, "image/png"}
      rows << {"/pending.png", Gori::Store::FlowState::Pending, nil, nil}
      rows << {"/broken.png", Gori::Store::FlowState::Error, 200, "image/png"}
      rows << {"/icon.svg", Gori::Store::FlowState::Complete, 200, "image/svg"}
      rows.each_with_index do |(target, state, status, ct), i|
        c.exec("INSERT INTO flows (id, created_at, scheme, host, port, method, target, http_version, " \
               "request_head, state, status, content_type, static_asset) " \
               "VALUES (?,?,'https','a.test',443,'GET',?,'HTTP/1.1',X'00',?,?,?,1)",
          i + 1, i + 1, target, state.value, status, ct)
      end
    end
  end
  path
end

describe "Store::Schema V32" do
  it "reclassifies existing static flags under the current rule" do
    path = build_v31_static_rows
    begin
      store = Gori::Store.open(path)
      begin
        static_ids(store).should eq([1_i64])
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end

describe "Store static_asset writes" do
  it "keeps a pending flow visible, then classifies it when the response lands" do
    with_store do |store|
      req = ->(target : String) {
        Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443, method: "GET",
          target: target, http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy)
      }
      png = store.insert_flow(req.call("/logo.png"))
      api = store.insert_flow(req.call("/api"))
      static_ids(store).should be_empty
      store.search(Gori::QL.hide_static, 10).map(&.id).should contain(png)

      # The response turns /api into an image, and /logo.png into a 404.
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: api, status: 200, content_type: "image/jpeg", head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: png, status: 404, content_type: "image/png", head: "HTTP/1.1 404 X\r\n\r\n".to_slice))
      static_ids(store).should eq([api])
    end
  end

  it "does not lose a pending image behind a hide-static tail cursor" do
    with_store do |store|
      request = ->(target : String) {
        Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443, method: "GET",
          target: target, http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy)
      }
      png = store.insert_flow(request.call("/uploads/avatar.png"))
      api = store.insert_flow(request.call("/api"))
      page1 = store.search(Gori::QL.hide_static, 10, nil, 0_i64).map(&.id)
      cursor = page1.max
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: png, status: 200, content_type: "text/html", head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      page2 = store.search(Gori::QL.hide_static, 10, nil, cursor).map(&.id)
      (page1 + page2).should contain(png)
      (page1 + page2).should contain(api)
    end
  end

  it "keeps failed 2xx image transfers visible" do
    with_store do |store|
      request = ->(target : String) {
        Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443, method: "GET",
          target: target, http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy)
      }
      error = store.insert_flow(request.call("/error.png"))
      aborted = store.insert_flow(request.call("/aborted.png"))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: error, status: 200, content_type: "image/png", state: Gori::Store::FlowState::Error,
        error: "upstream response body was incomplete", head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: aborted, status: 200, content_type: "image/png", state: Gori::Store::FlowState::Aborted,
        error: "upstream response body was incomplete", head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      static_ids(store).should be_empty
      visible = store.search(Gori::QL.hide_static, 10).map(&.id)
      visible.should contain(error)
      visible.should contain(aborted)
    end
  end
end
