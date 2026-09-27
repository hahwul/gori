require "../spec_helper"

# The response-only read behind MCP `get_response_body_chunk`: head, body and the capture-cut
# flag, without the request BLOBs `get_flow` would materialize for every page.
private def seed_request(store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "POST", target: "/a", http_version: "HTTP/1.1",
    head: "POST /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: Bytes.new(64, 0x61_u8),
    source: Gori::FlowSource::Kind::Proxy))
end

describe "Store#response_parts" do
  it "returns the response head, body and truncation flag byte-exact, nil for a missing flow" do
    with_store do |store|
      id = seed_request(store)
      head = "HTTP/1.1 200 OK\r\n\r\n".to_slice
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: head, body: Bytes[0x7b, 0xff, 0x7d], body_truncated: true))
      parts = store.response_parts(id) || raise "no parts for #{id}"
      parts[0].should eq(head)
      parts[1].should eq(Bytes[0x7b, 0xff, 0x7d])
      parts[2].should be_true
      store.response_parts(9999_i64).should be_nil
    end
  end

  it "reads a flow that has no response yet as a nil head and body" do
    with_store do |store|
      id = seed_request(store)
      parts = store.response_parts(id) || raise "no parts for #{id}"
      parts[0].should be_nil
      parts[1].should be_nil
      parts[2].should be_false
    end
  end
end
