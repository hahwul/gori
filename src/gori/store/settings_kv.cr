require "db"

module Gori
  class Store
    # Key under which the TUI records what the user is currently viewing (active tab,
    # focus pane, selected flow, sub-tab) so a separate `gori mcp` process can report it
    # via get_current_context. Written cross-process through the shared settings table.
    UI_STATE_KEY = "ui_state"

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
