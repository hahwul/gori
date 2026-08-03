# `gori run probe` — passively scan captured flows for issues (zero requests).
module Gori
  module CLI
    module Run
      # The categories a `--category` filter accepts (shared with the MCP probe tools).
      PROBE_CATEGORIES = Probe::FILTER_CATEGORIES

      # Triage/config subcommands operate on PERSISTED findings (the `probe_issues` table the
      # live scanner fills — what the TUI Probe tab shows) or on the scan config; a bare
      # `gori run probe` is still the stateless rescan. These words are therefore RESERVED as
      # the first positional: to scan with a QL query that starts with one, pass it via
      # --query. The dispatch below is generated from this list so the two cannot drift.
      PROBE_SUBCOMMANDS = {
        "issues"  => ->(a : Array(String)) { cmd_probe_issues(a) },
        "dismiss" => ->(a : Array(String)) { cmd_probe_dismiss(a) },
        "promote" => ->(a : Array(String)) { cmd_probe_promote(a) },
        "delete"  => ->(a : Array(String)) { cmd_probe_delete(a) },
        "rm"      => ->(a : Array(String)) { cmd_probe_delete(a) },
        "rules"   => ->(a : Array(String)) { cmd_probe_rules(a) },
        "mode"    => ->(a : Array(String)) { cmd_probe_mode(a) },
      }

      private def self.cmd_probe(args : Array(String)) : Nil
        if (sub = args.first?) && (run = PROBE_SUBCOMMANDS[sub]?)
          run.call(args[1..])
        else
          cmd_probe_scan(args)
        end
      end

      private def self.cmd_probe_scan(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        min_sev : Store::Severity? = nil
        category : String? = nil
        format = :text
        active = false
        allow_unscoped = false
        unsafe = false
        aggressive = false
        insecure = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe [QL query] [options]\n\n" \
                     "Scan captured History flows AND Repeater responses for issues —\n" \
                     "the headless equivalent of the TUI Probe tab. By default runs passive checks\n" \
                     "(zero outbound requests). Pass --active to also run active checks (reflected\n" \
                     "params, CORS/host-header reflection, open redirect, CRLF injection, 403/path/\n" \
                     "header access-control bypass, nginx & parameter traversal, GraphQL\n" \
                     "introspection, SSTI, etc.). QL filters apply to History only; all Repeater\n" \
                     "tabs with a stored response are scanned.\n\n" \
                     "Triage the findings the live scanner already persisted (the TUI Probe tab's\n" \
                     "list) with: probe issues · probe dismiss · probe promote · probe delete.\n" \
                     "Manage which checks run with: probe rules · probe mode.\n" \
                     "Those words are reserved as the first argument — to scan with a QL query\n" \
                     "starting with one, pass it as --query."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only scan flows matching this QL query (host: status:>=500 size: …)") { |v| query = v }
          p.on("--severity=LEVEL", "Only show issues at/above LEVEL (info|low|medium|high|critical)") { |v| min_sev = parse_severity(v) }
          p.on("--category=CAT", "Only show issues in CAT (#{PROBE_CATEGORIES.join("|")})") { |v| category = parse_probe_category(v) }
          p.on("-a", "--active", "Include light-touch active checks (sends probe requests)") { active = true }
          p.on("--allow-unscoped", "With --active, probe flows even when outside the project scope (default: only scope-included hosts)") { allow_unscoped = true }
          p.on("--unsafe", "With --active, ALSO probe unsafe methods (POST/PUT/PATCH/DELETE) — re-sends may mutate server data") { unsafe = true }
          p.on("--aggressive", "With --active, raise per-rule caps + wider bypass sets (implies --unsafe)") { aggressive = true }
          # Every other outbound `gori run` subcommand carries this; probe did not, so
          # `scan_all`'s `verify_upstream: true` default was unreachable from the CLI and an
          # internal target with a self-signed certificate failed every active probe with no
          # way to say otherwise.
          p.on("-k", "--insecure-upstream", "With --active, do not verify upstream TLS certificates") { insecure = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # A positional QL is accepted too ("gori run probe status:>=500" / "-status:200"),
        # mirroring history; an explicit --query wins. Terms join with spaces (QL ANDs them).
        positional_query = (positional + neg_terms).join(' ')
        query ||= positional_query unless positional_query.empty?

        filter : QL::Filter? = nil
        if q = query
          parsed = QL.parse(q)
          QL.invalid_regex_terms(q).each do |t|
            STDERR.puts "gori run probe: warning: invalid regex in #{t.inspect} — that term matches nothing"
          end
          # A query that compiles to NOTHING (e.g. `status:>=foo`) becomes the match-all EMPTY
          # filter — here that would scan every flow, the opposite of what was asked. Refuse it.
          if !q.strip.empty? && parsed == QL::EMPTY
            abort "gori run probe: query #{truncate_query(q).inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
          end
          filter = parsed
        end

        store = open_store(resolve_read_project(project_name, db_path))
        scope = Scope.load(store)
        # --active with no scope include rule (and no --allow-unscoped) probes NOTHING
        # (matches_url? requires ≥1 include) — warn so an empty active result isn't mistaken
        # for "clean".
        if active && !allow_unscoped && scope.include_count == 0
          STDERR.puts "gori run probe: --active has no scope include rules — active probes skipped (add a scope include rule or pass --allow-unscoped)"
        end
        groups, flow_n, repeater_n = begin
          ids = begin
            Probe::Scan.flow_ids(store, filter)
          rescue ex
            abort "gori run probe: query #{truncate_query(query).inspect} failed: #{ex.message}"
          end
          meter = STDERR.tty?
          # --aggressive implies --unsafe (it also raises caps + widens bypass sets).
          opts = Probe::Active::Options.new(allow_unsafe: unsafe || aggressive, aggressive: aggressive)
          # A scan now SKIPS an item that blows up instead of losing the whole batch, so the
          # skips have to be reported — otherwise a partial scan prints the same summary as a
          # complete one and reads as "clean".
          scan_errors = [] of String
          dets, rn = Probe::Scan.scan_all(store, ids, active: active, scope: scope,
            verify_upstream: !insecure,
            allow_unscoped: allow_unscoped, opts: opts, progress: probe_progress_meter(meter),
            on_error: ->(where : String, ex : Exception) { scan_errors << "#{where}: #{ex.message}"; nil })
          STDERR.print "\r\e[K" if meter # clear the in-place meter before the summary line
          unless scan_errors.empty?
            n = scan_errors.size
            STDERR.puts "gori run probe: #{n} item#{n == 1 ? "" : "s"} skipped after an error " \
                        "(results are INCOMPLETE) — first: #{scan_errors.first}"
          end
          {Probe.group(dets), ids.size, rn}
        ensure
          store.close
        end

        if ms = min_sev
          groups = groups.select { |g| g.severity.value >= ms.value }
        end
        if cat = category
          groups = groups.select { |g| g.category == cat }
        end
        report_probe(groups, flow_n, repeater_n, format, query, min_sev, category)
      end

      private def self.report_probe(groups : Array(Probe::Group), flow_n : Int32, repeater_n : Int32,
                                    format : Symbol, query : String?, min_sev : Store::Severity?,
                                    category : String?) : Nil
        parts = [] of String
        parts << "#{flow_n} flow#{flow_n == 1 ? "" : "s"}"
        parts << "#{repeater_n} repeater#{repeater_n == 1 ? "" : "s"}" if repeater_n > 0 || query.nil?
        STDERR.puts "scanned #{parts.join(" + ")} · #{groups.size} issue#{groups.size == 1 ? "" : "s"}"
        if format == :json
          puts CLI::Output.probe_array_json(groups)
        elsif groups.empty?
          scope = query ? " in flows matching #{query.inspect}" : ""
          # Distinguish "nothing found" from "filters removed everything" — else an empty result
          # under --severity/--category looks like the QL query itself matched no flows.
          STDERR.puts((min_sev || category) ? "no issues match the --severity/--category filter#{scope}" : "no issues#{scope}")
        else
          groups.each { |g| puts CLI::Output.probe_group_text(g) }
        end
      end

      # --- triage over PERSISTED findings -------------------------------------------------

      private def self.cmd_probe_issues(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        min_sev : Store::Severity? = nil
        category : String? = nil
        host : String? = nil
        include_closed = false
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe issues [options]\n\n" \
                     "List the findings the scanner already persisted — the same rows the TUI Probe\n" \
                     "tab shows, each with the id the dismiss/promote/delete subcommands take.\n" \
                     "Shows OPEN findings only by default (the TUI's default lens)."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-a", "--all", "Also show dismissed/confirmed/resolved findings") { include_closed = true }
          p.on("--severity=LEVEL", "Only show findings at/above LEVEL (info|low|medium|high|critical)") { |v| min_sev = parse_severity(v) }
          p.on("--category=CAT", "Only show findings in CAT (#{PROBE_CATEGORIES.join("|")})") { |v| category = parse_probe_category(v) }
          p.on("--host=HOST", "Only show findings for this exact host") { |v| host = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run probe issues: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe issues: missing value for #{f}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        issues = begin
          list = store.probe_issues(category, host.try(&.strip).presence, min_sev)
          include_closed ? list : list.select(&.status.open?)
        ensure
          store.close
        end

        if format == :json
          puts CLI::Output.probe_issue_array_json(issues)
        elsif issues.empty?
          STDERR.puts include_closed ? "no probe findings" : "no open probe findings (pass --all to include dismissed)"
        else
          STDERR.puts "#{issues.size} finding#{issues.size == 1 ? "" : "s"}"
          issues.each { |i| puts CLI::Output.probe_issue_text(i) }
        end
      end

      private def self.cmd_probe_dismiss(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        code : String? = nil
        host : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe dismiss <id> | --code=CODE | --host=HOST\n\n" \
                     "Mute findings. With <id>, TOGGLES that one finding dismissed ⇄ open; with\n" \
                     "--code/--host, bulk-mutes every OPEN finding sharing it. Reversible —\n" \
                     "a dismissed finding still lists under `probe issues --all`."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--code=CODE", "Bulk-dismiss every open finding with this check code") { |v| code = v }
          p.on("--host=HOST", "Bulk-dismiss every open finding on this host") { |v| host = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe dismiss: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe dismiss: missing value for #{f}" }
        end
        parser.parse(args)

        id = parse_probe_issue_id(positional.first?, "gori run probe dismiss")
        selectors = [id, code, host].count { |v| !v.nil? }
        if selectors != 1
          abort "gori run probe dismiss: pass exactly one of <id>, --code=CODE, or --host=HOST"
        end

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          if c = code
            n = store.probe_issues.count { |i| i.code == c && i.status.open? }
            abort "gori run probe dismiss: NOT applied (project busy) — the findings are unchanged" unless store.dismiss_probe_by_code(c)
            puts "Dismissed #{n} open \"#{c}\" finding#{n == 1 ? "" : "s"}."
          elsif hst = host
            n = store.probe_issues.count { |i| i.host == hst && i.status.open? }
            abort "gori run probe dismiss: NOT applied (project busy) — the findings are unchanged" unless store.dismiss_probe_by_host(hst)
            puts "Dismissed #{n} open finding#{n == 1 ? "" : "s"} on #{hst}."
          elsif iid = id
            issue = store.get_probe_issue(iid) || abort("gori run probe dismiss: no probe finding with id #{iid}")
            landed = Probe::Triage.toggle_dismiss(store, issue)
            puts "Finding ##{issue.id} is now #{landed.label}."
          end
        ensure
          store.close
        end
      end

      private def self.cmd_probe_promote(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe promote <id>\n\n" \
                     "Promote a machine finding to a human-confirmed Issue (see `gori run issues`),\n" \
                     "carrying its severity/host/sample evidence over. Marks the source finding\n" \
                     "Confirmed so a repeat call cannot mint a duplicate."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe promote: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe promote: missing value for #{f}" }
        end
        parser.parse(args)

        id = parse_probe_issue_id(positional.first?, "gori run probe promote")
        abort "gori run probe promote: <id> is required (see `gori run probe issues`)" unless id

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          issue = store.get_probe_issue(id) || abort("gori run probe promote: no probe finding with id #{id}")
          res = Probe::Triage.promote(store, issue)
          case res.outcome
          in Probe::Triage::Outcome::Promoted
            puts "Promoted finding ##{issue.id} to Issue ##{res.issue_id}."
          in Probe::Triage::Outcome::AlreadyPromoted
            puts "Finding ##{issue.id} was already promoted to an issue."
          in Probe::Triage::Outcome::Failed
            # Nothing was written — exit non-zero so a script retries rather than moving on.
            abort "gori run probe promote: finding ##{issue.id} NOT promoted (store busy or unwritable); it is unchanged"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_probe_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        all = false
        yes = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe delete <id> | --all --yes\n\n" \
                     "Delete <id>: also SUPPRESSES that (code, host) pair so the next scan does not\n" \
                     "immediately re-add it — prefer `probe dismiss` when you only want it out of\n" \
                     "the default lens.\n" \
                     "Delete --all: wipes every finding AND every suppression, so a rescan\n" \
                     "re-discovers everything. Needs --yes."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("--all", "Delete EVERY probe finding AND every suppression in the project") { all = true }
          p.on("--yes", "Required with --all (there is no interactive prompt here)") { yes = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe delete: missing value for #{f}" }
        end
        parser.parse(args)

        id = parse_probe_issue_id(positional.first?, "gori run probe delete")
        abort "gori run probe delete: pass <id> or --all" if id.nil? && !all
        abort "gori run probe delete: <id> and --all are mutually exclusive" if id && all

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          if all
            n = store.count_probe_issues
            unless yes
              abort "gori run probe delete: refusing to delete #{n} finding#{n == 1 ? "" : "s"} (and every suppression) without --yes"
            end
            abort "gori run probe delete: NOT cleared (project busy) — every finding is still there" unless store.clear_probe_issues
            puts "Deleted #{n} finding#{n == 1 ? "" : "s"} and cleared every suppression."
          elsif iid = id
            issue = store.get_probe_issue(iid) || abort("gori run probe delete: no probe finding with id #{iid}")
            abort "gori run probe delete: finding ##{issue.id} NOT deleted (project busy)" unless store.delete_probe_issue(issue.id)
            puts "Deleted finding ##{issue.id}."
          end
        ensure
          store.close
        end
      end

      # --- scan rules + mode ----------------------------------------------------------------

      private def self.cmd_probe_rules(args : Array(String)) : Nil
        case sub = args.first?
        when "enable"       then cmd_probe_rule_enabled(args[1..], true)
        when "disable"      then cmd_probe_rule_enabled(args[1..], false)
        when "add"          then cmd_probe_rule_add(args[1..])
        when "delete", "rm" then cmd_probe_rule_delete(args[1..])
        when "list"         then cmd_probe_rules_list(args[1..])
        else
          # Same guard, same reason as cmd_issues / cmd_links — see `verb_token?`.
          # `probe rules remove my-rule` (or `disble`) listed the rules and exited 0.
          if verb_token?(sub)
            abort "gori run probe rules: unknown subcommand '#{sub}' " \
                  "(add, enable, disable, delete/rm, list)"
          end
          cmd_probe_rules_list(args)
        end
      end

      private def self.cmd_probe_rules_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        kind : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe rules [list] [options]\n\n" \
                     "List every scan rule — built-in passive, built-in active, and custom match\n" \
                     "rules — with whether it is enabled. A scan on ANY surface (here, the TUI, or\n" \
                     "MCP) honours this config."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--kind=KIND", "Only list rules of this kind (passive|active|custom)") { |v| kind = parse_rule_kind(v) }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run probe rules: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe rules: missing value for #{f}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        entries, mode = begin
          list = Probe::RuleCatalog.load(store)
          list = list.select { |e| e.kind == kind } if kind
          {list, store.probe_mode}
        ensure
          store.close
        end

        if format == :json
          puts JSON.build { |j| j.array { entries.each { |e| Probe::RuleCatalog.entry_json(j, e) } } }
          return
        end
        off = entries.count { |e| !e.enabled }
        STDERR.puts "mode: #{mode.label} · #{entries.size} rule#{entries.size == 1 ? "" : "s"}#{off > 0 ? " (#{off} disabled)" : ""}"
        entries.each { |e| puts CLI::Output.probe_rule_text(e) }
      end

      private def self.cmd_probe_rule_enabled(args : Array(String), enabled : Bool) : Nil
        verb = enabled ? "enable" : "disable"
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe rules #{verb} <rule-id>\n\n" \
                     "Turn a scan rule on/off for this project (ids from `probe rules`).\n" \
                     "Disabling a built-in stops NEW detections; findings it already produced stay."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe rules #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe rules #{verb}: missing value for #{f}" }
        end
        parser.parse(args)

        id = positional.first? || abort("gori run probe rules #{verb}: <rule-id> is required (see `gori run probe rules`)")
        store = open_store(resolve_read_project(project_name, db_path))
        begin
          entry = Probe::RuleCatalog.load(store).find { |e| e.id == id } ||
                  abort("gori run probe rules #{verb}: no scan rule with id '#{id}' (see `gori run probe rules`)")
          if entry.kind == "custom"
            abort "gori run probe rules #{verb}: '#{id}' is a GLOBAL custom rule (stored in settings.json, shared across projects) — it cannot be toggled per project" if entry.scope == "global"
            row_id = probe_custom_row_id(id) || abort("gori run probe rules #{verb}: malformed custom rule id '#{id}'")
            store.set_probe_custom_rule_enabled(row_id, enabled)
          else
            disabled = store.probe_disabled_rules
            # `set_rule_enabled` (not a bare delete/add) so a DEFAULT-OFF rule toggles correctly:
            # for those ids the stored-set membership is INVERTED — see Probe::DEFAULT_DISABLED_RULES.
            Probe.set_rule_enabled(disabled, id, enabled)
            store.set_probe_disabled_rules(disabled)
          end
          puts "Rule '#{id}' is now #{enabled ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      private def self.cmd_probe_rule_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        title : String? = nil
        pattern : String? = nil
        description = ""
        side = "response"
        region = "body"
        match_kind = "string"
        sev_s = "info"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe rules add --title=T --pattern=P [options]\n\n" \
                     "Add a PROJECT custom match rule: a string or regex tested against one region\n" \
                     "of every captured flow, emitting a finding on a hit."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-tTITLE", "--title=TITLE", "Rule name, shown as the finding title (required)") { |v| title = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "String to look for, or a regex with --regex (required)") { |v| pattern = v }
          p.on("--description=TEXT", "What the rule is for") { |v| description = v }
          p.on("--side=SIDE", "request|response (default response)") { |v| side = v.strip.downcase }
          p.on("--region=REGION", "whole|header|body (default body)") { |v| region = v.strip.downcase }
          p.on("--regex", "Treat --pattern as a regex instead of a literal string") { match_kind = "regex" }
          p.on("-sSEVERITY", "--severity=SEVERITY", "info|low|medium|high|critical (default info)") { |v| sev_s = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run probe rules add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe rules add: missing value for #{f}" }
        end
        parser.parse(args)

        t = title
        abort "gori run probe rules add: --title is required" if t.nil? || t.empty?
        pat = pattern
        abort "gori run probe rules add: --pattern is required" if pat.nil? || pat.empty?
        abort "gori run probe rules add: invalid --side '#{side}' (#{Probe::CustomRule::SIDES.join("|")})" unless Probe::CustomRule::SIDES.includes?(side)
        abort "gori run probe rules add: invalid --region '#{region}' (#{Probe::CustomRule::REGIONS.join("|")})" unless Probe::CustomRule::REGIONS.includes?(region)
        # A regex PCRE rejects would match nothing forever while reporting the rule saved fine.
        abort "gori run probe rules add: invalid regex --pattern (PCRE rejected it)" unless Probe::CustomRule.valid_pattern?(pat, match_kind)
        severity = Store::Severity.parse?(sev_s.strip) || abort("gori run probe rules add: invalid --severity '#{sev_s}' (info|low|medium|high|critical)")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          id = store.insert_probe_custom_rule(t, description, side, region, match_kind, pat, severity)
          abort "gori run probe rules add: failed to persist the rule (store busy or unwritable)" if id == 0
          puts "Custom rule 'custom_p_#{id}' created."
        ensure
          store.close
        end
      end

      private def self.cmd_probe_rule_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe rules delete <custom-rule-id>\n\n" \
                     "Delete a project custom rule. A built-in can only be DISABLED, never deleted."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe rules delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe rules delete: missing value for #{f}" }
        end
        parser.parse(args)

        id = positional.first? || abort("gori run probe rules delete: <custom-rule-id> is required")
        row_id = probe_custom_row_id(id) ||
                 abort("gori run probe rules delete: '#{id}' is not a project custom rule — a built-in can only be disabled (`probe rules disable #{id}`)")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          abort "gori run probe rules delete: no custom rule with id '#{id}'" unless store.probe_custom_rules.any? { |r| r.id == row_id }
          store.delete_probe_custom_rule(row_id)
          puts "Custom rule '#{id}' deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_probe_mode(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String
        modes = Probe::Mode.values.map(&.label)

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe mode [#{modes.join("|")}]\n\n" \
                     "Get (no argument) or set the project's scan mode:\n" \
                     "  off         no analysis at all\n" \
                     "  passive     zero-request checks on captured traffic (default)\n" \
                     "  active      passive plus light-touch probes that SEND requests to\n" \
                     "              scope-included targets\n" \
                     "  aggressive  active with raised caps, wider bypass sets, and UNSAFE\n" \
                     "              methods (POST/PUT/PATCH/DELETE) — authorized targets only\n\n" \
                     "This arms the AUTOMATIC pipeline for live captures, not just one scan."
          p.on("--project=NAME", "Project to read/write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe mode: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe mode: missing value for #{f}" }
        end
        parser.parse(args)

        want = positional.first?.try(&.strip.downcase)
        # Mode.from_setting silently falls back to Passive on an unknown label — that would
        # report success for a typo, so validate against the labels first.
        abort "gori run probe mode: invalid mode '#{want}' (#{modes.join("|")})" if want && !modes.includes?(want)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          if w = want
            mode = Probe::Mode.from_setting(w)
            store.set_probe_mode(mode)
            puts "Scan mode set to #{mode.label}."
          else
            puts store.probe_mode.label
          end
        ensure
          store.close
        end
      end

      private def self.parse_rule_kind(v : String) : String
        k = v.strip.downcase
        %w[passive active custom].includes?(k) ? k : abort("gori run probe rules: invalid --kind '#{v}' (passive|active|custom)")
      end

      # "custom_p_12" → 12. nil for a built-in id or a GLOBAL custom rule ("custom_g_…"),
      # neither of which is a project DB row.
      private def self.probe_custom_row_id(id : String) : Int64?
        return nil unless id.starts_with?("custom_p_")
        id[9..].to_i64?
      end

      private def self.parse_probe_issue_id(v : String?, ctx : String) : Int64?
        return nil unless v
        v.to_i64? || abort("#{ctx}: invalid finding id #{v.inspect} (expected an integer — see `gori run probe issues`)")
      end

      # A live progress callback for Probe::Scan (an in-place "scanned i/n flows" meter,
      # throttled to every 64th flow), or nil when STDERR isn't a TTY.
      private def self.probe_progress_meter(meter : Bool) : Proc(Int32, Int32, Nil)?
        return nil unless meter
        ->(i : Int32, n : Int32) do
          if (i & 0x3F) == 0
            STDERR.print "\r[probe] scanned #{i + 1}/#{n} flows"
            STDERR.flush
          end
          nil
        end
      end

      # A malformed QL query can be arbitrarily large (a raw regex term, say) — don't dump
      # the whole thing into an error message. Keep enough to identify the query, not replay it.
      QUERY_ECHO_LIMIT = 200

      private def self.truncate_query(q : String?) : String?
        return q unless q && q.size > QUERY_ECHO_LIMIT
        "#{q[0, QUERY_ECHO_LIMIT]}…"
      end

      private def self.parse_severity(v : String) : Store::Severity
        Store::Severity.parse?(v) || abort "gori run probe: invalid --severity '#{v}' (info|low|medium|high|critical)"
      end

      private def self.parse_probe_category(v : String) : String
        d = v.downcase
        PROBE_CATEGORIES.includes?(d) ? d : abort("gori run probe: invalid --category '#{v}' (#{PROBE_CATEGORIES.join("|")})")
      end
    end
  end
end
