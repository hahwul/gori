require "db"

module Gori
  class Store
    # --- match&replace rules (in-flight head rewrite lens) -------------------

    def match_rules : Array(MatchRule)
      list = [] of MatchRule
      @db.query("SELECT id, enabled, target, part, pattern, replacement, op, match_kind, name, host FROM match_rules ORDER BY position, id") do |rs|
        rs.each do
          list << MatchRule.new(
            rs.read(Int64), rs.read(Int32) != 0,
            RuleTarget.from_label(rs.read(String)), RulePart.from_label(rs.read(String)),
            rs.read(String), rs.read(String),
            RuleOp.from_label(rs.read(String)), MatchKind.from_label(rs.read(String)),
            rs.read(String), rs.read(String))
        end
      end
      list
    end

    # Insert a rule at the END of the ordered list (position = max+1) so reordering has
    # distinct slots to swap. Legacy rows sit at position 0 and sort by id underneath —
    # move_rule renumbers the whole list on first use, so ties never persist.
    def insert_rule(target : RuleTarget, part : RulePart, pattern : String, replacement : String,
                    op : RuleOp = RuleOp::Replace, match_kind : MatchKind = MatchKind::Literal,
                    name : String = "", host : String = "", enabled : Bool = true) : Int64
      exec_task ->(c : DB::Connection) {
        pos = c.query_one("SELECT COALESCE(MAX(position), -1) + 1 FROM match_rules", as: Int64)
        c.exec("INSERT INTO match_rules (enabled, target, part, pattern, replacement, op, match_kind, name, host, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          enabled ? 1 : 0, target.label, part.label, pattern, replacement,
          op.label, match_kind.label, name, host, pos)
        nil
      }
    end

    def set_rule_enabled(id : Int64, enabled : Bool) : Nil
      exec_task ->(c : DB::Connection) { c.exec("UPDATE match_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    # Update a rule's fields in place (enabled/position unchanged). No-op when the id
    # doesn't exist.
    def update_rule(id : Int64, target : RuleTarget, part : RulePart, pattern : String, replacement : String,
                    op : RuleOp = RuleOp::Replace, match_kind : MatchKind = MatchKind::Literal,
                    name : String = "", host : String = "") : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE match_rules SET target = ?, part = ?, pattern = ?, replacement = ?, op = ?, match_kind = ?, name = ?, host = ? WHERE id = ?",
          target.label, part.label, pattern, replacement, op.label, match_kind.label, name, host, id)
        nil
      }
    end

    # Move a rule one slot up (dir < 0) or down (dir > 0) in the ordered list. Reads the
    # current order, swaps the two neighbours, and rewrites every position 0..n-1 so the
    # order is stable and tie-free afterwards (the table is tiny — a full renumber is
    # cheaper than reasoning about legacy position-0 ties). No-op at an edge / unknown id.
    def move_rule(id : Int64, dir : Int32) : Nil
      ids = [] of Int64
      @db.query("SELECT id FROM match_rules ORDER BY position, id") { |rs| rs.each { ids << rs.read(Int64) } }
      i = ids.index(id)
      return unless i
      j = i + (dir < 0 ? -1 : 1)
      return unless 0 <= j < ids.size
      ids.swap(i, j)
      exec_task ->(c : DB::Connection) {
        ids.each_with_index { |rid, pos| c.exec("UPDATE match_rules SET position = ? WHERE id = ?", pos, rid) }
        nil
      }
    end

    def delete_rule(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM match_rules WHERE id = ?", id); nil }
    end
  end
end
