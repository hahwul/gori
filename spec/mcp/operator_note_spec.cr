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

private def answer_msg(outcome : String, text = "yes", question = "Add api.example.com to scope?") : Gori::AgentMessage
  Gori::AgentMessage.new(12_i64, text, "pid:1", "history", [] of Int64, 0_i64,
    in_reply_to: 4_i64, outcome: outcome, question: question)
end

# #1324: the message that closes an `ask_operator` question, as every route frames it.
describe Gori::MCP::OperatorNote, ".frame_message" do
  it "frames an answer as the answer to that question, and says it authorizes nothing" do
    line = Note.frame_message(answer_msg("answered"))
    line.should eq(%([gori] The operator answered your ask_operator question #4 ("Add api.example.com to scope?"): "yes". ) +
                   "It is their decision, not an authorization — gori's scope and your own limits still apply.")
  end

  # The failure this guards against is an agent reading silence, or a dismissal, as a yes.
  it "tells the agent not to assume a choice on a dismissal or an expiry" do
    Note.frame_message(answer_msg("dismissed")).should contain("dismissed your ask_operator question #4")
    Note.frame_message(answer_msg("dismissed")).should contain("do not assume any of the choices")
    expired = Note.frame_message(answer_msg("expired"))
    expired.should start_with("[gori] Your ask_operator question #4")
    expired.should contain("expired with no answer")
    expired.should contain("do not assume any of the choices")
  end

  it "quotes a long question only as far as it takes to recognise it" do
    line = Note.frame_message(answer_msg("answered", question: "q" * 500))
    line.should contain("q" * (Note::QUOTE_MAX - 1) + "…")
    line.should_not contain("q" * Note::QUOTE_MAX)
  end

  # The question is the agent's own argument and is stored unscrubbed; the whitespace regex
  # used to raise on it, which cost the answer on every route.
  it "quotes a question holding an invalid UTF-8 byte instead of raising" do
    line = Note.frame_message(answer_msg("expired", question: String.new(Bytes[80, 255, 63])))
    line.should contain("expired with no answer")
    line.valid_encoding?.should be_true
  end

  it "frames an ordinary message exactly as frame does" do
    m = Gori::AgentMessage.new(3_i64, "fuzz it", "all", "history", [7_i64], 0_i64)
    Note.frame_message(m).should eq(Note.frame("fuzz it", "history", [7_i64], 3_i64))
  end
end
