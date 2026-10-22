require "db"

module Gori
  class Store
    # --- hostname overrides (per-project /etc/hosts) -------------------------

    # Each override: {id, host (lowercased), ip}. ORDER BY id so the TUI list is
    # stable (insertion order); HostOverrides owns the lookup semantics.
    def host_overrides : Array({Int64, String, String})
      rows = [] of {Int64, String, String}
      @db.query("SELECT id, host, ip FROM host_overrides ORDER BY id") do |rs|
        rs.each { rows << {rs.read(Int64), rs.read(String), rs.read(String)} }
      end
      rows
    end

    # INSERT OR IGNORE — the UNIQUE(host) constraint makes re-adding the same host a
    # no-op (the model dedupes first and surfaces it to the user as a duplicate).
    def add_host_override(host : String, ip : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO host_overrides (host, ip) VALUES (?, ?)", host, ip); nil
      }
    end

    # Returns whether the override was actually changed (false = no such id, the store was
    # busy/locked/closing, or that host already belongs to another override).
    #
    # `UPDATE OR IGNORE` for the same reason `update_scope_rule` uses it: colliding with
    # UNIQUE(host) would RAISE inside the writer's transaction, rolling back everything batched
    # with it and poisoning the connection's cached statement until the error surfaces at
    # teardown. A no-op plus `changes()` says the same thing without either cost.
    def update_host_override(id : Int64, host : String, ip : String) : Bool
      exec_row("UPDATE OR IGNORE host_overrides SET host = ?, ip = ? WHERE id = ?", host, ip, id)
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def remove_host_override(id : Int64) : Bool
      exec_ok("DELETE FROM host_overrides WHERE id = ?", id)
    end
  end
end
