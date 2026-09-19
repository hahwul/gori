require "../spec_helper"
require "../support/mcp_harness"

describe "MCP reply_to_operator (#1090)" do
  it "writes the reply row and hands back the summary line" do
    with_store do |store|
      t = tools_for(store)
      r = t.call("reply_to_operator", JSON.parse(%({"summary":"Done: 3 endpoints checked, 1 IDOR","detail":"GET /api/orders/{id} returns other users' orders","level":"success","in_reply_to":12})))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["ok"].should be_true
      j["summary"].should eq("Done: 3 endpoints checked, 1 IDOR")
      reply = store.agent_replies_after(0, 10).rows.first
      reply.level.should eq("success")
      reply.in_reply_to.should eq(12)
      reply.pid.should eq(Process.pid.to_i64)
      reply.detail.not_nil!.should contain("/api/orders")
    end
  end

  it "refuses without a summary" do
    with_store do |store|
      r = tools_for(store).call("reply_to_operator", JSON.parse(%({"detail":"only a body"})))
      r.is_error.should be_true
      r.field.should eq("summary")
    end
  end

  it "is listed with its schema and named in the handshake" do
    with_store do |store|
      lines = mcp_drive(store,
        %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
        %({"jsonrpc":"2.0","method":"notifications/initialized"}),
        %({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
      lines.find { |l| l["id"]? == 1 }.not_nil!["result"]["instructions"].as_s.should contain("reply_to_operator")
      tools = lines.find { |l| l["id"]? == 2 }.not_nil!["result"]["tools"].as_a
      t = tools.find { |x| x["name"] == "reply_to_operator" }.not_nil!
      t["inputSchema"]["required"].as_a.map(&.as_s).should eq(["summary"])
    end
  end
end
