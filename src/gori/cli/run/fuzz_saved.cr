# Permanent fuzz-run readers and deletion. Execution lives in fuzz.cr so `fuzz save` uses the
# exact same parser/Plan/engine path as the legacy ephemeral command.
module Gori
  module CLI
    module Run
      private def self.cmd_fuzz_saved_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        session_id : Int64? = nil
        limit = 50
        offset = 0
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz list [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--session=ID", "Only runs saved from this Fuzzer session") { |v| session_id = parse_flow_id(v, "gori run fuzz list") }
          p.on("-nN", "--limit=N", "Runs to return (default 50, max 1000)") { |v| limit = parse_count(v, "--limit").clamp(1, 1000) }
          p.on("--offset=N", "Runs to skip") { |v| offset = parse_nonneg(v, "--offset") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run fuzz list: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz list: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run fuzz list: unexpected argument #{positional.first.inspect}" unless positional.empty?

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        begin
          runs = store.fuzz_runs(session_id, limit, offset)
          counts = store.fuzz_result_counts(runs.map(&.id))
          if format == :json
            puts JSON.build { |j| j.array { runs.each { |run| fuzz_saved_run_json(j, run, counts[run.id]? || 0_i64) } } }
          elsif runs.empty?
            puts "No saved fuzz runs."
          else
            runs.each do |run|
              count = counts[run.id]? || 0_i64
              proto = run.websocket? ? "WS" : (run.http2? ? "H2" : "H1")
              session = run.session_id.try { |id| " session:#{id}" } || ""
              puts "##{run.id}  [#{run.status}] [#{proto}]  #{run.mode}  #{run.matched}/#{run.sent} hit  " \
                   "#{count} rows#{session}  → #{CLI::Output.term_safe(run.target)}"
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_fuzz_saved_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        limit = 200
        offset = 0
        matched_only = false
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz show RUN_ID [RESULT_INDEX] [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-nN", "--limit=N", "Result rows to return (default 200, max 5000)") { |v| limit = parse_count(v, "--limit").clamp(1, 5000) }
          p.on("--offset=N", "Result rows to skip") { |v| offset = parse_nonneg(v, "--offset") }
          p.on("--matched-only", "Only matcher hits") { matched_only = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run fuzz show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz show: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run fuzz show: expected RUN_ID and optional RESULT_INDEX" unless positional.size.in?(1, 2)
        run_id = parse_flow_id(positional[0], "gori run fuzz show")
        result_idx = positional[1]?.try { |v| parse_flow_id(v, "gori run fuzz show") }

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        begin
          run = store.get_fuzz_run(run_id) || abort "gori run fuzz show: no saved run ##{run_id}"
          if idx = result_idx
            row = store.get_fuzz_result(run_id, idx) ||
                  abort "gori run fuzz show: run ##{run_id} has no result ##{idx}"
            show_saved_fuzz_result_detail(run, row, format)
          else
            # Summary pages never fetch the retained request/response BLOBs. Exact
            # `RESULT_INDEX` detail above deliberately keeps the full projection.
            rows = store.fuzz_result_summaries(run_id, limit, offset, matched_only)
            show_saved_fuzz_run(store, run, rows, offset, matched_only, format)
          end
        ensure
          store.close
        end
      end

      private def self.cmd_fuzz_saved_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        yes = false
        force_stale = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz delete RUN_ID --yes [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--yes", "Actually delete the run and every stored result") { yes = true }
          p.on("--force-stale", "Also delete a running/saving row left by a crashed writer") { force_stale = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run fuzz delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz delete: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run fuzz delete: expected one RUN_ID" unless positional.size == 1
        run_id = parse_flow_id(positional[0], "gori run fuzz delete")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          run = store.get_fuzz_run(run_id) || abort "gori run fuzz delete: no saved run ##{run_id}"
          unless yes
            count = store.fuzz_result_count(run_id)
            abort "gori run fuzz delete: refusing to delete run ##{run_id} (#{count} results) without --yes"
          end
          # Status guard, parent delete and the committed child-row count are one writer
          # transaction. The typed result keeps a concurrent finisher/deleter from turning a
          # stale preflight count into a successful-looking message.
          deleted = store.delete_fuzz_run_result(run_id, allow_active: force_stale)
          case deleted.status
          in Store::FuzzRunDeleteStatus::Deleted
            count = deleted.deleted_results
            puts "Deleted fuzz run ##{run_id} and #{count} result#{count == 1 ? "" : "s"}."
          in Store::FuzzRunDeleteStatus::NotFound
            abort "gori run fuzz delete: no saved run ##{run_id}"
          in Store::FuzzRunDeleteStatus::Active
            abort "gori run fuzz delete: run ##{run_id} is still #{run.status}; if its writer crashed, " \
                  "retry with --force-stale (never use it while another gori is saving)"
          in Store::FuzzRunDeleteStatus::WriteFailed
            abort "gori run fuzz delete: NOT deleted (project busy)"
          end
        ensure
          store.close
        end
      end

      private def self.show_saved_fuzz_run(store : Store, run : Store::FuzzRunRecord,
                                           rows : Array(Store::FuzzResultRecord), offset : Int32,
                                           matched_only : Bool, format : Symbol) : Nil
        total = store.fuzz_result_count(run.id, matched_only)
        case format
        when :json
          output = JSON.build do |j|
            j.object do
              j.field("run") { fuzz_saved_run_json(j, run, store.fuzz_result_count(run.id)) }
              j.field("results") { j.array { rows.each { |row| CLI::Output.fuzz_row_fields(j, Fuzz::Persistence.result(row)) } } }
              j.field "offset", offset
              j.field "returned", rows.size
              j.field "total_available", total
              j.field "matched_only", matched_only
            end
          end
          puts output
        when :jsonl
          rows.each { |row| puts CLI::Output.fuzz_row_json(Fuzz::Persistence.result(row)) }
        else
          puts "fuzz run ##{run.id} · #{run.status} · #{run.mode} · #{run.sent} sent · #{run.matched} hit · #{run.errors} errors"
          rows.each { |row| puts CLI::Output.fuzz_row_text(Fuzz::Persistence.result(row)) }
          STDERR.puts "showing #{offset + 1}-#{offset + rows.size} of #{total}" unless rows.empty?
        end
      end

      private def self.show_saved_fuzz_result_detail(run : Store::FuzzRunRecord,
                                                     row : Store::FuzzResultRecord,
                                                     format : Symbol) : Nil
        abort "gori run fuzz show: RESULT_INDEX detail supports text or json" if format == :jsonl
        if format == :json
          output = JSON.build do |j|
            j.object do
              j.field "run_id", run.id
              j.field("result") { CLI::Output.fuzz_row_fields(j, Fuzz::Persistence.result(row)) }
              fuzz_saved_bytes_json(j, "request", row.request)
              fuzz_saved_bytes_json(j, "wire", row.wire)
              fuzz_saved_bytes_json(j, "response_head", row.response_head)
              fuzz_saved_bytes_json(j, "response_body", row.response_body)
            end
          end
          puts output
        else
          puts CLI::Output.fuzz_row_text(Fuzz::Persistence.result(row))
          puts "\n── REQUEST ──"
          puts CLI::Output.term_safe_multiline(row.request.try { |b| String.new(b) } || "(not retained)")
          if wire = row.wire
            puts "\n── WIRE REQUEST ──"
            puts CLI::Output.term_safe_multiline(String.new(wire))
          end
          puts "\n── RESPONSE ──"
          response = IO::Memory.new
          row.response_head.try { |head| response.write(head) }
          row.response_body.try { |body| response.write(body) }
          bytes = response.to_slice
          puts CLI::Output.term_safe_multiline(bytes.empty? ? "(not retained)" : String.new(bytes))
        end
      end

      private def self.fuzz_saved_run_json(j : JSON::Builder, run : Store::FuzzRunRecord,
                                           stored_results : Int64) : Nil
        j.object do
          j.field "id", run.id
          j.field "session_id", run.session_id
          j.field "created_at", run.created_at
          j.field "finished_at", run.finished_at
          j.field "target", run.target.scrub
          j.field "mode", run.mode.scrub
          j.field "total", run.total
          j.field "sent", run.sent
          j.field "matched", run.matched
          j.field "errors", run.errors
          j.field "status", run.status.scrub
          j.field "http2", run.http2?
          j.field "sni", run.sni.try(&.scrub)
          j.field "tls_preset", run.tls_preset.try(&.scrub)
          j.field "websocket", run.websocket?
          j.field "surface", run.surface.try(&.scrub)
          j.field "source_ref", run.source_ref.try(&.scrub)
          j.field "snapshot_version", run.snapshot_version
          j.field "legacy", run.snapshot_version == 0
          j.field "stored_results", stored_results
        end
      end

      private def self.fuzz_saved_bytes_json(j : JSON::Builder, key : String, bytes : Bytes?) : Nil
        unless value = bytes
          j.field key, nil
          return
        end
        text = String.new(value)
        if text.valid_encoding?
          j.field key, text
          j.field "#{key}_encoding", "utf8"
        else
          j.field key, Base64.strict_encode(value)
          j.field "#{key}_encoding", "base64"
        end
        j.field "#{key}_size", value.size
      end
    end
  end
end
