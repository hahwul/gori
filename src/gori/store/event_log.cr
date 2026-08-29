require "db"

module Gori
  class Store
    # Append one row to the #124 event feed (the AI firehose). Goes through the writer
    # fiber like every other insert; returns last_insert_rowid (0 on a dropped/closed-store
    # write — the caller decides whether a lost event matters). NEVER used for flow rows
    # (flows are the firehose via list_history); this is job-lifecycle + agent-action events.
    # `actor` defaults to whichever surface this process is (`FlowSource.surface`, set once at
    # the entry point), so every producer records WHO without each one remembering to. Pass it
    # explicitly only to say something the ambient value cannot — `nil` for an event no surface
    # asked for.
    def insert_event(source : String, kind : String, level : String, message : String, *,
                     goto_tab : String? = nil, goto_session_id : Int64? = nil,
                     flow_id : Int64? = nil, payload : String? = nil,
                     actor : String? = FlowSource.surface.try(&.token)) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO events (created_at, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload, actor) VALUES (?,?,?,?,?,?,?,?,?,?)",
          now_us, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload, actor)
        nil
      }
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
