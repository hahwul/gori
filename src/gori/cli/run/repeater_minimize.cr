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
        allow_unscoped = false
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
          p.on("--allow-unscoped", "Minimize even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
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
        # HostOverrides.load snapshots rows into memory, so it is safe to keep past the close.
        # Loaded from the SAME open that fetched `rec` rather than via cli_host_overrides,
        # which returns nil without an explicit --project/--db — a repeater session always
        # belongs to a resolved project, so the overrides must not depend on the flag.
        rec, host_overrides = begin
          {store.get_repeater(id), Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater minimize: no repeater session ##{id}" unless rec
        outbound = project_outbound(project_name, db_path, allow_unscoped)

        text = String.new(rec.request)
        scheme, host, port = minimize_target_or_abort(id, rec, text, outbound)
        auto_cl = rec.auto_content_length?
        # Mirrors the TUI's resolve: env-expand, then Content-Length resync only when the
        # session has Auto-CL on (the same gate that lets body params be removed at all).
        resolve = ->(t : String) do
          raw = Env.expand_wire(t)
          auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
        end
        # Fuzz::Sender applies the Outbound gate (Sandbox / exclude) at the socket seam;
        # CappedBackend bounds total sends. Same stack the TUI builds.
        backend = Fuzz::CappedBackend.new(
          Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), outbound, rec.http2?,
            !insecure, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds,
            overrides: host_overrides),
          Repeater::Minimize::SEND_CAP)

        meter = STDERR.tty?
        report = Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) do |progress|
          if meter
            STDERR.print "\r[minimize] #{progress.done}/#{progress.total} candidates"
            STDERR.flush
          end
        end
        STDERR.print "\r\e[K" if meter
        outbound.close

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
                                                text : String, outbound : Gori::Outbound) : {String, String, Int32}
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
        # Minimize dials `Fuzz::Sender` directly rather than through `Repeater::Plan`, by
        # design, so the builder's unresolved-token refusal (#519) never runs for it and this
        # is the only place that check can happen (#524). Checked BEFORE the target parse: an
        # unresolved `$HOST` survives `Env.expand` as the literal host, which would otherwise
        # surface as an unparseable-target abort naming no variable at all.
        #
        # Head-only on the REQUEST (`unresolved_wire`) for #519's reason — a `$` in a captured
        # body is a byte, and a whole-request check refuses nearly every binary-body session —
        # but whole-string on the target and SNI, which are short operator-typed fields with no
        # body to exclude. The MCP and TUI minimize paths carry the same three checks.
        names = Env.unresolved_wire(text) | Env.unresolved(rec.target) |
                (rec.sni.try { |s| Env.unresolved(s) } || [] of String)
        unless names.empty?
          abort "gori run repeater minimize: " +
                env_unresolved_error(Env.token_list(names), " for session ##{id}")
        end
        scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(rec.target))
        abort "gori run repeater minimize: could not determine a target host for session ##{id}" if host.empty?
        abort "gori run repeater minimize: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        target = Gori::Outbound.request_target(text)
        # Layer 1 (include list): the configured project scope, waivable with --allow-unscoped —
        # mirrors fuzz/mine/sequence and MCP minimize's scope_refusal (#406).
        if outbound.check_request(scheme, host, target).blocked?
          abort "gori run repeater minimize: #{host} is out of the project scope — add a scope include rule or pass --allow-unscoped"
        end
        # Layer 2 (Sandbox / exclude): applies even under --allow-unscoped.
        if reason = outbound.send_block(scheme, host, target)
          abort "gori run repeater minimize: #{reason}"
        end
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
