require "db"

module Gori
  class Store
    # Key under which the TUI records what the user is currently viewing (active tab,
    # focus pane, selected flow, sub-tab) so a separate `gori mcp` process can report it
    # via get_current_context. Written cross-process through the shared settings table.
    UI_STATE_KEY = "ui_state"

    # The Decoder tab's open sub-tabs ({input, chain, name}), as a JSON array. Per PROJECT,
    # not settings.json: a conversion is normally material lifted from THIS project's traffic
    # (send-to-Decoder from History), so it must not follow the operator into the next
    # project. The NAMED chains (`decoder.chains`) stay global — a chain spec is tool config,
    # not engagement data.
    DECODER_SESSIONS_KEY = "decoder_sessions"

    # The Rewriter tab's editable preview sample (the left pane of the live preview pair).
    # Per project for the same reason: an operator pastes a real captured request in there to
    # see what the rules do to it. Absent = show RewriterController::DEFAULT_SAMPLE.
    REWRITER_SAMPLE_KEY = "rewriter_sample"

    # The Authorize tab's identities (name + header overlay), as a JSON array. Per PROJECT
    # because a session cookie belongs to one target — carrying it into the next engagement
    # would be both useless and a disclosure. The values are stored in PLAINTEXT, exactly as
    # `env.vars` already is on this same table; the tree is 0700 and the DB 0600.
    AUTHORIZE_IDENTITIES_KEY = "authorize_identities"

    def setting(key : String) : String?
      @db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    end

    # Returns whether the write committed (false = store busy/locked/closing). Most callers
    # (high-frequency UI-state writes) ignore it; a caller that must confirm the value
    # persisted (an MCP mutation tool) checks it and surfaces PROJECT_BUSY on false.
    def set_setting(key : String, value : String) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", key, value, value)
        nil
      }
    end

    # Drop a per-project setting so `setting(key)` reads nil again (the Project settings pane
    # clears a network override this way — reverting the field to inherit the global value).
    # Returns whether the write committed (false = store busy/locked/closing).
    def delete_setting(key : String) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM settings WHERE key = ?", key)
        nil
      }
    end
  end
end
