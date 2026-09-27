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

  it "shrinks the page cache on the writer's connection only, leaving readers at 64 MiB" do
    with_store do |store|
      store.insert_flow(capture(1)).should be > 0
      writer = store.@writer_conn.not_nil!
      writer.scalar("PRAGMA cache_size").as(Int64).should eq(Gori::Store::WRITER_CACHE_KIB)
      # A reader checked out while the writer holds its own connection is a different one.
      store.@db.using_connection do |reader|
        reader.should_not be(writer)
        reader.scalar("PRAGMA cache_size").as(Int64).should eq(-64000)
      end
    end
  end
end
