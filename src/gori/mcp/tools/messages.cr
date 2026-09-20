require "json"
require "../../store"
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
        lines = fresh.map { |m| OperatorNote.frame(Serialize.text(m.text), m.from_tab, m.flow_ids, m.id) }
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
        limit = clamp(optional_int_arg(h, "limit"), 50, 200)
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
        fresh.each { |m| store.record_agent_delivery(m.id, AgentDelivery::VIA_PICKED_UP, label, true, pid: pid) } if can_mark
        next_cursor = {since, page.scanned_max}.max
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
      @[Tool("reply_to_operator", read_only: false)]
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
        pid = Process.pid.to_i64
        id = store.record_agent_reply(summary, str(h, "detail").presence, level || "info",
          session_label, pid, optional_int_arg(h, "in_reply_to"))
        Result.new(JSON.build do |j|
          j.object do
            j.field "ok", id > 0
            j.field "id", id
            j.field "summary", Serialize.text(AgentReply.summary_line(summary))
            j.field "note", "the operator sees the summary in gori's notification ring (and Miss Ring's bubble); the detail opens from the ring"
          end
        end)
      end
    end
  end
end
