require "json"
require "../../store"

module Gori
  module MCP
    class Tools
      private def list_rules : Result
        rules = store.match_rules
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" do
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "enabled", r.enabled?
                    j.field "name", r.name
                    j.field "target", r.target.label
                    j.field "part", r.part.label
                    j.field "op", r.op.label
                    j.field "match", r.match_kind.label
                    j.field "host", r.host
                    j.field "pattern", r.pattern
                    j.field "replacement", r.replacement
                  end
                end
              end
            end
          end
        end)
      end

      # Whether a rule's pattern is acceptable: only a Replace+Regex rule must compile; a
      # literal or header-op rule is always fine. Mirrors the CLI's valid_regex? guard so the
      # MCP surface rejects a bad pattern instead of persisting a rule that silently never fires.
      private def valid_rule_regex?(op : Store::RuleOp, match_kind : Store::MatchKind, pattern : String) : Bool
        return true unless op.replace? && match_kind.regex?
        Regex.new(pattern)
        true
      rescue
        false
      end

      private def create_rule(h) : Result
        pattern = str(h, "pattern")
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        tp = rule_target_part(h, Store::RuleTarget::Request, Store::RulePart::Head)
        return tp if tp.is_a?(Result)
        target, part = tp
        ok = rule_op_kind(h, Store::RuleOp::Replace, Store::MatchKind::Literal)
        return ok if ok.is_a?(Result)
        op, match_kind = ok
        part = Store::RulePart::Head if op.header? # header ops are head-only
        # Reject an uncompilable regex up front (the CLI does; the proxy would otherwise
        # rescue the compile to passthrough and the rule would silently never fire).
        unless valid_rule_regex?(op, match_kind, pattern)
          return err("invalid regex pattern (failed to compile)", "INVALID_ARGUMENT", field: "pattern")
        end
        replacement = str(h, "replacement") || ""
        name = str(h, "name") || ""
        host = str(h, "host") || ""
        # Atomic disabled creation: insert already-disabled so there is no window
        # where a just-created rule is live before a follow-up disable call.
        enabled = bool_arg(h, "enabled", true)
        id = store.insert_rule(target, part, pattern, replacement, op, match_kind, name, host, enabled)
        return busy("failed to persist rule (store busy or unwritable)") if id == 0
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "target", target.label
            j.field "part", part.label
            j.field "op", op.label
            j.field "match", match_kind.label
            j.field "enabled", enabled
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "invalid rule arguments", "INVALID_ARGUMENT")
      end

      private def update_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        existing = store.match_rules.find { |r| r.id == id }
        return not_found("no rule with id #{id}") unless existing
        tp = rule_target_part(h, existing.target, existing.part)
        return tp if tp.is_a?(Result)
        target, part = tp
        ok = rule_op_kind(h, existing.op, existing.match_kind)
        return ok if ok.is_a?(Result)
        op, match_kind = ok
        part = Store::RulePart::Head if op.header?
        pattern = present?(h, "pattern") ? str(h, "pattern") : existing.pattern
        return err("pattern must not be empty", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        unless valid_rule_regex?(op, match_kind, pattern)
          return err("invalid regex pattern (failed to compile)", "INVALID_ARGUMENT", field: "pattern")
        end
        replacement = present?(h, "replacement") ? (str(h, "replacement") || "") : existing.replacement
        name = present?(h, "name") ? (str(h, "name") || "") : existing.name
        host = present?(h, "host") ? (str(h, "host") || "") : existing.host
        store.update_rule(id, target, part, pattern, replacement, op, match_kind, name, host)
        if present?(h, "enabled")
          en = bool_arg(h, "enabled", existing.enabled?)
          store.set_rule_enabled(id, en)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "updated", true
            j.field "target", target.label
            j.field "part", part.label
            j.field "op", op.label
          end
        end)
      rescue ex : Gori::Error
        err(ex.message || "invalid rule arguments", "INVALID_ARGUMENT")
      end

      # Estimate how many captured flows a rule WOULD affect by replaying the SAME
      # transform the live proxy uses (regex / header ops / host-scope all reflected)
      # over recent flows. Nothing is written. Approximate: response bodies are scanned
      # as STORED (possibly compressed) wire bytes.
      private def preview_rule(h) : Result
        pattern = str(h, "pattern")
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        tp = rule_target_part(h, Store::RuleTarget::Request, Store::RulePart::Head)
        return tp if tp.is_a?(Result)
        target, part = tp
        ok = rule_op_kind(h, Store::RuleOp::Replace, Store::MatchKind::Literal)
        return ok if ok.is_a?(Result)
        op, match_kind = ok
        part = Store::RulePart::Head if op.header?
        replacement = str(h, "replacement") || ""
        host = str(h, "host") || ""
        candidate = Store::MatchRule.new(0_i64, true, target, part, pattern, replacement, op, match_kind, "", host)
        # Reuse the engine's preview over a throwaway Rules bound only to the store.
        pv = Gori::Rules.new(store, [] of Store::MatchRule).preview(candidate)
        Result.new(JSON.build do |j|
          j.object do
            j.field "target", target.label
            j.field "part", part.label
            j.field "op", op.label
            j.field "match", match_kind.label
            j.field "pattern", pattern
            j.field "would_match", pv.matched
            j.field "scanned", pv.scanned
            j.field "total_flows", pv.total
            j.field "scan_capped", pv.total > pv.scanned
            j.field "note", "Replays the rule transform over recent flows (bounded to #{Gori::Rules::RULE_PREVIEW_SCAN}); response bodies are matched as stored wire bytes."
          end
        end)
      end

      # Parse target/part from args, defaulting to the given fallbacks. Returns the
      # pair or an error Result. Shared by create/update/preview_rule.
      private def rule_target_part(h, dft_target : Store::RuleTarget, dft_part : Store::RulePart) : {Store::RuleTarget, Store::RulePart} | Result
        tgt_s = str(h, "target").try(&.strip)
        target = tgt_s.nil? || tgt_s.empty? ? dft_target : Store::RuleTarget.parse?(tgt_s)
        return err("invalid 'target' (expected request|response)", "INVALID_ARGUMENT", field: "target") unless target
        part_s = str(h, "part").try(&.strip)
        part = part_s.nil? || part_s.empty? ? dft_part : Store::RulePart.parse?(part_s)
        return err("invalid 'part' (expected head|body)", "INVALID_ARGUMENT", field: "part") unless part
        {target, part}
      end

      # Parse op/match from args, defaulting to the given fallbacks. Returns the pair or
      # an error Result. Shared by create/update/preview_rule.
      private def rule_op_kind(h, dft_op : Store::RuleOp, dft_kind : Store::MatchKind) : {Store::RuleOp, Store::MatchKind} | Result
        op_s = str(h, "op").try(&.strip)
        op = if op_s.nil? || op_s.empty?
               dft_op
             else
               case op_s.downcase
               when "replace"       then Store::RuleOp::Replace
               when "add_header"    then Store::RuleOp::AddHeader
               when "set_header"    then Store::RuleOp::SetHeader
               when "remove_header" then Store::RuleOp::RemoveHeader
               else                      nil
               end
             end
        return err("invalid 'op' (expected replace|add_header|set_header|remove_header)", "INVALID_ARGUMENT", field: "op") unless op
        # Validate `match` explicitly instead of leaning on MatchKind.from_label
        # (which coerces any unknown label to Literal). A silent literal fallback
        # would mislead a caller into thinking a `regex` rule was applied while the
        # proxy actually did a literal match — so an unrecognized label is rejected.
        kind_s = str(h, "match").try(&.strip)
        kind = if kind_s.nil? || kind_s.empty?
                 dft_kind
               else
                 case kind_s.downcase
                 when "literal" then Store::MatchKind::Literal
                 when "regex"   then Store::MatchKind::Regex
                 else                nil
                 end
               end
        return err("invalid 'match' (expected literal|regex)", "INVALID_ARGUMENT", field: "match") unless kind
        {op, kind}
      end

      private def set_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        enabled = bool(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        return not_found("no rule with id #{id}") unless rule_exists?(id)
        store.set_rule_enabled(id, enabled)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "enabled", enabled } })
      end

      private def delete_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return not_found("no rule with id #{id}") unless rule_exists?(id)
        store.delete_rule(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      # Whether a Match&Replace rule id exists. A full read (the store has no
      # single-row rule fetch), but the rule set is tiny and enable/disable/delete
      # are low-frequency actions.
      private def rule_exists?(id : Int64) : Bool
        store.match_rules.any? { |r| r.id == id }
      end
    end
  end
end
