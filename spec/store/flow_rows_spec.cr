require "../spec_helper"

# The id-scoped row read behind MCP `list_history{ids}` (#1091) — the missing middle between
# `flow_row` (one id) and `ids_matching` (an id-scoped MATCH, no rows).
describe "Store#flow_rows" do
  it "returns the rows that exist and simply omits the ones that do not" do
    with_store do |store|
      ids = (1..3).map do |i|
        store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: i.to_i64, scheme: "https", host: "acme.test", port: 443,
          method: "GET", target: "/#{i}", http_version: "HTTP/1.1",
          head: "GET /#{i} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
          source: Gori::FlowSource::Kind::Proxy))
      end
      # Unordered by design — the CALLER knows what order to put them back in (for a marked
      # set that is the operator's own screen order, which no ORDER BY here could reproduce).
      store.flow_rows([ids[0], 9999_i64, ids[2]]).map(&.id).sort!.should eq([ids[0], ids[2]])
      store.flow_rows([ids[1], ids[1]]).map(&.id).should eq([ids[1]])
      store.flow_rows([] of Int64).should be_empty
    end
  end
end

# A foreign or hand-edited row (an imported project archive) can hold sizes whose SUM leaves
# Int64; the read used to raise, which took every list holding the row down with it.
describe "Store#flow_row sizes" do
  it "saturates a request + response size past Int64 instead of raising" do
    path = File.tempname("gori-flow-size", ".db")
    begin
      store = Gori::Store.open(path)
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      store.close
      DB.open("sqlite3:#{path}") do |db|
        db.exec("UPDATE flows SET request_size = ?, response_size = ? WHERE id = ?", Int64::MAX, Int64::MAX, id)
      end
      reopened = Gori::Store.open(path)
      begin
        reopened.flow_row(id).not_nil!.size.should eq(Int64::MAX)
      ensure
        reopened.close
      end
    ensure
      [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete?(f) }
    end
  end
end
