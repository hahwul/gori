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
        # Nothing before this session bound the project is replayed (the courier keeps the same rule).
        since = {optional_int_arg(h, "since") || 0_i64, @messages_floor}.max
        limit = clamp(optional_int_arg(h, "limit"), 50, 200)
        include_delivered = bool_arg(h, "include_delivered", false)
        page = store.agent_messages_after(since, pid, limit)
        # Always known, whatever the caller asked for: marking is only ever for rows no
        # route has carried yet, or every repeat call would stack a "picked it up" per row.
        already = store.delivered_agent_message_ids(since, pid)
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
    end
  end
end
