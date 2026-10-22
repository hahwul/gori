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

    # Returns whether the rule was actually changed (false = no such id, the store was
    # busy/locked/closing, or the new triple is already another rule's).
    #
    # `UPDATE OR IGNORE`, and that is not cosmetic. A plain UPDATE colliding with the table's
    # UNIQUE(kind, match_type, pattern) RAISES inside the writer's transaction, and the cost of
    # that raise is out of all proportion to the edit: it rolls back the whole BATCH — the
    # captured flows the writer happened to group with it — and it leaves the driver's cached
    # prepared statement holding an error that sqlite only reports when the statement is
    # FINALIZED, which is when the writer hands its connection back at `Store#close`. That
    # raise, in the teardown, is what used to make gori hang on exit (see writer_loop). OR
    # IGNORE turns the collision into a no-op, so nothing is poisoned and nothing unrelated is
    # lost; `changes()` inside the same transaction is what still reports it as not applied.
    def update_scope_rule(id : Int64, kind : String, match_type : String, pattern : String) : Bool
      exec_row("UPDATE OR IGNORE scope_rules SET kind = ?, match_type = ?, pattern = ? WHERE id = ?", kind, match_type, pattern, id)
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def remove_scope_rule(id : Int64) : Bool
      exec_ok("DELETE FROM scope_rules WHERE id = ?", id)
    end
  end
end
