require "../spec_helper"

describe Gori::Store, "#1090 operator messages" do
  it "posts a message the feed carries under the operator source, addressed and with context" do
    with_store do |store|
      id = store.post_agent_message("fuzz the login form", "pid:4242", "history", [7_i64, 9_i64])
      id.should be > 0
      row = store.events_after(0, 10).first
      row.source.should eq("operator")
      row.kind.should eq("agent_message")
      row.actor.should eq("tui")
      m = Gori::AgentMessage.from_row(row).not_nil!
      m.text.should eq("fuzz the login form")
      m.target.should eq("pid:4242")
      m.from_tab.should eq("history")
      m.flow_ids.should eq([7_i64, 9_i64])
      m.for?(4242).should be_true
      m.for?(1).should be_false
    end
  end

  it "reads messages after a cursor for one courier, all or by pid, and skips rows it cannot parse" do
    with_store do |store|
      store.insert_event("operator", "agent_message", "info", "hand-written, no payload")
      a = store.post_agent_message("to everyone", "all", nil)
      store.post_agent_message("to someone else", "pid:9", nil)
      b = store.post_agent_message("to me", "pid:4242", "issues")
      mine = store.agent_messages_after(0, 4242)
      mine.map(&.id).should eq([a, b])
      store.agent_messages_after(a, 4242).map(&.text).should eq(["to me"])
      store.agent_messages_after(b, 4242).should be_empty
    end
  end

  it "records deliveries with a level per outcome and reads them back" do
    with_store do |store|
      m = store.post_agent_message("hi", "all", nil)
      store.record_agent_delivery(m, "socket", "claude-code pid 1", true)
      store.record_agent_delivery(m, "poll", "codex pid 2", false, "no live route")
      store.record_agent_delivery(m, "channel", "claude-code pid 3", false, "write failed")
      rows = store.events_after(m, 10)
      rows.map(&.level).should eq(%w[success info warn])
      rows.all? { |r| r.kind == "agent_delivery" }.should be_true
      ds = store.agent_deliveries_after(m, 10)
      ds.map(&.via).should eq(%w[socket poll channel])
      ds.map(&.ok).should eq([true, false, false])
      ds[1].reason.should eq("no live route")
      ds.map(&.target_label).first.should eq("claude-code pid 1")
      store.delivered_agent_message_ids(0).should eq(Set{m})
    end
  end

  it "reports the feed's high-water mark for a cursor that starts at now" do
    with_store do |store|
      store.last_event_id.should eq(0)
      id = store.post_agent_message("x", "all", nil)
      store.last_event_id.should eq(id)
    end
  end

  it "is a source the closed filters know" do
    Gori::Store::EVENT_SOURCES.should contain("operator")
  end
end
