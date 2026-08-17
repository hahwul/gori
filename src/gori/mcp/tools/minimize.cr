require "json"
require "../../store"
require "../../scope"
require "../../repeater/minimize"
require "../../repeater/flow_request"
require "../../repeater/ws_engine"
require "../../env"
require "../../fuzz/template"

module Gori
  module MCP
    class Tools
      # minimize_repeater — strip cosmetic headers, tracking-cookie crumbs, and unused
      # query/body params from a saved repeater request while keeping the response within
      # tolerance of a calibrated baseline (Caido-"squash"-style). Drives the same
      # `Repeater::Minimize` engine as the TUI's Space→M and `gori run repeater minimize`.
      #
      # ACTIVE: sends many real outbound requests, so it is write-gated AND scope-gated
      # (the Gori::Outbound decision its Fuzz::Sender carries hard-blocks a Sandbox/exclude
      # at the socket seam).
      # Which spelling of the repeater id this CALL used. `delete_repeater` and
      # `update_repeater` name the same thing `id`, so an agent generalising from its siblings
      # reaches for `id` here; both are accepted, and the one the caller actually reached for
      # is what every message below names.
      #
      # When NEITHER is there it answers the schema's REQUIRED name. It used to fall back to
      # the alias, so a call with no id at all was told "missing required 'id'" for an argument
      # `tools/list` does not mark required — sending the agent to add a field the schema
      # never asked for.
      private def minimize_id_key(h) : String
        return "id" if present?(h, "id") && !present?(h, "repeater_id")
        "repeater_id"
      end

      private def minimize_repeater(h) : Result
        key = minimize_id_key(h)
        id = int(h, key)
        return Result.new(id_error(h, key), is_error: true) unless id
        rec = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless rec

        text = String.new(rec.request)
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        # `send_repeater --verbatim` exists because a session can hold EVIDENCE (seeded from a
        # capture). Minimize is a search over that same request, so it needs the same knob:
        # without it the one flag that makes such a session sendable made it un-minimizable —
        # a captured `$top` was refused outright, and a captured `$where` was minimized against
        # substituted bytes with a reframed Content-Length, i.e. against a request that a later
        # `--verbatim` send would never put on the wire.
        verbatim = bool_arg(h, "verbatim", false)
        # Read BEFORE the search, not after: `apply` used to be parsed once the sends were
        # already spent, so an unintelligible value would refuse a run that had put up to 250
        # real requests on the wire.
        apply = bool_arg(h, "apply", false)
        target = minimize_target(id, rec, text, ob)
        return target if target.is_a?(Result)
        scheme, host, port = target

        # The SEARCH's Auto-CL, not the session's — `send_repeater --verbatim` reads
        # `auto_content_length: !verbatim && rec.auto_content_length?`, and this has to agree
        # with it or the minimized request is not the request a verbatim send would produce.
        # Under verbatim a body param stops being a removal candidate, which is the honest
        # consequence: removing one requires reframing Content-Length, and verbatim is the
        # operator saying do not reframe. The session's own stored setting is untouched (the
        # apply-back below still writes `rec.auto_content_length?`).
        auto_cl = !verbatim && rec.auto_content_length?
        # Mirrors the TUI/CLI resolve: env-expand, then Content-Length resync only when
        # Auto-CL is on (the same gate that lets body params be removed at all). `verbatim`
        # drops the whole draft pass — no `$VAR` substitution and no `$`-refusal — exactly as
        # `--verbatim`/`expand_request: false` does on the send path.
        #
        # It does NOT drop the head's line terminators, which is what `t.to_slice` used to do:
        # `Minimize.run` hands this proc its head-LF working form, so a CRLF-stored session
        # went on the wire bare-LF — verbatim INVENTING the very desync primitive the flag
        # exists to preserve. `gori run repeater minimize --verbatim` fixed this on its side
        # in #556; this is the same restore, through the engine's own (idempotent) helper, so
        # the report's already-CRLF text round-trips through it unchanged. The BODY is byte
        # for byte either way — `restore_eol` is head-only.
        stored_crlf = Repeater::Minimize.head_crlf?(text)
        resolve = ->(t : String) do
          raw = if verbatim
                  stored_crlf ? Repeater::Minimize.restore_eol(t, true).to_slice : t.to_slice
                else
                  Env.expand_wire(t)
                end
          auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
        end
        # Minimize dials Fuzz::Sender directly (many capped probe sends) rather than through
        # Repeater::Plan, so it needs the project's host overrides threaded by hand — without
        # them this was the one repeater send path left resolving the target for real while
        # every other surface honoured the operator's pin (#367).
        # `evidence: verbatim` is the SEND-seam half of the flag the resolver above already
        # honours. `verbatim` means "the stored bytes ARE the message", and the resolver duly
        # stops expanding `$KEY` — but the session-binding pass lives one seam later, inside
        # `Fuzz::Sender`, and ran anyway. A repeater seeded from a capture whose body carries
        # `$id`/`$ne`/`$ref` therefore had a live session token spliced into every probe:
        # measured at 12 copies of the token across 6 sends of one `minimize_repeater
        # {verbatim: true}` call, with the tool reporting a clean minimization. See
        # `Fuzz::Sender#evidence?`.
        # Keep-alive — see the CLI twin in `cli/run/repeater_minimize.cr`. The three minimize
        # surfaces build the same stack, so they get the same transport.
        backend = Fuzz::CappedBackend.new(
          Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), ob, rec.http2?,
            @verify_upstream, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds,
            overrides: HostOverrides.load(store), evidence: verbatim,
            keep_alive: true, idle_conns: 1),
          Repeater::Minimize::SEND_CAP)

        report = begin
          Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) { }
        ensure
          backend.close # release the parked socket even if the run raises
        end

        applied = false
        if apply && !report.aborted && !report.removed.empty?
          # ws_keep_key/ws_http_only for the reason the CLI twin gives: update_repeater's SQL
          # sets both columns unconditionally and its signature defaults them to false, so
          # omitting them CLEARS a session that carried either.
          applied = store.update_repeater(id: id, target: rec.target,
            request: report.minimized_text.to_slice, http2: rec.http2?,
            auto_cl: rec.auto_content_length?, sni: rec.sni,
            ws_keep_key: rec.ws_keep_key?, ws_http_only: rec.ws_http_only?)
        end

        Result.new(JSON.build do |j|
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
            j.field "minimized_request", report.minimized_text
          end
        end)
      end

      # The validated {scheme, host, port} to minimize against, or a refusal Result. Split out
      # of minimize_repeater to keep it under the cyclomatic-complexity bar.
      private def minimize_target(id : Int64, rec : Store::RepeaterRecord, text : String,
                                  ob : Outbound) : {String, String, Int32} | Result
        if Repeater::WsEngine.upgrade_request?(text)
          return err("repeater #{id} is a WebSocket upgrade — minimize works on plain HTTP requests",
            "INVALID_ARGUMENT", field: "repeater_id")
        end
        # The TUI refuses this too (repeater_view.cr#minimizable?). A saved request holding
        # §fuzz§ markers is a TEMPLATE, not a request: minimizing it would send 250 requests
        # containing literal § bytes (garbage the origin answers uniformly, which then lets
        # real headers look removable) and apply:true would overwrite the marked-up template.
        unless Fuzz::Template.marker_regions(text).empty?
          return err("repeater #{id} contains §fuzz§ markers — remove them first, or use fuzz_start to sweep them",
            "INVALID_ARGUMENT", field: "repeater_id")
        end
        # The TUI refuses this too (repeater_view.cr#minimize_refusal). A saved request
        # holding a lone `%%%` line is SEVERAL requests: minimize reads it as one, strips
        # lines out of the operator's second request and reports them as removals from the
        # first — and apply:true then stores the remnant over the session. An agent calling
        # this would destroy the operator's group and be told it optimised it.
        if Repeater::Minimize.group_document?(text)
          return err("repeater #{id} holds a %%% separator — it is several requests, and minimize would read them as one (apply:true would store the remnant); split them into one session each",
            "INVALID_ARGUMENT", field: "repeater_id")
        end
        # Minimize dials `Fuzz::Sender` directly rather than through `Repeater::Plan`, by
        # design, so the builder's dial-tuple refusal never runs for it and this is the only
        # place that check can happen (#524). Checked BEFORE the target parse: an unresolved
        # `$HOST` survives `Env.expand` as the literal host, which would otherwise surface as
        # an unparseable-target error naming no variable at all.
        #
        # The REQUEST is no longer checked at all. A `$NAME` with no value is a literal string
        # on the wire everywhere now (see `Env::Escape`), so a captured OData `$filter`, a
        # Mongo `$where` or a GraphQL `$id` in a query string minimizes as authored. Only the
        # TARGET and SNI are refused — `$` is not a legal byte in a hostname, and a literal one
        # there comes back as an unparseable target or an out-of-scope block, naming the wrong
        # gate. The CLI and TUI minimize paths carry the same two checks.
        names = Env.unresolved(rec.target) |
                (rec.sni.try { |s| Env.unresolved(s) } || [] of String)
        unless names.empty?
          return err(env_unresolved_error(Env.token_list(names)), "INVALID_ARGUMENT", field: "repeater_id")
        end
        scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(rec.target))
        return err("could not determine a target host for repeater #{id}", "INVALID_ARGUMENT", field: "repeater_id") if host.empty?
        unless scheme.in?("http", "https")
          return err("unsupported target scheme '#{scheme}' (use http or https)", "INVALID_ARGUMENT", field: "repeater_id")
        end
        if gate = scope_refusal(ob, scheme, host, text)
          return gate
        end
        {scheme, host, port}
      end

      # The same two-layer gate the other active tools use, now expressed through the one
      # seam: Layer 2 (Sandbox) first — it is a hard containment gate allow_unscoped does
      # NOT lift — then Layer 1's allowlist, which allow_unscoped does. Layer 2 is applied
      # again per send inside Fuzz::Sender; this only lets minimize refuse with a precise
      # message before it starts.
      private def scope_refusal(ob : Outbound, scheme : String, host : String, text : String) : Result?
        target = Outbound.request_target(text)
        if reason = ob.send_block(scheme, host, target)
          return err("#{reason} — minimize refuses to send", "SCOPE_BLOCKED",
            field: "repeater_id", details: JSON.parse({"scope_decision" => "sandbox"}.to_json))
        end
        return nil unless ob.check_request(scheme, host, target).blocked?
        err("#{host} is outside — or without — a configured scope; pass allow_unscoped:true to minimize anyway",
          "SCOPE_BLOCKED", field: "repeater_id",
          details: JSON.parse({"scope_decision" => "unscoped", "host" => host}.to_json))
      end

      # The tools/list schemas for the request-minimizer tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_minimize_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "minimize_repeater",
          "Strip cosmetic headers, tracking-cookie crumbs, and unused query/body params " \
          "from a saved repeater request while keeping the response within tolerance of a " \
          "calibrated baseline (Caido-\"squash\"-style). ACTIVE: sends MANY real outbound " \
          "requests (capped at 250) and is scope-gated. Returns the trimmed request plus " \
          "what was removed; pass apply:true to also save it back to the session." do |s|
          s.field "repeater_id", intprop("repeater database id (`id` is accepted as an alias — the sibling repeater tools spell it that way)"), required: true
          s.field "id", intprop("alias for repeater_id")
          s.field "apply", boolprop("write the minimized request back into the session (default false)")
          s.field "verbatim", boolprop("search with the stored bytes EXACTLY, as send_request/--verbatim would send them: no $VAR expansion, no bare-LF→CRLF promotion, no Content-Length resync (so body params stop being removal candidates). Use it for a session seeded from a capture, where an unresolved $filter/$top/$where is stored evidence rather than a typo — without it such a session is either refused by name or minimized against substituted bytes. Default false")
          s.field "allow_unscoped", boolprop("minimize even when the target host is outside — or without — a configured scope (default false)")
        end
      end
    end
  end
end
