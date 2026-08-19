require "uri"
require "./scope"
require "./store"
require "./proxy/codec/http1"

module Gori
  # THE outbound chokepoint for gori-originated ("active") traffic.
  #
  # Everything gori sends that did NOT come from a proxied client — Repeater sends,
  # Fuzzer/Miner/Sequencer sweeps, Repeater minimize, Probe's active checks — bypasses
  # the proxy's own per-request gate (Interceptor/ClientConn) by dialing an upstream
  # directly. The invariant "no active request leaves gori without a scope decision" was
  # therefore enforced by CONVENTION at ~20 call sites across three surfaces (TUI,
  # `gori run`, MCP), and had been silently broken more than once — a new tool, or a new
  # send path inside an old tool, simply forgot to gate.
  #
  # `Outbound` makes the decision a VALUE that an active sender cannot be constructed
  # without (`Fuzz::Sender`, `Repeater::Sender`), so forgetting it is a compile error
  # rather than a security hole. It carries both layers of the gate:
  #
  #   Layer 1 (`check`)        — the up-front include/allowlist decision, made ONCE before
  #                              the first byte. Its strictness is the ONE thing that
  #                              legitimately differs per surface (see `Gate`).
  #   Layer 2 (`sweep_block` / — the per-send HARD gate: Sandbox mode (and, for automated
  #            `send_block`)     sweeps, explicit EXCLUDE rules). Identical on every
  #                              surface, and applied even when Layer 1 was waived.
  #
  # Reload semantics are uniform (DESIGN.md P5, pending #353): the scope is re-read from
  # its store at most once per `RELOAD_INTERVAL` before a Layer-2 check, so a mid-run
  # EXCLUDE or Sandbox toggle stops an in-flight sweep on every surface. Previously only
  # MCP did this; `gori run` snapshotted the rules at start-up and the TUI honoured a
  # change only as a side effect of its own data_version poll.
  class Outbound
    # The per-send error strings an automated sweep's blocked Result carries. Stable —
    # `Fuzz::Engine` surfaces them as a row error and specs assert on them.
    #
    # Layer 2 has TWO independent reasons with different remedies, so they get different
    # sentences. They used to collapse into one bare "blocked by scope", which is also the
    # wording of the Layer-1 abort — so an operator who had just passed `--allow-unscoped`
    # read the same three words back and reasonably concluded the flag had done nothing.
    # `Discover::Engine::SCOPE_REFUSED` already names both possibilities for the same
    # gate; this splits them so the message names the ONE that fired, and its exit.
    SANDBOX_SWEEP_ERROR = "blocked by sandbox (out of scope) — add a scope include rule, or turn Sandbox off"
    EXCLUDE_SWEEP_ERROR = "blocked by a scope exclude rule — excludes hold even under --allow-unscoped"
    # The refusal for ONE hand-authored Repeater send. Distinct wording because Sandbox
    # is the only rule that stops these (see `send_block`), and the TUI/CLI show it verbatim.
    SANDBOX_ERROR = "blocked by sandbox (out of scope)"

    # True for a Layer-2 refusal — the two strings `sweep_block` returns above and nothing
    # else does. Such a refusal is PERMANENT for a retrying caller: the scope does not move
    # between two attempts a `retry_pause` apart (a reload is throttled to `RELOAD_INTERVAL`),
    # and `CappedBackend#send` charges the request cap BEFORE the gate refuses — so re-asking
    # spends a second request for an answer that is already fixed.
    #
    # ONE HOME, the same rule AGENTS.md states for `Codec::Http1.request_token_safe?`: this
    # predicate had three private copies (`Sequencer::Engine`/`Miner::Engine`'s
    # `permanent_refusal?`, `Fuzz::Engine#gate_refused?`), which is exactly how the Sequencer
    # came to be missing two of the constants while its siblings had all of them. A new
    # Layer-2 refusal is now added here once.
    #
    # `Fuzz::CappedBackend::CAP_ERROR` is deliberately NOT folded in, even though two of the
    # three callers also treat it as permanent: it is a tool's constant, and `outbound.cr`
    # requires only `scope`/`store`/the codec — a core chokepoint reaching into `fuzz/` would
    # invert the layering (DESIGN.md §2.1). It is also counted differently on the Fuzzer path
    # (a cap stop is not a `@blocked` payload unit — see `Fuzz::Engine#run_one`), so the cap
    # question stays with the callers that ask it.
    def self.permanent_refusal?(err : String?) : Bool
      err == SANDBOX_SWEEP_ERROR || err == EXCLUDE_SWEEP_ERROR
    end

    # A running job's rules would otherwise be a start-time snapshot. A per-send DB read is
    # too heavy at high concurrency, so the in-place reload is time-throttled to this.
    RELOAD_INTERVAL = 1.second

    # The Layer-1 policy: what the surface does BEFORE the first byte goes out. This is the
    # only axis on which the three surfaces legitimately disagree, so it is named here
    # instead of being re-derived (differently) at each call site.
    enum Gate
      # Refuse anything the scope does not explicitly INCLUDE — including a project with
      # no scope rules at all. The strict default for agent-driven sends (MCP) and for
      # Probe's automatic active scanner, where nobody eyeballed the target.
      Allowlist
      # Refuse only when a scope IS configured and the target falls outside it; an
      # unconfigured project stays permissive. The operator-driven `gori run` default.
      Configured
      # No up-front gate at all: the operator named this target themselves (the TUI's
      # Fuzzer/Miner/Sequencer/Repeater), or explicitly waived the allowlist with
      # --allow-unscoped / allow_unscoped:true. Layer 2 still applies.
      Waived
    end

    # Why Layer 1 was waived. Recorded so an unscoped send is a DELIBERATE, nameable state
    # in the logs and in MCP's result JSON — never a nil `Scope?` that silently skipped the
    # gate (the `scope ? ScopedBackend.new(sender, scope) : sender` fail-open this replaces).
    enum Reason
      # An explicit --allow-unscoped / allow_unscoped:true from the operator or agent.
      Operator
      # No project is in play (`gori run fuzz --request req.txt`), so there is no Scope to
      # gate against. Permissive exactly as before, but now a named state rather than a nil.
      NoProject
      # The human typed this target into the TUI. Layer 1 would only re-ask a question the
      # operator just answered by hand; Layer 2 (Sandbox) still hard-stops the send.
      Interactive

      # snake_case token for the audit line / log ("no_project", not "NoProject").
      def label : String
        to_s.underscore
      end
    end

    # The Layer-1 outcome. `decision` is the WIRE string MCP already emits
    # ("in_scope" | "out_of_scope" | "unscoped") — kept a String so the JSON contract is
    # unchanged. `blocked` is authoritative: no caller re-derives it from `decision`.
    #
    # `excluded` is carried ALONGSIDE `decision` rather than as a fourth decision string:
    # `blocked` is derived from `decision` above, so a new value would have had to be added
    # to two gate branches to avoid letting an excluded target through the Configured gate.
    # It exists because every surface phrased an out-of-scope refusal as "add a scope include
    # rule", and for a target an EXCLUDE rule matched that advice cannot work — an include
    # never overrides an exclude. The rule to delete is the one to name. Layer 2 already got
    # this right (see `EXCLUDE_SWEEP_ERROR`); this is Layer 1 catching up.
    record Verdict, decision : String, host : String, rule_id : Int64?, blocked : Bool,
      excluded : Bool = false do
      def blocked? : Bool
        blocked
      end

      def excluded? : Bool
        excluded
      end

      def in_scope? : Bool
        decision == "in_scope"
      end

      # True when the target had no configured scope to be judged against.
      def unscoped? : Bool
        decision == "unscoped"
      end
    end

    IN_SCOPE     = "in_scope"
    OUT_OF_SCOPE = "out_of_scope"
    UNSCOPED     = "unscoped"

    # The remedy sentence for a Layer-1 refusal, in ONE place so the six surfaces that abort
    # on `blocked?` cannot each invent their own — and, more to the point, cannot each repeat
    # the "add a scope include rule" advice for a target an EXCLUDE rule matched, where no
    # include will ever help. `waiver` is the surface's own spelling of the override flag
    # (`--allow-unscoped`, `allow_unscoped:true`); nil when the surface has none.
    def self.remedy(verdict : Verdict, waiver : String?) : String
      return "delete or narrow the scope EXCLUDE rule that matches it (an include rule cannot override an exclude)" if verdict.excluded?
      base = "add a scope include rule"
      waiver ? "#{base} or pass #{waiver}" : base
    end

    getter scope : Scope?
    getter gate : Gate
    # nil for a gated Outbound; set (and only set) when `gate` is Waived.
    getter reason : Reason?

    @last_reload : Time::Instant
    # A Store this Outbound OWNS and must close (the CLI hands over the read connection so
    # the scope can keep reloading for the length of the run). nil when the store belongs to
    # someone longer-lived — the MCP server, the TUI session — which must NOT be closed here.
    @owned_store : Store?

    private def initialize(@scope : Scope?, @gate : Gate, @reason : Reason?, @owned_store : Store? = nil)
      # Seed the throttle clock now: the scope was just loaded, so the first reload is due
      # one interval into the run, not on the first send.
      @last_reload = Time.instant
    end

    # ── construction ─────────────────────────────────────────────────────────────
    # Three surface-shaped entry points. Everything else is a compile error, which is the
    # point: a new tool cannot invent a fourth policy by accident.

    # Agent-driven (MCP): refuse anything not explicitly included, including an
    # unconfigured project, unless the caller passed allow_unscoped:true.
    def self.agent(scope : Scope, allow_unscoped : Bool) : Outbound
      allow_unscoped ? waived(scope, Reason::Operator) : new(scope, Gate::Allowlist, nil)
    end

    # Operator-driven (`gori run`): an unconfigured project stays permissive, a configured
    # one refuses an out-of-scope target unless --allow-unscoped. A nil scope means no
    # project is in play at all, which becomes an explicit Unscoped(NoProject).
    # `owns_store` hands the still-open read connection over so the rules can keep
    # reloading mid-run; the caller must call `#close` when the command finishes.
    def self.cli(scope : Scope?, allow_unscoped : Bool, owns_store : Store? = nil) : Outbound
      return new(nil, Gate::Waived, Reason::NoProject) unless scope
      return new(scope, Gate::Waived, Reason::Operator, owns_store) if allow_unscoped
      new(scope, Gate::Configured, nil, owns_store)
    end

    # Interactive (TUI): the operator typed the target, so there is no up-front gate — but
    # Sandbox still hard-stops every send.
    def self.interactive(scope : Scope) : Outbound
      waived(scope, Reason::Interactive)
    end

    # Layer 1 waived, for a named reason. The ONLY way to reach an ungated decision, and it
    # still carries the Scope so Layer 2 keeps applying.
    def self.waived(scope : Scope?, reason : Reason) : Outbound
      new(scope, Gate::Waived, reason)
    end

    # Layer 1 at its strictest, for a caller that has already resolved allow_unscoped
    # itself (Probe's scanner / automatic analyzer). A nil scope has nothing to allowlist
    # against, so it blocks everything — the fail-CLOSED direction, matching the old
    # `!!scope.try(&.matches_url?(...))` per-flow gate this replaces.
    def self.allowlist(scope : Scope?) : Outbound
      new(scope, Gate::Allowlist, nil)
    end

    # ── layer 1: the up-front decision ───────────────────────────────────────────

    # The scope verdict for one target URL. Made ONCE, before anything is sent.
    def check(url : String, host : String) : Verdict
      decision, rule_id, excluded = evaluate(url, host)
      blocked = case @gate
                in Gate::Waived     then false
                in Gate::Allowlist  then decision != IN_SCOPE
                in Gate::Configured then decision == OUT_OF_SCOPE
                end
      Verdict.new(decision, host, rule_id, blocked, excluded)
    end

    # `check` for callers that only need the yes/no (Probe's per-flow active filter).
    def allows?(url : String, host : String) : Bool
      !check(url, host).blocked?
    end

    # `check` against a request's scheme/host/target parts.
    def check_request(scheme : String, host : String, target : String) : Verdict
      check(Outbound.scope_url(scheme, host, target), host)
    end

    # Whether Layer 1 is enforced at all — for the log/audit line that records how a send
    # was authorised.
    def gated? : Bool
      !@gate.waived?
    end

    # A short audit token for logs: "gated" or "unscoped:operator".
    def label : String
      (r = @reason) ? "unscoped:#{r.label}" : "gated"
    end

    # ── layer 2: the per-send hard gate ──────────────────────────────────────────

    # The refusal reason for one send from an AUTOMATED sweep (Fuzzer, Miner, Sequencer,
    # minimize, Probe active), or nil to proceed. Sandbox mode AND explicit EXCLUDE rules
    # both stop it: a sweep's blast radius is wide enough that an operator's carve-out has
    # to hold, even under --allow-unscoped.
    def sweep_block(scheme : String, host : String, target : String) : String?
      refresh
      s = @scope
      return nil unless s
      url = Outbound.scope_url(scheme, host, target)
      # EXCLUDE is tested FIRST because it is the more specific answer. `sandbox_blocks?` is
      # `sandbox && !allowlisted?`, and an excluded URL is never allowlisted — so with the
      # sandbox on, an exclude match trips BOTH. Reporting sandbox there would tell an
      # operator who already has a matching include rule to "add a scope include rule",
      # which is advice that cannot work. Naming the exclude names the rule they can delete.
      return EXCLUDE_SWEEP_ERROR if s.excluded?(url, host)
      s.sandbox_blocks?(url, host) ? SANDBOX_SWEEP_ERROR : nil
    end

    # The refusal reason for ONE hand-authored Repeater send, or nil to proceed. Sandbox
    # ALONE stops it — an EXCLUDE rule deliberately does not, mirroring the proxy path
    # (`Interceptor#sandbox_blocks?`): excludes are a lens/automation carve-out, not a
    # "never touch this again" order, and a human replaying one request has already decided.
    def send_block(scheme : String, host : String, target : String) : String?
      refresh
      s = @scope
      return nil unless s
      s.sandbox_blocks?(Outbound.scope_url(scheme, host, target), host) ? SANDBOX_ERROR : nil
    end

    # ── lifetime ─────────────────────────────────────────────────────────────────

    # Release the store this Outbound owns (CLI only — see `.cli`). Idempotent, and a no-op
    # for a scope whose store belongs to the MCP server or the TUI session.
    def close : Nil
      store = @owned_store
      @owned_store = nil
      store.try(&.close)
    rescue
      # a close failure must never take down a run that already finished its work
    end

    # ── shared helpers ───────────────────────────────────────────────────────────

    # The request-target (path) from a raw request's first line — the value every caller
    # splices into `scheme://host<target>` to match string/regex scope rules. Was copied
    # verbatim into four files before this.
    #
    # Split on RUNS of ASCII whitespace, not a single ' ': `"GET  /admin HTTP/1.1"` (two
    # spaces, or a tab) otherwise splits to `["GET", "", "/admin", ...]`, so `[1]?` is the
    # empty string — non-nil, so `|| "/"` never fires — and the scope gate then evaluates an
    # EMPTY path, silently satisfying any string/regex include/exclude rule. That let a
    # doubled space in the request line bypass the scope layers on this path. `split`
    # with no argument collapses whitespace runs and drops the empty parts, so the real
    # request-target is recovered from a malformed request line. (The bytes themselves still
    # go on the wire byte-exact — P7 — this only feeds the scope decision.)
    #
    # It ALSO reads from the first NON-BLANK line rather than blindly the first: a raw request
    # may arrive with leading blank line(s) — an operator's authored bytes, or a peer that emits
    # an empty line before the request-line — and reading the first line blindly gates the
    # innocuous "/" while the REAL target sits on a later line and goes on the wire.
    #
    # ONE HOME: the recovery itself now lives on `Codec::Http1.request_target_line`, because the
    # PROXY gate needs the identical predicate (`Codec::Http1.gate_target` — read its comment
    # for the bypass it closes) and re-deriving a request-line rule next to a new caller is the
    # shape AGENTS.md flags as thrice-recurring (#390/#394/#397). `Outbound` keeps these two
    # names because ~20 active-send call sites and `spec/outbound_spec.cr` speak them.
    def self.request_target(bytes : Bytes) : String
      Proxy::Codec::Http1.request_target_line(bytes)
    end

    def self.request_target(text : String) : String
      Proxy::Codec::Http1.request_target_line(text)
    end

    # The URL the gate evaluates, ALWAYS anchored on the DIAL target (the scheme/host the
    # engine actually connects to), never the request LINE's host.
    #
    # A raw request may carry an ABSOLUTE-FORM request line (`GET http://other/p HTTP/1.1`)
    # whose host is deliberately different from the origin being dialled: a Host-header /
    # cache-poisoning / SSRF test, which gori must still send verbatim (P7). But
    # `Scope.request_url` returns an absolute-form target UNCHANGED, so gating on it would
    # match the spoofed host's rules while the bytes go somewhere else — an anchored include
    # like `^https?://acme\.test/` would authorise a send to `evil.test`. So reduce an
    # absolute-form target to its path+query and rebuild it against the dial host.
    #
    # This was previously only done on MCP's `send_request` (`request_scope_url`); the sweep
    # and Repeater paths passed the raw target through, so hoisting it here is what makes the
    # rule identical on all three surfaces. Port is omitted to match `Scope.request_url`'s
    # origin-form convention (the scope lens keys on host, not port).
    # Reduced with `Url.origin_path`, the LEXICAL split, rather than `URI.parse` — which
    # raises on exactly the targets a security tool is most likely to be handed. A
    # non-numeric or oversized port (`http://acme.test:abc/admin`, `:99999999999999999999`)
    # raises `URI::Error`/`OverflowError`, and rescuing that to nil read as "no path", so
    # the gate evaluated `scheme://host/`. An INCLUDE still matched on host, so this was
    # invisible for the common config — but a path EXCLUDE (`/admin`) no longer matched the
    # url it was tested against, and the operator's carve-out silently stopped holding.
    # `sweep_block` promises that carve-out holds even under `--allow-unscoped`.
    #
    # The proxy already refuses this input rather than degrading (`ClientConn#handle_one`
    # records it and writes a gateway error); there is no reason for the gate that guards
    # the ACTIVE tools to be the lenient one. `origin_path` cannot raise, so it does not
    # degrade at all: it keeps path+query verbatim, fragment included — one more thing for
    # an exclude to match, never one fewer.
    def self.scope_url(scheme : String, host : String, target : String) : String
      target = Url.origin_path(target) if Store::FlowRow.absolute_form?(target)
      Scope.request_url(scheme, host, target)
    end

    # ── internals ────────────────────────────────────────────────────────────────

    # The scope's own reading of a URL, independent of the Gate: the allowlist test Probe
    # Active and the Sandbox gate share (≥1 INCLUDE matches, no EXCLUDE), plus the matched
    # include's rule id for the audit trail.
    private def evaluate(url : String, host : String) : {String, Int64?, Bool}
      s = @scope
      return {UNSCOPED, nil, false} unless s && s.configured?
      # `matches_url?` folds "no include matched" and "an EXCLUDE matched" into one false.
      # They need opposite remedies, so ask the exclude question separately rather than
      # letting the caller guess from a single out_of_scope.
      return {OUT_OF_SCOPE, nil, s.excluded?(url, host)} unless s.matches_url?(url, host)
      {IN_SCOPE, s.rules.find { |r| r.include? && r.matches?(url, host) }.try(&.id), false}
    end

    # Throttled in-place reload of the scope from its store so a mid-run rule / Sandbox
    # change is honoured within ~RELOAD_INTERVAL on every surface. Advances the clock
    # BEFORE the (blocking) reload so a burst of concurrent worker fibers can't stampede
    # the store — exactly one reload fires per window (single-threaded fiber scheduler:
    # the check→set is a non-yielding critical section). A failed reload is swallowed: the
    # last-known scope stays in force rather than breaking the run (and a CLI command that
    # already closed its store degrades to the old snapshot behaviour instead of raising).
    private def refresh : Nil
      now = Time.instant
      return if now - @last_reload < RELOAD_INTERVAL
      @last_reload = now
      @scope.try(&.reload)
    rescue
      # keep the last-known scope on a reload failure
    end
  end
end
