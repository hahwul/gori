# `gori run repeater minimize` — strip the noise out of a saved repeater request while
# keeping the response essentially the same (Caido-"squash"-style). Drives the same
# `Repeater::Minimize` engine as the TUI's Space→M, so a CLI run and a TUI run produce the
# same trimmed request for the same session.
module Gori
  module CLI
    module Run
      private def self.cmd_repeater_minimize(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        apply = false
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater minimize <repeater-id> [options]\n\n" \
                     "Strip cosmetic headers, tracking-cookie crumbs, and unused query/body params\n" \
                     "from a saved repeater request, keeping the response within tolerance of a\n" \
                     "calibrated baseline. SENDS MANY REAL REQUESTS (capped at #{Repeater::Minimize::SEND_CAP}).\n" \
                     "Prints the trimmed request; pass --apply to also save it back to the session."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--apply", "Write the minimized request back into the repeater session") { apply = true }
          p.on("-k", "--insecure", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run repeater minimize: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater minimize: missing value for #{f}" }
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run repeater minimize: <repeater-id> is required")
        id = id_s.to_i64? || abort("gori run repeater minimize: invalid repeater id #{id_s.inspect}")

        store = open_store(resolve_read_project(project_name, db_path))
        rec, scope = begin
          {store.get_repeater(id), Gori::Scope.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater minimize: no repeater session ##{id}" unless rec

        text = String.new(rec.request)
        scheme, host, port = minimize_target_or_abort(id, rec, text, scope)
        auto_cl = rec.auto_content_length?
        # Mirrors the TUI's resolve: env-expand, then Content-Length resync only when the
        # session has Auto-CL on (the same gate that lets body params be removed at all).
        resolve = ->(t : String) do
          raw = Env.expand_wire(t)
          auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
        end
        # ScopedBackend is the hard gate a Sandbox/exclude rule enforces at the socket seam;
        # CappedBackend bounds total sends. Same stack the TUI builds.
        backend = Fuzz::ScopedBackend.new(
          Fuzz::CappedBackend.new(
            Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), rec.http2?,
              !insecure, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds),
            Repeater::Minimize::SEND_CAP),
          scope)

        meter = STDERR.tty?
        report = Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) do |progress|
          if meter
            STDERR.print "\r[minimize] #{progress.done}/#{progress.total} candidates"
            STDERR.flush
          end
        end
        STDERR.print "\r\e[K" if meter

        if apply && !report.aborted && !report.removed.empty?
          w = open_store(resolve_read_project(project_name, db_path))
          begin
            w.update_repeater(id: id, target: rec.target, request: report.minimized_text.to_slice,
              http2: rec.http2?, auto_cl: auto_cl, sni: rec.sni)
          ensure
            w.close
          end
        end
        report_repeater_minimize(id, report, format, apply)
        exit 1 if report.aborted
      end

      # The validated {scheme, host, port} to minimize against, or an abort. Split out of
      # cmd_repeater_minimize to keep it under the cyclomatic-complexity bar.
      private def self.minimize_target_or_abort(id : Int64, rec : Store::RepeaterRecord,
                                                text : String, scope : Gori::Scope) : {String, String, Int32}
        if Repeater::WsEngine.upgrade_request?(text)
          abort "gori run repeater minimize: session ##{id} is a WebSocket upgrade — minimize works on plain HTTP requests"
        end
        # The TUI refuses this too (repeater_view.cr#minimizable?). A saved request holding
        # §fuzz§ markers is a TEMPLATE, not a request: minimizing it would send 250 requests
        # containing literal § bytes (garbage the origin answers uniformly, which then lets
        # real headers look removable) and --apply would overwrite the user's marked-up
        # template with the mangled result.
        unless Fuzz::Template.marker_regions(text).empty?
          abort "gori run repeater minimize: session ##{id} contains §fuzz§ markers — remove them first, or use `gori run fuzz` to sweep them"
        end
        scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(rec.target))
        abort "gori run repeater minimize: could not determine a target host for session ##{id}" if host.empty?
        abort "gori run repeater minimize: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        abort_if_sandboxed!(scope, scheme, host, request_target(text.to_slice), "gori run repeater minimize")
        {scheme, host, port}
      end

      private def self.report_repeater_minimize(id : Int64, report : Repeater::Minimize::Report,
                                                format : Symbol, applied : Bool) : Nil
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "repeater_id", id
              j.field "aborted", report.aborted
              j.field "note", report.note
              j.field "sends", report.sends
              j.field("removed") do
                j.array do
                  report.removed.each do |r|
                    j.object { j.field "kind", r.kind.to_s.downcase; j.field "label", r.label }
                  end
                end
              end
              j.field "removed_count", report.removed.size
              j.field "applied", applied && !report.aborted && !report.removed.empty?
              j.field "minimized_request", report.minimized_text
            end
          end)
          return
        end
        STDERR.puts "#{report.note} · #{report.sends} send#{report.sends == 1 ? "" : "s"}"
        report.removed.each { |r| STDERR.puts "  - [#{r.kind.to_s.downcase}] #{r.label}" }
        STDERR.puts "saved back to session ##{id}" if applied && !report.aborted && !report.removed.empty?
        puts report.minimized_text
      end
    end
  end
end
