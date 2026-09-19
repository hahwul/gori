require "../spec_helper"

describe Gori::Tui::AgentMessageNotes, ".reply_line" do
  it "names the client and carries the agent's level" do
    r = Gori::AgentReply.new(1_i64, "Found 2 IDORs", "long", "success", "claude-code pid 7", 7_i64, nil, 0_i64)
    Gori::Tui::AgentMessageNotes.reply_line(r).should eq({:success, "claude-code: Found 2 IDORs"})
  end

  it "scrubs what the peer wrote and falls back to info for an unknown level" do
    esc = 27.chr
    r = Gori::AgentReply.new(2_i64, "hm#{esc}[31m", nil, "weird", "x#{1.chr}y pid 1", 1_i64, nil, 0_i64)
    level, message = Gori::Tui::AgentMessageNotes.reply_line(r)
    level.should eq(:info)
    message.includes?(esc).should be_false
    message.includes?(1.chr).should be_false
  end
end
