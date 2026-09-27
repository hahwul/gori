require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The `ask_operator` answer card (#1324). A dumb form: a key records `decision` and answers
# :commit, and the open-site's closure writes it — so these examples assert the decision the
# closure would read, and what the operator can SEE, never a store write.
private def question(choices = ["yes", "no"], default : String? = "no", detail : String? = "It serves the same session cookie.",
                     text = "Add api.example.com to scope?") : Gori::AgentQuestion
  now = Time.utc.to_unix_ms * 1000
  Gori::AgentQuestion.new(7_i64, text, detail, choices, default, "claude-code pid 42", 42_i64,
    now + 28_i64 * 60_000_000, now - 120_000_000_i64)
end

private def card(q = question) : AgentQuestionOverlay
  AgentQuestionOverlay.new(q, "claude-code")
end

describe Gori::Tui::AgentQuestionOverlay do
  it "exposes the chrome the shell's collapsed ladders read off an overlay" do
    OverlayHarness.new(card).assert_chrome(OverlayKind::AgentQuestion, "AGENT ASKS")
  end

  it "draws the question, how long it has waited and has left, the detail and each choice" do
    h = OverlayHarness.new(card)
    box = h.box.not_nil!
    mb = h.render
    mb.row(box.y).should contain("claude-code")
    mb.row(box.y + 1).should contain("Add api.example.com to scope?")
    mb.row(box.y + 2).should contain("asked 2m ago")
    mb.row(box.y + 2).should contain("expires in 2")
    h.rendered?("It serves the same session cookie.").should be_true
    mb.row(box.bottom - 3).should contain("1  yes")
    mb.row(box.bottom - 2).should contain("2  no")
    mb.row(box.bottom - 2).should contain("default")
  end

  it "starts on the default, so ↵ without moving answers with it" do
    ov = card
    h = OverlayHarness.new(ov)
    ov.selected.should eq(1)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.decided_choice.should eq("no")
    ov.dismissed?.should be_false
  end

  it "answers with a choice's digit in one key" do
    ov = card(question(["allow", "deny", "ask later"], nil))
    h = OverlayHarness.new(ov)
    ov.selected.should eq(0)
    h.type("3").should eq(:closed)
    ov.decided_choice.should eq("ask later")
  end

  it "ignores a digit past the last choice" do
    ov = card
    h = OverlayHarness.new(ov)
    h.type("3").should eq(:open)
    h.commits.should eq(0)
  end

  it "moves between choices with the arrows and j/k before ↵" do
    ov = card(question(["a", "b", "c"], "a"))
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Down) # clamps at the last
    ov.selected.should eq(2)
    h.type("k")
    ov.selected.should eq(1)
    h.press(Termisu::Input::Key::Enter)
    ov.decided_choice.should eq("b")
  end

  # `x` is the explicit "I will not choose"; esc is only "later" and leaves the question open.
  it "dismisses on x and closes for later on esc without deciding" do
    ov = card
    h = OverlayHarness.new(ov)
    h.type("x").should eq(:closed)
    ov.dismissed?.should be_true
    ov.decided_choice.should be_nil

    later = card
    h2 = OverlayHarness.new(later)
    h2.press(Termisu::Input::Key::Escape).should eq(:closed)
    h2.commits.should eq(0)
    later.decision.should be_nil
  end

  it "answers with the choice under a click" do
    ov = card
    h = OverlayHarness.new(ov)
    box = h.box.not_nil!
    h.click(box.x + 6, box.bottom - 3).should eq(:closed)
    ov.decided_choice.should eq("yes")
  end

  it "keeps the card open when the write is refused, so ↵ can try again" do
    ov = card
    h = OverlayHarness.new(ov, commit: false)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1)
  end

  it "draws without a detail band when the agent gave none" do
    h = OverlayHarness.new(card(question(detail: nil)))
    box = h.box.not_nil!
    h.render.row(box.bottom - 3).should contain("1  yes")
  end

  it "scrubs control characters the agent put in its question" do
    esc = 27.chr
    h = OverlayHarness.new(card(question(text: "scope?#{esc}[2J now")))
    box = h.box.not_nil!
    h.render.row(box.y + 1).includes?(esc).should be_false
  end
end

describe Gori::Tui::AgentMessageNotes, "questions" do
  it "announces who is asking what, and keeps the context and choices for the long form" do
    q = question
    Gori::Tui::AgentMessageNotes.question_line(q).should eq("claude-code asks: Add api.example.com to scope?")
    d = Gori::Tui::AgentMessageNotes.question_detail(q)
    d.should contain("It serves the same session cookie.")
    d.should contain("Choices: yes · no")
  end

  it "says how long the question has left in minutes, hours, or that it is gone" do
    q = question
    base = q.created_at
    Gori::Tui::AgentMessageNotes.question_meta(q, base + 60_000_000_i64).should contain("asked 1m ago")
    Gori::Tui::AgentMessageNotes.question_meta(q, q.expires_at - 30_000_000_i64).should contain("expires in <1m")
    Gori::Tui::AgentMessageNotes.question_meta(q, q.expires_at).should contain("expired")
    long = Gori::AgentQuestion.new(1_i64, "q", nil, ["a", "b"], nil, "x pid 1", 1_i64, base + 90_i64 * 60_000_000, base)
    Gori::Tui::AgentMessageNotes.question_meta(long, base).should contain("expires in 1h 30m")
  end

  it "confirms an answer and a dismissal in the toast" do
    Gori::Tui::AgentMessageNotes.question_answered(question, "yes").should eq("answered claude-code: yes")
    Gori::Tui::AgentMessageNotes.question_answered(question, nil).should eq("dismissed claude-code's question")
  end
end

describe Gori::Tui::Notifications, "question notes" do
  it "offers a question until it is settled, and finds the note by the question's id" do
    ring = Gori::Tui::Notifications.new
    ring.push(:info, "unrelated")
    n = ring.push(:info, "claude-code asks: x", nil, source: "agent", addressed: true, question_id: 9_i64)
    n.question_open?.should be_true
    ring.for_question(9_i64).should be(n)
    ring.for_question(10_i64).should be_nil
    n.question_state = :answered
    n.question_open?.should be_false
    ring.push(:info, "plain").question_open?.should be_false
  end
end
