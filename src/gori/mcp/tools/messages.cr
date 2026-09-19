require "json"
require "../../store"
require "../operator_note"
require "../serialize"

module Gori
  module MCP
    class Tools
      # How many pending messages one tool result carries. A bound, not a cap on what the
      # operator may say: the cursor advances only past what was scanned, so a longer backlog
      # rides out over the next few calls instead of burying one tool's answer under it.
      TOOL_RESULT_MESSAGES = 5

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
      # Carried, so it retires the message: the client requested this result and was answered,
      # which is the same standard the socket write is held to ("landed", never "acted on").
      # The cost is the one the courier already accepts — a message the courier is delivering
      # by socket in its own fiber at this instant can be read twice — and re-reading beats the
      # silent loss the other stance would buy.
      #
      # `nil` when there is nothing to say, which is the overwhelmingly common case and costs
      # one `MAX(id)` scalar (the courier's idle gate, for the same reason).
      def pending_operator_note(tool : String) : String?
        # The poll tool answers with these itself, and has already marked them.
        return nil if tool == "operator_messages"
        s = @store
        return nil unless s
        high = s.last_event_id
        return nil if high <= @messages_cursor
        pid = Process.pid.to_i64
        page = s.agent_messages_after(@messages_cursor, pid, TOOL_RESULT_MESSAGES)
        candidates = page.rows.map(&.id).to_set
        already = candidates.empty? ? Set(Int64).new : s.delivered_agent_message_ids(@messages_floor, pid, candidates)
        # Advance past what was SCANNED, never past what matched — a page full of another
        # session's messages must not strand this session's behind it (the courier's rule).
        @messages_cursor =
          if page.full
            {@messages_cursor, page.scanned_max}.max
          else
            {@messages_cursor, page.scanned_max, high}.max
          end
        fresh = page.rows.reject { |m| already.includes?(m.id) }
        return nil if fresh.empty?
        label = "#{@client_name || "agent"} pid #{pid}"
        # A read-only server has no writer fiber: the note still goes out, and `operator_messages`
        # may hand the same line over again because nothing could record that this one landed.
        unless s.read_only?
          fresh.each do |m|
            s.record_agent_delivery(m.id, AgentDelivery::VIA_TOOL_RESULT, label, true, pid: pid)
          end
        end
        fresh.map { |m| OperatorNote.frame(m.text, m.from_tab, m.flow_ids, m.id) }.join("\n")
      rescue ex
        # This rides on someone else's tool call. A store error here costs the note, never the
        # answer the agent asked for — and the message stays in the feed for the poll tool.
        Log.warn(exception: ex) { "mcp: could not read pending operator messages" }
        nil
      end

      # #1090, layer three: what the operator said, read by the agent itself. Returns the
      # messages addressed to this session (or to all) after `since` that no live route has
      # already carried, and marks them delivered (`via: "poll"`) so the operator's ring can
      # say "picked up". A read-only server has no writer fiber and cannot mark; the result
      # says so rather than pretending.
      @[Tool("operator_messages")]
      private def operator_messages(h) : Result
        pid = Process.pid.to_i64
        # Nothing before this session bound the project is replayed (the courier keeps the same rule).
        since = {optional_int_arg(h, "since") || 0_i64, @messages_floor}.max
        limit = clamp(optional_int_arg(h, "limit"), 50, 200)
        include_delivered = bool_arg(h, "include_delivered", false)
        page = store.agent_messages_after(since, pid, limit)
        # Marking is only ever for rows no confirmed route has carried yet, or every repeat
        # call would stack a "picked it up" per row. Ask only about THIS page's ids (and not at
        # all when the page is empty — the common "start of turn, nothing new" case), so the
        # delivery scan is bounded by what we are handing over, not by the session's history.
        candidates = page.rows.map(&.id).to_set
        already = candidates.empty? ? Set(Int64).new : store.delivered_agent_message_ids(since, pid, candidates)
        fresh = page.rows.reject { |m| already.includes?(m.id) }
        rows = include_delivered ? page.rows : fresh
        can_mark = !store.read_only?
        label = "#{@client_name || "agent"} pid #{pid}"
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
      @[Tool("reply_to_operator")]
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
        label = "#{@client_name || "agent"} pid #{pid}"
        id = store.record_agent_reply(summary, str(h, "detail").presence, level || "info",
          label, pid, optional_int_arg(h, "in_reply_to"))
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
