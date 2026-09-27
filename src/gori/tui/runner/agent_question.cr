require "../agent_question_overlay"
require "../agent_message_notes"

# An agent's `ask_operator` questions (#1324) — announced in the ring, counted on the `ask:`
# chip, answered on a card. ExecContext verb implementations; reopens Gori::Tui::Runner (see
# tui/runner.cr for the loop).
#
# The quiet shape on purpose: a question never raises its card by itself. It lands as a ring
# note Miss Ring holds until the operator's next key, the chip counts what is waiting, and the
# card opens only when the operator reaches for it — a modal that took focus mid-edit would
# turn the next keystroke into somebody else's answer.
#
# Open questions are STATE, not events: a question an agent asked while no window was open is
# still waiting when one opens, so the first poll reads every open question from the feed
# rather than starting at "now" the way the reply and delivery tails do.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Every question still open, oldest first — including one whose asker is not attached right
  # now; `answerable_questions` is the subset the card and the chip offer.
  @pending_questions : Array(Gori::AgentQuestion) = [] of Gori::AgentQuestion
  # Where the next open-question scan starts when nothing is pending, and the feed's
  # high-water mark at the last scan (-1: never scanned, so the first poll reads them all).
  @question_floor : Int64 = 0_i64
  @question_seen_high : Int64 = -1_i64
  # The ids already put in the ring, so a question announces once however many polls see it.
  @questions_announced : Set(Int64) = Set(Int64).new

  # Called every DV_POLL_INTERVAL tick, after the presence scan it reads the askers from.
  # Returns true when the ring or the chip changed.
  def drain_agent_questions : Bool
    store = @session.store
    now = now_us
    before = answerable_questions.map(&.id)
    high = store.last_event_id
    if high != @question_seen_high
      # From just below the oldest one still pending, so a pending question closed since the
      # last scan is seen closed; from the last high-water mark when none is.
      floor = @pending_questions.min_of?(&.id).try { |id| id - 1 } || @question_floor
      open = store.open_agent_questions(floor, now)
      open_ids = open.map(&.id).to_set
      # Closed by another window, or by the asking server's expiry.
      @pending_questions.each do |q|
        settle_question(q, q.expired?(now) ? :expired : :closed) unless open_ids.includes?(q.id)
      end
      @pending_questions = open
      @question_floor = high
      @question_seen_high = high
    end
    # The clock closes a question here too: the expiry row is written by the asking server,
    # which may be gone, and a card must not stay offered past the time the agent was told.
    @pending_questions.reject! do |q|
      next false unless q.expired?(now)
      settle_question(q, :expired)
      true
    end
    # An announced question whose asker detached can no longer be answered — nothing would
    # read the row.
    @pending_questions.each do |q|
      settle_question(q, :gone) if @questions_announced.includes?(q.id) && !asker_attached?(q)
    end
    announced = false
    answerable_questions.each do |q|
      next if @questions_announced.includes?(q.id)
      @questions_announced << q.id
      @notifications.push(:info, AgentMessageNotes.question_line(q), nil, source: "agent",
        detail: AgentMessageNotes.question_detail(q), addressed: true, question_id: q.id)
      announced = true
    end
    announced || answerable_questions.map(&.id) != before
  rescue ex
    Log.warn(exception: ex) { "tui: could not read agent questions" }
    false
  end

  # The questions the operator can answer now: open, and asked by an agent still attached.
  def answerable_questions : Array(Gori::AgentQuestion)
    return @pending_questions if @pending_questions.empty?
    @pending_questions.select { |q| asker_attached?(q) }
  end

  # `app.answer-agent` and the `ask:` chip: the oldest question waiting.
  def answer_agent_question : Nil
    if q = answerable_questions.first?
      open_question_card(q)
    else
      @toast = "no agent question is waiting"
    end
  end

  # The pending question announced by ring note `note`, if it can still be answered.
  private def answerable_question_for(note : Notifications::Note) : Gori::AgentQuestion?
    return nil unless note.question_open?
    id = note.question_id
    answerable_questions.find { |q| q.id == id }
  end

  # `from_ring` hands esc (and the answer) back to the notification centre, on the row the
  # card was opened from — the same pop-back the note detail card makes.
  private def open_question_card(q : Gori::AgentQuestion, *, from_ring : Int32? = nil) : Nil
    ov = AgentQuestionOverlay.new(q, AgentMessageNotes.question_sender(q))
    ov.on_commit = -> { commit_question(q, ov) }
    if note_id = from_ring
      ov.on_close = -> { open_notifications_at(note_id) }
    end
    open_overlay(ov)
  end

  # Write the operator's decision. Re-checks the asker at the side effect, where a guard
  # belongs (#724): the card may have been up for minutes, and a row addressed to a process
  # that has exited is an answer nobody will ever read.
  private def commit_question(q : Gori::AgentQuestion, ov : AgentQuestionOverlay) : Bool
    who = AgentMessageNotes.question_sender(q)
    unless attached_agents.any? { |e| e.pid == q.pid }
      @toast = "#{who} is no longer attached — nothing would read the answer"
      settle_question(q, :gone)
      return true
    end
    choice = ov.decided_choice
    outcome = ov.dismissed? ? Gori::AgentQuestion::OUTCOME_DISMISSED : Gori::AgentQuestion::OUTCOME_ANSWERED
    case @session.store.close_agent_question(q, outcome, choice, "operator", "tui", @active_tab.to_s)
    when 0
      # Nothing was written, and nothing downstream would say so: keep the card up so ↵
      # tries again, the way the tell-agent prompt does.
      @toast = "not sent — project busy; try again"
      false
    when -1
      @toast = "that question was already answered or has expired"
      settle_question(q, :closed)
      @pending_questions.reject! { |p| p.id == q.id }
      true
    else
      @toast = AgentMessageNotes.question_answered(q, choice)
      settle_question(q, ov.dismissed? ? :dismissed : :answered)
      @pending_questions.reject! { |p| p.id == q.id }
      true
    end
  end

  # Mark the ring note that announced `q` as no longer answerable. Idempotent: the first
  # state wins, so a later poll cannot relabel an answered question as closed.
  private def settle_question(q : Gori::AgentQuestion, state : Symbol) : Nil
    note = @notifications.for_question(q.id)
    return unless note && note.question_state.nil?
    note.question_state = state
  end

  private def asker_attached?(q : Gori::AgentQuestion) : Bool
    @agents.any? { |e| e.kind == Gori::AgentPresence::KIND_MCP && e.pid == q.pid }
  end

  private def now_us : Int64
    Time.utc.to_unix_ms * 1000
  end
end
