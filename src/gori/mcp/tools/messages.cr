require "json"
require "../../store"
require "../../agent_presence"
require "../operator_note"
require "../serialize"

module Gori
  module MCP
    class Tools
      # How many pending messages one tool result carries. A bound, not a cap on what the
      # operator may say: the cursor advances only past what was scanned, so a longer backlog
      # rides out over the next few calls instead of burying one tool's answer under it — and
      # the note says when it is holding some back.
      TOOL_RESULT_MESSAGES = 5

      # One tool result's worth of operator messages: the text to attach, the ids it covers,
      # and where the cursor lands once it has actually gone out. Nothing here is marked yet —
      # `commit_operator_note` does that, after the frame is on the wire.
      record PendingNote, text : String, ids : Array(Int64), cursor : Int64

      # #1090 layer four, the half the agent does not have to remember. Whatever the operator
      # said that no confirmed route has carried rides back on the NEXT gori tool result —
      # whatever tool that was — as a second content block beside the tool's own answer.
      #
      # This exists because the other three routes are each ONE client's door: the inbox socket
      # is Claude Code's, `codex queue` is Codex's, the channel is a preview of Claude Code's.
      # Every other MCP client gori installs into (grok, pi, hermes, Antigravity, Claude
      # Desktop) has no door at all — their sessions were surveyed for one — so for them the
      # poll tool was the whole channel, and a poll only works if the model REMEMBERS to call
      # it. The handshake `instructions` that ask it to are delivered once, at initialize, and
      # a model deep in a long session is not reading them any more (#1003 is the same lesson).
      # A tool result is the one thing every client puts in front of its model on gori's behalf
      # without being asked, so it is where the message goes.
      #
      # It marks NOTHING: the carry is confirmed only when the response is actually emitted,
      # and this method cannot see that — `Server#handle_tools_call` calls
      # `commit_operator_note` once it has. The one thing it does move is the cursor on the
      # path where it returns `nil`, and only there; see below for why that is not the same
      # thing as marking.
      #
      # `nil` when there is nothing to say, which is the overwhelmingly common case and costs
      # one `MAX(id)` scalar (the courier's idle gate, for the same reason).
      def pending_operator_note(tool : String) : PendingNote?
        # The poll tool answers with these itself, and has already marked them.
        return nil if tool == "operator_messages"
        s = @store
        return nil unless s
        high = s.last_event_id
        return nil if high <= @messages_cursor
        pid = Process.pid.to_i64
        page = s.agent_messages_after(@messages_cursor, pid, TOOL_RESULT_MESSAGES)
        fresh = unclaimed(s, page, pid)
        # The oldest row another route in this process is still handing over. A claim is
        # TEMPORARY — that route may fail, and then this layer owes the message again — so it
        # is the one reason a row may be skipped without the cursor being allowed past it.
        held = page.rows.select { |m| @in_flight_messages.includes?(m.id) }.min_of?(&.id)
        # Advance past what was SCANNED, never past what matched — a page full of another
        # session's messages must not strand this session's behind it (the courier's rule).
        cursor =
          if page.full
            {@messages_cursor, page.scanned_max}.max
          else
            {@messages_cursor, page.scanned_max, high}.max
          end
        cursor = {@messages_cursor, {cursor, held - 1}.min}.max if held
        if fresh.empty?
          # Nothing is going out, so there is nothing a failed emit could have to take back:
          # the cursor moves HERE or it never moves at all. It used to be computed and then
          # thrown away with the `nil`, which left the `high <= @messages_cursor` gate above
          # permanently open — the feed is the firehose every gori action writes to, so `high`
          # climbs all session while the cursor sat at the floor it was constructed with. Every
          # tool call on the surface then paid a `kind = 'agent_message'` walk of the whole feed
          # (there is no index on `kind`) instead of the one scalar this method advertises:
          # 0.96ms against 0.005ms over a 50k-row feed, and it grows with the project.
          @messages_cursor = cursor
          return nil
        end
        # Announce them to the rest of the process BEFORE the frame is built. Emitting a
        # response yields (`send` takes the write lock and flushes), and the courier's next
        # tick lands in that gap: with no claim it would find these rows unclaimed — the
        # delivery row that answers for them is not written until `commit_operator_note` — and
        # write the same line to the session's inbox socket as well. `release_operator_note`
        # gives them back from `Server#handle_tools_call`'s `ensure`, on every exit.
        fresh = fresh.select { |m| claim_message(m.id) }
        return nil if fresh.empty?
        lines = fresh.map { |m| OperatorNote.frame_message(m, Serialize.text(m.text)) }
        # A full page may be hiding more behind it, and this carrier is the one the model did
        # not ask for: if it does not say so here, nothing does, and the rest waits for a tool
        # call that may never come.
        lines << "[gori] More operator messages are waiting — call operator_messages to read them." if page.full
        PendingNote.new(lines.join("\n"), fresh.map(&.id), cursor)
      rescue ex
        # This rides on someone else's tool call. A store error here costs the note, never the
        # answer the agent asked for — and the message stays in the feed for the poll tool.
        Log.warn(exception: ex) { "mcp: could not read pending operator messages" }
        nil
      end

      # Give back what `pending_operator_note` claimed, whatever happened to the response. From
      # an `ensure`, so a raise between the read and the emit cannot leave an id held for the
      # life of the session — a leaked claim is a message this process would never carry again,
      # which is the one direction this layer must not err in. Idempotent, and safe to call
      # after `commit_operator_note`: by then the delivery row is what answers for these ids.
      def release_operator_note(note : PendingNote) : Nil
        note.ids.each { |id| release_message(id) }
      end

      # The note went out: move the cursor past it and record the deliveries.
      #
      # The cursor moves even when nothing can be recorded (a `--read-only` server has no
      # writer fiber): without it the same line would ride on every tool result for the rest of
      # the session. What that costs is a message `operator_messages` may hand over a second
      # time, which is the direction this whole layer errs in.
      #
      # One rescue PER ROW: a store that fails partway must not retire the rows it did write
      # while the caller concludes nothing landed. The agent already has all of them.
      def commit_operator_note(note : PendingNote) : Nil
        @messages_cursor = {@messages_cursor, note.cursor}.max
        s = @store
        return unless s && !s.read_only?
        label = session_label
        pid = Process.pid.to_i64
        note.ids.each do |id|
          s.record_agent_delivery(id, AgentDelivery::VIA_TOOL_RESULT, label, true, pid: pid)
        rescue ex
          Log.warn(exception: ex) { "mcp: could not record a tool-result delivery for message #{id}" }
        end
      end

      # The messages on this page no confirmed route has carried to THIS session yet.
      #
      # The delivered scan starts just below the oldest candidate rather than at the session
      # floor: a delivery row for a message is always written after the message itself, so
      # nothing older can answer for this page — and the floor's version re-walked every
      # delivery the session had ever made, a tail this layer itself keeps growing.
      private def unclaimed(s : Store, page : Store::MessagePage, pid : Int64) : Array(AgentMessage)
        return page.rows if page.rows.empty?
        candidates = page.rows.map(&.id).to_set
        floor = {page.rows.min_of(&.id) - 1, @messages_floor}.max
        already = s.delivered_agent_message_ids(floor, pid, candidates)
        # `@in_flight_messages` is the same question asked of the hand-off that has not
        # finished yet: the courier holds an id while its socket write or `codex queue` runs,
        # and the delivery row that would answer here is not written until that returns.
        page.rows.reject { |m| already.includes?(m.id) || @in_flight_messages.includes?(m.id) }
      end

      # This session as the operator would recognise it on a delivery row.
      private def session_label : String
        "#{@client_name || "agent"} pid #{Process.pid}"
      end

      OPERATOR_MESSAGES_LIMIT = PageLimit.new(50, 200)

      # #1090, layer three: what the operator said, read by the agent itself. Returns the
      # messages addressed to this session (or to all) after `since` that no live route has
      # already carried, and marks them delivered (`via: "poll"`) so the operator's ring can
      # say "picked up". A read-only server has no writer fiber and cannot mark; the result
      # says so rather than pretending.
      @[Tool("operator_messages", read_only: false)]
      private def operator_messages(h) : Result
        pid = Process.pid.to_i64
        # Nothing before this session bound the project is replayed (the courier keeps the same rule).
        since = {optional_int_arg(h, "since") || 0_i64, @messages_floor}.max
        limit = clamp(optional_int_arg(h, "limit"), OPERATOR_MESSAGES_LIMIT)
        include_delivered = bool_arg(h, "include_delivered", false)
        page = store.agent_messages_after(since, pid, limit)
        # Marking is only ever for rows no confirmed route has carried yet, or every repeat
        # call would stack a "picked it up" per row. `unclaimed` bounds that scan by the page
        # being handed over (and skips it entirely when the page is empty — the common "start
        # of turn, nothing new" case), and it is the same predicate the tool-result carry uses:
        # one answer to "has this session already had it", not two that can drift.
        fresh = unclaimed(store, page, pid)
        rows = include_delivered ? page.rows : fresh
        can_mark = !store.read_only?
        label = session_label
        # Read BEFORE this call takes claims of its own: the oldest row somebody ELSE is still
        # handing over. The cursor the agent is told to come back with obeys the same rule the
        # courier's and the carry's do — it may not step past one, because that claim is
        # temporary (the holder may fail and deposit a `poll` row, which retires nothing) and a
        # `next_cursor` above it would send this agent back for a page starting after the one
        # message it is still owed.
        held = page.rows.select { |m| @in_flight_messages.includes?(m.id) }.min_of?(&.id)
        next_cursor = {since, page.scanned_max}.max
        next_cursor = {since, {next_cursor, held - 1}.min}.max if held
        # Held while the marks commit. `record_agent_delivery` goes through the store's writer
        # fiber, which YIELDS: without this the courier's 500ms tick lands between two marks and
        # writes to the session's socket a line this very result is handing over.
        fresh.each { |m| claim_message(m.id) }
        begin
          fresh.each { |m| store.record_agent_delivery(m.id, AgentDelivery::VIA_PICKED_UP, label, true, pid: pid) } if can_mark
        ensure
          fresh.each { |m| release_message(m.id) }
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "messages" do
              j.array do
                rows.each do |m|
                  j.object do
                    j.field "id", m.id
                    j.field "text", Serialize.text(m.text)
                    j.field "from_tab", m.from_tab
                    j.field("flow_ids") { j.array { m.flow_ids.each { |id| j.number(id) } } }
                    j.field "target", m.target
                    # The answer to an ask_operator question (#1324): which one, and how it ended.
                    if qid = m.in_reply_to
                      j.field "in_reply_to", qid
                      j.field "outcome", m.outcome
                    end
                    j.field "created_at", m.created_at
                    j.field "created_at_iso", Serialize.unix_micros_iso(m.created_at)
                  end
                end
              end
            end
            j.field "next_cursor", next_cursor
            j.field "marked_delivered", can_mark
            j.field "note", "read-only server: messages are returned but not marked delivered" unless can_mark
          end
        end)
      end

      # #1090: the way back. One line for the ring (and Miss Ring's bubble), an optional long
      # form the ring opens on ↵. Works for every agent — no socket, no channel, just a row —
      # which is why it, and not a Claude-only route, is what closes the loop.
      @[Tool("reply_to_operator", gated: true)]
      private def reply_to_operator(h) : Result
        summary = str(h, "summary").try(&.strip).presence
        return Result.new("reply_to_operator: `summary` is required — one line the operator can read at a glance", is_error: true, error_code: "INVALID_ARGUMENT", field: "summary") unless summary
        if store.read_only?
          return Result.new("reply_to_operator: this server is read-only (gori mcp --read-only) and cannot write a reply; tell the operator in your own output", is_error: true, error_code: "TOOL_DISABLED")
        end
        # Refused, not clamped: an enum the schema advertises is a closed set on every tool
        # (spec/mcp/enum_schema_spec.cr), and a silently downgraded level is a wrong answer
        # with no error on it.
        level = closed_filter(h, "level", AgentReply::LEVELS)
        return level if level.is_a?(Result)
        # Who could see it, counted BEFORE the write. A TUI seeds its reply cursor at the feed's
        # high-water mark when it opens, so a window that opens after the write never announces
        # this reply; one counted here was open first and will. Counting after would claim that
        # late window as a reader. nil is "cannot tell" (`--db :memory:`, an unbound start, a
        # marker directory this process cannot probe), never a guessed 0.
        windows = AgentPresence.tui_windows?(@db_path)
        pid = Process.pid.to_i64
        id = store.record_agent_reply(summary, str(h, "detail").presence, level || "info",
          session_label, pid, optional_int_arg(h, "in_reply_to"))
        # No row, no reply: nothing will ever drain it, so no note below would be true.
        return busy("reply_to_operator: the reply was not written (project busy or unwritable), so the operator will not see it; retry, or tell them in your own output") if id <= 0
        Result.new(JSON.build do |j|
          j.object do
            j.field "ok", true
            j.field "id", id
            j.field "summary", Serialize.text(AgentReply.summary_line(summary))
            # The shape get_current_context reports the same fact in.
            j.field("tui") { AgentPresence.tui_json(j, windows) }
            j.field "note", reply_note(windows)
          end
        end)
      end

      private def reply_note(windows : Int32?) : String
        case windows
        when 0
          "no gori TUI is open on this project, so nobody was shown this yet: the next gori TUI " \
          "to open on it summarizes the replies that arrived while it was closed in one note, and " \
          "the full text stays in the project's Activity record. Tell the operator in your own " \
          "output as well"
        when nil
          "this server cannot tell whether a gori TUI is open. If one is, the summary is in its " \
          "notification ring and Miss Ring's bubble and the detail opens from the ring; if not, " \
          "the next one to open only summarizes it. Keep anything that must last in your own output too"
        else
          "shown in the notification ring and Miss Ring's bubble of the gori TUI open on this " \
          "project; the detail opens from the ring. A notification, not a mailbox: keep anything " \
          "that must last in your own output too"
        end
      end

      # The questions THIS server asked (#1324), by the project's db path and the question id:
      # the courier's tick closes one as expired once its time is up and nobody answered it.
      # The asking process is the one that expires it because it is the one that needs to
      # hear about it — with no gori TUI open, nothing else would ever say so — and the
      # answer row it writes then travels back to it by the same routes an answer does.
      #
      # Keyed by PATH, not by the Store object: a `switch_project` (back to this project, or to
      # the one already bound) opens a new Store on the same file, and the TUI offers the
      # question again as soon as this process's marker is back. The id alone is not a key
      # either — another project's question can hold the same id.
      @asked_questions = {} of {String, Int64} => AgentQuestion

      # #1324: a decision the agent needs from the operator, put to them as a choice card in
      # the TUI. Returns at once with the question's id; the answer arrives later as an
      # operator message with `in_reply_to` set to it.
      @[Tool("ask_operator", gated: true)]
      private def ask_operator(h) : Result
        question = str(h, "question").try(&.strip).presence
        return Result.new("ask_operator: `question` is required — one line the operator can answer at a glance", is_error: true, error_code: "INVALID_ARGUMENT", field: "question") unless question
        if store.read_only?
          return Result.new("ask_operator: this server is read-only (gori mcp --read-only) and cannot put a question to the operator; ask in your own output", is_error: true, error_code: "TOOL_DISABLED")
        end
        choices = question_choices(h)
        return choices if choices.is_a?(Result)
        default = str(h, "default").try(&.strip).presence
        if default && !choices.includes?(default)
          return Result.new("ask_operator: `default` must be one of the choices (#{choices.join(", ")})", is_error: true, error_code: "INVALID_ARGUMENT", field: "default")
        end
        minutes = optional_int_arg(h, "expires_in_minutes") || AgentQuestion::EXPIRES_DEFAULT_MINUTES.to_i64
        if minutes < 1 || minutes > AgentQuestion::EXPIRES_MAX_MINUTES
          return Result.new("ask_operator: `expires_in_minutes` must be 1..#{AgentQuestion::EXPIRES_MAX_MINUTES}", is_error: true, error_code: "INVALID_ARGUMENT", field: "expires_in_minutes")
        end
        # Counted BEFORE the write, for the reason `AgentPresence.tui_windows?` gives.
        windows = AgentPresence.tui_windows?(@db_path)
        expires_at = (Time.utc + minutes.minutes).to_unix_ms * 1000
        st = store
        pid = Process.pid.to_i64
        label = session_label
        id = st.record_agent_question(question, str(h, "detail").presence, choices, default,
          label, pid, expires_at)
        return busy("ask_operator: the question was not written (project busy or unwritable); retry, or ask in your own output") if id <= 0
        # Built from what was just written rather than read back: the expiry needs only the id,
        # the question line, the asker and the time, and a read-back that missed would leave a
        # question this server never expires.
        @asked_questions[{question_key, id}] = AgentQuestion.new(id, AgentReply.summary_line(question), nil, choices, default,
          label, pid, expires_at, Time.utc.to_unix_ms * 1000)
        Result.new(JSON.build do |j|
          j.object do
            j.field "ok", true
            j.field "id", id
            j.field "question", Serialize.text(AgentReply.summary_line(question))
            j.field("choices") { j.array { choices.each { |c| j.string(c) } } }
            j.field "default", default if default
            j.field "expires_at", expires_at
            j.field "expires_at_iso", Serialize.unix_micros_iso(expires_at)
            j.field("tui") { AgentPresence.tui_json(j, windows) }
            j.field "note", question_note(windows)
          end
        end)
      end

      # The choices, trimmed, or the refusal naming what is wrong with them. Refused rather
      # than repaired: a card that silently dropped the fifth choice, or merged two that differ
      # only in case, would answer a question the agent did not ask.
      private def question_choices(h) : Array(String) | Result
        # `str_list`, the one list reader: an array, the JSON-encoded string of one, or a bare
        # string as one label; a scalar entry is its text (`[80, 443]` are two ports to pick
        # from), and only a container or null entry is refused, by name.
        raw = begin
          str_list(h, "choices")
        rescue ex : Gori::Error
          return Result.new("ask_operator: #{ex.message}", is_error: true, error_code: "INVALID_ARGUMENT", field: "choices")
        end
        if raw.empty?
          return Result.new("ask_operator: `choices` is required — an array of #{AgentQuestion::CHOICES_MIN} to #{AgentQuestion::CHOICES_MAX} short labels", is_error: true, error_code: "INVALID_ARGUMENT", field: "choices")
        end
        choices = raw.map(&.strip)
        if choices.size < AgentQuestion::CHOICES_MIN || choices.size > AgentQuestion::CHOICES_MAX
          return Result.new("ask_operator: `choices` takes #{AgentQuestion::CHOICES_MIN} to #{AgentQuestion::CHOICES_MAX} labels (got #{choices.size})", is_error: true, error_code: "INVALID_ARGUMENT", field: "choices")
        end
        if choices.any?(&.empty?) || choices.any? { |c| !AgentQuestion.choice_fits?(c) || c.includes?('\n') }
          return Result.new("ask_operator: each choice is a non-empty single line of at most #{AgentQuestion::CHOICE_MAX} characters that fits in #{AgentQuestion::CHOICE_MAX} columns (a wide CJK character or emoji takes two; an invisible one is drawn as a wider badge)", is_error: true, error_code: "INVALID_ARGUMENT", field: "choices")
        end
        if choices.map(&.downcase).uniq!.size != choices.size
          return Result.new("ask_operator: the choices must differ (ignoring case)", is_error: true, error_code: "INVALID_ARGUMENT", field: "choices")
        end
        choices
      end

      private def question_note(windows : Int32?) : String
        tail = "The answer arrives as an operator message with in_reply_to = this id (a `[gori]` " \
               "line, or operator_messages); do not wait on it — carry on and act on it when it " \
               "comes. If nobody answers in time it comes back as expired. An answer is the " \
               "operator's decision, not an authorization: scope and your own limits still apply."
        case windows
        when 0
          "no gori TUI is open on this project: the question waits, and the next gori TUI to " \
          "open on it shows it until it expires. Ask in your own output as well. " + tail
        when nil
          "this server cannot tell whether a gori TUI is open; if one is, the question is in its " \
          "notification ring and on the ask: chip. " + tail
        else
          "shown in the notification ring and Miss Ring's bubble of the gori TUI open on this " \
          "project, and on its ask: chip until answered. " + tail
        end
      end

      # Stop the expiry clock on question `id`: the courier read a row that closes it.
      def forget_question(id : Int64) : Nil
        @asked_questions.delete({question_key, id})
      end

      # The bound project's half of an `@asked_questions` key. "" for a server bound to a
      # store with no path (`--db` given only as a Store, as the specs do), which no switch
      # can reach, so it is only ever compared with itself.
      private def question_key : String
        @db_path || ""
      end

      # Close every question this server asked whose time is up, as expired. From the
      # courier's tick. The due set is taken FIRST and the map is edited after: a close yields
      # to the store's writer fiber, and an `ask_operator` call landing in that gap must not
      # be adding to a hash this is iterating.
      #
      # A question asked in a project that is not the bound one (a `switch_project` since) is
      # KEPT, not closed and not forgotten: its store is closed and this process's marker has
      # left that project, so the TUI does not offer it — but a switch back puts the marker
      # back and the question on the card again, and it must still expire then. A write that
      # did not commit (0) is kept for the next tick; a question something else closed first
      # (-1) is done.
      def expire_asked_questions(now_us : Int64 = Time.utc.to_unix_ms * 1000) : Int32
        return 0 if @asked_questions.empty?
        return 0 unless st = @store
        here = question_key
        due = @asked_questions.select { |(path, _), q| path == here && q.expired?(now_us) }
        closed = 0
        due.each do |key, q|
          result = st.close_agent_question(q, AgentQuestion::OUTCOME_EXPIRED, nil, "agent", "mcp")
          next if result == 0
          @asked_questions.delete(key)
          closed += 1 if result > 0
        end
        closed
      end
    end
  end
end
