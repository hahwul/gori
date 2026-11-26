require "../../spec_helper"

# A bare list_history word over SQLite's LIKE pattern limit (50000 bytes) failed the store read
# with "LIKE or GLOB pattern too complex", and history_read_failed coded every store failure
# INTERNAL, though no retry can fix this one. Genuine store failures keep INTERNAL.
describe "MCP list_history oversized bare word" do
  it "refuses it as INVALID_ARGUMENT on field query, and the server keeps answering" do
    with_store do |store|
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: 1,
        method: "GET", target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      t = tools_for(store)
      r = t.call("list_history", JSON::Any.new({"query" => JSON::Any.new("A" * 60_000)}))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("query")
      t.call("list_history", JSON.parse(%({"query":"x"}))).is_error.should be_false
    end
  end
end
