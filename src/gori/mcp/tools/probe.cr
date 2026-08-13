require "json"
require "../../ql"
require "../../scope"
require "../../probe"

module Gori
  module MCP
    class Tools
      # Active mode sends real requests per flow inline (unlike the async fuzz/mine jobs),
      # so cap how many flows an active scan touches. Passive mode is request-free and uncapped.
      PROBE_ACTIVE_MAX_FLOWS = 500

      # probe_scan — the MCP surface for the Prism scanner (parity with `gori run probe`).
      # PASSIVE by default (zero outbound requests): scans captured History flows (optional
      # QL filter) + Repeater tabs and returns grouped issues. active:true also runs the
      # light-touch active checks that SEND requests — gated on write access AND project scope
      # (the same two-layer `Gori::Outbound` model as the CLI/TUI: an allowlist filter per flow
      # + a per-send Sandbox/exclude hard block inside the sender).
      private def probe_scan(h) : Result
        filter = probe_scan_filter(h)
        return filter if filter.is_a?(Result)

        if e = bad_severity(str(h, "severity"))
          return e
        end
        category = probe_scan_category(h)
        return category if category.is_a?(Result)

        active = bool_arg(h, "active", false)
        allow_unscoped = bool_arg(h, "allow_unscoped", false)
        # --aggressive implies unsafe (it also raises caps + widens bypass sets).
        aggressive = bool_arg(h, "aggressive", false)
        unsafe = bool_arg(h, "unsafe", false) || aggressive
        gate = probe_active_gate(active, allow_unscoped)
        return gate if gate.is_a?(Result)
        scope, scope_configured = gate

        opts = Probe::Active::Options.new(allow_unsafe: unsafe, aggressive: aggressive)
        ids = Probe::Scan.flow_ids(store, filter)
        # Cap only the ACTIVE sends (network volume); the request-free PASSIVE scan always
        # covers every flow. (An earlier version truncated `ids`, which silently dropped
        # passive coverage of the newest flows under active:true.)
        # A scan SKIPS an item that blows up rather than losing the batch; count the skips so the
        # agent can tell an incomplete result from a clean one (surfaced as `scan_errors`).
        scan_errors = 0
        # The budget is built here so `capped` can report whether it actually STOPPED a send,
        # rather than guessing from the pre-filter id count — see `Scan::Budget#exhausted?`.
        budget = Probe::Scan::Budget.new(active ? PROBE_ACTIVE_MAX_FLOWS : nil)
        # `insecure` is the ACTIVE path's `gori run probe -k`: a lab / staging origin with a
        # self-signed certificate is the ordinary case for a scan, and without this the active
        # checks simply failed there with a TLS error that named nothing actionable.
        verify_upstream = !bool_arg(h, "insecure", false) && @verify_upstream
        dets, repeater_n = Probe::Scan.scan_all(store, ids, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, opts: opts, active_budget: budget,
          on_error: ->(_where : String, _ex : Exception) { scan_errors += 1; nil })
        capped = budget.exhausted?

        groups = probe_filter_groups(Probe.group(dets), severity_from(str(h, "severity")), category.as(String?))
        Result.new(probe_scan_json(groups, ids.size, repeater_n, active, allow_unscoped,
          scope_configured, capped, unsafe, aggressive, clamp(int(h, "limit"), 200, 2000), scan_errors))
      end

      # --- persisted probe issues + triage (parity with the TUI Probe tab) -------------------
      #
      # probe_scan is a STATELESS rescan; these read and mutate the `probe_issues` table the
      # live Analyzer fills — the same rows a human triages in the TUI. Without them an agent
      # could produce findings (probe_scan, send_request) but never dismiss or promote one.

      # probe_issues — list persisted findings. Defaults to OPEN only, mirroring the TUI's
      # default open-only lens; include_closed:true is the `a` toggle.
      private def probe_issues(h) : Result
        if e = bad_severity(str(h, "severity"))
          return e
        end
        category = probe_scan_category(h)
        return category if category.is_a?(Result)

        include_closed = bool_arg(h, "include_closed", false)
        all = store.probe_issues(category.as(String?), str(h, "host").try(&.strip).presence,
          severity_from(str(h, "severity")))
        all = all.select(&.status.open?) unless include_closed

        req_off = int(h, "offset")
        req_lim = int(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 100, 500)
        page = all[offset, limit]? || [] of Store::ProbeIssue
        Result.new(JSON.build do |j|
          j.object do
            j.field("issues") { j.array { page.each { |i| Probe.issue_json(j, i) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total", all.size
            j.field "has_more", offset + page.size < all.size
            j.field "include_closed", include_closed
          end
        end)
      end

      # probe_dismiss — mute a finding. Either one `id` (toggles dismissed ⇄ open, same rule as
      # the TUI's `c`), or a bulk `code`/`host` mute of every OPEN issue sharing it.
      private def probe_dismiss(h) : Result
        code = str(h, "code").try(&.strip).presence
        host = str(h, "host").try(&.strip).presence
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if id.nil? && present?(h, "id")

        selectors = [id, code, host].count { |v| !v.nil? }
        if selectors != 1
          return err("pass exactly one of 'id' (single issue), 'code' (bulk by check code), or 'host' (bulk by host)",
            "INVALID_ARGUMENT", field: "id")
        end

        if code
          n = store.open_probe_issue_count(code: code)
          return busy("dismiss NOT applied (store busy or unwritable); the findings are unchanged") unless store.dismiss_probe_by_code(code)
          return Result.new({"dismissed" => n, "code" => code}.to_json)
        end
        if host
          n = store.open_probe_issue_count(host: host)
          return busy("dismiss NOT applied (store busy or unwritable); the findings are unchanged") unless store.dismiss_probe_by_host(host)
          return Result.new({"dismissed" => n, "host" => host}.to_json)
        end

        # The selector count above guarantees `id` is the one that was given.
        return err("pass exactly one of 'id', 'code', or 'host'", "INVALID_ARGUMENT", field: "id") unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        landed = Probe::Triage.toggle_dismiss(store, issue)
        Result.new({"id" => issue.id, "status" => landed.label}.to_json)
      end

      # probe_promote — turn a machine finding into a human-confirmed Issue (the Issues report).
      private def probe_promote(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        res = Probe::Triage.promote(store, issue)
        case res.outcome
        in Probe::Triage::Outcome::AlreadyPromoted
          # The desired end state already holds, so not an error — but say so rather than
          # reporting a promotion that did not happen.
          Result.new({"id" => issue.id, "promoted" => false,
                      "reason" => "already promoted to an issue"}.to_json)
        in Probe::Triage::Outcome::Failed
          # Nothing was written. This IS an error: unlike AlreadyPromoted, retrying is correct.
          busy("probe finding #{issue.id} NOT promoted (store busy or unwritable); it is unchanged")
        in Probe::Triage::Outcome::Promoted
          Result.new({"id" => issue.id, "promoted" => true, "issue_id" => res.issue_id}.to_json)
        end
      end

      # probe_delete — hard-delete one finding, or clear them all.
      #
      # The two forms behave OPPOSITELY on suppressions: deleting one finding records a
      # (code, host) suppression so the next scan does not immediately re-add it, whereas
      # all:true calls Store#clear_probe_issues, which wipes every suppression too — so a
      # rescan re-discovers everything. all:true is therefore gated on confirm:true.
      private def probe_delete(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) if id.nil? && present?(h, "id")
        all = bool_arg(h, "all", false)
        # Reject the ambiguous combination rather than silently letting `all` win — an agent
        # that sets `all` defensively alongside a specific `id` would lose the whole table.
        # (The CLI refuses the same input.)
        if all && id
          return err("pass 'id' (one finding) or all:true (clear every finding), not both",
            "INVALID_ARGUMENT", field: "all")
        end
        if all
          n = store.count_probe_issues
          unless bool_arg(h, "confirm", false)
            return err("refusing to delete #{n} finding#{n == 1 ? "" : "s"} without confirm:true — this also clears every hard-delete suppression, so a rescan re-discovers them",
              "CONFIRM_REQUIRED", field: "confirm", details: JSON.parse({"findings" => n}.to_json))
          end
          return busy("findings NOT cleared (store busy or unwritable); every one is still there") unless store.clear_probe_issues
          return Result.new({"deleted" => n, "all" => true, "suppressions_cleared" => true}.to_json)
        end
        return err("pass 'id' (one finding) or all:true (clear every finding)", "INVALID_ARGUMENT", field: "id") unless id
        issue = store.get_probe_issue(id)
        return not_found("no probe issue with id #{id}") unless issue
        return busy("finding NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_probe_issue(id)
        Result.new({"deleted" => 1, "id" => id}.to_json)
      end

      # --- scan rules + mode (parity with the TUI Probe tab's Rules sub-tab) -----------------

      # list_probe_rules — every built-in (passive + active) and custom rule, with its enabled
      # state. The ids here are what set_probe_rule_enabled / delete_probe_rule take.
      private def list_probe_rules(h) : Result
        kind = str(h, "kind").try(&.strip.downcase).presence
        if kind && !%w[passive active custom].includes?(kind)
          return err("invalid kind '#{kind}' (passive|active|custom)", "INVALID_ARGUMENT", field: "kind")
        end
        entries = Probe::RuleCatalog.load(store)
        entries = entries.select { |e| e.kind == kind } if kind
        Result.new(JSON.build do |j|
          j.object do
            j.field "mode", store.probe_mode.label
            j.field("rules") { j.array { entries.each { |e| Probe::RuleCatalog.entry_json(j, e) } } }
            j.field "total", entries.size
            j.field "disabled_count", entries.count { |e| !e.enabled }
          end
        end)
      end

      # set_probe_rule_enabled — turn one rule on/off. Built-ins live in the project's
      # disabled-id set; a custom rule carries its own enabled flag (project rules only —
      # a GLOBAL custom rule lives in the user's settings.json, outside this project).
      private def set_probe_rule_enabled(h) : Result
        id = str(h, "id").try(&.strip).presence
        return err("missing required 'id' (see list_probe_rules)", "INVALID_ARGUMENT", field: "id") unless id
        enabled = optional_bool_arg(h, "enabled")
        return err("missing required 'enabled'", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?

        entry = Probe::RuleCatalog.load(store).find { |e| e.id == id }
        return not_found("no scan rule with id '#{id}' (see list_probe_rules)") unless entry

        if entry.kind == "custom"
          if entry.scope == "global"
            return err("'#{id}' is a GLOBAL custom rule (stored in settings.json, shared across projects) — it cannot be toggled per project",
              "INVALID_ARGUMENT", field: "id")
          end
          row_id = custom_rule_row_id(id)
          return err("malformed custom rule id '#{id}'", "INVALID_ARGUMENT", field: "id") unless row_id
          ok = store.set_probe_custom_rule_enabled(row_id, enabled)
        else
          disabled = store.probe_disabled_rules
          # `set_rule_enabled` (not a bare delete/add) so a DEFAULT-OFF rule toggles correctly:
          # for those ids the stored-set membership is INVERTED — see `Probe::DEFAULT_DISABLED_RULES`.
          Probe.set_rule_enabled(disabled, id, enabled)
          ok = store.set_probe_disabled_rules(disabled)
        end
        # Both writers report whether the toggle COMMITTED. Returning `{enabled: false}` over a
        # rolled-back batch tells an agent a scan rule is muted while it keeps firing on every
        # later scan — the same refusal the CLI twin makes (cli/run/probe.cr).
        # `busy`, not a bare `err`: a rolled-back batch is transient, so the Result must carry
        # `retryable: true` the way every other PROJECT_BUSY refusal in this server does.
        return busy("scan rule '#{id}' NOT updated (store busy or unwritable); it is unchanged") unless ok
        Result.new({"id" => id, "enabled" => enabled, "kind" => entry.kind}.to_json)
      end

      # create_probe_rule — add a PROJECT custom match rule (string/regex over one region of a
      # flow). Global rules are a settings.json concern and are not writable here.
      private def create_probe_rule(h) : Result
        fields = custom_rule_fields(h)
        return fields if fields.is_a?(Result)
        title, description, side, region, kind, pattern, severity = fields
        id = store.insert_probe_custom_rule(title, description, side, region, kind, pattern, severity)
        return err("failed to persist the rule (store busy or unwritable)", "STORE_ERROR") if id == 0
        Result.new({"id" => "custom_p_#{id}", "row_id" => id, "title" => title}.to_json)
      end

      private def update_probe_rule(h) : Result
        id = str(h, "id").try(&.strip).presence
        return err("missing required 'id' (see list_probe_rules)", "INVALID_ARGUMENT", field: "id") unless id
        row_id = custom_rule_row_id(id)
        return err("'#{id}' is not a project custom rule (only project custom rules are editable)",
          "INVALID_ARGUMENT", field: "id") unless row_id
        return not_found("no custom rule with id '#{id}'") unless store.probe_custom_rules.any? { |r| r.id == row_id }

        fields = custom_rule_fields(h)
        return fields if fields.is_a?(Result)
        title, description, side, region, kind, pattern, severity = fields
        store.update_probe_custom_rule(row_id, title, description, side, region, kind, pattern, severity)
        Result.new({"id" => id, "title" => title}.to_json)
      end

      private def delete_probe_rule(h) : Result
        id = str(h, "id").try(&.strip).presence
        return err("missing required 'id' (see list_probe_rules)", "INVALID_ARGUMENT", field: "id") unless id
        row_id = custom_rule_row_id(id)
        return err("'#{id}' is not a project custom rule — a built-in can only be DISABLED (set_probe_rule_enabled), never deleted",
          "INVALID_ARGUMENT", field: "id") unless row_id
        return not_found("no custom rule with id '#{id}'") unless store.probe_custom_rules.any? { |r| r.id == row_id }
        store.delete_probe_custom_rule(row_id)
        Result.new({"deleted" => 1, "id" => id}.to_json)
      end

      # set_probe_mode — the per-project scan mode. Raising it to active/aggressive arms the
      # AUTOMATIC probe pipeline for a live capture, so it is gated like any outbound action.
      private def set_probe_mode(h) : Result
        label = str(h, "mode").try(&.strip.downcase).presence
        return err("missing required 'mode' (off|passive|active|aggressive)", "INVALID_ARGUMENT", field: "mode") unless label
        # Mode.from_setting silently falls back to Passive on an unknown label — that would
        # report success for a typo, so validate against the labels first.
        valid = Probe::Mode.values.map(&.label)
        unless valid.includes?(label)
          return err("invalid mode '#{label}' (#{valid.join("|")})", "INVALID_ARGUMENT", field: "mode")
        end
        mode = Probe::Mode.from_setting(label)
        # Echoing the REQUESTED mode as fact would misreport a dropped write — and the
        # direction that matters is lowering the mode to STOP active probing, where a live
        # capture instance keeps the persisted mode and keeps sending.
        unless store.set_probe_mode(mode)
          return busy("scan mode NOT persisted (store busy or unwritable); the mode is unchanged")
        end
        Result.new({"mode" => mode.label, "scanning" => mode.scanning?,
                    "probes_actively" => mode.probes_actively?}.to_json)
      end

      # "custom_p_12" → 12. Returns nil for a built-in id or a GLOBAL custom rule ("custom_g_…"),
      # neither of which is a project DB row.
      private def custom_rule_row_id(id : String) : Int64?
        return nil unless id.starts_with?("custom_p_")
        id[9..].to_i64?
      end

      # Validate + normalize the shared create/update field set.
      private def custom_rule_fields(h) : {String, String, String, String, String, String, Store::Severity} | Result
        title = str(h, "title").try(&.strip).presence
        return err("missing required 'title'", "INVALID_ARGUMENT", field: "title") unless title
        pattern = str(h, "pattern").try(&.strip).presence
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") unless pattern

        spec = custom_rule_match_spec(h, pattern)
        return spec if spec.is_a?(Result)
        side, region, kind = spec

        sev_s = str(h, "severity")
        if e = bad_severity(sev_s)
          return e
        end
        {title, str(h, "description").try(&.strip) || "", side, region, kind, pattern,
         severity_from(sev_s) || Store::Severity::Info}
      end

      # The {side, region, match_kind} triple, each defaulted and checked against its allowed
      # set, plus the pattern's own compile check. Split out of custom_rule_fields to stay
      # under the cyclomatic-complexity bar.
      private def custom_rule_match_spec(h, pattern : String) : {String, String, String} | Result
        side = (str(h, "side").try(&.strip.downcase).presence || "response")
        unless Probe::CustomRule::SIDES.includes?(side)
          return err("invalid side '#{side}' (#{Probe::CustomRule::SIDES.join("|")})", "INVALID_ARGUMENT", field: "side")
        end
        region = (str(h, "region").try(&.strip.downcase).presence || "body")
        unless Probe::CustomRule::REGIONS.includes?(region)
          return err("invalid region '#{region}' (#{Probe::CustomRule::REGIONS.join("|")})", "INVALID_ARGUMENT", field: "region")
        end
        kind = (str(h, "match_kind").try(&.strip.downcase).presence || "string")
        unless Probe::CustomRule::KINDS.includes?(kind)
          return err("invalid match_kind '#{kind}' (#{Probe::CustomRule::KINDS.join("|")})", "INVALID_ARGUMENT", field: "match_kind")
        end
        # A regex that PCRE rejects would match nothing forever while reporting success (the
        # rule's own #matches? rescues to false) — refuse it here instead, the same way the
        # TUI's rule overlay validates before it saves. SafeRegexp.compile RAISES on a bad
        # pattern, it does not return nil.
        unless Probe::CustomRule.valid_pattern?(pattern, kind)
          return err("invalid regex pattern (PCRE rejected it)", "INVALID_ARGUMENT", field: "pattern")
        end
        {side, region, kind}
      end

      # The QL filter (History only; blank/absent → nil = scan all), or a QUERY_SYNTAX Result.
      private def probe_scan_filter(h) : QL::Filter? | Result
        query = str(h, "query").try(&.strip).presence
        return nil unless query
        ql_filter_or_error(h, query)
      end

      # The validated category slug (or nil), or an INVALID_ARGUMENT Result.
      private def probe_scan_category(h) : String? | Result
        category = str(h, "category").try(&.strip.downcase).presence
        return nil unless category
        return category if Probe::FILTER_CATEGORIES.includes?(category)
        err("invalid category '#{category}' (#{Probe::FILTER_CATEGORIES.join("|")})", "INVALID_ARGUMENT", field: "category")
      end

      # Resolve the scope for an active scan: {scope, scope_configured}. Passive → {nil, false}.
      # Refuses (Result) an active run without write access, or with no configured scope unless
      # allow_unscoped — every captured host would otherwise be probed. Probe::Scan turns the
      # returned scope into the `Gori::Outbound` decision its senders dial through.
      private def probe_active_gate(active : Bool, allow_unscoped : Bool) : {Scope?, Bool} | Result
        return {nil, false} unless active
        return err("active probe scan is disabled (gori mcp --read-only); pass active:false for a passive scan", "TOOL_DISABLED") unless @allow_actions
        scope = Scope.load(store)
        # Layer-1 (the Outbound ALLOWLIST gate) sends an active probe only to a scope-INCLUDED
        # flow, so with zero include rules every flow is gated out and active mode would run
        # nothing. Refuse up front (mirrors `gori run probe`'s include-count check) — an
        # excludes-only scope counts as "no includes" here, not as a configured allowlist.
        if scope.include_count == 0 && !allow_unscoped
          return err("active probe scan needs a scope INCLUDE rule (or allow_unscoped:true); with no include rule every active probe is gated out, so outbound requests are refused by default",
            "SCOPE_BLOCKED", field: "active", details: JSON.parse({"scope_decision" => "unscoped"}.to_json))
        end
        {scope, scope.configured?}
      end

      private def probe_filter_groups(groups : Array(Probe::Group), min_sev : Store::Severity?,
                                      category : String?) : Array(Probe::Group)
        groups = groups.select { |g| g.severity.value >= min_sev.value } if min_sev
        groups = groups.select { |g| g.category == category } if category
        groups
      end

      private def probe_scan_json(groups : Array(Probe::Group), flows_scanned : Int32, repeater_n : Int32,
                                  active : Bool, allow_unscoped : Bool, scope_configured : Bool,
                                  capped : Bool, unsafe : Bool, aggressive : Bool, limit : Int32,
                                  scan_errors : Int32 = 0) : String
        JSON.build do |j|
          j.object do
            j.field "flows_scanned", flows_scanned
            j.field "repeaters_scanned", repeater_n
            # Only present when something was skipped: coverage is INCOMPLETE, so a clean-looking
            # empty result must not be read as "nothing found".
            j.field "scan_errors", scan_errors if scan_errors > 0
            j.field "active", active
            if active
              j.field "scope_configured", scope_configured
              j.field "active_scope_gated", !allow_unscoped # per-flow include-filter applied unless bypassed
              j.field "active_flows_capped", true if capped
              j.field "active_unsafe_methods", true if unsafe # POST/PUT/PATCH/DELETE re-sent
              j.field "active_aggressive", true if aggressive # raised caps + wider bypass sets
            end
            j.field "issue_count", groups.size
            j.field("issues") { j.array { groups.first(limit).each { |g| Probe.group_json(j, g) } } }
            j.field "truncated", true if groups.size > limit
          end
        end
      end

      # The tools/list schemas for the Probe tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_probe_tools(j : JSON::Builder) : Nil
        tool j, "probe_scan",
          "Scan captured History flows (optional QL filter) + Repeater tabs for issues — the " \
          "MCP equivalent of `gori run probe`. PASSIVE by default (zero outbound requests). " \
          "active:true also runs light-touch active checks that SEND requests (reflected " \
          "params, CORS/host-header reflection, open redirect, CRLF injection, 403/path/header " \
          "access-control bypass, nginx & parameter traversal, GraphQL introspection, SSTI) — " \
          "requires write access and is scope-gated (per-flow scope include + a Sandbox/exclude " \
          "hard-block). Returns " \
          "{flows_scanned, repeaters_scanned, issue_count, issues:[{code, category, host, " \
          "title, severity, hit_count, affected, affected_count, evidence, sample_flow_id, " \
          "sample_repeater_id, remediation, cwe, cwe_name}]}, highest-severity first. " \
          "`cwe`/`cwe_name` are OMITTED for a code with no meaningful CWE — a technology " \
          "fingerprint, an informational jwt_in_* note, or a custom rule. Writes nothing." do |s|
          s.field "query", strprop("gori QL filter applied to History flows only; empty scans all (Repeater tabs are always scanned)")
          s.field "active", boolprop("also run active checks that SEND probe requests (default false = passive, request-free); requires write access + a configured scope")
          s.field "severity", strprop("only return issues at/above this level (info|low|medium|high|critical)")
          s.field "category", strprop("only return issues in this category (#{Probe::FILTER_CATEGORIES.join("|")})")
          s.field "allow_unscoped", boolprop("with active:true, run even when a target host is outside — or without — a configured scope (default false)")
          s.field "unsafe", boolprop("with active:true, ALSO probe unsafe methods (POST/PUT/PATCH/DELETE) — re-sends may mutate server data (default false)")
          s.field "aggressive", boolprop("with active:true, raise per-rule caps + use wider bypass sets (implies unsafe) — authorized targets only (default false)")
          s.field "insecure", boolprop("with active:true, skip upstream TLS verification (default false) — mirrors `gori run probe -k`, for a lab/staging origin with a self-signed certificate")
          s.field "limit", intprop("max issue groups to return (default 200, max 2000)")
        end

        tool j, "probe_issues",
          "List PERSISTED probe findings — the rows the live scanner accumulated (what the TUI " \
          "Probe tab shows), each with a stable `id` the probe_dismiss/probe_promote/probe_delete " \
          "tools act on. This is triage state, unlike probe_scan's stateless rescan. Defaults to " \
          "OPEN findings only, mirroring the TUI's default lens. Returns " \
          "{issues, returned, offset, total, has_more} — not a bare array." do |s|
          s.field "include_closed", boolprop("also return dismissed/confirmed/resolved findings (default false = open only)")
          s.field "severity", strprop("only return findings at/above this level (info|low|medium|high|critical)")
          s.field "category", strprop("only return findings in this category (#{Probe::FILTER_CATEGORIES.join("|")})")
          s.field "host", strprop("only return findings for this exact host")
          s.field "limit", intprop("max rows (default 100, max 500)")
          s.field "offset", intprop("start row (default 0)")
        end

        tool j, "list_probe_rules",
          "List every scan rule — built-in passive, built-in active, and custom match rules — " \
          "with whether the operator has each enabled, plus the project's current scan `mode`. " \
          "The `id` of each row is what set_probe_rule_enabled / update_probe_rule / " \
          "delete_probe_rule take. Both a scan here and one in the TUI honour this config." do |s|
          s.field "kind", strprop("only list rules of this kind (passive|active|custom)")
        end

        return unless @allow_actions

        tool j, "probe_dismiss",
          "Mute probe findings (ids come from probe_issues). Pass exactly ONE selector: `id` " \
          "toggles a single finding dismissed ⇄ open; `code` or `host` bulk-mutes every OPEN " \
          "finding sharing it. Reversible — a dismissed finding still appears under " \
          "probe_issues include_closed:true." do |s|
          s.field "id", intprop("probe finding id to toggle")
          s.field "code", strprop("bulk-dismiss every open finding with this check code")
          s.field "host", strprop("bulk-dismiss every open finding on this host")
        end

        tool j, "probe_promote",
          "Promote a probe finding (id from probe_issues) to a human-confirmed Issue in the " \
          "Issues report, carrying its severity/host/sample evidence over. Marks the source " \
          "finding Confirmed so a repeat call cannot mint a duplicate — a second call returns " \
          "{promoted: false} rather than erroring." do |s|
          s.field "id", intprop("probe finding id"), required: true
        end

        tool j, "probe_delete",
          "Hard-delete probe findings (ids from probe_issues). Deleting ONE also SUPPRESSES " \
          "that (code, host) pair so the next scan does not immediately re-add it — prefer " \
          "probe_dismiss when you only want it out of the default lens. all:true is the " \
          "OPPOSITE: it wipes every finding AND every suppression, so a rescan re-discovers " \
          "everything; it needs confirm:true and cannot be combined with `id`." do |s|
          s.field "id", intprop("probe finding id to delete")
          s.field "all", boolprop("delete EVERY probe finding AND every suppression (default false)")
          s.field "confirm", boolprop("required with all:true; without it the call is refused")
        end

        tool j, "set_probe_rule_enabled",
          "Turn one scan rule on or off for this project (ids from list_probe_rules). " \
          "Disabling a built-in stops NEW detections; findings it already produced stay. " \
          "A GLOBAL custom rule lives in the user's settings.json and cannot be toggled here." do |s|
          s.field "id", strprop("rule id from list_probe_rules"), required: true
          s.field "enabled", boolprop("true to enable, false to disable"), required: true
        end

        tool j, "create_probe_rule",
          "Add a PROJECT custom match rule — a string or regex tested against one region of " \
          "each captured flow, emitting a finding on a hit. A regex PCRE rejects is refused " \
          "rather than silently never matching." do |s|
          s.field "title", strprop("short rule name (shown as the finding title)"), required: true
          s.field "pattern", strprop("the string to look for, or a regex when match_kind=regex"), required: true
          s.field "description", strprop("what the rule is for (default empty)")
          s.field "side", strprop("request|response (default response)")
          s.field "region", strprop("whole|header|body (default body)")
          s.field "match_kind", strprop("string|regex (default string)")
          s.field "severity", strprop("info|low|medium|high|critical (default info)")
        end

        tool j, "update_probe_rule",
          "Replace a project custom rule's fields (same shape as create_probe_rule). " \
          "Built-ins are not editable — disable them with set_probe_rule_enabled instead." do |s|
          s.field "id", strprop("custom rule id from list_probe_rules (custom_p_…)"), required: true
          s.field "title", strprop("short rule name"), required: true
          s.field "pattern", strprop("the string or regex to match"), required: true
          s.field "description", strprop("what the rule is for")
          s.field "side", strprop("request|response (default response)")
          s.field "region", strprop("whole|header|body (default body)")
          s.field "match_kind", strprop("string|regex (default string)")
          s.field "severity", strprop("info|low|medium|high|critical (default info)")
        end

        tool j, "delete_probe_rule",
          "Delete a project custom rule. A built-in can only be DISABLED, never deleted." do |s|
          s.field "id", strprop("custom rule id from list_probe_rules (custom_p_…)"), required: true
        end

        tool j, "set_probe_mode",
          "Set the project's scan mode. off = no analysis; passive = zero-request checks on " \
          "captured traffic (default); active = passive plus light-touch probes that SEND " \
          "requests to scope-included targets; aggressive = active with raised caps, wider " \
          "bypass sets, and UNSAFE methods (POST/PUT/PATCH/DELETE) — authorized targets only. " \
          "This arms the AUTOMATIC pipeline for live captures, not just one scan." do |s|
          s.field "mode", strprop("off|passive|active|aggressive"), required: true
        end
      end
    end
  end
end
