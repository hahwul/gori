require "db"
require "json"

module Gori
  class Store
    # --- match&replace rules (in-flight head rewrite lens) -------------------

    def match_rules : Array(MatchRule)
      list = [] of MatchRule
      @db.query("SELECT id, enabled, target, part, CAST(pattern AS BLOB) AS pattern, CAST(replacement AS BLOB) AS replacement, op, match_kind, name, host, body_file FROM match_rules ORDER BY position, id") do |rs|
        rs.each do
          list << MatchRule.new(
            rs.read(Int64), rs.read(Int32) != 0,
            RuleTarget.from_label(rs.read(String)), RulePart.from_label(rs.read(String)),
            # pattern/replacement are OPERATOR bytes and rewrite live traffic: an MCP
            # `create_rule` can carry a real NUL (JSON permits \u0000), and reading a TEXT
            # column through the driver's NUL-terminated pointer truncated it — so the rule
            # that rewrote traffic was not the rule that was created, and `list_rules`
            # echoed the truncated form, making the discrepancy invisible everywhere.
            String.new(rs.read(Bytes)), String.new(rs.read(Bytes)),
            RuleOp.from_label(rs.read(String)), MatchKind.from_label(rs.read(String)),
            rs.read(String), rs.read(String), rs.read(String))
        end
      end
      list
    end

    # Insert a rule at the END of the ordered list (position = max+1) so reordering has
    # distinct slots to swap. Legacy rows sit at position 0 and sort by id underneath —
    # move_rule renumbers the whole list on first use, so ties never persist.
    def insert_rule(target : RuleTarget, part : RulePart, pattern : String, replacement : String,
                    op : RuleOp = RuleOp::Replace, match_kind : MatchKind = MatchKind::Literal,
                    name : String = "", host : String = "", enabled : Bool = true,
                    body_file : String = "") : Int64
      exec_task ->(c : DB::Connection) {
        pos = c.query_one("SELECT COALESCE(MAX(position), -1) + 1 FROM match_rules", as: Int64)
        c.exec("INSERT INTO match_rules (enabled, target, part, pattern, replacement, op, match_kind, name, host, body_file, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          enabled ? 1 : 0, target.label, part.label, pattern, replacement,
          op.label, match_kind.label, name, host, body_file, pos)
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing → the
    # caller must not report the toggle as applied; the rule stays in its prior state).
    def set_rule_enabled(id : Int64, enabled : Bool) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("UPDATE match_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    # Update a rule's fields in place (enabled/position unchanged). No-op when the id
    # doesn't exist.
    # Returns whether the write committed (false = store busy/locked/closing).
    def update_rule(id : Int64, target : RuleTarget, part : RulePart, pattern : String, replacement : String,
                    op : RuleOp = RuleOp::Replace, match_kind : MatchKind = MatchKind::Literal,
                    name : String = "", host : String = "", body_file : String = "") : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE match_rules SET target = ?, part = ?, pattern = ?, replacement = ?, op = ?, match_kind = ?, name = ?, host = ?, body_file = ? WHERE id = ?",
          target.label, part.label, pattern, replacement, op.label, match_kind.label, name, host, body_file, id)
        nil
      }
    end

    # Move a rule one slot up (dir < 0) or down (dir > 0) in the ordered list. Reads the
    # current order, swaps the two neighbours, and rewrites every position 0..n-1 so the
    # order is stable and tie-free afterwards (the table is tiny — a full renumber is
    # cheaper than reasoning about legacy position-0 ties). No-op at an edge / unknown id.
    # Returns whether the reorder committed (false = nothing to move, or store
    # busy/locked/closing), like the identical `move_color_rule`. Rule PRECEDENCE decides which
    # of two rules touching the same header wins, so a caller that reports a swap the store
    # dropped leaves the operator believing an order that reverts at next start.
    def move_rule(id : Int64, dir : Int32) : Bool
      ids = [] of Int64
      @db.query("SELECT id FROM match_rules ORDER BY position, id") { |rs| rs.each { ids << rs.read(Int64) } }
      i = ids.index(id)
      return false unless i
      j = i + (dir < 0 ? -1 : 1)
      return false unless 0 <= j < ids.size
      ids.swap(i, j)
      exec_task_ok ->(c : DB::Connection) {
        ids.each_with_index { |rid, pos| c.exec("UPDATE match_rules SET position = ? WHERE id = ?", pos, rid) }
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def delete_rule(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM match_rules WHERE id = ?", id); nil }
    end

    # --- this project's answer to a GLOBAL rule ------------------------------------------
    # A global rule (settings.json `rewriter.rules`) carries a default enabled state that every
    # project follows until that project disagrees. The disagreement is stored HERE, as one
    # JSON object under a single settings key — global id → the state this project wants —
    # rather than as a copy of the rule, so editing the rule still reaches every project and
    # nothing has to be re-synced.
    #
    # An entry exists ONLY while it differs from the default: `Rules` deletes it the moment the
    # two agree again, so a project that was merely toggled back and forth follows the library
    # afterwards instead of pinning a state that happens to match today.
    REWRITER_OVERRIDES_KEY = "rewriter_global_overrides"

    # Tolerant read: an unreadable or corrupt value degrades to "no overrides", i.e. every
    # global rule follows its default. Fail-open is right here and not a safety hole — the
    # DEFAULT is the operator's own global choice, not an escalation, and the alternative
    # (raising) would take down the Rewriter tab and the proxy's rule load with it.
    def rewriter_overrides : Hash(Int64, Bool)
      map = {} of Int64 => Bool
      raw = setting(REWRITER_OVERRIDES_KEY)
      return map if raw.nil? || raw.strip.empty?
      JSON.parse(raw).as_h?.try &.each do |k, v|
        id = k.to_i64?
        b = v.as_bool?
        map[id] = b if id && !b.nil?
      end
      map
    rescue
      {} of Int64 => Bool
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller must
    # not report the toggle as applied; the rule keeps rewriting whatever it was rewriting).
    def set_rewriter_override(id : Int64, enabled : Bool) : Bool
      write_rewriter_overrides(rewriter_overrides.merge({id => enabled}))
    end

    # Drop this project's disagreement, so the rule follows the global default again.
    def clear_rewriter_override(id : Int64) : Bool
      map = rewriter_overrides
      return true unless map.has_key?(id)
      map.delete(id)
      write_rewriter_overrides(map)
    end

    private def write_rewriter_overrides(map : Hash(Int64, Bool)) : Bool
      return delete_setting(REWRITER_OVERRIDES_KEY) if map.empty?
      set_setting(REWRITER_OVERRIDES_KEY, map.to_h { |id, on| {id.to_s, on} }.to_json)
    end
  end
end
