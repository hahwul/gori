require "json"
require "termisu"
require "../unicode_reveal"
require "./agent_messages"

module Gori
  # A question an agent put to the operator with MCP `ask_operator` (#1324): one line, an
  # optional long form, and two to four choices the operator picks from in the TUI. A feed row
  # like the reply beside it — `source: "agent"`, `kind: "agent_question"`, `actor: "mcp"` —
  # addressed back to the asking process by `pid`, the `gori mcp` pid a presence marker names.
  #
  # A question has no state column. It is OPEN until an `agent_message` with `in_reply_to`
  # set to its id exists, and exactly one ever does (`Store#close_agent_question`): the
  # operator's answer or dismissal from the TUI, or the asking server's expiry. That row is
  # also how the answer travels, so every route that carries an operator message — the inbox
  # socket, `codex queue`, the channel, the tool-result carry, the poll — carries it with no
  # route of its own.
  record AgentQuestion, id : Int64, question : String, detail : String?, choices : Array(String),
    default : String?, target_label : String, pid : Int64, expires_at : Int64, created_at : Int64 do
    KIND = "agent_question"

    # Two to four short labels: enough for a real decision, few enough that each keeps a
    # digit key on the card and a row the operator can read in one glance. CHOICE_MAX is in
    # terminal COLUMNS (`label_width`), not characters: a full-width card draws the default's
    # label in 58 of them, so forty wide CJK characters (80 columns) were clipped, and two
    # labels differing only at the end read the same while the agent got different answers.
    CHOICES_MIN =  2
    CHOICES_MAX =  4
    CHOICE_MAX  = 40

    # The columns the card draws `label` in, the way `Tui::Screen.display_width` counts them:
    # an invisible codepoint is drawn as its `UnicodeReveal` badge, so it costs the badge's
    # width rather than the 0 a raw width table gives it.
    def self.label_width(label : String) : Int32
      w = 0
      label.each_grapheme do |g|
        grapheme = g.to_s
        if badge = UnicodeReveal.visible(grapheme)
          badge.each_grapheme { |glyph| w += Termisu::UnicodeWidth.grapheme_width(glyph.to_s) }
        else
          w += Termisu::UnicodeWidth.grapheme_width(grapheme)
        end
      end
      w
    end

    # A choice the card can draw whole: at most CHOICE_MAX columns, and at most CHOICE_MAX
    # characters too, since a combining mark stacked on a visible glyph costs no column.
    def self.choice_fits?(label : String) : Bool
      label.size <= CHOICE_MAX && label_width(label) <= CHOICE_MAX
    end

    # Minutes until an unanswered question expires. Half an hour by default: long enough for
    # an operator who stepped away for a coffee, short enough that an agent waiting on it
    # hears "no answer" inside the same working session. A day at most.
    EXPIRES_DEFAULT_MINUTES =   30
    EXPIRES_MAX_MINUTES     = 1440

    OUTCOME_ANSWERED  = "answered"
    OUTCOME_DISMISSED = "dismissed"
    OUTCOME_EXPIRED   = "expired"
    OUTCOMES          = {OUTCOME_ANSWERED, OUTCOME_DISMISSED, OUTCOME_EXPIRED}

    def self.payload_json(detail : String?, choices : Array(String), default : String?,
                          target : String, pid : Int64, expires_at : Int64) : String
      JSON.build do |j|
        j.object do
          j.field "target", target
          j.field "pid", pid
          j.field "detail", detail if detail
          j.field("choices") { j.array { choices.each { |c| j.string(c) } } }
          j.field "default", default if default
          j.field "expires_at", expires_at
        end
      end
    end

    # A feed row → a question, or nil when the payload is not one (fewer than two choices, no
    # expiry): a question the card could not offer an answer to is not shown at all.
    def self.from_row(row : Store::EventRow) : AgentQuestion?
      return nil unless row.kind == KIND
      h = row.payload.try { |p| JSON.parse(p).as_h? }
      return nil unless h
      choices = h["choices"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || return nil
      return nil if choices.size < CHOICES_MIN
      expires = h["expires_at"]?.try(&.as_i64?) || return nil
      new(row.id, row.message, h["detail"]?.try(&.as_s?), choices.first(CHOICES_MAX),
        h["default"]?.try(&.as_s?), h["target"]?.try(&.as_s?) || "agent",
        h["pid"]?.try(&.as_i64?) || 0_i64, expires, row.created_at)
    rescue JSON::ParseException
      nil
    end

    # Unix micros, the unit `created_at` and `expires_at` share.
    def expired?(now_us : Int64) : Bool
      now_us >= expires_at
    end

    # How the operator message that closes this question is addressed: back to the one
    # process that asked.
    def target : String
      "pid:#{pid}"
    end
  end

  class Store
    # Post one question. `detail` is capped like a reply's (`AgentReply::DETAIL_MAX`); the
    # choices are the caller's to validate — this writes what it is given.
    def record_agent_question(question : String, detail : String?, choices : Array(String),
                              default : String?, target : String, pid : Int64,
                              expires_at : Int64) : Int64
      insert_event("agent", AgentQuestion::KIND, "info", AgentReply.summary_line(question),
        payload: AgentQuestion.payload_json(AgentReply.cap_detail(detail), choices, default, target, pid, expires_at), actor: "mcp")
    end

    # The questions after `since_id` that are still open at `now_us`: not past their expiry,
    # and not closed by an answer, a dismissal or an expiry row. Oldest first.
    #
    # The feed has no index on `kind`, so this walks it from `since_id`; the caller keeps that
    # floor at its oldest open question (or at the feed's end when there is none), which
    # bounds the walk by the life of one question. Expired rows are dropped BEFORE the closure
    # scan, so a project full of old questions costs one pass, not one per question.
    def open_agent_questions(since_id : Int64, now_us : Int64) : Array(AgentQuestion)
      found = [] of AgentQuestion
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id > ? AND kind = ? ORDER BY id ASC",
        args: [since_id, AgentQuestion::KIND] of DB::Any) do |rs|
        rs.each do
          q = AgentQuestion.from_row(read_event(rs))
          found << q if q && !q.expired?(now_us)
        end
      end
      return found if found.empty?
      closed = closed_question_ids(@db, found.min_of(&.id))
      found.reject { |q| closed.includes?(q.id) }
    end

    # The ids of the questions an `agent_message` after `since_id` closed. For a reader that
    # keeps the open set itself and only needs to hear what closed since it last looked — the
    # TUI's poll, which then never re-walks the feed from its oldest open question (#1324).
    def agent_questions_closed_after(since_id : Int64) : Set(Int64)
      closed_question_ids(@db, since_id)
    end

    # One operator message by its feed id, or nil when it is gone or is not one. The TUI asks
    # it of a delivery row, whose own payload carries only the message id.
    def agent_message(id : Int64) : AgentMessage?
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id = ? AND kind = ?",
        args: [id, AgentMessage::KIND] of DB::Any) do |rs|
        rs.each { return AgentMessage.from_row(read_event(rs)) }
      end
      nil
    end

    # Close `question` with its one closing message. `outcome` is one of
    # `AgentQuestion::OUTCOMES`; `answer` is the chosen label for an answer. `source`/`actor`
    # name who closed it: the operator in the TUI, or the asking server's expiry.
    #
    # Answers the message id, 0 when the write did not commit (retryable), or -1 when the
    # question was already closed — by another window, or by an expiry that landed first —
    # or when an answer or a dismissal comes after `expires_at`. The asker was told an
    # unanswered question comes back expired, and its expiry row lands on the courier's next
    # tick, which a card left open (or an asker bound elsewhere for a while) can outlast; an
    # "answered" written in that gap reaches an agent that has already been told otherwise.
    def close_agent_question(question : AgentQuestion, outcome : String, answer : String?,
                             source : String, actor : String, from_tab : String? = nil,
                             now_us : Int64 = Time.utc.to_unix_ms * 1000) : Int64
      return -1_i64 if outcome != AgentQuestion::OUTCOME_EXPIRED && question.expired?(now_us)
      text =
        case outcome
        when AgentQuestion::OUTCOME_ANSWERED  then answer || ""
        when AgentQuestion::OUTCOME_DISMISSED then "(dismissed without an answer)"
        else                                       "(expired without an answer)"
        end
      payload = AgentMessage.payload_json(question.target, from_tab, [] of Int64,
        in_reply_to: question.id, outcome: outcome, question: question.question)
      insert_event_unless(source, AgentMessage::KIND, "info", text, payload: payload, actor: actor) do |c|
        closed_question_ids(c, question.id - 1, question.id).includes?(question.id)
      end
    end

    # The ids of questions an `agent_message` after `since_id` closes. `only`, when given,
    # stops the walk at the first message that closes that one question — the guard inside
    # `close_agent_question`'s transaction needs a yes or no, not the set.
    private def closed_question_ids(db : DB::Database | DB::Connection, since_id : Int64,
                                    only : Int64? = nil) : Set(Int64)
      ids = Set(Int64).new
      db.query("SELECT payload FROM events WHERE id > ? AND kind = ? ORDER BY id ASC",
        args: [since_id, AgentMessage::KIND] of DB::Any) do |rs|
        rs.each do
          raw = rs.read(String?)
          next unless raw && raw.includes?("in_reply_to")
          id = begin
            JSON.parse(raw)["in_reply_to"]?.try(&.as_i64?)
          rescue JSON::ParseException
            nil
          end
          next unless id
          ids << id
          break if only && id == only
        end
      end
      ids
    end
  end
end
