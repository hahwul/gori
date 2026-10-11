require "../spec_helper"

# #1588 — `Store#ws_messages(match:)` narrows one flow's transcript in SQL, with the QL `ws`
# term's own per-message predicate, so the narrowed list reaches messages older than any
# display window.
describe "Gori::Store#ws_messages with a match" do
  it "keeps only the matching messages, newest-limited, and counts them" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "ws.test", port: 443,
        method: "GET", target: "/s", http_version: "HTTP/1.1",
        head: "GET /s HTTP/1.1\r\nHost: ws.test\r\n\r\n".to_slice, body: nil,
        source: Gori::FlowSource::Kind::Proxy))
      store.insert_ws_message(id, "out", 1, "hit-old".to_slice)
      30.times { |i| store.insert_ws_message(id, "in", 1, "noise #{i}".to_slice) }
      store.insert_ws_message(id, "in", 1, "[gori] hit notice".to_slice)
      store.insert_ws_message(id, "in", 1, "HIT-new".to_slice)

      match = Gori::QL.ws_match("hit").not_nil!
      store.ws_messages(id, match: match).map { |m| String.new(m.payload) }.should eq(["hit-old", "HIT-new"])
      # A window smaller than the transcript still reaches the oldest match.
      store.ws_messages(id, 5, match).map { |m| String.new(m.payload) }.should eq(["hit-old", "HIT-new"])
      store.ws_messages(id, 1, match).map { |m| String.new(m.payload) }.should eq(["HIT-new"])
      store.ws_messages_after(id, 0_i64, 1, match).map { |m| String.new(m.payload) }.should eq(["hit-old"])
      store.count_ws_messages(id, match).should eq(2)
      store.count_ws_messages(id).should eq(33)
      store.ws_messages(id, 5).size.should eq(5) # no match = the window, unchanged
    end
  end
end
