require "../spec_helper"

describe "SQLite3::ResultSet#read on a TEXT column" do
  it "reads a value past an embedded NUL instead of stopping at it" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "GET", target: "/a\0b/tail", http_version: "HTTP/1.1",
        head: "GET /a\0b/tail HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      store.flow_rows([id]).first.target.should eq("/a\0b/tail")
    end
  end
end
