require "json"
require "../../store"
require "../serialize"

module Gori
  module MCP
    class Tools
      # #1090, layer three: what the operator said, read by the agent itself. Returns the
      # messages addressed to this session (or to all) after `since` that no live route has
      # already carried, and marks them delivered (`via: "poll"`) so the operator's ring can
      # say "picked up". A read-only server has no writer fiber and cannot mark; the result
      # says so rather than pretending.
      @[Tool("operator_messages")]
      private def operator_messages(h) : Result
        pid = Process.pid.to_i64
        # Nothing before this session attached is replayed — the same rule the courier keeps.
        # The floor is the feed's end at bind time, taken once per store.
        floor = operator_messages_floor
        since = {optional_int_arg(h, "since") || 0_i64, floor}.max
        limit = clamp(optional_int_arg(h, "limit"), 50, 200)
        include_delivered = bool_arg(h, "include_delivered", false)
        page = store.agent_messages_after(since, pid, limit)
        already = include_delivered ? Set(Int64).new : store.delivered_agent_message_ids(since, pid)
        rows = page.rows.reject { |m| already.includes?(m.id) }
        can_mark = !store.read_only?
        label = "#{@client_name || "agent"} pid #{pid}"
        rows.each { |m| store.record_agent_delivery(m.id, AgentDelivery::VIA_PICKED_UP, label, true, pid: pid) } if can_mark
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

      # The feed's end when this store was bound: `operator_messages{since:0}` reads from here,
      # never from the project's first day. Keyed on the store object so a `switch_project`
      # takes a new floor with the new feed.
      private def operator_messages_floor : Int64
        s = store
        if @messages_floor_store != s.object_id
          @messages_floor_store = s.object_id
          @messages_floor = s.last_event_id
        end
        @messages_floor
      end

      @messages_floor = 0_i64
      @messages_floor_store = nil.as(UInt64?)
    end
  end
end
