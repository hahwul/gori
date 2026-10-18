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

describe Gori::Store do
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
end
