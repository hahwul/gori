require "../spec_helper"

private def io_request(target : String, original : Bytes? = nil) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "io.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: io.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy, intercept_original: original)
end

# A request edited at Intercept stores what went upstream in `flows` and what the client sent
# in `intercept_originals` (V44); the side row's existence is the "edited" flag (#1378).
describe "Store intercept originals (V44)" do
  original = "GET /?id=1 HTTP/1.1\r\nHost: io.test\r\n\r\n".to_slice

  it "keeps the pre-edit request beside an edited flow and flags every read of its row" do
    with_store do |store|
      edited = store.insert_flow(io_request("/?id=2", original))
      plain = store.insert_flow(io_request("/plain"))

      store.intercept_original(edited).should eq(original)
      store.intercept_original(plain).should be_nil

      store.flow_row(edited).not_nil!.intercept_edited?.should be_true
      store.flow_row(plain).not_nil!.intercept_edited?.should be_false
      store.get_flow(edited).not_nil!.row.intercept_edited?.should be_true
      store.get_flow(edited, body_max: 16).not_nil!.row.intercept_edited?.should be_true
      store.recent_flows(10).map { |r| {r.id, r.intercept_edited?} }.should eq([{plain, false}, {edited, true}])
      store.search(Gori::QL.parse("host:io.test"), 10).find!(&.id.==(edited)).intercept_edited?.should be_true
    end
  end

  it "goes with its flow on delete and on clear" do
    with_store do |store|
      a = store.insert_flow(io_request("/a", original))
      b = store.insert_flow(io_request("/b", original))

      store.delete_flow(a).should be_true
      store.intercept_original(a).should be_nil
      store.intercept_original(b).should eq(original)

      store.clear_flows.should be_true
      store.@db.scalar("SELECT COUNT(*) FROM intercept_originals").as(Int64).should eq(0)
    end
  end
end
