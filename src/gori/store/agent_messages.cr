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
    ok : Bool, reason : String?, created_at : Int64, pid : Int64 = 0_i64 do
    KIND = "agent_delivery"
    # Routes. `poll` is the courier's DEPOSIT (no live route; the row waits in the feed) and is
    # `ok` — nothing failed. `picked_up` is the agent's own `operator_messages` read.
    VIA_POLL      = "poll"
    VIA_PICKED_UP = "picked_up"

    def self.from_row(row : Store::EventRow) : AgentDelivery?
      return nil unless row.kind == KIND
      h = row.payload.try { |p| JSON.parse(p).as_h? }
      return nil unless h
      mid = h["message_id"]?.try(&.as_i64?) || return nil
      new(row.id, mid, h["via"]?.try(&.as_s?) || VIA_POLL, h["target"]?.try(&.as_s?) || "agent",
        h["ok"]?.try(&.as_bool?) || false, h["reason"]?.try(&.as_s?), row.created_at,
        h["pid"]?.try(&.as_i64?) || 0_i64)
    rescue JSON::ParseException
      nil
    end
  end

  # The agent's answer to the operator (#1090): one line for the ring and Miss Ring's bubble,
  # an optional long form the ring opens on ↵. `source: "agent"`, `kind: "agent_reply"`,
  # `actor: "mcp"` — the same row shape the agent's other actions already leave in the feed.
  record AgentReply, id : Int64, summary : String, detail : String?, level : String,
    target_label : String, pid : Int64, in_reply_to : Int64?, created_at : Int64 do
    KIND   = "agent_reply"
    LEVELS = %w[info success warn error]
    # A summary is ONE line for a one-row ring; a detail is bounded like any stored blob.
    SUMMARY_MAX = 200
    DETAIL_MAX  = 32 * 1024

    def self.from_row(row : Store::EventRow) : AgentReply?
      return nil unless row.kind == KIND
      h = row.payload.try { |p| JSON.parse(p).as_h? } || {} of String => JSON::Any
      new(row.id, row.message, h["detail"]?.try(&.as_s?), row.level,
        h["target"]?.try(&.as_s?) || "agent", h["pid"]?.try(&.as_i64?) || 0_i64,
        h["in_reply_to"]?.try(&.as_i64?), row.created_at)
    rescue JSON::ParseException
      nil
    end

    # The first line of what the agent sent, capped — the rest belongs in `detail`.
    def self.summary_line(text : String) : String
      line = text.each_line.first? || ""
      line = line.strip
      line.size > SUMMARY_MAX ? line[0, SUMMARY_MAX - 1] + "…" : line
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
    # session as the operator would recognise it (`claude-code pid 48213`), `pid` the courier
    # process that handled it — a broadcast has one row PER recipient, and the poll layer must
    # not read claude-code's socket delivery as "codex already has it".
    def record_agent_delivery(message_id : Int64, via : String, target : String, ok : Bool,
                              reason : String? = nil, pid : Int64 = 0_i64) : Int64
      level = !ok ? "warn" : (via == AgentDelivery::VIA_POLL ? "info" : "success")
      summary =
        if !ok
          "#{target}: #{reason || "not delivered"}"
        elsif via == AgentDelivery::VIA_POLL
          "left for #{target} to pick up"
        else
          "delivered to #{target} (#{via})"
        end
      payload = JSON.build do |j|
        j.object do
          j.field "message_id", message_id
          j.field "via", via
          j.field "target", target
          j.field "ok", ok
          j.field "pid", pid
          j.field "reason", reason if reason
        end
      end
      insert_event("operator", AgentDelivery::KIND, level, summary, payload: payload)
    end

    # The agent's reply. `level` outside `AgentReply::LEVELS` becomes `info`; `detail` is cut
    # to `DETAIL_MAX` on a character boundary (the row says so with a trailing marker).
    def record_agent_reply(summary : String, detail : String?, level : String, target : String,
                           pid : Int64, in_reply_to : Int64? = nil) : Int64
      level = AgentReply::LEVELS.includes?(level) ? level : "info"
      if (d = detail) && d.bytesize > AgentReply::DETAIL_MAX
        # Cut on a character boundary: `scrub` turns a split sequence into U+FFFD, dropped.
        detail = String.new(d.to_slice[0, AgentReply::DETAIL_MAX]).scrub.rchop('\uFFFD') + "\n… (cut)"
      end
      payload = JSON.build do |j|
        j.object do
          j.field "target", target
          j.field "pid", pid
          j.field "detail", detail if detail
          j.field "in_reply_to", in_reply_to if in_reply_to
        end
      end
      insert_event("agent", AgentReply::KIND, level, AgentReply.summary_line(summary), payload: payload, actor: "mcp")
    end

    record ReplyPage, rows : Array(AgentReply), scanned_max : Int64, full : Bool

    def agent_replies_after(since_id : Int64, limit : Int32 = 100) : ReplyPage
      rows = [] of AgentReply
      scanned, full = each_event_of_kind(AgentReply::KIND, since_id, limit) do |row|
        AgentReply.from_row(row).try { |r| rows << r }
      end
      ReplyPage.new(rows, scanned, full)
    end

    # One page of the kind-filtered feed. `scanned_max` is the id of the LAST ROW THE SQL PAGE
    # RETURNED, matching or not, and `full` says the page hit its limit — a cursor must advance
    # to `scanned_max` when full (there may be more behind it) and may jump to the feed's
    # high-water mark only when it was not. Advancing only past MATCHING rows is how a courier
    # starves behind fifty messages for someone else (the review's repro).
    record MessagePage, rows : Array(AgentMessage), scanned_max : Int64, full : Bool
    record DeliveryPage, rows : Array(AgentDelivery), scanned_max : Int64, full : Bool

    # Messages after `since_id` (feed cursor), oldest first, addressed to `pid` or to all.
    def agent_messages_after(since_id : Int64, pid : Int64, limit : Int32 = 100) : MessagePage
      rows = [] of AgentMessage
      scanned, full = each_event_of_kind(AgentMessage::KIND, since_id, limit) do |row|
        if (m = AgentMessage.from_row(row)) && m.for?(pid)
          rows << m
        end
      end
      MessagePage.new(rows, scanned, full)
    end

    def agent_deliveries_after(since_id : Int64, limit : Int32 = 100) : DeliveryPage
      rows = [] of AgentDelivery
      scanned, full = each_event_of_kind(AgentDelivery::KIND, since_id, limit) do |row|
        AgentDelivery.from_row(row).try { |d| rows << d }
      end
      DeliveryPage.new(rows, scanned, full)
    end

    # One SQL page of one kind, oldest first. Yields every row the page returned and answers
    # {last scanned id, page was full} — the two facts every cursor over this feed needs, in
    # one place, so the "advance past what was scanned, not past what matched" rule cannot
    # drift between the readers.
    private def each_event_of_kind(kind : String, since_id : Int64, limit : Int32, & : EventRow ->) : {Int64, Bool}
      scanned = since_id
      count = 0
      @db.query("SELECT #{EVENT_COLS} FROM events WHERE id > ? AND kind = ? ORDER BY id ASC LIMIT ?",
        args: [since_id, kind, limit.to_i64] of DB::Any) do |rs|
        rs.each do
          row = read_event(rs)
          scanned = row.id
          count += 1
          yield row
        end
      end
      {scanned, count >= limit}
    end

    # The feed's high-water mark — where a courier or a delivery tail STARTS, so a session that
    # attaches later never replays what was said before it arrived.
    def last_event_id : Int64
      @db.scalar("SELECT COALESCE(MAX(id), 0) FROM events").as(Int64)
    rescue
      0_i64
    end

    # The delivery tail's starting cursor: the feed's end. A delivery is a feed row, so the
    # high-water mark of the feed is the high-water mark of deliveries too; one number, so the
    # TUI's tail and the courier's cursor can never disagree about where "now" is.
    def last_agent_delivery_id : Int64
      last_event_id
    end

    # Which message ids THIS session (`pid`) has already been handed by a live route or its
    # own poll, for `operator_messages`: only rows that landed (`ok`), and only this
    # recipient's — a broadcast delivered to another session is still owed to this one.
    def delivered_agent_message_ids(since_id : Int64, pid : Int64) : Set(Int64)
      ids = Set(Int64).new
      cursor = since_id
      loop do
        page = agent_deliveries_after(cursor, 500)
        page.rows.each { |d| ids << d.message_id if d.ok && d.pid == pid && d.via != AgentDelivery::VIA_POLL }
        break unless page.full
        cursor = page.scanned_max
      end
      ids
    end
  end
end
