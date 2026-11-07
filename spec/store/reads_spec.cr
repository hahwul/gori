require "../spec_helper"

private def seed_count_flow(store : Gori::Store, host : String, status : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice))
  id
end

private def seed_ranked_flow(store : Gori::Store, host : String, dur_us : Int64?, size : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  return id unless dur_us # no response yet
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: Bytes.new(size),
    body_size: size.to_i64, duration_us: dur_us))
  id
end

describe Gori::Store do
  # #1680: a row feed says why a flow failed without a `show` per errored flow — filled by
  # `with_errors`, never by `SELECT_ROW` (the list index does not carry `error`).
  it "fills an errored flow's stored error on its row, and nil on any other" do
    with_store do |store|
      ok = seed_count_flow(store, "a.test", 200)
      failed = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "b.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: b.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: failed, status: 0, head: Bytes.empty, state: Gori::Store::FlowState::Error, error: "upstream connect failed: b.test:443"))
      rows = store.recent_flows(10)
      rows.find! { |r| r.id == failed }.error.should be_nil # the list read leaves it alone
      filled = store.with_errors(rows)
      filled.map(&.id).should eq(rows.map(&.id))
      filled.find! { |r| r.id == failed }.error.should eq("upstream connect failed: b.test:443")
      filled.find! { |r| r.id == ok }.error.should be_nil
      store.get_flow(failed).not_nil!.row.error.should eq("upstream connect failed: b.test:443")
    end
  end

  # #1648: `count_matching` is `search` without the rows, so the number an agent or a script
  # asks for and the pages it would otherwise walk can never disagree.
  describe "#count_matching" do
    it "counts what search would return, past any page size, and every flow for EMPTY" do
      with_store do |store|
        7.times { seed_count_flow(store, "a.test", 500) }
        3.times { seed_count_flow(store, "b.test", 200) }
        filter = Gori::QL.parse("status:500")
        store.count_matching(filter).should eq(7)
        store.count_matching(filter).should eq(store.search(filter, 100).size)
        store.count_matching(Gori::QL.parse("host:nowhere.test")).should eq(0)
        store.count_matching(Gori::QL::EMPTY).should eq(10)
      end
    end

    it "raises on a query SQLite refuses to run instead of answering 0" do
      with_store do |store|
        seed_count_flow(store, "a.test", 200)
        broken = Gori::QL::Filter.new("no_such_column = 1", [] of DB::Any)
        expect_raises(Exception) { store.count_matching(broken) }
      end
    end
  end

  # The scan's id list: what `search` matches, oldest first, without materialising a row.
  describe "#flow_ids" do
    it "lists every matching id oldest first, and every flow for nil" do
      with_store do |store|
        ids = [seed_count_flow(store, "a.test", 200), seed_count_flow(store, "b.test", 500), seed_count_flow(store, "a.test", 500)]
        store.flow_ids(nil).should eq(ids)
        filter = Gori::QL.parse("host:a.test")
        store.flow_ids(filter).should eq(store.search(filter, 10).map(&.id).reverse!)
        store.flow_ids(filter).should eq([ids[0], ids[2]])
      end
    end
  end

  describe "#ranked" do
    it "returns the top flows by duration or response size, ties newest first, unanswered last" do
      with_store do |store|
        fast = seed_ranked_flow(store, "a.test", 5_000_i64, 900)
        slow = seed_ranked_flow(store, "a.test", 90_000_i64, 10)
        tie = seed_ranked_flow(store, "b.test", 90_000_i64, 20)
        pending = seed_ranked_flow(store, "a.test", nil, 0)
        store.ranked(nil, Gori::Store::Rank::Slowest, 10).map(&.id).should eq([tie, slow, fast, pending])
        store.ranked(nil, Gori::Store::Rank::Slowest, 1).map(&.id).should eq([tie])
        store.ranked(nil, Gori::Store::Rank::Largest, 1).map(&.id).should eq([fast])
        filter = Gori::QL.parse("host:a.test")
        store.ranked(filter, Gori::Store::Rank::Slowest, 2).map(&.id).should eq([slow, fast])
      end
    end
  end
end
