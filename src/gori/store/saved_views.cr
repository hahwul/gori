require "db"

module Gori
  class Store
    # --- Saved History views (#776) -----------------------------------------------------
    #
    # The project half of the view library; the global half lives in settings.json
    # (`saved_views.views`, see Settings::SavedView) and the two fold together in
    # `SavedViews.merged`. Shaped like `color_rules` above — same "returns whether the write
    # COMMITTED" contract on every mutator — minus the ordering column, because a view is
    # chosen by pick rather than matched in sequence (see schema V18).

    def saved_views : Array(SavedViewRow)
      list = [] of SavedViewRow
      # Ordered by NAME, not by insertion: the picker is a lookup, so alphabetical is what
      # makes a name findable. Ties broken by id so the order is total.
      @db.query("SELECT id, name, query FROM saved_views ORDER BY name COLLATE NOCASE, id") do |rs|
        rs.each { list << SavedViewRow.new(rs.read(Int64), rs.read(String), rs.read(String)) }
      end
      list
    end

    # Returns the new id, or 0 when the write did not commit — the same contract
    # `insert_color_rule` has, and the reason `Settings.saved_views_next_id` counts from 1 on
    # the other side of the scope boundary.
    #
    # 0 also covers a UNIQUE-index rejection (a name already taken in this project). Callers
    # check `SavedViews.name_taken?` first so they can say WHICH problem it was; this is the
    # backstop for a race between that check and the insert.
    #
    # OR IGNORE, exactly as `insert_extract_rule` does for its UNIQUE `name`, and for a reason
    # far bigger than this table: a RAISE inside the closure is caught by the writer loop's
    # per-batch rescue, which rolls back the WHOLE batch — up to `BATCH_MAX` ops, captured
    # flows included — counts every one of them as a write failure and marks the connection
    # suspect. A duplicate view name must cost the view, not the capture running beside it.
    def insert_saved_view(name : String, query : String) : Int64
      new_id = 0_i64
      changed = 0_i64
      # Both numbers off the `DB::ExecResult` the driver already filled in, read INSIDE the
      # closure — no follow-up SELECT to prepare and step inside the writer's batch.
      ok = exec_task_ok ->(c : DB::Connection) {
        res = c.exec("INSERT OR IGNORE INTO saved_views (name, query) VALUES (?, ?)", name, query)
        changed = res.rows_affected
        new_id = res.last_insert_id
        nil
      }
      ok && changed > 0 ? new_id : 0_i64
    end

    # Update a view in place. Returns whether the write committed AND matched a row — false for
    # an unknown id (a view a peer deleted must not be reported as edited) and for a rename onto
    # another view's name.
    #
    # OR IGNORE + `changes()`, like `update_extract_rule`: a cross-process rename collision must
    # not raise inside the writer's transaction (see `insert_saved_view`). The TUI, `gori run
    # views rename` and MCP `update_view` are all supported peers against one project.
    def update_saved_view(id : Int64, name : String, query : String) : Bool
      changed = 0_i64
      ok = exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE OR IGNORE saved_views SET name = ?, query = ? WHERE id = ?", name, query, id)
        changed = c.scalar("SELECT changes()").as(Int64)
        nil
      }
      ok && changed > 0
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller must
    # not report the view as deleted; it is still in the picker).
    def delete_saved_view(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM saved_views WHERE id = ?", id); nil }
    end
  end
end
