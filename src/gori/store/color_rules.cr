require "db"
require "json"

module Gori
  class Store
    # --- Colormarker rules (History row colouring, display only) -------------------------
    #
    # The project half of the rule set; the global half lives in settings.json
    # (`colormarker.rules`, see Settings::ColormarkerRule) and the two fold together in
    # `Colormarker.merged`. Deliberately shaped like `match_rules` above — same ordering
    # column, same "returns whether the write COMMITTED" contract on every mutator — because
    # the two features share a scope model and a UI, and a reader who knows one should not
    # have to re-learn the other.

    def color_rules : Array(ColorRule)
      list = [] of ColorRule
      # Column order mirrors ColorRule's positional initialize, so the reads line up by
      # construction rather than by counting.
      @db.query("SELECT id, enabled, match_filter, color, style, name FROM color_rules ORDER BY position, id") do |rs|
        rs.each do
          list << ColorRule.new(
            rs.read(Int64), rs.read(Int32) != 0, rs.read(String),
            rs.read(String), MarkerStyle.from_label(rs.read(String)),
            rs.read(String))
        end
      end
      list
    end

    # Insert a rule at the END of the ordered list (position = max+1) so reordering has
    # distinct slots to swap. Returns the new id, or 0 when the write did not commit — the
    # same contract `insert_rule` has, and the reason `Settings.colormarker_next_rule_id`
    # counts from 1 on the other side of the scope boundary.
    def insert_color_rule(match_filter : String, color : String = "yellow",
                          style : MarkerStyle = MarkerStyle::Full, name : String = "",
                          enabled : Bool = true) : Int64
      exec_task ->(c : DB::Connection) {
        pos = c.query_one("SELECT COALESCE(MAX(position), -1) + 1 FROM color_rules", as: Int64)
        c.exec("INSERT INTO color_rules (enabled, name, match_filter, color, style, position) VALUES (?, ?, ?, ?, ?, ?)",
          enabled ? 1 : 0, name, match_filter, color, style.label, pos)
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller
    # must not report the toggle as applied; the row colour is unchanged).
    def set_color_rule_enabled(id : Int64, enabled : Bool) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("UPDATE color_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    # Update a rule's fields in place (enabled/position unchanged). No-op on an unknown id.
    # Returns whether the write committed.
    def update_color_rule(id : Int64, match_filter : String, color : String,
                          style : MarkerStyle, name : String = "") : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE color_rules SET name = ?, match_filter = ?, color = ?, style = ? WHERE id = ?",
          name, match_filter, color, style.label, id)
        nil
      }
    end

    # Move a rule one slot up (dir < 0) or down (dir > 0). Full renumber afterwards, like
    # `move_rule` — the table is tiny and tie-free positions are worth more than the saved
    # writes.
    #
    # Reordering here changes WHICH rule paints a row, not merely the order two effects are
    # applied in: the first enabled match wins — which is why this answers whether the write
    # COMMITTED rather than returning Nil the way `move_rule` does. `move_rule` is TUI-only
    # (there is no `gori run rewriter move`), but this one is reachable from `gori run
    # colormarker move` and MCP `move_color_rule`, and both of those already report
    # PROJECT_BUSY on their GLOBAL branch. Without an answer here the PROJECT branch reported
    # a successful reorder for a rolled-back write — i.e. told the operator a different rule
    # paints the row than actually does.
    #
    # False also covers "nothing moved" (an edge of the block, or an unknown id), same
    # contract `Rules#move` states.
    def move_color_rule(id : Int64, dir : Int32) : Bool
      move_position("color_rules", id, dir)
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def delete_color_rule(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM color_rules WHERE id = ?", id); nil }
    end

    # --- this project's answer to a GLOBAL colour rule -----------------------------------
    # Same shape, and the same reasoning, as REWRITER_OVERRIDES_KEY above: a global rule
    # carries a default enabled state every project follows until that project disagrees, and
    # the disagreement is stored here as one JSON object (global id → the state this project
    # wants) rather than as a copy of the rule.
    #
    # An entry exists ONLY while it differs from the default: `Colormarker` deletes it the
    # moment the two agree again, so a project that was toggled off and back on goes back to
    # FOLLOWING the library instead of pinning today's answer.
    COLORMARKER_OVERRIDES_KEY = "colormarker_global_overrides"

    # Tolerant read: an unreadable or corrupt value degrades to "no overrides", i.e. every
    # global rule follows its default. Fail-open costs at most a wrongly-coloured row here —
    # the value is a display choice, not a gate — and raising would take the Colormarker tab
    # and History's row loop down with it.
    def colormarker_overrides : Hash(Int64, Bool)
      global_overrides(COLORMARKER_OVERRIDES_KEY)
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller
    # must not report the toggle as applied; the row colour is unchanged).
    def set_colormarker_override(id : Int64, enabled : Bool) : Bool
      set_global_override(COLORMARKER_OVERRIDES_KEY, id, enabled)
    end

    # Drop this project's disagreement, so the rule follows the global default again.
    def clear_colormarker_override(id : Int64) : Bool
      clear_global_override(COLORMARKER_OVERRIDES_KEY, id)
    end
  end
end
