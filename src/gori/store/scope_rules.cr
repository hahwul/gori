require "db"

module Gori
  class Store
    # Each rule: {id, kind (include|exclude), match_type (host|string|regex), pattern}.
    # ORDER BY id so the TUI list is stable (insertion order); Scope owns the semantics.
    def scope_rules : Array({Int64, String, String, String})
      rules = [] of {Int64, String, String, String}
      @db.query("SELECT id, kind, match_type, pattern FROM scope_rules ORDER BY id") do |rs|
        rs.each { rules << {rs.read(Int64), rs.read(String), rs.read(String), rs.read(String)} }
      end
      rules
    end

    def add_scope_rule(kind : String, match_type : String, pattern : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO scope_rules (kind, match_type, pattern) VALUES (?, ?, ?)", kind, match_type, pattern); nil
      }
    end

    def update_scope_rule(id : Int64, kind : String, match_type : String, pattern : String) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE scope_rules SET kind = ?, match_type = ?, pattern = ? WHERE id = ?", kind, match_type, pattern, id); nil
      }
    end

    def remove_scope_rule(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM scope_rules WHERE id = ?", id); nil }
    end
  end
end
