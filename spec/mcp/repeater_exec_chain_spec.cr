require "../spec_helper"

# A `§v¦exec:…§` marker in a stored Repeater request runs its command when the operator sends the
# tab. An agent may write requests but not arm commands, so `create_repeater` / `update_repeater`
# ask the `exec` gate, as `create_fuzzer` does of a template.
private EXEC_REQUEST  = "GET /?a=§v¦exec:/usr/bin/true§ HTTP/1.1\r\nHost: h\r\n\r\n"
private PLAIN_REQUEST = "GET /?a=v HTTP/1.1\r\nHost: h\r\n\r\n"

private def repeater_args(request : String) : JSON::Any
  JSON.parse({"target" => "http://127.0.0.1:9", "request" => request}.to_json)
end

describe "MCP Repeater exec chains" do
  it "refuses to create one under exec off or ask, and stores nothing" do
    with_store do |store|
      off = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, denied_permissions: Set{"exec"})
      off.call("create_repeater", repeater_args(EXEC_REQUEST)).error_code.should eq("TOOL_DISABLED")
      ask = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, asked_permissions: Set{"exec"})
      ask.call("create_repeater", repeater_args(EXEC_REQUEST)).error_code.should eq("APPROVAL_PENDING")
      store.repeaters_mcp.should be_empty
      # The gate is about the command: a plain request and an allowed exec are both written.
      off.call("create_repeater", repeater_args(PLAIN_REQUEST)).is_error.should be_false
      tools_for(store).call("create_repeater", repeater_args(EXEC_REQUEST)).is_error.should be_false
      store.repeaters_mcp.size.should eq(2)
    end
  end

  it "refuses to write one into an existing session, but lets a rename through" do
    with_store do |store|
      plain = tools_for(store).call("create_repeater", repeater_args(PLAIN_REQUEST))
      plain_id = JSON.parse(plain.text)["id"].as_i64
      armed = tools_for(store).call("create_repeater", repeater_args(EXEC_REQUEST))
      armed_id = JSON.parse(armed.text)["id"].as_i64
      off = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, denied_permissions: Set{"exec"})
      off.call("update_repeater", JSON.parse({"id" => plain_id, "request" => EXEC_REQUEST}.to_json))
        .error_code.should eq("TOOL_DISABLED")
      String.new(store.get_repeater(plain_id).not_nil!.request).should eq(PLAIN_REQUEST)
      off.call("update_repeater", JSON.parse({"id" => armed_id, "name" => "renamed"}.to_json)).is_error.should be_false
    end
  end

  it "refuses, per flow, to seed a session whose captured request holds one" do
    with_store do |store|
      seed = ->(path : String) do
        store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
          method: "GET", target: path, http_version: "HTTP/1.1",
          head: "GET #{path} HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Import))
      end
      armed = seed.call("/?a=§v¦exec:/usr/bin/true§")
      plain = seed.call("/plain")
      off = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, denied_permissions: Set{"exec"})
      r = off.call("create_repeaters", JSON.parse({"flow_ids" => [armed, plain]}.to_json))
      r.is_error.should be_false
      reply = JSON.parse(r.text)
      reply["created"].as_a.map(&.["flow_id"].as_i64).should eq([plain])
      reply["failed"].as_a.map(&.["flow_id"].as_i64).should eq([armed])
      reply["failed"][0]["reason"].as_s.should contain("runs a local command")
      store.repeaters_mcp.size.should eq(1)
      # Allowed, the capture is seeded as it is.
      JSON.parse(tools_for(store).call("create_repeaters", JSON.parse({"flow_ids" => [armed]}.to_json)).text)["created_count"].should eq(1)
    end
  end
end
