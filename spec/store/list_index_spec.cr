require "../spec_helper"

# Schema V37 adds `idx_flows_list`, a covering index over the History list projection. Its
# whole value is that a list page or a QL filter never reads a `flows` row — with large
# bodies those rows' late columns sit behind overflow chains. The thing that silently
# regresses is COVERAGE: a column added to `SELECT_ROW`, or a new QL term over a column the
# index lacks, sends every list read back to the table with no test failing on timing. So
# these pin the plan, not a duration.

private def query_plan(store : Gori::Store, sql : String, args : Array(DB::Any) = [] of DB::Any) : String
  plan = [] of String
  store.@db.query("EXPLAIN QUERY PLAN #{sql}", args: args) do |rs|
    rs.each { 3.times { rs.read }; plan << rs.read(String) }
  end
  plan.join(" | ")
end

# The statement `Store#search` runs for a filter (newest-first page, no cursor).
private def search_plan(store : Gori::Store, query : String) : String
  f = Gori::QL.parse(query)
  query_plan(store, "#{Gori::Store::SELECT_ROW} WHERE #{f.sql} ORDER BY id DESC LIMIT ?", f.args + [200] of DB::Any)
end

private def index_columns(store : Gori::Store, index : String) : Array(String)
  store.@db.query_all("SELECT name FROM pragma_index_info('#{index}') ORDER BY seqno", as: String)
end

private def list_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "list.test", port: 443, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: list.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

describe "History list covering index (schema V37)" do
  it "carries every column SELECT_ROW reads, with id leading" do
    with_store do |store|
      cols = index_columns(store, "idx_flows_list")
      cols.first.should eq("id")
      projected = Gori::Store::SELECT_ROW.split("FROM").first.sub("SELECT", "").split(',').map(&.strip)
      (projected - cols).should be_empty
    end
  end

  it "answers every recent_flows page from the index, in id order" do
    with_store do |store|
      sel = Gori::Store::SELECT_ROW
      [
        "#{sel} ORDER BY id DESC LIMIT 200",
        "#{sel} WHERE id < 5000 ORDER BY id DESC LIMIT 200",
        "#{sel} WHERE id > 5000 ORDER BY id ASC LIMIT 200",
      ].each do |sql|
        plan = query_plan(store, sql)
        plan.should contain("COVERING INDEX idx_flows_list")
        plan.should_not contain("TEMP B-TREE")
      end
    end
  end

  it "answers the projection filters from the index without a sort" do
    with_store do |store|
      ["host:api", "path:/admin", "url:example.com/api", "method:DELETE", "scheme:https",
       "src:repeater", "src:gori", "size:>1000", "reqsize:>1000", "respsize:>1mb", "dur:>800ms",
       "stub:true", "static:false", "-status:200", "proto:grpc", "proto:sse", "host~^cdn",
       "path~/v2/.*/items", "zzqxnomatch",
       # A two-sided status range is spelled `+status` so it does not take idx_flows_status
       # and sort every matching row (ql.cr's `status_cond`), and proto:ws carries one too.
       "status:2xx", "status:5xx", "proto:ws", "proto:http", "status:>=500"].each do |q|
        plan = search_plan(store, q)
        plan.should contain("COVERING INDEX idx_flows_list"), "#{q}: #{plan}"
        plan.should_not contain("TEMP B-TREE"), "#{q}: #{plan}"
      end
    end
  end

  it "keeps an exact status on its own index" do
    with_store do |store|
      search_plan(store, "status:500").should contain("INDEX idx_flows_status (status=?)")
    end
  end

  it "still reads a single flow by rowid" do
    with_store do |store|
      query_plan(store, "#{Gori::Store::SELECT_ROW} WHERE id = ?", [1_i64] of DB::Any)
        .should contain("INTEGER PRIMARY KEY (rowid=?)")
    end
  end

  it "migrates a V36 project to the index, rows unchanged" do
    path = File.tempname("gori-list-v37", ".db")
    begin
      store = Gori::Store.open(path)
      ids = (1..5).map { |i| store.insert_flow(list_request("/p/#{i}")) }
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: ids[2], status: 404,
        head: "HTTP/1.1 404 Not Found\r\n\r\n".to_slice, content_type: "text/html",
        state: Gori::Store::FlowState::Complete))
      store.flush
      before = store.recent_flows(10)
      store.@db.exec("DROP INDEX idx_flows_list")
      store.@db.exec("PRAGMA user_version = 36")
      store.close

      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        index_columns(store, "idx_flows_list").first.should eq("id")
        store.recent_flows(10).should eq(before)
        store.search(Gori::QL.parse("status:404"), 10).map(&.id).should eq([ids[2]])
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
