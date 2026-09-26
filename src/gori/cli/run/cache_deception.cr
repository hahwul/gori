require "../../cache_deception"
require "../../authorize/engine"
require "../../host_overrides"

# `gori run cache-deception` — check captured flows for WEB CACHE DECEPTION, the headless
# equivalent of the MCP `cache_deception_check` tool. Replays each flow as its captured
# (authenticated) identity to prime any cache, re-requests the SAME url anonymously, then makes
# a cache-busted anonymous control request. Borrows the Authorize engine.
module Gori
  module CLI
    module Run
      @[Subcommand("cache-deception", help: [
        {"cache-deception [<id>…]", "Check flows for web cache deception (authenticated, anonymous, cache-busted control)"},
      ])]
      private def self.cmd_cache_deception(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_ids = [] of Int64
        unsafe_methods = false
        allow_unscoped = false
        insecure = false
        timeout = Authorize::ACTIVE_TIMEOUT
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run cache-deception [<flow-id>…] [options]\n\n" \
                     "For each selected flow, replay it as its captured (AUTHENTICATED) identity to\n" \
                     "prime any cache, re-request the SAME url with NO session, then compare with an\n" \
                     "anonymous cache-busted control request. Matching content supports a public\n" \
                     "verdict only when the control is not itself a cache hit; otherwise the buster\n" \
                     "may have been ignored. If the anonymous request gets the authenticated response\n" \
                     "FROM a cache and the control differs, that private response may be cached under\n" \
                     "a key an anonymous client hits — a web cache deception. The crafted paths that\n" \
                     "are the Fuzzer's `cache-delimiters` payload set; check the promising hits here.\n\n" \
                     "Only safe methods (GET/HEAD/OPTIONS) are checked without --unsafe-methods."
          p.on("--flow=ID", "Check this captured flow (repeatable; same as a positional id)") { |v| flow_ids << parse_flow_id(v, "gori run cache-deception") }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--unsafe-methods", "Also check POST/PUT/PATCH/DELETE — side effects can run up to three times") { unsafe_methods = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--format=FMT", "Output: text (default) | json (one array at the end) | jsonl (streamed)") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run cache-deception: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run cache-deception: missing value for #{f}" }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)
        positional.each { |s| flow_ids << parse_flow_id(s, "gori run cache-deception") }
        abort "gori run cache-deception: name at least one flow id (or --flow ID)" if flow_ids.empty?

        store = open_store(resolve_read_project(project_name, db_path))
        outbound = project_outbound(project_name, db_path, allow_unscoped)
        overrides = Gori::HostOverrides.load(store)
        engine = Authorize::Engine.live(outbound, !insecure, timeout, overrides: overrides)

        reports = [] of CacheDeception::Report
        checked = 0
        sent = 0
        begin
          flow_ids.uniq.each do |id|
            detail = store.get_flow(id)
            unless detail
              STDERR.puts "gori run cache-deception: no flow with id #{id}"
              next
            end
            next if report_skip_reason?(id, detail, unsafe_methods)
            row = detail.row
            next if report_outbound_skip?(id, row, outbound)
            report = CacheDeception.check(engine, detail)
            next unless report # nil only if the engine was stopped before completing the check
            reports << report
            sent += report.sent_count
            checked += 1 unless report.verdict.blocked? || report.verdict.errored?
            emit_cache_deception(report, format) if format != :json
          end
        ensure
          store.close
          outbound.close
        end

        emit_cache_deception_json_array(reports) if format == :json
        deceptions = reports.count(&.verdict.deception?)
        STDERR.puts "checked #{checked} flow#{checked == 1 ? "" : "s"} — " \
                    "#{deceptions} likely cache deception#{deceptions == 1 ? "" : "s"}"
        exit_if_no_cache_deception_evidence(reports, sent, checked)
      end

      private def self.exit_if_no_cache_deception_evidence(reports : Array(CacheDeception::Report),
                                                           sent : Int32, checked : Int32) : Nil
        if reports.empty?
          STDERR.puts "gori run cache-deception: no flow was checked — every selection was missing, skipped, or out of scope"
          exit 1
        end
        if sent == 0
          STDERR.puts "gori run cache-deception: every send was refused before the socket"
          exit 1
        end
        if checked == 0
          STDERR.puts "gori run cache-deception: no response could be compared"
          exit 1
        end
      end

      private def self.report_outbound_skip?(id : Int64, row : Store::FlowRow,
                                             outbound : Outbound) : Bool
        verdict = outbound.check_request(row.scheme, row.host, row.target, row.port)
        return false unless verdict.blocked?
        STDERR.puts "  skip flow #{id}: #{Outbound.remedy(verdict, "--allow-unscoped")}"
        true
      end

      private def self.report_skip_reason?(id : Int64, detail : Store::FlowDetail,
                                           unsafe_methods : Bool) : Bool
        reason = CacheDeception.skip_reason(detail, unsafe_methods)
        return false unless reason
        STDERR.puts "  skip flow #{id}: #{CacheDeception.reason_label(reason)}" \
                    "#{reason == :unsafe_method ? " (pass --unsafe-methods to check it anyway)" : ""}"
        true
      end

      private def self.emit_cache_deception(report : CacheDeception::Report, format : Symbol) : Nil
        case format
        when :jsonl then puts cache_deception_report_json(report)
        else             puts cache_deception_report_text(report)
        end
      end

      private def self.cache_deception_report_text(report : CacheDeception::Report) : String
        auth = report.authenticated
        anon = report.anonymous
        control = report.control
        detail = String.build do |io|
          io << "  authenticated: " << (auth ? cache_deception_trial_text(auth) : "—")
          io << "  ·  anonymous: " << (anon ? cache_deception_trial_text(anon) : "—")
          io << "  ·  cache-busted: " << (control ? cache_deception_trial_text(control) : "—")
          io << "  ·  anonymous cache: " << report.cache.token
        end
        "[#{report.verdict.label}] #{report.method} #{report.url}\n#{detail}"
      end

      private def self.cache_deception_trial_text(trial : Authorize::Trial) : String
        cache = CacheStatus.classify(trial.response_head).token
        if e = trial.summary.error
          "error (#{e}), cache: #{cache}"
        else
          "#{trial.summary.status || "—"} #{trial.summary.size || 0}b, cache: #{cache}"
        end
      end

      private def self.cache_deception_report_json(report : CacheDeception::Report) : String
        JSON.build { |j| cache_deception_report_fields(j, report) }
      end

      private def self.emit_cache_deception_json_array(reports : Array(CacheDeception::Report)) : Nil
        puts(JSON.build do |j|
          j.array { reports.each { |r| cache_deception_report_fields(j, r) } }
        end)
      end

      private def self.cache_deception_report_fields(j : JSON::Builder, report : CacheDeception::Report) : Nil
        j.object do
          j.field "flow_id", report.flow_id
          j.field "method", report.method
          j.field "url", report.url
          j.field "verdict", report.verdict.label
          j.field "deception", report.verdict.deception?
          j.field "cache", report.cache.token
          cache_deception_trial_fields(j, "authenticated", report.authenticated)
          cache_deception_trial_fields(j, "anonymous", report.anonymous)
          cache_deception_trial_fields(j, "cache_busted", report.control)
          report.blocked_reason.try { |r| j.field "blocked_reason", r }
        end
      end

      private def self.cache_deception_trial_fields(j : JSON::Builder, name : String,
                                                    trial : Authorize::Trial?) : Nil
        return unless trial
        j.field name do
          j.object do
            j.field "status", trial.summary.status
            j.field "size", trial.summary.size
            j.field "verdict", trial.verdict.label
            j.field "cache", CacheStatus.classify(trial.response_head).token
            trial.summary.error.try { |e| j.field "error", e }
          end
        end
      end

      # The output shapes are `private def self.`, so a spec reaches them through this module
      # shim — the pattern `authorize_plan_error_for_spec` uses.
      def self.cache_deception_text_for_spec(report : CacheDeception::Report) : String
        cache_deception_report_text(report)
      end

      def self.cache_deception_json_for_spec(report : CacheDeception::Report) : String
        cache_deception_report_json(report)
      end
    end
  end
end
