require "db"

module Gori
  class Store
    # Every `source` the #124 feed carries, as the producers spell it. The column is a free
    # string — `insert_event` takes whatever it is handed — so this is the list of what is
    # actually WRITTEN, and it exists because three surfaces had each grown their own copy of
    # it: the Activity pane's filter cycle (`ACT_SOURCES`), that filter's keybinding help in
    # `verbs/activity.cr` (which had already lost `config`), and the MCP `list_events{source}`
    # schema. All three read this now. A filter offering a source nothing writes returns an
    # empty feed that reads as "nothing happened".
    #
    # Ordered the way a reader wants them: who acted first (`agent`, `config`, `issues`), then
    # the background producers.
    #
    # `issues` is the one that proves the list has to live here. `runner/evidence.cr` started
    # writing it (an operator froze a copy of a flow onto an issue) without registering it, and
    # because the column is a free string nothing complained: the rows landed in the feed, the
    # Activity pane's `s` chip could never narrow to them, and MCP `list_events{source:"issues"}`
    # was REFUSED as invalid while naming a set that omitted a source the project writes. A
    # writer that is not in this list is reachable only by reading the whole feed.
    EVENT_SOURCES = %w[agent config issues bindings rewriter probe discover fuzzer miner sequencer]

    # Every `level` the feed carries, in the order the Activity pane's `l` chip cycles them.
    # Here for the reason EVENT_SOURCES is: the column is a free string and this is the list of
    # what is actually written.
    EVENT_LEVELS = %w[info success warn error]

    # The feed's spelling of a producer's level SYMBOL.
    #
    # The four job controllers (fuzzer, miner, sequencer, discover) each pick a level as a symbol
    # and hand the SAME symbol to the notification centre, whose vocabulary is not this one:
    # `:warning` is a tray level, `warn` is the feed's. Spelling it straight through with
    # `level.to_s` made the Sequencer the one producer of ten writing "warning", which the
    # Activity pane then had to match on TOP of "warn" (`act_level_set`) or its chip would hide
    # half the feed's warnings, and which an MCP reader comparing `level` still sees as two words
    # for one level. Everything else passes through — `:info`, `:success` and `:error` are
    # spelled the same on both sides.
    def self.event_level(level : Symbol) : String
      level == :warning ? "warn" : level.to_s
    end

    # The Symbol form, which is what a producer holding a level symbol must call.
    #
    # At the SINK, not at the four call sites. Spelling it per-producer is what let the
    # divergence in the first place — each one reaches for `level.to_s` because it is already
    # handing that symbol to the notification centre — and a fix applied at four call sites is a
    # fix the fifth producer does not get. There is exactly one door into this table, so the
    # vocabulary is decided on the way through it.
    def insert_event(source : String, kind : String, level : Symbol, message : String, *,
                     goto_tab : String? = nil, goto_session_id : Int64? = nil,
                     flow_id : Int64? = nil, payload : String? = nil,
                     actor : String? = nil) : Int64
      insert_event(source, kind, Store.event_level(level), message,
        goto_tab: goto_tab, goto_session_id: goto_session_id,
        flow_id: flow_id, payload: payload, actor: actor)
    end

    # Append one row to the #124 event feed (the AI firehose). Goes through the writer
    # fiber like every other insert; returns last_insert_rowid (0 on a dropped/closed-store
    # write — the caller decides whether a lost event matters). NEVER used for flow rows
    # (flows are the firehose via list_history); this is job-lifecycle + agent-action events.
    # `actor` defaults to nil — NOT to the ambient surface — and the difference is the whole
    # point of the column. Most producers here are background engines: a binding that missed, a
    # hook that failed, an `Alt-Svc` notice the capture proxy wrote about a client's own
    # request. No surface acted in any of those, and defaulting would file every one of them
    # under whichever process happened to observe it: `tui` in the TUI, `mcp` inside an MCP
    # server, for the same event. That is worse than an empty column, because the actor filter
    # would then return them as the operator's own doing.
    #
    # A surface is claimed only where one demonstrably acted — `ConfigLog.record` (a human or an
    # agent changed a setting) and `log_agent_action` (an agent called a tool), both of which
    # pass `FlowSource.surface` explicitly.
    def insert_event(source : String, kind : String, level : String, message : String, *,
                     goto_tab : String? = nil, goto_session_id : Int64? = nil,
                     flow_id : Int64? = nil, payload : String? = nil,
                     actor : String? = nil) : Int64
      # `event: true` is what puts this write on the `events` retention cadence
      # (`Store::EVENTS_TRIM_INTERVAL`). Without it the cap is enforced only by the FLOW-insert
      # sweep, which never runs in an MCP server or a TUI with capture off — the two surfaces
      # that write most of these rows.
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO events (created_at, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload, actor) VALUES (?,?,?,?,?,?,?,?,?,?)",
          now_us, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload, actor)
        nil
      }, event: true
    end

    # Empty the #124 feed. The human-facing counterpart to retention's `trim_events`, for an
    # operator who wants the log to start at "now" — a new engagement phase in the same project.
    #
    # `id` is AUTOINCREMENT, so SQLite keeps the high-water mark in `sqlite_sequence` and a row
    # inserted after this still gets an id above every id that ever existed. That is what keeps
    # an agent's `events_after` watermark sound across a clear: it matches nothing until new
    # events arrive, and can never be handed a REUSED id belonging to a different event. The
    # same property `trim_events` relies on, for the same reason.
    def clear_events : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM events")
        nil
      }
    end
  end
end
