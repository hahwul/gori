require "db"
require "json"

module Gori
  class Store
    # --- match&replace rules (in-flight head rewrite lens) -------------------

    def match_rules : Array(MatchRule)
      list = [] of MatchRule
      @db.query("SELECT id, enabled, target, part, CAST(pattern AS BLOB) AS pattern, CAST(replacement AS BLOB) AS replacement, op, match_kind, name, host, body_file, respond, respond_args FROM match_rules ORDER BY position, id") do |rs|
        rs.each do
          id = rs.read(Int64)
          enabled = rs.read(Int32) != 0
          target_label = rs.read(String)
          part_label = rs.read(String)
          pattern = String.new(rs.read(Bytes))
          replacement = String.new(rs.read(Bytes))
          op_label = rs.read(String)
          match_kind_label = rs.read(String)
          name = rs.read(String)
          host = rs.read(String)
          body_file = rs.read(String)
          respond_label = rs.read(String)
          respond_args = rs.read(String)
          list << MatchRule.new(
            id, enabled,
            RuleTarget.from_label(target_label), RulePart.from_label(part_label),
            # pattern/replacement are OPERATOR bytes and rewrite live traffic: an MCP
            # `create_rule` can carry a real NUL (JSON permits \u0000), and reading a TEXT
            # column through the driver's NUL-terminated pointer truncated it — so the rule
            # that rewrote traffic was not the rule that was created, and `list_rules`
            # echoed the truncated form, making the discrepancy invisible everywhere.
            pattern, replacement,
            RuleOp.from_label(op_label), MatchKind.from_label(match_kind_label),
            name, host, body_file,
            unknown_target: RuleTarget.from_label?(target_label) ? nil : target_label,
            unknown_part: RulePart.from_label?(part_label) ? nil : part_label,
            unknown_op: RuleOp.from_label?(op_label) ? nil : op_label,
            unknown_match_kind: MatchKind.from_label?(match_kind_label) ? nil : match_kind_label,
            respond: RespondKind.from_label?(respond_label) || RespondKind.implied(body_file),
            respond_args: respond_args,
            unknown_respond: RespondKind.from_label?(respond_label) ? nil : respond_label)
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
                    body_file : String = "", respond : String = "inline",
                    respond_args : String = "") : Int64
      # A stale-grammar process must not mix two grammars into one database — see
      # `store/env_write_guard.cr`. The `pattern` is a needle or a regex and nothing expands it, so
      # only the `replacement` is re-spelled — and not even that for a stub, whose replacement is
      # a response sent as authored (`RuleOp#expands_tokens?`).
      (w = env_write) && op.expands_tokens? && (replacement = w.call(replacement, EnvMigration::Kind::Rule))
      exec_task ->(c : DB::Connection) {
        pos = c.query_one("SELECT COALESCE(MAX(position), -1) + 1 FROM match_rules", as: Int64)
        c.exec("INSERT INTO match_rules (enabled, target, part, pattern, replacement, op, match_kind, name, host, body_file, respond, respond_args, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          enabled ? 1 : 0, target.label, part.label, pattern, replacement,
          op.label, match_kind.label, name, host, body_file, respond, respond_args, pos)
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
                    name : String = "", host : String = "", body_file : String = "",
                    respond : String = "inline", respond_args : String = "") : Bool
      (w = env_write) && op.expands_tokens? && (replacement = w.call(replacement, EnvMigration::Kind::Rule))
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE match_rules SET target = ?, part = ?, pattern = ?, replacement = ?, op = ?, match_kind = ?, name = ?, host = ?, body_file = ?, respond = ?, respond_args = ? WHERE id = ?",
          target.label, part.label, pattern, replacement, op.label, match_kind.label, name, host, body_file, respond, respond_args, id)
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
      rules = match_rules
      move_position("match_rules", id, dir, rules.map(&.id), frozen: rules.select(&.inert?).map(&.id))
    end

    # The swap-and-renumber behind `move_rule`, `move_color_rule` and `move_display_column`.
    # `ids` is the table's rows in display order (read here when not given); a `frozen` row on
    # either side of the swap refuses it. False = nothing moved, or the write did not commit.
    private def move_position(table : String, id : Int64, dir : Int32, ids : Array(Int64)? = nil,
                              *, frozen : Array(Int64) = [] of Int64) : Bool
      order = ids || begin
        list = [] of Int64
        @db.query("SELECT id FROM #{table} ORDER BY position, id") { |rs| rs.each { list << rs.read(Int64) } }
        list
      end
      i = order.index(id)
      return false unless i
      j = i + (dir < 0 ? -1 : 1)
      return false unless 0 <= j < order.size
      return false if frozen.includes?(order[i]) || frozen.includes?(order[j])
      order.swap(i, j)
      exec_task_ok ->(c : DB::Connection) {
        order.each_with_index { |rid, pos| c.exec("UPDATE #{table} SET position = ? WHERE id = ?", pos, rid) }
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
      global_overrides(REWRITER_OVERRIDES_KEY)
    end

    # Returns whether the write committed (false = store busy/locked/closing → the caller must
    # not report the toggle as applied; the rule keeps rewriting whatever it was rewriting).
    def set_rewriter_override(id : Int64, enabled : Bool) : Bool
      set_global_override(REWRITER_OVERRIDES_KEY, id, enabled)
    end

    # Drop this project's disagreement, so the rule follows the global default again.
    def clear_rewriter_override(id : Int64) : Bool
      clear_global_override(REWRITER_OVERRIDES_KEY, id)
    end

    # The one implementation behind both override maps (this one and
    # `COLORMARKER_OVERRIDES_KEY`), which differ only in the settings key they live under.
    private def global_overrides(key : String) : Hash(Int64, Bool)
      parse_global_overrides(setting(key))
    rescue
      {} of Int64 => Bool
    end

    # Never raises: it also runs on the writer fiber, where a raise rolls back the whole batch.
    private def parse_global_overrides(raw : String?) : Hash(Int64, Bool)
      map = {} of Int64 => Bool
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

    private def set_global_override(key : String, id : Int64, enabled : Bool) : Bool
      write_global_override(key, id, enabled)
    end

    private def clear_global_override(key : String, id : Int64) : Bool
      write_global_override(key, id, nil)
    end

    # Set (`enabled`) or drop (nil) ONE entry, with the map read inside the writer transaction.
    # A pool read followed by a whole-map write let two gori processes toggling DIFFERENT global
    # rules erase each other's override, both reporting success — the lost update
    # `mutate_setting` documents. Not that helper, because it cannot delete a row: an EMPTY map
    # deletes the key outright rather than storing "{}", which is what makes "the override
    # disappeared when the two agreed again" observable from outside.
    private def write_global_override(key : String, id : Int64, enabled : Bool?) : Bool
      exec_task_ok ->(c : DB::Connection) {
        map = parse_global_overrides(c.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String))
        unless map[id]? == enabled
          enabled.nil? ? map.delete(id) : (map[id] = enabled)
          if map.empty?
            c.exec("DELETE FROM settings WHERE key = ?", key)
          else
            v = map.to_h { |rid, on| {rid.to_s, on} }.to_json
            c.exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?", key, v, v)
          end
        end
        nil
      }
    end
  end
end
