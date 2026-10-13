require "db"
require "json"
require "../dial_address"

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

    # Drop every grant for `host` (bare or with any port), compared in `OverrideHost.key` form:
    # a host override repointing that name means an approval given for it named a server it no
    # longer dials.
    def drop_mcp_host_grants(host : String) : Nil
      key = OverrideHost.key(host)
      grants = mcp_host_grants
      kept = grants.reject { |g| OverrideHost.key(Store.grant_host(g)) == key }
      set_setting(MCP_HOST_GRANTS_KEY, kept.to_json) unless kept.size == grants.size
    end

    # The host half of a grant: `host:port` loses its port, a bare host is itself.
    def self.grant_host(grant : String) : String
      host, sep, port = grant.rpartition(':')
      !sep.empty? && !port.empty? && port.each_char.all?(&.ascii_number?) ? host : grant
    end

    # The project-wide outbound request budget's shared rows (#1601), written only by
    # `lease_outbound_slots`: the next free rate slot (unix µs) and the requests counted against
    # `net.outbound_max_requests`.
    OUTBOUND_BUDGET_NEXT_KEY  = "outbound.budget.next_slot_us"
    OUTBOUND_BUDGET_SPENT_KEY = "outbound.budget.spent"
    # How far ahead of now the shared clock may run before a lease waits instead (one lease's span).
    OUTBOUND_LEASE_SPAN_US = 250_000_i64

    # Claim up to `want` request slots for `Outbound::Budget` in ONE transaction opened
    # `BEGIN IMMEDIATE`, so this read-modify-write is atomic against every other gori process on
    # the same DB, which is what makes the ceiling project-wide.
    #
    # Returns `{at_us, granted}`: `granted` slots `interval_us` apart starting at `at_us`; or none
    # granted and `at_us` the instant to ask again, because the shared clock already runs more
    # than `OUTBOUND_LEASE_SPAN_US` into the future; or `{0, 0}` when `max` is spent. nil when the
    # store was busy. `refund` hands back requests an earlier lease counted and never sent. The
    # count moves only while a `max` is set, so a total set later starts from zero.
    def lease_outbound_slots(now_us : Int64, interval_us : Int64, want : Int32, max : Int64?,
                             refund : Int64) : {Int64, Int32}?
      res = {0_i64, 0}
      run = ->(c : DB::Connection) { res = lease_outbound_rows(c, now_us, interval_us, want, max, refund); nil }
      ok = @read_only ? lease_on_reader(run) : exec_task_ok(run)
      ok ? res : nil
    end

    # The arithmetic of `lease_outbound_slots`, inside its transaction on `c`.
    private def lease_outbound_rows(c : DB::Connection, now_us : Int64, interval_us : Int64, want : Int32,
                                    max : Int64?, refund : Int64) : {Int64, Int32}
      res = {0_i64, 0}
      read = ->(k : String) { c.query_one?("SELECT value FROM settings WHERE key = ?", k, as: String).try(&.to_i64?) || 0_i64 }
      write = ->(k : String, v : Int64) {
        c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", k, v.to_s, v.to_s)
      }
      spent = {read.call(OUTBOUND_BUDGET_SPENT_KEY) - refund, 0_i64}.max
      # A row further ahead than leases at THIS rate can push it was left by a slower rate (or
      # a wall clock that stepped back) and restarts at now, or it would stall every process.
      row = read.call(OUTBOUND_BUDGET_NEXT_KEY)
      reach = now_us + OUTBOUND_LEASE_SPAN_US + {OUTBOUND_LEASE_SPAN_US, interval_us}.max
      at = interval_us > 0 && row <= reach ? {row, now_us}.max : now_us
      # A quarter of what is left at most: a lease a live process never sends (an idle TUI or
      # MCP server holds one until it exits) must not lock every other process out of the total.
      grant = max ? {want.to_i64, max - spent, {(max - spent) // 4, 1_i64}.max}.min : want.to_i64
      if grant <= 0
        grant = 0_i64
      elsif interval_us > 0 && at > now_us + OUTBOUND_LEASE_SPAN_US
        grant = 0_i64
        res = {at - OUTBOUND_LEASE_SPAN_US, 0}
      else
        res = {at, grant.to_i32}
        write.call(OUTBOUND_BUDGET_NEXT_KEY, at + grant * interval_us) if interval_us > 0
      end
      write.call(OUTBOUND_BUDGET_SPENT_KEY, spent + grant) if max && (grant > 0 || refund > 0)
      res
    end

    # A read-only store has no writer (#752), yet its sends must still count against the budget
    # every other process sees: one short transaction on a reader connection, with `query_only`
    # lifted for its length only. No writer fiber here, so the busy wait cannot block on our own.
    private def lease_on_reader(run : DB::Connection -> Nil) : Bool
      @db.using_connection do |c|
        c.exec("PRAGMA query_only = OFF")
        begin
          c.exec("BEGIN IMMEDIATE")
          begin
            run.call(c)
            c.exec("COMMIT")
            true
          rescue
            c.exec("ROLLBACK") rescue nil
            false
          end
        ensure
          c.exec("PRAGMA query_only = ON")
        end
      end
    rescue
      false
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
