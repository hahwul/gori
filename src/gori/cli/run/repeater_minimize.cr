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
        verbatim = false
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
          p.on("--verbatim", "Send the stored bytes as-is: no $VAR expansion, no Content-Length resync (same meaning as `repeater send --verbatim`; body params stop being candidates because their framing could not be kept honest)") { verbatim = true }
          p.on("-k", "--insecure", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--allow-unscoped", "Minimize even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run repeater minimize: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater minimize: missing value for #{f}" }
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run repeater minimize: <repeater-id> is required")
        id = id_s.to_i64? || abort("gori run repeater minimize: invalid repeater id #{id_s.inspect}")

        # Resolved ONCE and reused by the `--apply` write below. `resolve_read_project` with no
        # --project/--db falls through to `registry.list.first`, and that list is sorted by each
        # project's DB-file MTIME (`Project#last_modified`) — so the "most-recently-active"
        # project can change identity while this command runs, and a minimize is minutes long
        # (up to SEND_CAP real sends). Re-resolving at apply time therefore let a peer's write
        # steer the UPDATE into a DIFFERENT project's `repeaters` row #id.
        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
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
        # `--verbatim` means exactly what it means on `repeater send`: the stored bytes ARE
        # the message. So the resolver stops expanding AND stops re-framing, and `auto_cl`
        # goes off with it — which also takes body params out of the candidate set, because
        # removing one without re-lengthing the body would put a request on the wire whose
        # Content-Length disagreed with it for a reason the operator did not choose.
        # (`session_plan_options` folds the same two flags together the same way.)
        auto_cl = !verbatim && rec.auto_content_length?
        resolve = minimize_resolver(id, text, verbatim, auto_cl)
        # Fuzz::Sender applies the Outbound gate (Sandbox / exclude) at the socket seam;
        # CappedBackend bounds total sends. Same stack the TUI builds.
        # `evidence: verbatim` is the SEND-seam half of the same flag `resolve` honours just
        # above — see `Fuzz::Sender#evidence?`. Without it `--verbatim` stopped `$KEY`
        # expansion and then let the session-binding pass substitute a live token into the
        # captured body of every one of up to SEND_CAP probes.
        # Keep-alive: a minimize is a greedy bisection that fires up to SEND_CAP candidate
        # requests at ONE origin, one after another. It is sequential by construction, so
        # `idle_conns: 1` is the whole need — but sequential is exactly why the handshakes
        # dominated: nothing else was in flight to hide them behind.
        backend = Fuzz::CappedBackend.new(
          Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), outbound, rec.http2?,
            !insecure, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds,
            overrides: host_overrides, evidence: verbatim,
            keep_alive: true, idle_conns: 1),
          Repeater::Minimize::SEND_CAP)

        meter = STDERR.tty?
        report = begin
          Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) do |progress|
            if meter
              STDERR.print "\r[minimize] #{progress.done}/#{progress.total} candidates"
              STDERR.flush
            end
          end
        ensure
          backend.close # release the parked socket even if the run raises
        end
        STDERR.print "\r\e[K" if meter
        outbound.close

        # `--apply` writes the minimized REQUEST back — and only that. `auto_cl` above folds in
        # `--verbatim`, which is a PER-SEND choice ("same meaning as `repeater send
        # --verbatim`", per its own help), so persisting it here turned one
        # `minimize --apply --verbatim` into a PERMANENT Auto-Content-Length OFF on the
        # session: `session_plan_options` reads `rec.auto_content_length?`, so every later
        # non-verbatim `repeater send <id>` — and the TUI — silently stopped resyncing
        # Content-Length after `$KEY` expansion, framing an expanded body under the stale
        # length. Confirmed on the binary (`auto_content_length` 1 → 0). The MCP twin already
        # writes the stored value and says so in a parenthetical (mcp/tools/minimize.cr); this
        # makes the two agree.
        #
        # The store also answers whether the write COMMITTED, and dropping that let a
        # busy/locked project print "saved back to session #N" — and report `"applied": true`
        # to a script — over a session still holding the un-minimized request. Same reason
        # `history delete`, `issues delete` and `project scope enable` all check theirs.
        applied = false
        wanted_apply = apply && !report.aborted && !report.removed.empty?
        if wanted_apply
          w = open_store(project)
          begin
            # EVERY column `update_repeater` writes comes off the stored row. Its SQL sets
            # ws_keep_key and ws_http_only unconditionally and its signature defaults both to
            # false, so omitting them CLEARS them — and a session can hold either flag with a
            # request that is not a WebSocket upgrade (`repeater create --ws-http-only -f
            # plain.txt`), which is exactly the shape `minimize_target_or_abort` lets through.
            applied = w.update_repeater(id: id, target: rec.target, request: report.minimized_text.to_slice,
              http2: rec.http2?, auto_cl: rec.auto_content_length?, sni: rec.sni,
              ws_keep_key: rec.ws_keep_key?, ws_http_only: rec.ws_http_only?)
          ensure
            w.close
          end
          unless applied
            STDERR.puts "gori run repeater minimize: --apply did NOT commit (project busy) — " \
                        "session ##{id} still holds the original request"
          end
        end
        # The report is rendered through the SAME resolver the search used, so the request
        # shown is the request that was tested. It used to print `minimized_text` raw — the
        # SOURCE form — which on a session holding a captured `$where`/CL-22 body printed a
        # 2-byte body under a Content-Length of 22: neither what went on the wire during the
        # search nor what a later `repeater send` would produce. `--apply` still stores the
        # source form (that is what the session row holds, and re-resolving it on every send
        # is the point of storing it).
        report_repeater_minimize(id, report, format, applied, resolve)
        # A refused `--apply` is a failed mutation, so it must not exit 0 — but the report is
        # printed first either way: the search already spent real sends, and throwing its
        # result away would cost the operator the run as well as the write.
        exit 1 if report.aborted || (wanted_apply && !applied)
      end

      # The editor-text → wire-bytes step `Minimize` sends through, and the ONE thing
      # `--verbatim` changes about this command.
      #
      # Draft (default): mirrors the TUI's resolve — env-expand, then a Content-Length resync
      # only when the session has Auto-CL on (the same gate that lets body params be removed
      # at all). VERBATIM: neither, because the operator has said the stored bytes ARE the
      # message — `repeater send --verbatim` means exactly this, and without it a session
      # holding a capture was either refused outright or minimized against bytes that differ
      # from what a later send would put on the wire.
      #
      # `Minimize.run` hands this proc the request LF-NORMALIZED (its text helpers are written
      # against that form) and restores the operator's terminator only on the REPORT.
      # `Env.expand_wire` re-terminates the head with CRLF, so the draft path never noticed; a
      # verbatim resolver that simply took the bytes would have put a CRLF-stored session on
      # the wire bare-LF, inventing the very desync primitive the flag exists to preserve.
      private def self.minimize_resolver(id : Int64, text : String, verbatim : Bool,
                                         auto_cl : Bool) : Proc(String, Bytes)
        # HEAD only, and the same question `Minimize.run` asks: a CRLF pair inside a multipart
        # body says nothing about how the operator terminated their header lines, and reading
        # it as if it did would re-terminate an LF-headed session on the way out.
        stored_crlf = Repeater::Minimize.head_crlf?(text)
        # The one case that restore cannot carry: a head whose lines DISAGREE (some CRLF, some
        # bare LF) is itself a smuggling shape, and minimize's LF round-trip flattens it to
        # all-CRLF. Nothing here can undo that — the algorithm rebuilds the head — so say it
        # rather than let `--verbatim` imply a byte-exactness it is not delivering.
        if verbatim && stored_crlf && mixed_line_endings?(text)
          STDERR.puts "gori run repeater minimize: session ##{id}'s head mixes CRLF and bare-LF " \
                      "line endings; minimize rebuilds the head, so every line is sent CRLF-terminated. " \
                      "Use `gori run repeater send #{id} --verbatim` for a byte-exact replay."
        end
        ->(t : String) do
          if verbatim
            stored_crlf ? restore_head_crlf(t) : t.to_slice
          else
            raw = Env.expand_wire(t)
            auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
          end
        end
      end

      # Put CRLF terminators back on the HEAD of a `Minimize` working text, leaving the body
      # byte-exact. The same split, and the same reason, as `Env.expand_wire`'s: in the head a
      # 0x0A is a line ending, in the body it is a byte.
      #
      # Needed because `Minimize` hands its `resolve` proc two different forms — the
      # head-LF-normalized working text during the search, and `restore_eol`'s already-CRLF
      # text in the report — so the step has to be idempotent. It is: `Env.normalize_crlf`
      # never emits `\r\r\n`, which is why `Minimize.restore_eol` can be reused verbatim here.
      #
      # It used to whole-string `gsub("\r\n", "\n")` first, to undo `restore_eol`'s blanket
      # `gsub("\n", "\r\n")` over the BODY. `Minimize` no longer touches the body at all, so
      # that pre-pass is not merely unnecessary — it would now flatten a multipart body's own
      # CRLF boundaries on the way to the wire.
      private def self.restore_head_crlf(text : String) : Bytes
        Repeater::Minimize.restore_eol(text, true).to_slice
      end

      # Does the HEAD carry both CRLF- and bare-LF-terminated lines? Head only: a raw 0x0A in
      # a body is a byte, not a line ending (`Env.expand_wire` splits on the same boundary and
      # for the same reason), and judging the whole request would flag every binary body.
      private def self.mixed_line_endings?(text : String) : Bool
        head = String.new(text.to_slice[0...Env.head_body_boundary(text.to_slice)])
        crlf = false
        lf = false
        pos = 0
        while nl = head.index('\n', pos)
          (nl > 0 && head[nl - 1] == '\r') ? (crlf = true) : (lf = true)
          pos = nl + 1
        end
        crlf && lf
      end

      # The validated {scheme, host, port} to minimize against, or an abort. Split out of
      # cmd_repeater_minimize to keep it under the cyclomatic-complexity bar.
      private def self.minimize_target_or_abort(id : Int64, rec : Store::RepeaterRecord,
                                                text : String,
                                                outbound : Gori::Outbound) : {String, String, Int32}
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
        # The TUI refuses this too (repeater_view.cr#minimize_refusal). A saved request
        # holding a lone `%%%` line is SEVERAL requests: minimize reads it as one, strips
        # lines out of the operator's second request and reports them as removals from the
        # first — and --apply then stores the remnant over the session. Reproduced: an
        # 8-send run reporting `[param] %%%\nGET /g2?other` and saving request 1 alone.
        if Repeater::Minimize.group_document?(text)
          abort "gori run repeater minimize: session ##{id} holds a %%% separator — it is several requests, and minimize would read them as one (--apply would store the remnant); split them into one session each"
        end
        # Minimize dials `Fuzz::Sender` directly rather than through `Repeater::Plan`, by
        # design, so the builder's dial-tuple refusal never runs for it and this is the only
        # place that check can happen (#524). Checked BEFORE the target parse: an unresolved
        # `$HOST` survives `Env.expand` as the literal host, which would otherwise surface as
        # an unparseable-target abort naming no variable at all.
        #
        # The REQUEST is no longer checked at all. A `$NAME` with no value is a literal string
        # on the wire everywhere now (see `Env::Escape`), so a captured OData `$filter`, a
        # Mongo `$where` or a GraphQL `$id` in a query string minimizes as authored. Only the
        # TARGET and SNI are refused — `$` is not a legal byte in a hostname, and a literal one
        # there comes back as an unparseable target or an out-of-scope block, naming the wrong
        # gate. The MCP and TUI minimize paths carry the same two checks.
        names = Env.unresolved(rec.target) |
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
        verdict = outbound.check_request(scheme, host, target)
        if verdict.blocked?
          abort "gori run repeater minimize: #{host} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
        end
        # Layer 2 (Sandbox / exclude): applies even under --allow-unscoped.
        if reason = outbound.send_block(scheme, host, target)
          abort "gori run repeater minimize: #{reason}"
        end
        {scheme, host, port}
      end

      # `resolve` is the SAME proc the search sent through, so `minimized_request` is the
      # request that was actually tested rather than the pre-resolution source text.
      #
      # `applied` is the OUTCOME of the write, not the `--apply` flag: the caller already
      # folded in "aborted", "nothing removed" AND "the store committed it", so re-deriving
      # the first two here would report a refused write as a successful one.
      private def self.report_repeater_minimize(id : Int64, report : Repeater::Minimize::Report,
                                                format : Symbol, applied : Bool,
                                                resolve : Proc(String, Bytes)) : Nil
        wire = resolve.call(report.minimized_text)
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
              j.field "applied", applied
              # The RESOLVED wire, plus the source form the session stores, because they are
              # different questions and the operator needs both: the first is what was sent,
              # the second is what `--apply` writes back and what a later send re-resolves.
              # `scrub` for the same reason the repeater's `head` field does it — a minimized
              # request can carry a binary body, and JSON cannot hold an 8-bit octet.
              j.field "minimized_request", String.new(wire).scrub
              unless String.new(wire).valid_encoding?
                j.field "minimized_request_lossy", true
                j.field "minimized_request_base64", Base64.strict_encode(wire)
              end
              j.field "minimized_source", report.minimized_text
            end
          end)
          return
        end
        STDERR.puts "#{report.note} · #{report.sends} send#{report.sends == 1 ? "" : "s"}"
        report.removed.each { |r| STDERR.puts "  - [#{r.kind.to_s.downcase}] #{r.label}" }
        STDERR.puts "saved back to session ##{id}" if applied
        STDOUT.write(wire)
        STDOUT.puts unless wire.empty? || wire[-1] == 0x0A_u8
      end
    end
  end
end
