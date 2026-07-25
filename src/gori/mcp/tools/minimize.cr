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
      private def minimize_repeater(h) : Result
        id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) unless id
        rec = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless rec

        text = String.new(rec.request)
        ob = outbound(bool(h, "allow_unscoped") || false)
        target = minimize_target(id, rec, text, ob)
        return target if target.is_a?(Result)
        scheme, host, port = target

        auto_cl = rec.auto_content_length?
        # Mirrors the TUI/CLI resolve: env-expand, then Content-Length resync only when the
        # session has Auto-CL on (the same gate that lets body params be removed at all).
        resolve = ->(t : String) do
          raw = Env.expand_wire(t)
          auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
        end
        # Minimize dials Fuzz::Sender directly (many capped probe sends) rather than through
        # Repeater::Plan, so it needs the project's host overrides threaded by hand — without
        # them this was the one repeater send path left resolving the target for real while
        # every other surface honoured the operator's pin (#367).
        backend = Fuzz::CappedBackend.new(
          Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), ob, rec.http2?,
            @verify_upstream, rec.sni.try { |v| Env.expand(v) }, timeout: 10.seconds,
            overrides: HostOverrides.load(store)),
          Repeater::Minimize::SEND_CAP)

        report = Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend) { }

        applied = false
        if (bool(h, "apply") || false) && !report.aborted && !report.removed.empty?
          applied = store.update_repeater(id: id, target: rec.target,
            request: report.minimized_text.to_slice, http2: rec.http2?,
            auto_cl: auto_cl, sni: rec.sni)
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
    end
  end
end
