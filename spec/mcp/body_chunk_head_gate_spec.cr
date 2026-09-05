require "../spec_helper"

# `Serialize.emit_head_base64` states the rule the byte-exact head falls under: "base64 is
# encoding, not redaction … redacting INSIDE the base64 is not an option — it would no longer
# be the bytes", so it withholds the raw head unless the caller passes `include_sensitive`.
# `get_response_body_chunk{part:"request"}` pages exactly those bytes and carried no such
# gate — it had no `include_sensitive` argument at all — so `get_flow` answering
# `authorization: [REDACTED]` and the chunk tool handing back the whole Bearer token were two
# readings of one stored flow.

private def call_json(store, name, args : String) : JSON::Any
  tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
  r = tools.call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_request(store, head : String, body : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "POST", target: "/v1/me", http_version: "HTTP/1.1",
    head: head.to_slice, body: body.to_slice, source: Gori::FlowSource::Kind::Proxy))
end

private def seed_authed_flow(store) : Int64
  seed_request(store,
    "POST /v1/me HTTP/1.1\r\nHost: api.test\r\nauthorization: Bearer s3cr3t-token\r\nContent-Length: 4\r\n\r\n",
    "body")
end

describe "MCP get_response_body_chunk request head" do
  it "withholds a head carrying a credential, and says it did" do
    with_store do |store|
      id = seed_authed_flow(store)
      j = call_json(store, "get_response_body_chunk", %({"flow_id":#{id},"part":"request"}))
      j["text"].as_s.should_not contain("s3cr3t-token")
      j["head_omitted"].as_bool.should be_true
      j["head_omitted_note"].as_s.should contain("include_sensitive")
      # What is left is the body alone, and the byte counts describe it.
      j["text"].as_s.should eq("body")
      j["total_bytes"].as_i.should eq(4)
    end
  end

  it "pages the whole message when the caller opts in" do
    with_store do |store|
      id = seed_authed_flow(store)
      j = call_json(store, "get_response_body_chunk",
        %({"flow_id":#{id},"part":"request","include_sensitive":true}))
      j["text"].as_s.should contain("s3cr3t-token")
      j.as_h.has_key?("head_omitted").should be_false
    end
  end

  it "leaves a head with nothing to withhold exactly as it was" do
    with_store do |store|
      id = seed_request(store,
        "POST /plain HTTP/1.1\r\nHost: api.test\r\nContent-Length: 4\r\n\r\n", "body")
      j = call_json(store, "get_response_body_chunk", %({"flow_id":#{id},"part":"request"}))
      j["text"].as_s.should start_with("POST /plain HTTP/1.1")
      j.as_h.has_key?("head_omitted").should be_false
    end
  end

  it "gates a repeater's stored request the same way" do
    with_store do |store|
      req = "GET /x HTTP/1.1\r\nHost: api.test\r\ncookie: session=abc123\r\n\r\n"
      rid = store.insert_repeater(target: "https://api.test", request: req.to_slice,
        http2: false, auto_cl: true, flow_id: nil, position: 0)
      j = call_json(store, "get_response_body_chunk", %({"repeater_id":#{rid},"part":"request"}))
      j["text"].as_s.should_not contain("session=abc123")
      j["head_omitted"].as_bool.should be_true
    end
  end
end
