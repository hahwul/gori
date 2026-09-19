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
end
