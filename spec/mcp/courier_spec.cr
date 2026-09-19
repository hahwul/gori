require "../spec_helper"
require "../../src/gori/mcp/courier"

private alias Courier = Gori::MCP::Courier

# A courier over a real store with every route injected: what it emits, what it writes to the
# socket, and what it records, without a fiber (the tick is driven by hand).
private class Rig
  getter frames = [] of String
  getter store : Gori::Store
  property client : String? = "claude-code"
  property? channels = false
  property inbox : String? = nil

  def initialize(@store)
  end

  def courier(pid = 77_i64) : Courier
    Courier.new(pid: pid, store: -> { @store.as(Gori::Store?) }, client: -> { @client },
      channels: -> { @channels }, emit: ->(f : String) { @frames << f; nil }, inbox: -> { @inbox })
  end
end

private def with_fake_inbox(&)
  dir = File.tempname("gori-courier")
  Dir.mkdir_p(dir)
  path = File.join(dir, "1.sock")
  server = UNIXServer.new(path)
  got = [] of String
  spawn do
    while client = server.accept?
      got.concat(client.gets_to_end.lines)
      client.close
    end
  end
  begin
    yield path, got
  ensure
    server.close rescue nil
    FileUtils.rm_rf(dir)
  end
end

describe Gori::MCP::Courier do
  it "starts at the feed's end so a late joiner never replays old messages" do
    with_store do |store|
      store.post_agent_message("before you came", "all", nil)
      rig = Rig.new(store)
      c = rig.courier
      c.tick.should eq(0)
      rig.frames.should be_empty
      store.post_agent_message("after", "all", nil)
      c.tick.should eq(1)
      c.delivered.should eq(1)
    end
  end

  it "leaves a message for polling when there is no live route, and records why" do
    with_store do |store|
      rig = Rig.new(store)
      rig.client = "codex"
      c = rig.courier(9_i64)
      c.tick
      m = store.post_agent_message("hi codex", "pid:9", "history")
      c.tick.should eq(1)
      d = store.agent_deliveries_after(m, 10).rows.first
      d.via.should eq("poll")
      d.ok.should be_true # a deposit is not a failure
      d.pid.should eq(9)
      d.target_label.should eq("codex pid 9")
      d.reason.not_nil!.should contain("operator_messages")
      rig.frames.should be_empty
    end
  end

  it "skips messages addressed to another courier" do
    with_store do |store|
      rig = Rig.new(store)
      c = rig.courier(9_i64)
      c.tick
      store.post_agent_message("not for you", "pid:10", nil)
      c.tick.should eq(0)
      store.agent_deliveries_after(0, 10).rows.should be_empty
      # …and the cursor still moved past it: the next tick does not rescan
      mine = store.post_agent_message("for you", "pid:9", nil)
      c.tick.should eq(1)
      c.cursor.should eq(mine)
    end
  end

  it "pushes a channel frame only when channels are on AND the client is Claude Code" do
    with_store do |store|
      rig = Rig.new(store)
      rig.channels = true
      c = rig.courier
      c.tick
      m = store.post_agent_message("fuzz the login", "all", "history", [3_i64, 4_i64])
      c.tick.should eq(1)
      rig.frames.size.should eq(1)
      f = JSON.parse(rig.frames[0])
      f["method"].should eq("notifications/claude/channel")
      f["params"]["content"].as_s.should start_with("fuzz the login")
      f["params"]["content"].as_s.should end_with(Gori::MCP::ClaudeInbox::REPLY_HINT)
      f["params"]["meta"]["message_id"].should eq(m.to_s)
      f["params"]["meta"]["from_tab"].should eq("history")
      f["params"]["meta"]["flow_ids"].should eq("3,4")
      f["id"]?.should be_nil # a notification, never a request
      d = store.agent_deliveries_after(m, 10).rows.first
      d.via.should eq("channel")
      d.ok.should be_true

      # channels on, but a client that is not Claude Code: no push, socket/poll instead
      rig.client = "codex"
      store.post_agent_message("again", "all", nil)
      c.tick
      rig.frames.size.should eq(1)
    end
  end

  it "writes to the inbox socket when one exists, framed as relayed operator intent" do
    with_store do |store|
      with_fake_inbox do |path, got|
        rig = Rig.new(store)
        rig.inbox = path
        c = rig.courier
        c.tick
        m = store.post_agent_message("look at issue 4", "all", "issues")
        c.tick.should eq(1)
        # the fake server's fiber needs a moment to read
        deadline = Time.instant + 2.seconds
        until got.size >= 1 || Time.instant >= deadline
          sleep 20.milliseconds
        end
        # one user line, preceded by an auth line when this spec itself runs under a Claude
        # session that exports CLAUDE_CODE_MESSAGING_TOKEN
        got.size.should be >= 1
        JSON.parse(got.last)["message"]["content"].as_s.should start_with("[gori] The operator at the gori TUI says (from the issues tab): look at issue 4")
        d = store.agent_deliveries_after(m, 10).rows.first
        d.via.should eq("socket")
        d.ok.should be_true
        rig.frames.should be_empty
      end
    end
  end

  it "records a failed socket write as a warning delivery instead of raising" do
    with_store do |store|
      rig = Rig.new(store)
      rig.inbox = "/nonexistent/gori.sock"
      c = rig.courier
      c.tick
      m = store.post_agent_message("x", "all", nil)
      c.tick.should eq(1)
      d = store.agent_deliveries_after(m, 10).rows.first
      d.via.should eq("socket")
      d.ok.should be_false
      d.reason.should_not be_nil
    end
  end

  it "does not starve behind a full page of messages for other sessions" do
    with_store do |store|
      rig = Rig.new(store)
      rig.client = "codex"
      c = rig.courier(9_i64)
      c.tick
      first = store.post_agent_message("one for me", "pid:9", nil)
      60.times { store.post_agent_message("someone else", "pid:10", nil) }
      last = store.post_agent_message("also for me", "pid:9", nil)
      c.tick.should eq(1)        # the first page (50 rows) held only the first
      c.cursor.should be < last  # …and the cursor stopped at what was scanned, not the feed's end
      c.tick.should eq(1)        # the next page finds the one behind the noise
      c.cursor.should be >= last # its own delivery rows land after the high-water it read
      store.agent_deliveries_after(0, 100).rows.map(&.message_id).should eq([first, last])
      c.tick.should eq(0)
    end
  end

  it "rebases its cursor when the store is swapped underneath it" do
    with_store do |a|
      with_store do |b|
        b.post_agent_message("old in b", "all", nil)
        current = a
        c = Courier.new(pid: 1_i64, store: -> { current.as(Gori::Store?) }, client: -> { "claude-code".as(String?) },
          channels: -> { false }, emit: ->(_f : String) { nil }, inbox: -> { nil.as(String?) })
        c.tick
        current = b
        c.tick.should eq(0) # not "old in b"
        b.post_agent_message("new in b", "all", nil)
        c.tick.should eq(1)
      end
    end
  end
end
