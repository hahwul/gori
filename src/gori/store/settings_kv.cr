require "db"
require "json"

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

    # The same row, under the name that describes what it now holds. An Authorize identity IS
    # a session slot (`Gori::SessionSlot`, DESIGN.md §7 2026-08-17), so there is one list and
    # one settings row for both. The stored KEY STRING deliberately stays
    # `authorize_identities`: an existing project's identities are its slots, and renaming the
    # row would orphan every one of them on upgrade while reporting a clean open.
    SESSION_SLOTS_KEY = AUTHORIZE_IDENTITIES_KEY

    # The project's own redaction config (#1035), as a JSON object:
    # `{"active": "<profile name>", "default": true, "profiles": [ … ]}`. Per PROJECT because
    # the half of a profile that names a TARGET's fields ("this API spells it `pwd_hash`, and
    # the account number lives at `/data/acct`") is engagement data: it is useless in the next
    # engagement and carrying it there would quietly widen what a default export replaces.
    # The half that is the operator's own policy stays in settings.json. `Redact::Policy` folds
    # the two.
    REDACTION_KEY = "redaction"

    # The hosts an operator approved for `gori mcp` sends from the approval card (#1585), as a
    # JSON array of `host` (any port) and `host:port` strings. Per PROJECT because a target
    # belongs to one engagement, and dropped on archive import (`ProjectArchive`): an approval
    # is authorization, never data a snapshot may carry in.
    MCP_HOST_GRANTS_KEY = "mcp_host_grants"

    def mcp_host_grants : Array(String)
      raw = setting(MCP_HOST_GRANTS_KEY) || return [] of String
      Array(String).from_json(raw)
    rescue JSON::ParseException
      [] of String
    end

    # Add one grant; whether it is now stored.
    # ponytail: read-modify-write, so two servers granting at once can lose one grant (it is
    # asked again — the closed direction); a table with a unique key if that ever matters.
    def add_mcp_host_grant(grant : String) : Bool
      grants = mcp_host_grants
      return true if grants.includes?(grant)
      set_setting(MCP_HOST_GRANTS_KEY, (grants << grant).to_json)
    end

    def setting(key : String) : String?
      @db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
    end

    # Does `key` hold exactly `value` right now (nil = no row)? Compared inside SQLite, so a
    # caller polling a large value for change — the Notes set is one JSON row, megabytes for a
    # big engagement — does not copy the whole value out on every poll just to find it equal.
    def setting_is?(key : String, value : String?) : Bool
      hit = @db.query_one?("SELECT value IS ? FROM settings WHERE key = ?", value, key, as: Int64)
      value.nil? ? hit.nil? : hit == 1
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

    # Several rows in ONE writer task, so they commit or roll back together. A nil value
    # deletes its key. For rows that are only meaningful as a set — a proxy address and the
    # credentials pinned to it — per-key writes can land one half and lose the other, leaving
    # the project pointing a live secret at the address it used to have. Returns whether the
    # batch COMMITTED, like the single-key calls above.
    def set_settings(entries : Array({String, String?})) : Bool
      return true if entries.empty?
      exec_task_ok ->(c : DB::Connection) {
        entries.each do |(key, value)|
          if value
            c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", key, value, value)
          else
            c.exec("DELETE FROM settings WHERE key = ?", key)
          end
        end
        nil
      }
    end
  end
end
