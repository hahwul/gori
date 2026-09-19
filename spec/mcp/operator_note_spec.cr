require "../spec_helper"
require "../../src/gori/mcp/operator_note"

private alias Note = Gori::MCP::OperatorNote

describe Gori::MCP::OperatorNote do
  it "frames the line as relayed operator intent" do
    Note.frame("fuzz it", "history").should start_with("[gori] The operator at the gori TUI says (from the history tab): fuzz it")
    Note.frame("fuzz it", nil).should start_with("[gori] The operator at the gori TUI says: fuzz it")
    # every line says where the answer goes — the live test's first lesson
    Note.frame("x", nil).should end_with(Note::REPLY_HINT)
    Note::REPLY_HINT.should contain("reply_to_operator")
  end

  it "carries the marked flows and the message id, because a carrying route retires the row" do
    # Once the socket write or the `codex queue` hand-off lands, `operator_messages` stops
    # answering with that message — so anything the agent still needs has to be in the
    # sentence. Ids, not bodies: the flows themselves are still fetched from the store.
    line = Note.frame("look at these", "history", [3_i64, 4_i64], 7_i64)
    line.should contain("look at these")
    line.should contain("3, 4")
    line.should contain("in_reply_to 7")
    # and nothing extra when there is nothing extra to say
    Note.frame("hi", nil).should_not contain("marked")
    Note.frame("hi", nil).should_not contain("in_reply_to")
  end
end
