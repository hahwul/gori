# `gori run probe` — passively scan captured flows for issues (zero requests).
module Gori
  module CLI
    module Run
      # The categories a PASSIVE scan can emit. Probe::Category::ACTIVE is intentionally absent —
      # active/reflected-param detections come only from the request-sending Active scanner, which
      # this command doesn't run, so accepting `--category active` would be a guaranteed-empty filter.
      PROBE_CATEGORIES = [
        Probe::Category::HEADERS, Probe::Category::COOKIES, Probe::Category::TECH,
        Probe::Category::INFOLEAK, Probe::Category::CORS, Probe::Category::CLIENT,
      ]

      private def self.cmd_probe(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        min_sev : Store::Severity? = nil
        category : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe [QL query] [options]\n\n" \
                     "Passively scan captured History flows AND Repeater responses (zero outbound\n" \
                     "requests) and report grouped issues — the headless equivalent of the TUI Probe\n" \
                     "tab. QL filters apply to History only; all Repeater tabs with a stored response\n" \
                     "are scanned. The light-touch active checks (reflected params, …) send requests,\n" \
                     "so they are intentionally excluded here — arm active mode in the TUI, or reach\n" \
                     "for fuzz/mine."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only scan flows matching this QL query (host: status:>=500 size: …)") { |v| query = v }
          p.on("--severity=LEVEL", "Only show issues at/above LEVEL (info|low|medium|high|critical)") { |v| min_sev = parse_severity(v) }
          p.on("--category=CAT", "Only show issues in CAT (#{PROBE_CATEGORIES.join("|")})") { |v| category = parse_probe_category(v) }
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
        groups, flow_n, repeater_n = begin
          ids = begin
            probe_scan_ids(store, filter)
          rescue ex
            abort "gori run probe: query #{query.inspect} failed: #{ex.message}"
          end
          dets, rn = scan_all(store, ids)
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

      # Flow IDs to scan, oldest-first (ascending id) — a stable, deterministic grouping order.
      # Reuses the proven search/recent_flows query paths.
      private def self.probe_scan_ids(store : Store, filter : QL::Filter?) : Array(Int64)
        rows = filter ? store.search(filter, Int32::MAX, raise_on_error: true) : store.recent_flows(Int32::MAX)
        rows.map(&.id).reverse! # search/recent_flows are newest-first; reverse → ascending id
      end

      # Passively analyze History flows (with responses) + every Repeater tab that has a stored
      # response. Returns {detections, repeater_count_scanned}. QL filters apply to History only.
      private def self.scan_all(store : Store, ids : Array(Int64)) : {Array(Probe::Detection), Int32}
        detections = scan_flows(store, ids)
        repeater_dets, repeater_n = scan_repeaters(store)
        detections.concat(repeater_dets)
        {detections, repeater_n}
      end

      # Passively analyze each flow THAT HAS A CAPTURED RESPONSE — mirroring the live analyzer,
      # which only scans on the `:updated` event (a response or WS upgrade exists), never on a
      # bare request. Skipping response-less flows (connect/TLS failures, still-pending) keeps
      # headless counts equal to the TUI Probe tab; otherwise request-only rules (secret_in_url,
      # some tech) would flag flows the live path never sees. Passive detections already carry
      # their source flow_id (ctx.fid). Streams one FlowDetail at a time (full BLOBs); tty meter.
      private def self.scan_flows(store : Store, ids : Array(Int64)) : Array(Probe::Detection)
        detections = [] of Probe::Detection
        progress = STDERR.tty?
        ids.each_with_index do |id, i|
          detail = store.get_flow(id)
          if detail && detail.response_head
            ws = detail.row.status == 101 ? store.ws_messages(id, 200) : [] of Store::WsMessage
            detections.concat(Probe::Passive.analyze(detail, ws))
          end
          if progress && (i & 0x3F) == 0
            STDERR.print "\r[probe] scanned #{i + 1}/#{ids.size} flows"
            STDERR.flush
          end
        end
        STDERR.print "\r\e[K" if progress # clear the in-place meter before the summary line
        detections
      end

      # Scan Repeater tabs that have a persisted response head (V11). Stamps sample_repeater_id.
      private def self.scan_repeaters(store : Store) : {Array(Probe::Detection), Int32}
        detections = [] of Probe::Detection
        n = 0
        store.repeaters.each do |rec|
          next unless detail = Probe.detail_from_repeater(rec)
          n += 1
          ws = store.ws_messages_for_repeater(rec.id, 200)
          Probe::Passive.analyze(detail, ws).each do |d|
            detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
          end
        end
        {detections, n}
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
