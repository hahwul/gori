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
