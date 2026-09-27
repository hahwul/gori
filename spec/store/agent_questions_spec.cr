require "../spec_helper"

# `ask_operator` questions (#1324): a feed row that stays open until ONE `agent_message` with
# `in_reply_to` closes it — the operator's answer or dismissal, or the asking server's expiry.
private def ask(store : Gori::Store, question = "Add api.example.com to scope?",
                choices = ["yes", "no"], expires_at = Int64::MAX, pid = 42_i64) : Gori::AgentQuestion
  id = store.record_agent_question(question, "it answers on 443", choices, "no", "claude-code pid #{pid}", pid, expires_at)
  store.open_agent_questions(id - 1, 0_i64).find { |q| q.id == id }.not_nil!
end

describe Gori::Store, "#1324 agent questions" do
  it "records a question as an agent row the reader parses back" do
    with_store do |store|
      q = ask(store)
      row = store.events_after(0, 10).first
      row.source.should eq("agent")
      row.kind.should eq("agent_question")
      row.actor.should eq("mcp")
      q.question.should eq("Add api.example.com to scope?")
      q.detail.should eq("it answers on 443")
      q.choices.should eq(["yes", "no"])
      q.default.should eq("no")
      q.pid.should eq(42)
      q.target.should eq("pid:42")
    end
  end

  it "stays open until a closing message, and then only once" do
    with_store do |store|
      q = ask(store)
      store.open_agent_questions(0_i64, 0_i64).map(&.id).should eq([q.id])
      mid = store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_ANSWERED, "yes", "operator", "tui", "history")
      mid.should be > 0
      store.open_agent_questions(0_i64, 0_i64).should be_empty
      # The expiry that lands second is refused, not written.
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_EXPIRED, nil, "agent", "mcp").should eq(-1)
      store.events_after(0, 10).count(&.kind.==("agent_message")).should eq(1)
    end
  end

  it "addresses the answer back to the asking process and frames it as one" do
    with_store do |store|
      q = ask(store, pid: 77_i64)
      store.close_agent_question(q, Gori::AgentQuestion::OUTCOME_ANSWERED, "yes", "operator", "tui", "repeater")
      page = store.agent_messages_after(q.id, 77_i64, 10)
      m = page.rows.first
      m.text.should eq("yes")
      m.target.should eq("pid:77")
      m.in_reply_to.should eq(q.id)
      m.outcome.should eq("answered")
      m.question.should eq("Add api.example.com to scope?")
      m.answer?.should be_true
      m.from_tab.should eq("repeater")
      # Nobody else is sent it.
      store.agent_messages_after(q.id, 78_i64, 10).rows.should be_empty
    end
  end

  it "names a dismissal and an expiry in the message text" do
    with_store do |store|
      a = ask(store)
      b = ask(store)
      store.close_agent_question(a, Gori::AgentQuestion::OUTCOME_DISMISSED, nil, "operator", "tui")
      store.close_agent_question(b, Gori::AgentQuestion::OUTCOME_EXPIRED, nil, "agent", "mcp")
      texts = store.agent_messages_after(0_i64, 42_i64, 10).rows.map { |m| {m.outcome, m.text} }
      texts.should eq([{"dismissed", "(dismissed without an answer)"}, {"expired", "(expired without an answer)"}])
    end
  end

  it "leaves out a question past its expiry and one already closed" do
    with_store do |store|
      stale = ask(store, expires_at: 100_i64)
      live = ask(store)
      other = ask(store)
      store.close_agent_question(other, Gori::AgentQuestion::OUTCOME_ANSWERED, "no", "operator", "tui")
      open = store.open_agent_questions(0_i64, 200_i64)
      open.map(&.id).should eq([live.id])
      stale.expired?(200_i64).should be_true
      live.expired?(200_i64).should be_false
    end
  end

  it "ignores a question row that offers fewer than two choices" do
    with_store do |store|
      store.insert_event("agent", "agent_question", "info", "hand-written", payload: %({"choices":["only"],"expires_at":9}))
      store.open_agent_questions(0_i64, 0_i64).should be_empty
    end
  end

  it "caps a long detail on a character boundary" do
    with_store do |store|
      q = ask(store, question: "q")
      store.record_agent_question("q", "é" * Gori::AgentReply::DETAIL_MAX, ["a", "b"], nil, "x pid 1", 1_i64, Int64::MAX)
      d = store.open_agent_questions(q.id, 0_i64).first.detail.not_nil!
      d.valid_encoding?.should be_true
      d.should end_with("… (cut)")
    end
  end
end
