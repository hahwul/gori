require "json"
require "../../store"

module Gori
  module MCP
    class Tools
      # Every rule that applies to this project, in apply order: the GLOBAL library first, then
      # the project's own rows. `id` is unique only WITHIN a scope, so every row carries its
      # `scope` and the mutation tools take one alongside the id.
      private def list_rules(h) : Result
        want = nil.as(Store::RuleScope?)
        if present?(h, "scope")
          sc = rule_scope(h)
          return sc if sc.is_a?(Result)
          want = sc
        end
        rules = Gori::Rules.merged(store)
        rules = rules.select { |r| r.scope == want } if want
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" do
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "scope", r.scope.label
                    # The EFFECTIVE state here. For a global rule the library's own default may
                    # differ — this project overrode it — and both are reported so an agent can
                    # tell "off everywhere" from "off in this engagement".
                    j.field "enabled", r.enabled?
                    if r.global?
                      j.field "overridden", r.overridden?
                      j.field "default_enabled", Settings.rewriter_rules.find { |g| g.id == r.id }.try(&.enabled)
                    end
                    j.field "name", r.name
                    j.field "target", r.target.label
                    j.field "part", r.part.label
                    j.field "op", r.op.label
                    j.field "match", r.match_kind.label
                    j.field "host", r.host
                    j.field "pattern", r.pattern
                    j.field "replacement", r.replacement
                    j.field "body_file", r.body_file
                  end
                end
              end
            end
          end
        end)
      end

      # The `scope` argument, defaulting to this project — the safe direction: a caller that
      # omits it edits the engagement in front of it, never every future one. An unrecognised
      # value is REFUSED rather than clamped, because clamping "globl" to project would report
      # success for an edit the caller meant to make everywhere.
      private def rule_scope(h) : Store::RuleScope | Result
        s = str(h, "scope")
        return Store::RuleScope::Project if s.nil? || s.empty?
        case s.downcase
        when "project" then Store::RuleScope::Project
        when "global"  then Store::RuleScope::Global
        else                err("invalid 'scope' (expected project|global)", "INVALID_ARGUMENT", field: "scope")
        end
      end

      # Whether a rule's pattern is acceptable: only a Replace+Regex rule must compile; a
      # literal or header-op rule is always fine. Mirrors the CLI's valid_regex? guard so the
      # MCP surface rejects a bad pattern instead of persisting a rule that silently never fires.
      private def valid_rule_regex?(op : Store::RuleOp, match_kind : Store::MatchKind, pattern : String) : Bool
        return true unless match_kind.regex?
        return true if op.header? # a header op matches by NAME; `match` does not apply
        Regex.new(pattern)
        true
      rescue
        false
      end

      # Guard the short-circuit-only arguments. A stub that cannot be parsed would answer every
      # matching request with gori's own 502 and never reach the origin, so it is refused at
      # creation rather than discovered from live traffic — the same stance the CLI takes.
      # `body_file` on any other op is rejected too: silently storing an ignored path would
      # leave the caller believing a body source is configured.
      private def short_circuit_error(op : Store::RuleOp, replacement : String, body_file : String) : Result?
        unless op.short_circuit?
          return err("'body_file' is only valid with op=short_circuit", "INVALID_ARGUMENT", field: "body_file") unless body_file.empty?
          return nil
        end
        return nil if Gori::RuleStub.valid?(replacement)
        err("'replacement' is not a parseable HTTP response (expected a status line such as " \
            "'200 OK', then headers, then a blank line and the body)", "INVALID_ARGUMENT", field: "replacement")
      end

      private def create_rule(h) : Result
        pattern = str(h, "pattern")
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        tp = rule_target_part(h, Store::RuleTarget::Request, Store::RulePart::Head)
        return tp if tp.is_a?(Result)
        target, part = tp
        ok = rule_op_kind(h, Store::RuleOp::Replace, Store::MatchKind::Literal)
        return ok if ok.is_a?(Result)
        op, match_kind = ok
        if bad = ws_shape_error(op, part)
          return bad
        end
        target, part = Gori::Rules.normalize_shape(op, target, part) # header ops head-only; a stub is request/head
        # Reject an uncompilable regex up front (the CLI does; the proxy would otherwise
        # rescue the compile to passthrough and the rule would silently never fire).
        unless valid_rule_regex?(op, match_kind, pattern)
          return err("invalid regex pattern (failed to compile)", "INVALID_ARGUMENT", field: "pattern")
        end
        replacement = str(h, "replacement") || ""
        name = str(h, "name") || ""
        host = str(h, "host") || ""
        body_file = str(h, "body_file") || ""
        if bad = short_circuit_error(op, replacement, body_file)
          return bad
        end
        # Atomic disabled creation: insert already-disabled so there is no window
        # where a just-created rule is live before a follow-up disable call.
        enabled = bool_arg(h, "enabled", true)
        id =
          if scope.global?
            Settings.add_rewriter_rule(target.label, part.label, pattern, replacement, op.label,
              match_kind.label, name, host, body_file, enabled)
          else
            store.insert_rule(target, part, pattern, replacement, op, match_kind, name, host, enabled, body_file: body_file)
          end
        if id == 0
          return busy(scope.global? ? "failed to persist global rule (settings not writable)" : "failed to persist rule (store busy or unwritable)")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
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
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        existing = Gori::Rules.merged(store).find { |r| r.id == id && r.scope == scope }
        return not_found("no #{scope.label} rule with id #{id}") unless existing
        tp = rule_target_part(h, existing.target, existing.part)
        return tp if tp.is_a?(Result)
        target, part = tp
        ok = rule_op_kind(h, existing.op, existing.match_kind)
        return ok if ok.is_a?(Result)
        op, match_kind = ok
        if bad = ws_shape_error(op, part)
          return bad
        end
        target, part = Gori::Rules.normalize_shape(op, target, part)
        pattern = present?(h, "pattern") ? str(h, "pattern") : existing.pattern
        return err("pattern must not be empty", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        unless valid_rule_regex?(op, match_kind, pattern)
          return err("invalid regex pattern (failed to compile)", "INVALID_ARGUMENT", field: "pattern")
        end
        replacement = present?(h, "replacement") ? (str(h, "replacement") || "") : existing.replacement
        name = present?(h, "name") ? (str(h, "name") || "") : existing.name
        host = present?(h, "host") ? (str(h, "host") || "") : existing.host
        body_file = present?(h, "body_file") ? (str(h, "body_file") || "") : existing.body_file
        if bad = short_circuit_error(op, replacement, body_file)
          return bad
        end
        updated =
          if scope.global?
            Settings.update_rewriter_rule(id, target.label, part.label, pattern, replacement,
              op.label, match_kind.label, name, host, body_file)
          else
            store.update_rule(id, target, part, pattern, replacement, op, match_kind, name, host, body_file)
          end
        return busy("rule not updated (store busy or unwritable); the rule is unchanged") unless updated
        if present?(h, "enabled")
          en = bool_arg(h, "enabled", existing.enabled?)
          # For a global rule this is THIS project's answer, exactly as `set_rule_enabled`
          # means it — changing the library's default is `set_rule_enabled` + everywhere.
          ok = scope.global? ? set_global_rule_enabled_here(id, en) : store.set_rule_enabled(id, en)
          return busy("rule fields were updated but the enable/disable did not persist (store busy or unwritable); retry") unless ok
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
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
        if bad = ws_shape_error(op, part)
          return bad
        end
        target, part = Gori::Rules.normalize_shape(op, target, part)
        # Reject an uncompilable regex up front, same as create/update_rule — otherwise
        # Rules#apply_rule's own rescue (a deliberate passthrough so a bad LIVE rule
        # can't corrupt traffic) silently reports a fake "0 matches" instead of the
        # compile error preview_rule exists to catch before create_rule.
        unless valid_rule_regex?(op, match_kind, pattern)
          return err("invalid regex pattern (failed to compile)", "INVALID_ARGUMENT", field: "pattern")
        end
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
        return err("invalid 'part' (expected head|body|ws)", "INVALID_ARGUMENT", field: "part") unless part
        {target, part}
      end

      # Only `replace` acts on a WebSocket message: a header op names a header and a WS
      # message has none, and a short-circuit rule answers a request that a WS message is
      # not. Refused rather than normalized — `Rules.normalize_shape` would coerce the part
      # to `head`, which does not narrow the rule but moves it to a different PROTOCOL: the
      # caller asked to rewrite WebSocket frames and would have got one rewriting HTTP heads.
      private def ws_shape_error(op : Store::RuleOp, part : Store::RulePart) : Result?
        return nil unless part.ws?
        return nil if op.replace?
        err("op '#{op.label}' cannot target part 'ws' — only 'replace' rewrites a WebSocket " \
            "message; use part=head for an HTTP header or short-circuit rule",
          "INVALID_ARGUMENT", field: "part")
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
               when "short_circuit" then Store::RuleOp::ShortCircuit
               else                      nil
               end
             end
        return err("invalid 'op' (expected replace|add_header|set_header|remove_header|short_circuit)", "INVALID_ARGUMENT", field: "op") unless op
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

      # For a global rule this writes THIS PROJECT's override by default — the same meaning `x`
      # has in the Rewriter tab. `everywhere: true` changes the library's own default instead,
      # which reaches every project that has not overridden it.
      private def set_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        enabled = optional_bool_arg(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        everywhere = bool_arg(h, "everywhere", false)
        return err("'everywhere' needs scope=global — a project rule has no default", "INVALID_ARGUMENT", field: "everywhere") if everywhere && !scope.global?
        return not_found("no #{scope.label} rule with id #{id}") unless rule_exists?(id, scope)
        ok =
          if !scope.global?
            store.set_rule_enabled(id, enabled)
          elsif everywhere
            Settings.set_rewriter_rule_enabled(id, enabled)
          else
            set_global_rule_enabled_here(id, enabled)
          end
        return busy("enable/disable NOT applied (store busy or unwritable); the rule is unchanged and may still be rewriting live traffic") unless ok
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "scope", scope.label
            j.field "enabled", enabled
            j.field "everywhere", everywhere if scope.global?
          end
        end)
      end

      # Make a global rule effectively `enabled` in THIS project. Agreeing with the library's
      # default CLEARS the override instead of pinning it, so the project keeps following a
      # later change to that default — the disposition `Rules#toggle` documents.
      private def set_global_rule_enabled_here(id : Int64, enabled : Bool) : Bool
        rule = Settings.rewriter_rules.find { |r| r.id == id }
        return false unless rule
        rule.enabled == enabled ? store.clear_rewriter_override(id) : store.set_rewriter_override(id, enabled)
      end

      private def delete_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        scope = rule_scope(h)
        return scope if scope.is_a?(Result)
        return not_found("no #{scope.label} rule with id #{id}") unless rule_exists?(id, scope)
        ok =
          if scope.global?
            deleted = Settings.delete_rewriter_rule(id)
            store.clear_rewriter_override(id) # this project's disagreement dies with the rule
            deleted
          else
            store.delete_rule(id)
          end
        return busy("rule NOT deleted (store busy or unwritable); it is unchanged and may still be rewriting live traffic") unless ok
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "scope", scope.label; j.field "deleted", true } })
      end

      # Whether a Match&Replace rule id exists IN THAT SCOPE. A full read (neither store has a
      # single-row rule fetch), but the rule set is tiny and enable/disable/delete are
      # low-frequency actions.
      private def rule_exists?(id : Int64, scope : Store::RuleScope) : Bool
        if scope.global?
          Settings.rewriter_rules.any? { |r| r.id == id }
        else
          store.match_rules.any? { |r| r.id == id }
        end
      end

      # --- extract rules / session bindings (#501) -----------------------------
      #
      # The READ half of a binding: an extract rule observes a response and writes ONE named
      # value into an in-memory table, which a Match & Replace rule then injects with
      # `replacement: "$SESSION"`. Same CRUD shape as the rules above so an agent that learned
      # one has learned the other.

      private def extract_rule_json(j : JSON::Builder, r : Store::ExtractRule) : Nil
        j.object do
          j.field "id", r.id
          j.field "enabled", r.enabled?
          j.field "name", r.name
          j.field "when", r.match_filter
          j.field "host", r.host
          j.field "kind", r.kind.label
          j.field "selector", r.selector
          j.field "pos_start", r.pos_start
          j.field "pos_end", r.pos_end
        end
      end

      private def list_extract_rules : Result
        rules = store.extract_rules
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", rules.size
            j.field "rules" { j.array { rules.each { |r| extract_rule_json(j, r) } } }
            # The whole point of the feature, stated where an agent reading this list will
            # see it — otherwise "no value field" reads as an omission rather than a design.
            j.field "note", "Values are bound in the memory of the gori that observed them and are " \
                            "never persisted, so they are not readable here. Inject one from a Match & " \
                            "Replace rule with replacement \"$NAME\"."
          end
        end)
      end

      # A throwaway `Bindings` over the store, so the MCP surface gets the SAME refusals the
      # TUI and CLI do (one name one writer, a valid key, a regex that compiles) instead of a
      # UNIQUE-constraint failure surfacing as "store busy". It holds no values — an MCP
      # process is not the process that observed them.
      private def extract_bindings : Gori::Bindings
        Gori::Bindings.new(store, store.extract_rules)
      end

      private def extract_kind_arg(h, dft : Gori::ExtractKind) : Gori::ExtractKind | Result
        raw = str(h, "kind").try(&.strip)
        return dft if raw.nil? || raw.empty?
        Gori::ExtractKind.parse?(raw) ||
          err("invalid 'kind' (expected cookie|header|regex|position|jsonpath)", "INVALID_ARGUMENT", field: "kind")
      end

      # The `$` is stripped so an agent may pass the token the way an operator reads it.
      private def extract_name_arg(raw : String?) : String?
        n = raw.try(&.strip)
        return nil if n.nil? || n.empty?
        n.starts_with?('$') ? n[1..] : n
      end

      # An omitted field keeps the row's current value — the "omitted fields are left
      # unchanged" contract every update_* tool here states, spelled once.
      private def keep(h, field : String, current : String) : String
        present?(h, field) ? (str(h, field) || "") : current
      end

      # The same contract for an integer column, bounded in Int64 BEFORE it is narrowed to the
      # store's Int32: `.to_i32` is checked, so `{"pos_start": 5000000000}` used to
      # OverflowError past the INVALID_ARGUMENT arm at `Tools#call` and come back INTERNAL for
      # the caller's own argument. The floor is Int32::MIN rather than 0 so `current` — an
      # already-stored value this method must be able to pass through untouched — can never be
      # the thing that raises.
      private def keep_int(h, field : String, current : Int32) : Int32
        bounded_int_arg(h, field, current.to_i64, min: Int32::MIN.to_i64, max: Int32::MAX.to_i64).to_i
      end

      # The enabled state the caller asked for, or nil when they omitted the field. Called
      # BEFORE the write commits, and that ordering is the point: `bool_arg` RAISES on a
      # non-boolean (`"enabled": "yes"`, which clients that stringify booleans send), so
      # reading it afterwards meant a rejected call had already persisted its changes.
      private def enabled_change(h, current : Bool) : Bool?
        present?(h, "enabled") ? bool_arg(h, "enabled", current) : nil
      end

      # `enabled_change` / `bool_arg`'s refusal turned into a Result, WITHOUT a method-wide
      # `rescue Gori::Error`. That rescue would be far broader than the argument error it was
      # added for — `Gori::Error` is this codebase's general error type, so a store failure
      # inside `bindings.add` would come back as INVALID_ARGUMENT carrying the store's message.
      # Scoped to the one call that can raise on the CALLER's input.
      private def enabled_arg(h, current : Bool) : Bool? | Result
        enabled_change(h, current)
      rescue ex : Gori::Error
        err(ex.message || "invalid 'enabled' (expected true or false)", "INVALID_ARGUMENT", field: "enabled")
      end

      # kind=position needs a real range; every other kind ignores the two ints.
      private def extract_range_error(kind : Gori::ExtractKind, pos_start : Int32, pos_end : Int32) : Result?
        return nil unless kind.position? && pos_end <= pos_start
        err("'pos_end' must be greater than 'pos_start' for kind=position", "INVALID_ARGUMENT", field: "pos_end")
      end

      private def create_extract_rule(h) : Result
        name = extract_name_arg(str(h, "name"))
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") unless name
        kind = extract_kind_arg(h, Gori::ExtractKind::Cookie)
        return kind if kind.is_a?(Result)
        selector = str(h, "selector") || ""
        # Bounded in Int64 before the narrowing, for the reason spelled out at `keep_int`.
        pos_start = bounded_int_arg(h, "pos_start", 0_i64, min: Int32::MIN.to_i64, max: Int32::MAX.to_i64).to_i
        pos_end = bounded_int_arg(h, "pos_end", 0_i64, min: Int32::MIN.to_i64, max: Int32::MAX.to_i64).to_i
        if bad = extract_range_error(kind, pos_start, pos_end)
          return bad
        end
        # Read BEFORE the insert, exactly as `create_rule` does: `bool_arg` RAISES on a
        # non-boolean (`"enabled": "yes"`, which clients that stringify booleans send), and
        # reading it after `bindings.add` had persisted meant the caller got a failure while a
        # live, ENABLED extract rule stayed behind — already observing responses and binding
        # its name for Match&Replace injection. A rejected create must leave nothing.
        enabled = enabled_arg(h, true)
        return enabled if enabled.is_a?(Result)
        enabled = enabled.nil? ? true : enabled
        bindings = extract_bindings
        if bad = bindings.add(name, str(h, "when") || "", kind, selector, pos_start, pos_end, str(h, "host") || "")
          return bad == Gori::Bindings::STORE_REFUSED ? busy(bad) : err(bad, "INVALID_ARGUMENT", field: "name")
        end
        row = store.extract_rules.find { |r| r.name == name }
        return busy("failed to persist extract rule (store busy or unwritable)") unless row
        if bad = apply_created_extract_state(row.id, enabled)
          return bad
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", row.id
            j.field "name", name
            j.field "kind", kind.label
            j.field "enabled", enabled
          end
        end)
      end

      # Atomic disabled creation, matching create_rule: flip before returning so there is no
      # window in which a just-created rule is already declaring its name.
      private def apply_created_extract_state(id : Int64, enabled : Bool) : Result?
        return nil if enabled
        return nil if store.set_extract_rule_enabled(id, false)
        busy("extract rule created but the disable did not persist (store busy or unwritable); retry")
      end

      private def update_extract_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        existing = store.extract_rules.find { |r| r.id == id }
        return not_found("no extract rule with id #{id}") unless existing
        name = extract_name_arg(present?(h, "name") ? str(h, "name") : existing.name)
        return err("name must not be empty", "INVALID_ARGUMENT", field: "name") unless name
        kind = extract_kind_arg(h, existing.kind)
        return kind if kind.is_a?(Result)
        selector = keep(h, "selector", existing.selector)
        pos_start = keep_int(h, "pos_start", existing.pos_start)
        pos_end = keep_int(h, "pos_end", existing.pos_end)
        if bad = extract_range_error(kind, pos_start, pos_end)
          return bad
        end
        filter = keep(h, "when", existing.match_filter)
        host = keep(h, "host", existing.host)
        en = enabled_arg(h, existing.enabled?)
        return en if en.is_a?(Result)
        if bad = extract_bindings.update(id, name, filter, kind, selector, pos_start, pos_end, host)
          # A store refusal is transient and gets the retryable code; a validation refusal is the
          # caller's own values and does not.
          return bad == Gori::Bindings::STORE_REFUSED ? busy(bad) : err(bad, "INVALID_ARGUMENT", field: "name")
        end
        unless en.nil?
          return busy("extract rule fields were updated but the enable/disable did not persist (store busy or unwritable); retry") unless store.set_extract_rule_enabled(id, en)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "updated", true
            j.field "name", name
            j.field "kind", kind.label
          end
        end)
      end

      private def set_extract_rule_enabled(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        enabled = optional_bool_arg(h, "enabled")
        return Result.new("missing required 'enabled' (true|false)", is_error: true) if enabled.nil?
        return not_found("no extract rule with id #{id}") unless store.extract_rules.any?(&.id.==(id))
        return busy("enable/disable NOT applied (store busy or unwritable); the extract rule is unchanged") unless store.set_extract_rule_enabled(id, enabled)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "enabled", enabled } })
      end

      private def delete_extract_rule(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return not_found("no extract rule with id #{id}") unless store.extract_rules.any?(&.id.==(id))
        return busy("extract rule NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_extract_rule(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      # The tools/list schemas for the Match & Replace / extract rule tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_rules_tools(j : JSON::Builder) : Nil
        tool j, "list_rules",
          "List the Match & Replace rules applied to this project (the Rewriter tab — literal/regex " \
          "replace or add/set/remove header, applied to in-flight request/response HEAD or BODY), in " \
          "apply order: GLOBAL rules (settings.json, shared by every project) first, then the " \
          "project's own. `id` is unique only within a scope, so pass both to the mutation tools. " \
          "For a global rule, `enabled` is the state in THIS project and `default_enabled` the " \
          "library's own; `overridden` says the two were made to differ here." do |s|
          s.field "scope", strprop("show only project | global rules (default: both)")
        end

        tool j, "list_extract_rules",
          "List the project's EXTRACT rules — the read half of a session binding. Each one " \
          "observes a response and binds one named value ($SESSION) in memory, which a Match & " \
          "Replace rule injects with replacement \"$SESSION\". Values are never persisted and are " \
          "not readable here. Unordered: an extract rule produces no bytes, so two cannot compose." { }

        return unless @allow_actions

        tool j, "create_rule",
          "Add a Match & Replace rule (the Rewriter tab) applied to in-flight traffic. " \
          "Persisted to the project, or to the global library shared by every project when " \
          "scope=global. Note: a gori TUI already running applies it only after its " \
          "rules reload (reopen the Rewriter tab or restart); `gori run` and newly opened TUIs " \
          "pick it up immediately." do |s|
          s.field "scope", strprop("project (default) | global — a global rule lives in settings.json and applies in EVERY project")
          s.field "pattern", strprop("for replace: the substring/regex to match; for a header op: the HEADER NAME; for short_circuit: the substring/regex matched against the REQUEST head"), required: true
          s.field "replacement", strprop("for replace: the replacement (empty = delete; supports $1 capture refs when match=regex); for add/set header: the header VALUE (default empty); for short_circuit: the canned RESPONSE — a status line such as '200 OK', then header lines, then a blank line and the body")
          s.field "target", strprop("request|response (default request; short_circuit is always request)")
          s.field "part", strprop("head|body|ws — head = request/status line + headers, body = entity body, ws = a WebSocket MESSAGE on an upgraded (101) flow with target picking the direction (request = client→server, response = server→client). Default head; ignored by header ops and short_circuit, which are head-only, and rejected for those ops when set to ws")
          s.field "op", strprop("short_circuit | replace | add_header | set_header | remove_header (default replace). short_circuit ANSWERS the request from the rule and never dials the origin — nothing is sent upstream; use it to stub a response that does not exist")
          s.field "body_file", strprop("short_circuit only: serve this file's bytes as the response BODY instead of the inline one (re-read when the file changes). Empty = inline")
          s.field "match", strprop("for replace: literal | regex (default literal). Regex supports $1/\\1 capture groups")
          s.field "name", strprop("optional label for the rule")
          s.field "host", strprop("optional host glob scoping the rule (e.g. 'example.com' substring, '*.example.com' wildcard; empty = all hosts)")
          s.field "enabled", boolprop("create the rule already enabled (default true); pass false for an atomic disabled creation (no live window before you can preview/adjust it)")
        end

        tool j, "update_rule",
          "Update an existing Match & Replace rule by id. Omitted fields are left unchanged. " \
          "For a global rule, `enabled` changes the state in THIS project (an override), not " \
          "the library's default — use set_rule_enabled with everywhere=true for that." do |s|
          s.field "id", intprop("rule id from list_rules"), required: true
          s.field "scope", strprop("which id: project (default) | global")
          s.field "pattern", strprop("new match substring/regex, or header name")
          s.field "replacement", strprop("new replacement / header value / canned response")
          s.field "target", strprop("request|response")
          s.field "part", strprop("head|body|ws (ws = a WebSocket message; replace only)")
          s.field "op", strprop("short_circuit | replace | add_header | set_header | remove_header")
          s.field "body_file", strprop("short_circuit only: file served as the response body ('' = inline)")
          s.field "match", strprop("literal | regex")
          s.field "name", strprop("rule label")
          s.field "host", strprop("host glob ('' = all hosts)")
          s.field "enabled", boolprop("enable/disable the rule")
        end

        tool j, "preview_rule",
          "Estimate how many captured flows a rule WOULD affect (by replaying the same transform " \
          "over recent flows) WITHOUT creating it. Use before create_rule to size a rule. " \
          "Approximate: response bodies are scanned as stored wire bytes." do |s|
          s.field "pattern", strprop("the substring/regex to match, or header name"), required: true
          s.field "replacement", strprop("replacement / header value (matters for header ops, which change the head regardless of match)")
          s.field "target", strprop("request|response (default request)")
          s.field "part", strprop("head|body|ws (default head; ws counts captured WebSocket messages, replace only)")
          s.field "op", strprop("short_circuit | replace | add_header | set_header | remove_header (default replace). For short_circuit this counts the flows the rule WOULD have answered instead of sending")
          s.field "match", strprop("literal | regex (default literal)")
          s.field "host", strprop("host glob ('' = all hosts)")
        end

        tool j, "set_rule_enabled",
          "Enable or disable a Match & Replace rule by id. For a GLOBAL rule this writes THIS " \
          "project's override by default; everywhere=true changes the rule's own default, which " \
          "every project that has not overridden it follows." do |s|
          s.field "id", intprop("rule id from list_rules"), required: true
          s.field "enabled", boolprop("true to enable, false to disable"), required: true
          s.field "scope", strprop("which id: project (default) | global")
          s.field "everywhere", boolprop("global rules only: change the default for every project instead of this one")
        end

        tool j, "delete_rule",
          "Delete a Match & Replace rule by id. Deleting a GLOBAL rule removes it from every " \
          "project." do |s|
          s.field "id", intprop("rule id from list_rules"), required: true
          s.field "scope", strprop("which id: project (default) | global")
        end

        tool j, "create_extract_rule",
          "Add an EXTRACT rule: observe a response and bind one named value ($NAME) in memory " \
          "for a Match & Replace rule to inject with replacement \"$NAME\". Only a DELIBERATE " \
          "single send (Repeater / send_request) feeds extraction — sweeps deliberately do not, " \
          "because a response echoing an attacker-shaped payload back could otherwise rebind the " \
          "operator's session to it. One name, one writer: a duplicate name is refused." do |s|
          s.field "name", strprop("the binding name, without the $ (letters, digits and _, not starting with a digit)"), required: true
          s.field "kind", strprop("cookie | header | regex | position | jsonpath (default cookie). regex/position/jsonpath read the DECODED body; cookie/header read the parsed head")
          s.field "selector", strprop("cookie name, header name, regex source, or JSON path ($.a.b[0]) — required for every kind except position")
          s.field "when", strprop("which messages to read, in intercept-filter syntax (host:/path:/method:/scheme:/status:, AND/OR/NOT, '' = any). status: matches responses only")
          s.field "host", strprop("optional host glob scoping the rule ('example.com' substring, '*.example.com' wildcard; empty = all hosts)")
          s.field "pos_start", intprop("kind=position only: start byte offset into the decoded body")
          s.field "pos_end", intprop("kind=position only: end byte offset (exclusive); must exceed pos_start")
          s.field "enabled", boolprop("create the rule already enabled (default true)")
        end

        tool j, "update_extract_rule",
          "Update an existing extract rule by id. Omitted fields are left unchanged. Renaming " \
          "drops the old name's bound value rather than re-labelling it." do |s|
          s.field "id", intprop("extract rule id from list_extract_rules"), required: true
          s.field "name", strprop("new binding name (without the $)")
          s.field "kind", strprop("cookie | header | regex | position | jsonpath")
          s.field "selector", strprop("cookie/header name, regex source, or JSON path")
          s.field "when", strprop("intercept-filter condition ('' = any message)")
          s.field "host", strprop("host glob ('' = all hosts)")
          s.field "pos_start", intprop("kind=position only: start byte offset")
          s.field "pos_end", intprop("kind=position only: end byte offset (exclusive)")
          s.field "enabled", boolprop("enable/disable the rule")
        end

        tool j, "set_extract_rule_enabled",
          "Enable or disable an extract rule by id. Disabling also UN-DECLARES its name, so a " \
          "Match & Replace rule injecting it goes back to refusing rather than sending a value " \
          "nothing is refreshing." do |s|
          s.field "id", intprop("extract rule id from list_extract_rules"), required: true
          s.field "enabled", boolprop("true to enable, false to disable"), required: true
        end

        tool j, "delete_extract_rule", "Delete an extract rule by id (its bound value is forgotten too)." do |s|
          s.field "id", intprop("extract rule id from list_extract_rules"), required: true
        end
      end
    end
  end
end
