require "json"

module Gori
  # One line the operator sent from the TUI to an attached agent session (#1090), as the
  # `events` feed carries it: `source = "operator"`, `kind = "agent_message"`, the text in
  # `message`, the addressing in `payload`. No table of its own — the feed already has the
  # never-reused AUTOINCREMENT cursor every courier needs, the retention sweep, and a reader
  # (`list_events`) on every surface.
  #
  # `target` is `"all"` or `"pid:<n>"`, where `<n>` is the pid of the `gori mcp` PROCESS
  # (`AgentPresence::Entry#pid` for a kind-`mcp` entry) — the one thing the TUI can name and
  # the one thing the courier inside that process knows about itself. Not the agent's own
  # pid: the TUI never sees it, and it differs per client.
  record AgentMessage, id : Int64, text : String, target : String, from_tab : String?,
    flow_ids : Array(Int64), created_at : Int64 do
    def self.payload_json(target : String, from_tab : String?, flow_ids : Array(Int64)) : String
      JSON.build do |j|
        j.object do
          j.field "target", target
          j.field "from_tab", from_tab if from_tab
          j.field("flow_ids") { j.array { flow_ids.each { |id| j.number(id) } } } unless flow_ids.empty?
        end
      end
    end

    # A feed row → a message, or nil when the payload does not parse as one (a hand-written
    # row through `insert_event`; ignored rather than delivered blind).
    def self.from_row(row : Store::EventRow) : AgentMessage?
      return nil unless row.kind == KIND
      h = row.payload.try { |p| JSON.parse(p).as_h? }
      return nil unless h
      target = h["target"]?.try(&.as_s?) || return nil
      ids = h["flow_ids"]?.try(&.as_a?).try(&.compact_map(&.as_i64?)) || [] of Int64
      new(row.id, row.message, target, h["from_tab"]?.try(&.as_s?), ids, row.created_at)
    rescue JSON::ParseException
      nil
    end

    # Is this message for the courier running in process `pid`?
    def for?(pid : Int64) : Bool
      target == "all" || target == "pid:#{pid}"
    end

    KIND   = "agent_message"
    SOURCE = "operator"
  end

  # What a courier (or the agent's own `operator_messages` call) reported about one message:
  # which route carried it and whether it landed. `via` is `channel` / `socket` / `poll`;
  # `ok: false` with `via: "poll"` means "no live route, left in the feed for the agent to read".
  record AgentDelivery, id : Int64, message_id : Int64, via : String, target_label : String,
    ok : Bool, reason : String?, created_at : Int64 do
    KIND = "agent_delivery"

    def self.from_row(row : Store::EventRow) : AgentDelivery?
      return nil unless row.kind == KIND
      h = row.payload.try { |p| JSON.parse(p).as_h? }
      return nil unless h
      mid = h["message_id"]?.try(&.as_i64?) || return nil
      new(row.id, mid, h["via"]?.try(&.as_s?) || "poll", h["target"]?.try(&.as_s?) || "agent",
        h["ok"]?.try(&.as_bool?) || false, h["reason"]?.try(&.as_s?), row.created_at)
    rescue JSON::ParseException
      nil
    end
  end

  class Store
    # Post one operator message. `from_tab` and `flow_ids` are context for the reader (which
    # tab the operator was on, what they had marked), never inlined into the text.
    def post_agent_message(text : String, target : String, from_tab : String?,
                           flow_ids : Array(Int64) = [] of Int64) : Int64
      insert_event("operator", AgentMessage::KIND, "info", text,
        payload: AgentMessage.payload_json(target, from_tab, flow_ids), actor: "tui")
    end

    # Record how a message was (or was not) delivered. `via` names the route, `target` the
    # session as the operator would recognise it (`claude-code pid 48213`).
    def record_agent_delivery(message_id : Int64, via : String, target : String, ok : Bool,
                              reason : String? = nil) : Int64
      level = ok ? "success" : (via == "poll" ? "info" : "warn")
      summary = ok ? "delivered to #{target} (#{via})" : "#{target}: #{reason || "not delivered"}"
      payload = JSON.build do |j|
        j.object do
          j.field "message_id", message_id
          j.field "via", via
          j.field "target", target
          j.field "ok", ok
          j.field "reason", reason if reason
        end
      end
      insert_event("operator", AgentDelivery::KIND, level, summary, payload: payload)
    end

    # Messages after `since_id` (feed cursor), oldest first, addressed to `pid` or to all.
    def agent_messages_after(since_id : Int64, pid : Int64, limit : Int32 = 100) : Array(AgentMessage)
      rows = [] of AgentMessage
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id > ? AND kind = ? ORDER BY id ASC LIMIT ?",
        args: [since_id, AgentMessage::KIND, limit.to_i64] of DB::Any) do |rs|
        rs.each do
          if (m = AgentMessage.from_row(read_event(rs))) && m.for?(pid)
            rows << m
          end
        end
      end
      rows
    end

    def agent_deliveries_after(since_id : Int64, limit : Int32 = 100) : Array(AgentDelivery)
      rows = [] of AgentDelivery
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id > ? AND kind = ? ORDER BY id ASC LIMIT ?",
        args: [since_id, AgentDelivery::KIND, limit.to_i64] of DB::Any) do |rs|
        rs.each { AgentDelivery.from_row(read_event(rs)).try { |d| rows << d } }
      end
      rows
    end

    # The feed's high-water mark — where a courier or a delivery tail STARTS, so a session that
    # attaches later never replays what was said before it arrived.
    def last_event_id : Int64
      @db.scalar("SELECT COALESCE(MAX(id), 0) FROM events").as(Int64)
    rescue
      0_i64
    end

    # Which message ids the agent's own poll has already been handed, for `operator_messages`:
    # every delivery row naming a message, regardless of route.
    def delivered_agent_message_ids(since_id : Int64) : Set(Int64)
      ids = Set(Int64).new
      agent_deliveries_after(since_id, 500).each { |d| ids << d.message_id if d.ok }
      ids
    end
  end
end
