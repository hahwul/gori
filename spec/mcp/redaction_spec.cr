require "../spec_helper"
require "../support/mcp_harness"

# `get_flow` under a redaction profile (#1035). An agent transcript is the case the issue names
# first and the one gori has least control over once the bytes leave, so the read tool an agent
# uses hands back the sanitized derivative when the project redacts by default — and says so.
private def with_redacting_project(&)
  with_store do |store|
    before = Gori::Redact.salt
    Gori::Redact.salt = "spec-salt"
    Gori::Redact::Policy.write_project_scope(store,
      Gori::Redact::Policy::ProjectScope.new(default: true))
    begin
      yield store
    ensure
      Gori::Redact.salt = before
    end
  end
end

private def json_flow(store, request : String, response : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "POST", target: "/login", http_version: "HTTP/1.1",
    head: "POST /login HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: request.to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: response.to_slice, content_type: "application/json"))
  id
end

private def get_flow(store, id : Int64, include_sensitive = false) : JSON::Any
  args = include_sensitive ? %({"id":#{id},"include_sensitive":true}) : %({"id":#{id}})
  responses = mcp_drive(store,
    %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}),
    %({"jsonrpc":"2.0","method":"notifications/initialized"}),
    %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_flow","arguments":#{args}}}))
  mcp_tool_payload(responses.find { |r| r["id"]?.try(&.as_i?) == 2 }.not_nil!)
end

describe "MCP get_flow body redaction" do
  it "returns the captured bytes, and no body_redaction field, when nothing turns it on" do
    with_store do |store|
      id = json_flow(store, %({"password":"pw"}), %({"token":"t"}))
      payload = get_flow(store, id)
      payload["request_body"]["text"].as_s.should eq %({"password":"pw"})
      payload["body_redaction"]?.should be_nil
    end
  end

  it "sanitizes both bodies and says which profile ran and what it did not look at" do
    with_redacting_project do |store|
      id = json_flow(store, %({"password":"pw"}), %({"token":"t"}))
      payload = get_flow(store, id)
      payload["request_body"]["text"].as_s
        .should eq %({"password":"#{Gori::Redact.placeholder("pw")}"})
      payload["response_body"]["text"].as_s
        .should eq %({"token":"#{Gori::Redact.placeholder("t")}"})
      note = payload["body_redaction"]
      note["profile"].as_s.should eq "default"
      note["bodies_redacted"].as_i.should eq 2
      note["websocket_frames_redacted"].as_i.should eq 0
      note["applies_to"].as_s.should contain "Heads, URLs and query strings are NOT redacted"
    end
  end

  # #1394's smaller default body points at get_response_body_chunk, which pages the EXACT
  # stored bytes — so under a profile get_flow keeps the full default rather than sending the
  # agent past a sanitized 8 KB to the unredacted rest.
  it "does not cut a redacted body at the default cap or point at the unredacted chunk tool" do
    with_redacting_project do |store|
      long = %({"token":"t","pad":"#{"p" * 20_000}"})
      id = json_flow(store, %({"a":1}), long)
      body = get_flow(store, id)["response_body"]
      body["text"].as_s.size.should be > Gori::MCP::Tools::AUTO_BODY_BYTES
      body.as_h.has_key?("more").should be_false
    end
  end

  it "turns body redaction off with include_sensitive, along with the header redaction" do
    with_redacting_project do |store|
      id = json_flow(store, %({"password":"pw"}), %({"token":"t"}))
      payload = get_flow(store, id, include_sensitive: true)
      payload["request_body"]["text"].as_s.should eq %({"password":"pw"})
      payload["body_redaction"]?.should be_nil
    end
  end

  it "sanitizes a WebSocket transcript's frames and counts them separately" do
    with_redacting_project do |store|
      id = mcp_seed_flow(store, "h.test", "GET", "/ws", 101)
      store.insert_ws_message(id, "out", 1, %({"token":"t1"}).to_slice)
      store.insert_ws_message(id, "in", 1, %({"ok":true}).to_slice)
      payload = get_flow(store, id)
      payload["body_redaction"]["websocket_frames_redacted"].as_i.should eq 1
      frames = payload["ws_messages"]["messages"].as_a
      frames[0]["text"].as_s.should eq %({"token":"#{Gori::Redact.placeholder("t1")}"})
      frames[1]["text"].as_s.should eq %({"ok":true})
    end
  end

  it "leaves the stored flow alone, so the exact bytes stay pageable" do
    with_redacting_project do |store|
      id = json_flow(store, %({"password":"pw"}), %({"token":"t"}))
      get_flow(store, id)
      String.new(store.get_flow(id).not_nil!.request_body.not_nil!).should eq %({"password":"pw"})
    end
  end
end

# The Repeater read tool applies the same profile: a request there is authored, but the
# credential in it came from the traffic.
describe "MCP get_repeater_context body redaction" do
  it "sanitizes the stored request and last response body, and says so" do
    with_redacting_project do |store|
      req = "POST /login HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n{\"password\":\"pw\"}"
      rid = store.insert_repeater("https://h.test", req.to_slice, false, true, nil, 0)
      store.update_repeater_response(rid, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
        %({"token":"t"}).to_slice, nil, 1_i64, request_sha256: nil)
      args = {id: rid, include_content: true, include_response_body: true}
      resp = mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":#{args.to_json}}}))
      payload = mcp_tool_payload(resp.find! { |r| r["id"]? == 2 })
      session = payload["sessions"][0]
      session["request"].as_s.should contain %({"password":"#{Gori::Redact.placeholder("pw")}"})
      session["last_response_body"].as_s.should eq %({"token":"#{Gori::Redact.placeholder("t")}"})
      payload["body_redaction"]["bodies_redacted"].as_i.should eq 2

      sensitive = {id: rid, include_content: true, include_response_body: true, include_sensitive: true}
      resp = mcp_drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_repeater_context","arguments":#{sensitive.to_json}}}))
      payload = mcp_tool_payload(resp.find! { |r| r["id"]? == 3 })
      payload["sessions"][0]["last_response_body"].as_s.should eq %({"token":"t"})
      payload["body_redaction"]?.should be_nil
    end
  end

  # A typed request ends its lines in a bare LF; one the profile leaves alone is shown exactly
  # as stored, since the sanitized copy's head is reframed and an agent writes this text back.
  it "redacts a bare-LF request, and leaves a request with nothing to redact byte-exact" do
    with_redacting_project do |store|
      typed = store.insert_repeater("https://h.test",
        "POST /a HTTP/1.1\nHost: h.test\nContent-Type: application/json\n\n{\"password\":\"pw\"}".to_slice, false, true, nil, 0)
      probe = "POST /b HTTP/1.1\r\nHost: h.test\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
      plain = store.insert_repeater("https://h.test", probe.to_slice, false, false, nil, 1)
      [{typed, %("password":"#{Gori::Redact.placeholder("pw")}")}, {plain, probe}].each do |(rid, want)|
        args = {id: rid, include_content: true}
        resp = mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":#{args.to_json}}}))
        mcp_tool_payload(resp.find! { |r| r["id"]? == 2 })["sessions"][0]["request"].as_s.should contain(want)
      end
    end
  end
end
