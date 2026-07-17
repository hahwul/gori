require "db"

module Gori
  class Store
    # Append one row to the #124 event feed (the AI firehose). Goes through the writer
    # fiber like every other insert; returns last_insert_rowid (0 on a dropped/closed-store
    # write — the caller decides whether a lost event matters). NEVER used for flow rows
    # (flows are the firehose via list_history); this is job-lifecycle + agent-action events.
    def insert_event(source : String, kind : String, level : String, message : String, *,
                     goto_tab : String? = nil, goto_session_id : Int64? = nil,
                     flow_id : Int64? = nil, payload : String? = nil) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO events (created_at, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload) VALUES (?,?,?,?,?,?,?,?,?)",
          now_us, source, kind, level, message, goto_tab, goto_session_id, flow_id, payload)
        nil
      }
    end
  end
end
