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

private def reply(id : Int64, summary : String, level : String = "info", who : String = "claude-code",
                  detail : String? = nil) : Gori::AgentReply
  Gori::AgentReply.new(id, summary, detail, level, "#{who} pid 7", 7_i64, nil, 1_790_000_000_000_000_i64 + id)
end

# The one note a window opens with when replies landed while none was open (#1322).
describe Gori::Tui::AgentMessageNotes, ".missed_replies" do
  it "names the one sender and counts what it sent" do
    level, message, detail = Gori::Tui::AgentMessageNotes.missed_replies(
      [reply(1, "Found 2 IDORs"), reply(2, "Done with /api")], 2)
    level.should eq(:info)
    message.should eq("claude-code sent 2 replies while you were away")
    detail.should contain("Found 2 IDORs")
    detail.should contain("Done with /api")
    detail.index("Found 2 IDORs").not_nil!.should be < detail.index("Done with /api").not_nil!
  end

  it "says one reply in the singular" do
    _, message, _ = Gori::Tui::AgentMessageNotes.missed_replies([reply(1, "x")], 1)
    message.should eq("claude-code sent 1 reply while you were away")
  end

  it "lists the senders when there are several, and takes the most severe level" do
    rows = [reply(1, "a", "success", "claude-code"), reply(2, "b", "error", "codex"), reply(3, "c", "warn", "claude-code")]
    level, message, _ = Gori::Tui::AgentMessageNotes.missed_replies(rows, 3)
    level.should eq(:error)
    message.should eq("3 replies arrived while you were away (claude-code, codex)")
  end

  # The count is the real total; the detail lists a page and points at the rest.
  it "counts past the page it lists and says where the rest are" do
    _, message, detail = Gori::Tui::AgentMessageNotes.missed_replies([reply(9, "last one")], 12)
    message.should eq("claude-code sent 12 replies while you were away")
    detail.should contain("11 more in the Project tab's Activity pane")
  end

  it "cuts a long detail instead of carrying every byte of it" do
    long = "z" * (Gori::Tui::AgentMessageNotes::MISSED_DETAIL_MAX + 500)
    _, _, detail = Gori::Tui::AgentMessageNotes.missed_replies([reply(1, "s", detail: long)], 1)
    detail.count('z').should eq(Gori::Tui::AgentMessageNotes::MISSED_DETAIL_MAX)
    detail.should contain("full reply is in the Activity pane")
  end

  it "scrubs the peer's summary on the way in" do
    esc = 27.chr
    _, message, detail = Gori::Tui::AgentMessageNotes.missed_replies([reply(1, "hi#{esc}[2J", who: "x#{1.chr}y")], 1)
    message.includes?(1.chr).should be_false
    detail.includes?(esc).should be_false
  end
end
