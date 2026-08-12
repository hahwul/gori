require "./active/types"
require "./active/reflected_param"
require "./active/cors_reflection"
require "./active/forbidden_bypass"
require "./active/nginx_alias_traversal"
require "./active/backslash_powered"
require "./active/graphql_introspection"
require "./active/lfi_param_traversal"
require "./active/open_redirect"
require "./active/host_header_injection"
require "./active/crlf_injection"
require "./active/path_normalization_bypass"
require "./active/url_rewrite_bypass"
require "./active/ssti"
require "./active/nextjs_action_no_auth"
require "./active/request_smuggling"
require "./active/ssrf_oast"
require "../outbound"
require "../scope"
require "../fuzz/engine"

module Gori
  module Probe
    # The lightweight active scanner. Each check is a self-contained `Active::Rule` in its own
    # file under `active/`; the analyzer iterates RULES, sending each rule's probe and folding
    # its detections. To add a check: drop a new `Rule` subclass in `active/` and append it here.
    module Active
      # The primary rule, reused for the registry AND the module-level facade.
      PRIMARY = ReflectedParam.new

      # The empty "nothing turned off" set — a shared constant so the `disabled` default in
      # .analyze does not allocate a Set per call. Mirrors Passive::NO_DISABLED (kept local so
      # active.cr need not require passive.cr).
      NO_DISABLED = Set(String).new

      RULES = [PRIMARY, CorsReflection.new, ForbiddenBypass.new,
               NginxAliasTraversal.new, BackslashPowered.new,
               GraphqlIntrospection.new, LfiParamTraversal.new,
               OpenRedirect.new, HostHeaderInjection.new,
               CrlfInjection.new, PathNormalizationBypass.new,
               UrlRewriteBypass.new, Ssti.new,
               NextjsActionNoAuth.new, RequestSmuggling.new,
               SsrfOast.new] of Rule

      # Convenience facade over the primary (reflected-param) rule. The analyzer drives the
      # whole RULES list; these keep a stable single-rule entry point for callers/tests.
      def self.dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
        PRIMARY.dedup_key(detail, opts)
      end

      def self.plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
        PRIMARY.plan(detail, opts)
      end

      def self.detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
        PRIMARY.detections(plan, result, detail)
      end

      # The WHOLE probe request, marked as bytes the session-binding pass must copy through
      # untouched (`Fuzz::Backend#send`'s `verbatim`). Not a convenience — the provenance of
      # every byte in `plan.request` is "something other than an operator writing a `$NAME`":
      #
      #   * Every rule in `active/` builds its request from the CAPTURED request
      #     (`detail.request_head` / `detail.request_body` / `detail.row`) and splices in its
      #     own gori-generated canary. Real captured traffic is full of `$NAME`-shaped bytes
      #     nobody typed — Mongo `$ne`/`$gt`/`$where`, JSON Schema `$ref`/`$schema`, and a
      #     GraphQL operation, which is MADE of `$variable` references (we ship a GraphQL rule
      #     precisely because we expect to see them). The `$`+`[A-Za-z_]`+`[A-Za-z0-9_]*`
      #     grammar has no delimiter requirement, so with an extract rule named `id` up, the
      #     captured `query GetUser($id: ID!)` went out as
      #     `query GetUser(<live session token>: ID!)` — a real credential in the target's
      #     access log, inside a request nobody authored (and no longer valid GraphQL, so the
      #     rule's differential measured a parse error), while the scan reported itself clean.
      #   * No rule authors a `$NAME` of its own: `grep '\$[A-Za-z_]' active/*.cr` is empty
      #     outside comments. And no operator STRING reaches a rule at all — `Options` is two
      #     Bools (allow_unsafe, aggressive). This is an automated sweep over stored evidence,
      #     not an operator draft: there is no editor, no `--payloads`, no template here.
      #
      # So there is nothing in this buffer that is eligible to expand, and one span covering
      # it is the honest description — not a blunt instrument standing in for per-rule spans.
      # (The miner's `Inject.apply_with_spans` marks the INJECTED material verbatim and lets
      # the captured seed resolve; here the polarity is inverted, because here the captured
      # request IS the test case rather than the template around it.)
      #
      # The one caller carrying operator-authored bytes is `Scan.scan_repeaters`, whose
      # `detail_from_repeater` blob is a MIX of editor text and a captured seed with no
      # provenance marks anywhere in the store — there is no span to track, so the choice is
      # expand-everything or expand-nothing. Nothing is load-bearing on that path today
      # anyway: it bypasses `Repeater::Plan`, so an env var `$KEY` already goes out literal
      # and only a session binding ever resolved. Erring to "nothing expands" costs a visible
      # 401 on a probe; erring the other way costs a live credential on the wire, silently.
      # Widening this back is a provenance signal on FlowDetail, never a re-widening here.
      #
      # Spelled as `Fuzz::Backend.all_verbatim` at every call site — including the SECOND send
      # loop in `Probe::Analyzer#execute_active` (the live TUI path, which never enters
      # `.analyze`). The reason this defect survived is that the two loops look
      # interchangeable, so they share one spelling and cannot drift again.
      #
      # Probe marks whole-buffer AT THE CALL SITE rather than taking `Fuzz::Sender`'s
      # `evidence:` flag, because of the inverted polarity argued above: the flag says "this
      # engine's buffer is a capture", which is true here, but probe reaches the sender through
      # `Scan.scan_repeaters` too, whose blob is mixed. Marking at the call site keeps the
      # decision next to the reasoning for it.
      #
      # (This block documents the four `Fuzz::Backend.all_verbatim` call sites below and in
      # `Probe::Analyzer#execute_active`. It used to document a `Probe::Active.all_verbatim`
      # twin of the same one-liner; the two were collapsed onto `Fuzz::Backend`'s, which is the
      # type every call site already holds.)

      # Compact per-flow request-count label for the Rules sub-tab + manual-run estimate:
      # "1 req/flow" for the fixed-cost rules, "4–8 req/flow" for the differential BackslashPowered.
      def self.estimate_label(rng : Range(Int32, Int32)) : String
        rng.begin == rng.end ? "#{rng.begin} req/flow" : "#{rng.begin}–#{rng.end} req/flow"
      end

      # Synchronously execute enabled Active rules against a flow (for headless / CLI scans).
      # `outbound` is the REQUIRED scope decision (Gori::Outbound): a Sandbox block or an
      # explicit exclude rule HARD-blocks the probe at the socket seam even when the caller
      # bypassed its own include gate (--allow-unscoped). Required rather than optional
      # precisely so a new caller cannot forget it.
      # `backend` overrides the default Fuzz::Sender so specs can drive the rules without a
      # socket; it is wrapped in Fuzz::GatedBackend so an injected backend is gated too.
      # `opts` widens the method gate / raises caps (manual unsafe opt-in, AGGRESSIVE mode).
      # `disabled` holds the RuleInfo#ids the operator turned off in the Rules sub-tab — the same
      # set the TUI analyzer filters on before enqueueing (analyzer.cr's maybe_enqueue_active), so
      # a headless scan honours that config too instead of silently running every built-in.
      # `on_error` (optional) is called with the failing rule's id when a rule raises; see the
      # per-rule rescue below for why that isolation exists at all.
      # `on_oob` (optional) receives each OUT-OF-BAND candidate a plan planted, once its probe
      # actually went out. It is a callback rather than a Store write because this module is
      # deliberately Store-free (rules depend only on the codec, the body decoder and the
      # sender); the caller that owns a Store — `Probe::Scan`, the TUI analyzer — persists it.
      # A caller that passes nothing simply does not participate in out-of-band checks.
      def self.analyze(detail : Store::FlowDetail, verify_upstream : Bool = true,
                       timeout : Time::Span = 10.seconds, *, outbound : Outbound,
                       backend : Fuzz::Backend? = nil, opts : Options = Options::DEFAULT,
                       disabled : Set(String) = NO_DISABLED,
                       on_error : Proc(String, Exception, Nil)? = nil,
                       on_oob : Proc(String, OutOfBand::Candidate, Nil)? = nil) : Array(Detection)
        # A short-circuited flow is refused before a single probe is sent (#511). Its baseline
        # response came from a Match&Replace stub, not from the origin, so every differential
        # this builds would be measuring the rule — and the probes themselves WOULD reach the
        # origin (Active dials directly, not through the proxy), so the comparison is between
        # two different responders. Same refusal, same reason, as `Passive.analyze`.
        return [] of Detection if detail.row.short_circuited?
        out = [] of Detection
        row = detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = detail.http_version.starts_with?("HTTP/2")
        # Fuzz::Sender gates itself, so it is never double-wrapped; only an injected
        # backend needs GatedBackend to reach the same decision.
        #
        # Keep-alive, because this ONE sender then serves the whole RULES loop below — every
        # rule's primary probe, its followups and its pipeline, all to the same origin. The
        # comment on `Fuzz::Sender#initialize` used to file Probe Active under "nothing to
        # amortise"; that was written for a one-shot sender and is the opposite of what this
        # loop does. `idle_conns: 1` because the loop is sequential: one socket is the most
        # that can ever be checked out. Closed in the ensure below.
        sender = if base = backend
                   Fuzz::GatedBackend.new(base, outbound).as(Fuzz::Backend)
                 else
                   Fuzz::Sender.new(origin, outbound, http2, verify_upstream, timeout: timeout,
                     keep_alive: true, idle_conns: 1)
                 end

        # Send-refusal reasons already reported for THIS flow (see the `result.ok?` branch).
        refusals = Set(String).new
        RULES.each do |rule|
          # `rule_disabled?` (not a bare `disabled.includes?`) so a DEFAULT-OFF rule is skipped
          # on a fresh project even though its id is absent from the set — see DEFAULT_DISABLED_RULES.
          next if Probe.rule_disabled?(rule.info.id, disabled)
          # ISOLATE each rule. Without this, one rule raising in plan/detections_all took down
          # the whole scan — every rule after it AND (via Scan.scan_flows) every remaining flow,
          # discarding findings already collected. The TUI path has always had this: the analyzer
          # wraps each rule in its own rescue (analyzer.cr's execute_active), so the same rule
          # that merely gets skipped in the TUI used to kill a `gori run probe` / MCP probe_scan
          # batch outright. Send FAILURES are not exceptions (Fuzz returns an errored Result and
          # `result.ok?` skips), so what this catches is a rule bug on hostile input.
          begin
            plan = rule.plan(detail, opts)
            next unless plan
            result = sender.send(plan.request, Fuzz::Backend.all_verbatim(plan.request))
            unless result.ok?
              # A refused or failed send is NOT an exception — `Fuzz::Sender` returns an
              # errored Result for a sandbox block, an unbound binding, a connect failure —
              # so the rescue below cannot see it and `next` alone made it invisible. With
              # Sandbox on and nothing in scope, EVERY probe was refused and the operator
              # read `0 issues` / MCP emitted no `scan_errors` key at all: indistinguishable
              # from a clean target. `Miner::Engine#first_error` and the TUI analyzer's
              # `emit_active_error` both name this; probe active is the one automated sweep
              # that never got the #491 treatment.
              #
              # Deduped per flow per reason: 14 rules refused for the same cause would
              # otherwise push 14 identical rows at the caller for one flow.
              err = result.error
              if err && refusals.add?(err)
                on_error.try &.call("flow #{row.id}", Gori::Error.new(err))
              end
              next
            end
            # The primary carried whatever payloads this plan planted, and it went out — so the
            # probes are now OUTSTANDING and must be recorded before anything else can fail.
            # Recorded here rather than at plan time because a payload that never reached the
            # target is not outstanding, and a row for it would sit unmatched forever, reading
            # as "we asked and nothing answered" when in fact nobody was ever asked.
            plan.oob.each { |c| on_oob.try &.call(rule.info.id, c) }
            results = [result]
            # Same verbatim marking as the primary above — a followup is built by the same
            # rule from the same captured request, so a differential whose baseline resolved
            # `$id` and whose followup did not would be measuring the substitution.
            plan.followups.each { |req| results << sender.send(req, Fuzz::Backend.all_verbatim(req)) }
            # THEN the pipeline group (if any): a same-connection sequence sent on ONE dedicated
            # socket via `send_pipeline`, results appended in order so `detections_all` sees
            # `[primary, followups…, pipeline…]`. Only the request-smuggling / desync rule ships
            # one; empty for every other rule = a strict no-op. Kept BYTE-IDENTICAL to the
            # analyzer's twin loop (`execute_active`) — `active_binding_provenance_spec` exists so
            # the two cannot drift, the reason the followup marking sits on both.
            results.concat(sender.send_pipeline(plan.pipeline, plan.probe_timeout)) unless plan.pipeline.empty?
            dets = rule.detections_all(plan, results, detail)
            out.concat(dets)
          rescue ex
            on_error.try &.call(rule.info.id, ex)
          end
        end
        out
      ensure
        # Release the keep-alive pool's parked socket. In the ensure so a rule that escapes
        # the per-rule rescue above still cannot leak an fd. A no-op on the injected-backend
        # path, whose `close` is empty.
        sender.try(&.close)
      end
    end
  end
end
