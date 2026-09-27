require "../spec_helper"

private def capture(i : Int32) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: i.to_i64, scheme: "http", host: "a.test", port: 80, method: "GET",
    target: "/p#{i}", http_version: "HTTP/1.1",
    head: "GET /p#{i} HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
end

# The writer's WAL pragmas are per CONNECTION, and the writer takes a fresh one from the pool
# whenever it retires a broken one, so they are asserted on the connection it actually holds.
describe "Gori::Store writer connection WAL pragmas" do
  it "sets the autocheckpoint interval and the WAL size limit on the writer's connection" do
    with_store do |store|
      store.insert_flow(capture(1)).should be > 0 # the writer has checked out its connection
      conn = store.@writer_conn.not_nil!
      conn.scalar("PRAGMA wal_autocheckpoint").as(Int64).should eq(Gori::Store::WAL_AUTOCHECKPOINT_PAGES)
      conn.scalar("PRAGMA journal_size_limit").as(Int64).should eq(Gori::Store::WAL_SIZE_LIMIT)
    end
  end
end
