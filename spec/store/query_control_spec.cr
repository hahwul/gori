require "../spec_helper"

private class ObservedQueryControl < Gori::Store::QueryControl
  getter started = Channel(Nil).new(1)
  @announced = false

  def progress : Int32
    unless @announced
      @announced = true
      @started.send(nil)
    end
    super
  end
end

private def seed_query_flow(store : Gori::Store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "example.test", port: 443,
    method: "POST", target: "/a", http_version: "HTTP/1.1",
    head: "POST /a HTTP/1.1\r\nHost: example.test\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: "ab\0needle".to_slice, source: Gori::FlowSource::Kind::Proxy))
end

# A long, deterministic read without a huge fixture or dependence on disk speed.
private def expensive_query : Gori::QL::Filter
  Gori::QL::Filter.new("(WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT sum(x) FROM n) = 0", [] of DB::Any)
end

describe Gori::Store::QueryControl do
  it "preserves search semantics and cursors, including NUL-safe body terms" do
    with_store do |store|
      id = seed_query_flow(store)
      store.index_pending!
      ["", "example", "host:example", "path:/a", "body:a", "body:ab", "body:needle",
       "body~needle", "header:Host", "NOT (host:other OR path:/missing)", "src:proxy"].each do |query|
        filter = Gori::QL.parse(query)
        [nil, id, id + 1].each do |before|
          store.search(filter, 10, before, control: Gori::Store::QueryControl.new).map(&.id)
            .should eq(store.search(filter, 10, before).map(&.id))
        end
        store.search(filter, 10, since_id: 0_i64, control: Gori::Store::QueryControl.new).map(&.id)
          .should eq(store.search(filter, 10, since_id: 0_i64).map(&.id))
      end
      store.distinct_hosts(prefix: "EX", control: Gori::Store::QueryControl.new)
        .should eq(store.distinct_hosts(prefix: "EX"))
    end
  end

  it "yields during a no-match read, cancels distinctly, and leaves the connection reusable" do
    with_store do |store|
      id = seed_query_flow(store)
      control = ObservedQueryControl.new
      result = Channel(Symbol).new(1)
      spawn do
        store.search(expensive_query, 10, control: control)
        result.send(:completed)
      rescue Gori::Store::QueryCancelled
        result.send(:cancelled)
      end
      receive_within(control.started)
      control.cancel
      receive_within(result).should eq(:cancelled)
      store.search(Gori::QL::EMPTY, 10).map(&.id).should eq([id])
      store.search(expensive_query, 10, raise_on_error: true).should be_empty
      seed_query_flow(store).should be > id # the writer continues too
    end
  end

  it "cancels active reads before closing their pool" do
    with_store do |store|
      seed_query_flow(store)
      control = ObservedQueryControl.new
      done = Channel(Nil).new(1)
      spawn do
        store.search(expensive_query, 10, control: control)
      rescue Gori::Store::QueryCancelled
        done.send(nil)
      end
      receive_within(control.started)
      store.close
      receive_within(done)
      control.cancelled?.should be_true
    end
  end

  it "keeps a shared control registered until all of its reads have finished" do
    with_store do |store|
      id = seed_query_flow(store)
      control = ObservedQueryControl.new
      done = Channel(Nil).new(1)
      spawn do
        store.search(expensive_query, 10, control: control)
      rescue Gori::Store::QueryCancelled
        done.send(nil)
      end
      receive_within(control.started)
      # This finishes while the first read is suspended inside SQLite.
      store.search(Gori::QL::EMPTY, 10, control: control).map(&.id).should eq([id])
      store.close
      receive_within(done)
      control.cancelled?.should be_true
    end
  end

  it "does not swallow pre-cancellation or install a handler after a preparation error" do
    with_store do |store|
      control = Gori::Store::QueryControl.new
      control.cancel
      expect_raises(Gori::Store::QueryCancelled) { store.search(Gori::QL::EMPTY, 10, control: control) }
      expect_raises(Gori::Store::QueryCancelled) { store.distinct_hosts(control: control) }
      broken = Gori::QL::Filter.new("host GLOB (", [] of DB::Any)
      expect_raises(SQLite3::Exception) do
        store.search(broken, 10, raise_on_error: true, control: Gori::Store::QueryControl.new)
      end
      store.search(Gori::QL::EMPTY, 10).should be_empty
    end
  end
end
