require "../spec_helper"

# `get_response_body_chunk` exists to page a body too large to inline, and it already draws
# this exact distinction twice: an offset past the end is flagged rather than answered as a
# final read, and a decoded view that hits the decompression ceiling sets `decode_capped`
# "so a caller knows more decoded data may exist". It never learned about the cut that
# happens FIRST and discards the most — the proxy's capture cap, recorded per row as
# `response_body_truncated`. So a 2.5 GB transfer stored as its first 2 KB paged to the end
# and answered `complete:true`, telling an agent it held a body of which gori kept 0.00008%.

private def chunk(tools : Gori::MCP::Tools, args : String) : JSON::Any
  r = tools.call("get_response_body_chunk", JSON.parse(args))
  fail "get_response_body_chunk errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_body(store, body : String, truncated : Bool) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/dump", http_version: "HTTP/1.1",
    head: "GET /dump HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    body: body.to_slice, body_truncated: truncated))
  id
end

describe "get_response_body_chunk completeness" do
  it "keeps `complete` false at the end of a body the capture cap cut" do
    with_store do |store|
      id = seed_body(store, "0123456789", truncated: true)
      tools = tools_for(store)

      last = chunk(tools, %({"flow_id":#{id},"offset":5,"limit":64}))
      last["returned_bytes"].as_i.should eq(5)
      last["total_bytes"].as_i.should eq(10) # the STORED total, all of it returned
      last["next_offset"].raw.should be_nil  # nothing further to page
      last["complete"].as_bool.should be_false
      last["source_truncated"].as_bool.should be_true
      last["source_truncated_warning"].as_s.should contain("capture cap")
      last["source_truncated_warning"].as_s.should contain("send_request")
    end
  end

  it "still completes a body that was captured whole" do
    with_store do |store|
      id = seed_body(store, "0123456789", truncated: false)
      whole = chunk(tools_for(store), %({"flow_id":#{id},"offset":0,"limit":64}))
      whole["complete"].as_bool.should be_true
      whole.as_h.has_key?("source_truncated").should be_false
    end
  end

  it "reports the cut on a paged REQUEST body too" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
        method: "POST", target: "/upload", http_version: "HTTP/1.1",
        head: "POST /upload HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        body: "abcdef".to_slice, body_truncated: true,
        source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))

      page = chunk(tools_for(store), %({"flow_id":#{id},"part":"request","offset":0,"limit":9999}))
      page["complete"].as_bool.should be_false
      page["source_truncated"].as_bool.should be_true
      page["source_truncated_warning"].as_s.should contain("request")
    end
  end

  # A repeater response is a send this process made and kept whole — nothing capped it on the
  # way in, so it must not inherit the warning.
  it "does not claim a cut on a repeater response" do
    with_store do |store|
      rid = store.insert_repeater("https://acme.test", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "hello".to_slice, nil, 1_i64)

      page = chunk(tools_for(store), %({"repeater_id":#{rid},"offset":0,"limit":64}))
      page["complete"].as_bool.should be_true
      page.as_h.has_key?("source_truncated").should be_false
    end
  end
end
