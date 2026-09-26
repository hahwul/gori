require "../spec_helper"

# The request-only read behind a History mine's seed names (#1231): the request's head and
# body, and never the response BLOB `get_flow` would materialize alongside them.
describe "Store#request_parts" do
  it "returns the request head and body, byte-exact, and nil for a missing flow" do
    with_store do |store|
      head = "POST /a HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "POST", target: "/a", http_version: "HTTP/1.1",
        head: head, body: Bytes[0x78, 0x3d, 0xff], source: Gori::FlowSource::Kind::Proxy))
      parts = store.request_parts(id) || raise "no parts for #{id}"
      parts[0].should eq(head)
      parts[1].should eq(Bytes[0x78, 0x3d, 0xff])
      store.request_parts(9999_i64).should be_nil
    end
  end

  it "reads a bodiless request as no body bytes" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "GET", target: "/", http_version: "HTTP/1.1",
        head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      parts = store.request_parts(id) || raise "no parts for #{id}"
      (parts[1] || Bytes.empty).should be_empty
    end
  end
end
