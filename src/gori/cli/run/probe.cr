# `gori run probe` — passively scan captured flows for issues (zero requests).
module Gori
  module CLI
    module Run
      # The categories a Probe scan can emit (shared with the MCP probe_scan tool).
      PROBE_CATEGORIES = Probe::SCAN_CATEGORIES

      private def self.cmd_probe(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        min_sev : Store::Severity? = nil
        category : String? = nil
        format = :text
        active = false
        allow_unscoped = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe [QL query] [options]\n\n" \
                     "Scan captured History flows AND Repeater responses for issues —\n" \
                     "the headless equivalent of the TUI Probe tab. By default runs passive checks\n" \
                     "(zero outbound requests). Pass --active to also run active checks (reflected\n" \
                     "params, CORS reflection, 403 bypass, nginx traversal, etc.). QL filters\n" \
                     "apply to History only; all Repeater tabs with a stored response are scanned."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only scan flows matching this QL query (host: status:>=500 size: …)") { |v| query = v }
          p.on("--severity=LEVEL", "Only show issues at/above LEVEL (info|low|medium|high|critical)") { |v| min_sev = parse_severity(v) }
          p.on("--category=CAT", "Only show issues in CAT (#{PROBE_CATEGORIES.join("|")})") { |v| category = parse_probe_category(v) }
          p.on("-a", "--active", "Include light-touch active checks (sends probe requests)") { active = true }
          p.on("--allow-unscoped", "With --active, probe flows even when outside the project scope (default: only scope-included hosts)") { allow_unscoped = true }
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
            abort "gori run probe: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
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
            abort "gori run probe: query #{query.inspect} failed: #{ex.message}"
          end
          meter = STDERR.tty?
          dets, rn = Probe::Scan.scan_all(store, ids, active: active, scope: scope,
            allow_unscoped: allow_unscoped, progress: probe_progress_meter(meter))
          STDERR.print "\r\e[K" if meter # clear the in-place meter before the summary line
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
