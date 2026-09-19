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
      page = store.agent_messages_after(0, 4242)
      page.rows.map(&.id).should eq([a, b])
      page.scanned_max.should eq(b)
      page.full.should be_false
      store.agent_messages_after(a, 4242).rows.map(&.text).should eq(["to me"])
      store.agent_messages_after(b, 4242).rows.should be_empty
      # a full page reports its last SCANNED id, matching or not, so a cursor can advance past
      # fifty messages for someone else instead of jumping to the feed's end over them
      60.times { store.post_agent_message("noise", "pid:9", nil) }
      c = store.post_agent_message("behind the noise", "pid:4242", nil)
      p1 = store.agent_messages_after(b, 4242, 50)
      p1.rows.should be_empty
      p1.full.should be_true
      p1.scanned_max.should be < c
      p2 = store.agent_messages_after(p1.scanned_max, 4242, 50)
      p2.rows.map(&.id).should eq([c])
      p2.full.should be_false
    end
  end

  it "records deliveries with a level per outcome and reads them back" do
    with_store do |store|
      m = store.post_agent_message("hi", "all", nil)
      store.record_agent_delivery(m, "socket", "claude-code pid 1", true, pid: 1)
      store.record_agent_delivery(m, "poll", "codex pid 2", true, "no live route", pid: 2)
      store.record_agent_delivery(m, "channel", "claude-code pid 3", false, "write failed", pid: 3)
      rows = store.events_after(m, 10)
      rows.map(&.level).should eq(%w[success info warn])
      rows.all? { |r| r.kind == "agent_delivery" }.should be_true
      ds = store.agent_deliveries_after(m, 10).rows
      ds.map(&.via).should eq(%w[socket poll channel])
      ds.map(&.ok).should eq([true, true, false])
      ds.map(&.pid).should eq([1, 2, 3])
      ds[1].reason.should eq("no live route")
      ds.map(&.target_label).first.should eq("claude-code pid 1")
      # "delivered" is per RECIPIENT and only for a live route: the socket landing at pid 1 does
      # not make pid 2's poll deposit a delivery, so pid 2's own read still returns the message
      store.delivered_agent_message_ids(0, 1).should eq(Set{m})
      store.delivered_agent_message_ids(0, 2).should be_empty
      store.delivered_agent_message_ids(0, 3).should be_empty
    end
  end

  it "counts only confirmed routes as carried: a successful channel push does not retire the message" do
    with_store do |store|
      m = store.post_agent_message("hi", "pid:1", nil)
      # An ok channel push to pid 1 — but a channel is unverifiable, so it is NOT carried.
      store.record_agent_delivery(m, Gori::AgentDelivery::VIA_CHANNEL, "claude-code pid 1", true, pid: 1)
      store.delivered_agent_message_ids(0, 1).should be_empty
      # Now a socket write that landed for the same session: that one is confirmed and carries it.
      store.record_agent_delivery(m, Gori::AgentDelivery::VIA_SOCKET, "claude-code pid 1", true, pid: 1)
      store.delivered_agent_message_ids(0, 1).should eq(Set{m})
      # The page-bounded overload agrees, and returns nothing for a candidate set that excludes m.
      store.delivered_agent_message_ids(0, 1, Set{m}).should eq(Set{m})
      store.delivered_agent_message_ids(0, 1, Set{m + 999}).should be_empty
      store.delivered_agent_message_ids(0, 1, Set(Int64).new).should be_empty
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
