require "../spec_helper"
require "../support/mcp_harness"

describe "MCP operator_messages (#1090)" do
  it "returns what the operator said, marks it picked up, and cursors forward" do
    with_store do |store|
      t = tools_for(store)
      t.call("operator_messages", JSON.parse("{}")) # first call takes the floor = feed end (empty)
      m1 = store.post_agent_message("first", "all", "history", [1_i64])
      store.post_agent_message("not mine", "pid:123456789", nil)
      m2 = store.post_agent_message("second", "pid:#{Process.pid}", "issues")
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
      # marked: a second call returns nothing new and keeps its place
      again = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)
      again["messages"].as_a.should be_empty
      again["next_cursor"].as_i64.should eq(m2)
      ds = store.agent_deliveries_after(0, 10).rows
      ds.map(&.message_id).should eq([m1, m2])
      ds.all? { |d| d.via == "picked_up" && d.ok && d.pid == Process.pid.to_i64 }.should be_true
      # unless asked for the delivered ones too
      inc = JSON.parse(t.call("operator_messages", JSON.parse(%({"include_delivered":true}))).text)
      inc["messages"].as_a.size.should eq(2)
      # and the cursor keeps its place on an empty page
      JSON.parse(t.call("operator_messages", JSON.parse(%({"since":#{m2}}))).text)["next_cursor"].as_i64.should eq(m2)
    end
  end

  it "never replays what was said before this session bound the project" do
    with_store do |store|
      store.post_agent_message("yesterday", "all", nil)
      t = tools_for(store)
      j = JSON.parse(t.call("operator_messages", JSON.parse(%({"since":0}))).text)
      j["messages"].as_a.should be_empty
      store.post_agent_message("today", "all", nil)
      JSON.parse(t.call("operator_messages", JSON.parse(%({"since":0}))).text)["messages"].as_a.map(&.["text"]).should eq(["today"])
    end
  end

  it "still hands a broadcast to this session when another session got it live" do
    with_store do |store|
      t = tools_for(store)
      t.call("operator_messages", JSON.parse("{}"))
      m = store.post_agent_message("everyone", "all", nil)
      store.record_agent_delivery(m, "socket", "claude-code pid 1", true, pid: 1)
      j = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)
      j["messages"].as_a.map(&.["text"]).should eq(["everyone"])
    end
  end

  it "advances past a full page of messages for other sessions" do
    with_store do |store|
      t = tools_for(store)
      t.call("operator_messages", JSON.parse("{}"))
      60.times { store.post_agent_message("noise", "pid:123456789", nil) }
      mine = store.post_agent_message("mine", "pid:#{Process.pid}", nil)
      j = JSON.parse(t.call("operator_messages", JSON.parse(%({"limit":50}))).text)
      j["messages"].as_a.should be_empty
      cur = j["next_cursor"].as_i64
      cur.should be < mine
      j2 = JSON.parse(t.call("operator_messages", JSON.parse(%({"since":#{cur},"limit":50}))).text)
      j2["messages"].as_a.map(&.["text"]).should eq(["mine"])
    end
  end

  it "omits a message a live route already carried to THIS session" do
    with_store do |store|
      t = tools_for(store)
      t.call("operator_messages", JSON.parse("{}"))
      m = store.post_agent_message("pushed already", "all", nil)
      store.record_agent_delivery(m, "socket", "claude-code pid #{Process.pid}", true, pid: Process.pid.to_i64)
      j = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)
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

  # The cursor the agent is told to come back with obeys the same rule the courier's and the
  # tool-result carry's do: it may not step past a row another route in this process is still
  # handing over. That claim is temporary — a `codex queue` that is refused deposits a `poll`
  # row, which retires nothing — so a `next_cursor` above it would send this agent back for a
  # page starting after the one message it is still owed, and the tool's own schema tells it to
  # pass that cursor.
  it "will not cursor past a message another route is still handing over" do
    with_store do |store|
      t = tools_for(store)
      t.call("operator_messages", JSON.parse("{}"))
      held = store.post_agent_message("mid hand-off", "all", nil)
      later = store.post_agent_message("said after", "all", nil)
      t.claim_message(held).should be_true

      j = JSON.parse(t.call("operator_messages", JSON.parse("{}")).text)
      j["messages"].as_a.map(&.["text"]).should eq(["said after"])
      j["next_cursor"].as_i64.should eq(held - 1)

      # The hand-off failed and left a poll deposit, which carries nothing. Coming back with
      # the cursor it was given, the agent still finds the line.
      store.record_agent_delivery(held, Gori::AgentDelivery::VIA_POLL, "x", true, pid: Process.pid.to_i64)
      t.release_message(held)
      back = JSON.parse(t.call("operator_messages",
        JSON.parse(%({"since":#{j["next_cursor"]}}))).text)
      back["messages"].as_a.map(&.["id"].as_i64).should contain(held)
      later.should be > held
    end
  end
end
