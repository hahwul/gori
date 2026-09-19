require "../spec_helper"
require "../support/mcp_harness"

describe "MCP operator_messages (#1090)" do
  it "returns what the operator said, marks it delivered, and cursors forward" do
    with_store do |store|
      m1 = store.post_agent_message("first", "all", "history", [1_i64])
      store.post_agent_message("not mine", "pid:123456789", nil)
      m2 = store.post_agent_message("second", "pid:#{Process.pid}", "issues")
      t = tools_for(store)
      r = t.call("operator_messages", JSON.parse("{}"))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["messages"].as_a.map(&.["text"]).should eq(["first", "second"])
      j["messages"][0]["from_tab"].should eq("history")
      j["messages"][0]["flow_ids"].as_a.map(&.as_i64).should eq([1_i64])
      j["messages"][1]["target"].should eq("pid:#{Process.pid}")
      j["messages"][0]["created_at_iso"].as_s.should contain("T")
      j["next_cursor"].as_i64.should eq(m2)
      j["marked_delivered"].should be_true
      # marked: a second call from the same cursor returns nothing new
      again = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)
      again["messages"].as_a.should be_empty
      again["next_cursor"].as_i64.should eq(m2)
      ds = store.agent_deliveries_after(0, 10)
      ds.map(&.message_id).should eq([m1, m2])
      ds.all? { |d| d.via == "poll" && d.ok }.should be_true
      # unless asked for the delivered ones too
      inc = JSON.parse(t.call("operator_messages", JSON.parse(%({"include_delivered":true}))).text)
      inc["messages"].as_a.size.should eq(2)
      # and the cursor keeps its place on an empty page
      JSON.parse(t.call("operator_messages", JSON.parse(%({"since":#{m2}}))).text)["next_cursor"].as_i64.should eq(m2)
    end
  end

  it "omits a message a live route already carried" do
    with_store do |store|
      m = store.post_agent_message("pushed already", "all", nil)
      store.record_agent_delivery(m, "socket", "claude-code pid 1", true)
      j = JSON.parse(tools_for(store).call("operator_messages", JSON.parse("{}")).text)
      j["messages"].as_a.should be_empty
      j["next_cursor"].as_i64.should eq(m)
    end
  end

  it "is listed with its schema" do
    with_store do |store|
      lines = mcp_drive(store,
        %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
        %({"jsonrpc":"2.0","method":"notifications/initialized"}),
        %({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
      tools = lines.find { |l| l["id"]? == 2 }.not_nil!["result"]["tools"].as_a
      op = tools.find { |t| t["name"] == "operator_messages" }.not_nil!
      op["inputSchema"]["properties"].as_h.keys.sort!.should eq(%w[include_delivered limit since])
    end
  end
end
