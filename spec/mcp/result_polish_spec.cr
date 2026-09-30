require "../spec_helper"
require "../support/mcp_harness"
require "socket"

# #1395: the independent error and result fixes from dogfooding the MCP surface. The job-stop
# and wrong-kind job id halves live in job_stop_status_spec.cr beside the stop contract.

# A local origin that answers every request with a body long enough for the default cap.
private def start_big_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        Gori::Proxy::Codec::Http1.read_head(c)
        body = "b" * 20_000
        c << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        c.flush
        c.close
      end
    end
  end
  port
end

describe "MCP result polish (#1395)" do
  it "names every seed source when create_repeater is given none" do
    with_store do |store|
      r = tools_for(store).call("create_repeater", JSON.parse("{}"))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.field.should eq("flow_id")
      %w[flow_id issue_id curl target request].each { |src| r.text.should contain(src) }
    end
  end

  it "answers the formerly bare-array tools as {items}" do
    with_store do |store|
      tools = tools_for(store)
      %w[list_host_overrides list_rule_presets list_sitemap_tags oast_presets].each do |name|
        mcp_ok_json(tools, name, "{}")["items"].as_a
      end
      jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlc2lnbmF0dXJlc2lnbmF0dXJl"
      mcp_ok_json(tools, "jwt_attacks", {token: jwt}.to_json)["items"].as_a.should_not be_empty
    end
  end

  it "says when preview_rule's defaulted part left bodies unscanned, and only then" do
    with_store do |store|
      tools = tools_for(store)
      defaulted = mcp_ok_json(tools, "preview_rule", %({"pattern":"hello","target":"response"}))
      defaulted["part"].as_s.should eq("head")
      defaulted["part_defaulted"].as_bool.should be_true
      defaulted["part_note"].as_s.should contain("part:\"body\"")
      explicit = mcp_ok_json(tools, "preview_rule", %({"pattern":"hello","target":"response","part":"head"}))
      explicit.as_h.has_key?("part_defaulted").should be_false
    end
  end

  it "links a send_request agent action to the flow it recorded, without the request line" do
    with_store do |store|
      port = start_big_origin
      tools = tools_for(store)
      res = mcp_ok_json(tools, "send_request",
        %({"url":"http://127.0.0.1:#{port}/secret?token=abc","allow_unscoped":true}))
      flow_id = res["recorded_flow_id"].as_i64
      event = store.events_after(0_i64, 50).find { |e| e.kind == "agent_action" && e.payload == "send_request" }.not_nil!
      event.flow_id.should eq(flow_id)
      event.message.should contain("http://127.0.0.1:#{port} → 200")
      event.message.should_not contain("token=abc")
    end
  end

  it "cuts a recorded send_request's body at the default cap with a pointer, and inlines an unrecorded one whole" do
    with_store do |store|
      port = start_big_origin
      tools = tools_for(store)
      recorded = mcp_ok_json(tools, "send_request", %({"url":"http://127.0.0.1:#{port}/","allow_unscoped":true}))
      body = recorded["body"]
      body["text"].as_s.size.should eq(Gori::MCP::Tools::AUTO_BODY_BYTES)
      body["more"].as_s.should contain("flow_id: #{recorded["recorded_flow_id"].as_i64}")

      # Nothing to page from afterwards, so nothing is cut.
      unrecorded = mcp_ok_json(tools, "send_request",
        %({"url":"http://127.0.0.1:#{port}/","allow_unscoped":true,"record_history":false}))
      unrecorded["body"]["text"].as_s.size.should eq(20_000)
      unrecorded["body"].as_h.has_key?("more").should be_false
    end
  end
end
