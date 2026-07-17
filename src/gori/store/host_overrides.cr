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

    def update_host_override(id : Int64, host : String, ip : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE host_overrides SET host = ?, ip = ? WHERE id = ?", host, ip, id); nil
      }
    end

    def remove_host_override(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM host_overrides WHERE id = ?", id); nil }
    end
  end
end
