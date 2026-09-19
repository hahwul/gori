require "../spec_helper"

describe Gori::Store, "#1090 agent replies" do
  it "records a reply as an agent row: one summary line, an optional detail, a clamped level" do
    with_store do |store|
      id = store.record_agent_reply("Found 2 IDORs\nsecond line is not the summary",
        "## Findings\n- /api/orders/1", "success", "claude-code pid 7", 7_i64, 3_i64)
      row = store.events_after(0, 10).first
      row.source.should eq("agent")
      row.kind.should eq("agent_reply")
      row.actor.should eq("mcp")
      row.level.should eq("success")
      row.message.should eq("Found 2 IDORs")
      r = store.agent_replies_after(0, 10).rows.first
      r.id.should eq(id)
      r.detail.should eq("## Findings\n- /api/orders/1")
      r.target_label.should eq("claude-code pid 7")
      r.pid.should eq(7)
      r.in_reply_to.should eq(3)
      store.record_agent_reply("x", nil, "shout", "codex pid 8", 8_i64)
      store.agent_replies_after(id, 10).rows.first.level.should eq("info")
    end
  end

  it "caps the summary at one line and the detail on a character boundary" do
    with_store do |store|
      long = "é" * 300
      store.record_agent_reply(long, "ü" * (Gori::AgentReply::DETAIL_MAX // 2 + 10), "info", "a pid 1", 1_i64)
      r = store.agent_replies_after(0, 10).rows.first
      r.summary.size.should eq(Gori::AgentReply::SUMMARY_MAX)
      r.summary.should end_with("…")
      d = r.detail.not_nil!
      d.valid_encoding?.should be_true
      d.should end_with("… (cut)")
    end
  end
end
