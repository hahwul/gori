require "json"
require "../../cache_deception"
require "../../authorize/engine"
require "../../host_overrides"

module Gori
  module MCP
    class Tools
      # --- cache_deception_check (web cache deception, synchronous) ------------
      #
      # The MCP adapter for `Gori::CacheDeception` (#1247). Synchronous, unlike `authorize_*`:
      # a check uses up to THREE sends for one flow (authenticated, anonymous, then a
      # cache-busted anonymous control), so
      # the job registry the longer authorize/fuzz runs need would be overhead here.
      #
      # It BORROWS the Authorize engine — `Engine.live`, the same scope-gated sender authorize
      # uses — with the identities fixed to as-captured and anonymous. What is MCP's own here is argument shapes, the strict Layer-1 gate
      # (`Outbound.agent`, because no human eyeballed this target), and the JSON a model reads.
      # No `env_refresh`: unlike authorize_start, this replays the request AS CAPTURED (verbatim
      # wire bytes) under built-in identities that carry no `$NAME`/session-slot value to
      # resolve, so there is no project env to re-read before the send.
      @[Tool("cache_deception_check", gated: true, agent_action: true, requires: ["get_flow"], permission: "send")]
      private def cache_deception_check(h) : Result
        flow_id = int(h, "flow_id")
        return err(id_error(h, "flow_id"), "INVALID_ARGUMENT", field: "flow_id") unless flow_id
        detail = store.get_flow(flow_id)
        return not_found("no flow with id #{flow_id}") unless detail

        unsafe = bool_arg(h, "unsafe_methods", false)
        if reason = CacheDeception.skip_reason(detail, unsafe)
          # A refusal the caller can act on, named the same way authorize names its skips.
          return err("flow #{flow_id} cannot be checked: #{CacheDeception.reason_label(reason)}" \
                     "#{reason == :unsafe_method ? " (pass unsafe_methods:true to replay it anyway — its side effect can run up to three times)" : ""}",
            "INVALID_ARGUMENT", field: "flow_id")
        end

        allow_unscoped = bool_arg(h, "allow_unscoped", false)
        ob = outbound(allow_unscoped)
        row = detail.row
        # LAYER 1 on the DIAL target, exactly as `Authorize::Plan.partition` does it — an
        # out-of-scope (or scope-less) project refuses the send here rather than at the socket.
        sc = ob.check_request(row.scheme, row.host, row.target, row.port)
        if sc.blocked?
          ob.close
          return scope_blocked(sc)
        end

        timeout = optional_int_arg(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds) ||
                  Authorize::ACTIVE_TIMEOUT
        verify = bool_arg(h, "verify", true)
        engine = Authorize::Engine.live(ob, verify, timeout, overrides: HostOverrides.load(store))
        report =
          begin
            CacheDeception.check(engine, detail, -> { cancelled? })
          rescue ex
            ob.close
            return err("cache-deception check failed: #{ex.message}", "INTERNAL_ERROR")
          end
        ob.close
        # `check` returns nil when cancellation stops the run before its trials complete.
        return err("cache-deception check produced no result", "INTERNAL_ERROR") unless report

        Log.info { "cache_deception_check flow=#{flow_id} verdict=#{report.verdict.label} cache=#{report.cache.token}" }
        Result.new(cache_deception_json(report))
      end

      private def cache_deception_json(report : CacheDeception::Report) : String
        JSON.build do |j|
          j.object do
            j.field "flow_id", report.flow_id
            j.field "method", Serialize.text(report.method)
            j.field "url", Serialize.text(report.url)
            j.field "verdict", report.verdict.label
            # The one an agent acts on: a confirmed cache of a (possibly private) response.
            j.field "deception", report.verdict.deception?
            # The anonymous response's cache status — the fact that turns "same body" into
            # "cached". `hit` here with verdict `cached` is the deception.
            j.field "cache", report.cache.token
            emit_cache_trial(j, "authenticated", report.authenticated)
            emit_cache_trial(j, "anonymous", report.anonymous)
            emit_cache_trial(j, "cache_busted", report.control)
            report.blocked_reason.try { |r| j.field "blocked_reason", Serialize.text(r) }
            j.field "note", cache_deception_note(report.verdict)
          end
        end
      end

      private def emit_cache_trial(j : JSON::Builder, name : String, trial : Authorize::Trial?) : Nil
        return unless trial
        j.field name do
          j.object do
            j.field "status", trial.summary.status
            j.field "size", trial.summary.size # decoded body size
            j.field "verdict", trial.verdict.label
            j.field "cache", CacheStatus.classify(trial.response_head).token
            trial.summary.error.try { |e| j.field "error", Serialize.text(e) }
          end
        end
      end

      # One sentence a model reads before deciding what to do next — the same "state the
      # finding, name the next action" shape the other tools' notes have.
      private def cache_deception_note(verdict : CacheDeception::Verdict) : String
        case verdict
        in .cached?
          "the anonymous re-request was served the authenticated response FROM a cache, while the " \
          "cache-busted anonymous control got different content — a web " \
          "cache deception. Confirm the body carried private data before reporting it; the Fuzzer's " \
          "`cache-delimiters` payload set finds the crafted paths that trigger it."
        in .served?
          "the anonymous re-request got matching content, but either it had no cache-hit evidence " \
          "or the cache-busted control matched without a cache-hit signal. A private cached response " \
          "was not confirmed; inspect the trials before ruling out hidden cache behavior."
        in .review?
          "the anonymous response was similar but not identical, or the matching cache-busted control " \
          "was itself a cache hit and may not have bypassed the cache — judge it."
        in .protected?
          "the anonymous re-request did NOT get the authenticated response, so no private content " \
          "was served without a session."
        in .blocked?
          "gori refused the send (Sandbox / an exclude rule) — nothing was measured."
        in .errored?
          "a send failed or the authenticated baseline could not anchor — the check proved nothing."
        end
      end

      private def list_cache_deception_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "cache_deception_check",
          "Test one captured flow for WEB CACHE DECEPTION (PortSwigger \"Gotta cache 'em all\"): " \
          "replay it as its captured (AUTHENTICATED) identity to prime any cache, then re-request " \
          "the SAME url with NO session, and compare. If the anonymous re-request is served the " \
          "authenticated response FROM a cache (`verdict:cached`, `deception:true`), that private " \
          "response was cached under a key an anonymous client hits; an anonymous cache-busted " \
          "query request checks whether matching content is public. If that control is itself a cache " \
          "hit, matching content is inconclusive (`verdict:review`), because the query may be ignored. " \
          "Each trial includes its `cache` signal; the top-level `cache` is the anonymous response. Reads " \
          "the same cache classifier as get_flow's `cache` / QL `cache:`. To find the CRAFTED paths that trigger " \
          "it (`;`, `.css`, `%00`, dot-segments), fuzz the path with the `cache-delimiters` payload " \
          "set, then check the promising hits here. ACTIVE: sends up to 3 real requests (safe methods only " \
          "unless unsafe_methods:true). Only GET/HEAD/OPTIONS are checked by default." do |s|
          s.field "flow_id", intprop("captured flow id to check (from list_history)"), required: true
          s.field "unsafe_methods", boolprop("also check a flow whose method is not GET/HEAD/OPTIONS " \
                                             "(default false) — its side effect can run up to three times")
          s.field "verify", boolprop("verify upstream TLS certificates (default true)")
          s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds (default 15000)")
          s.field "allow_unscoped", boolprop("check even when the flow's host is outside the project's " \
                                             "configured scope — REQUIRED for an out-of-scope target, or when " \
                                             "no scope is configured (active requests are refused by default)")
        end
      end
    end
  end
end
