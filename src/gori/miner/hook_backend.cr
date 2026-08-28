require "../env"
require "../process_hook"
require "../fuzz/engine"
require "./inject"

module Gori::Miner
  # The operator's per-request transform HOOK, wired as a `Fuzz::Backend` DECORATOR (#818/#846).
  #
  # WHY A DECORATOR, not a call at one inject site: a mine's requests do not all leave from one
  # place. Baseline calibration sends the raw request and per-location controls (`Baseline`),
  # each bucket sends one probe (`Engine#process_bucket`), and every finding's confirmation
  # sends `confirm_rounds` more (`Engine#confirm`). All of them go through `@backend.send`, so
  # wrapping the backend is the one seam that reaches every send — and it MUST reach the
  # baseline, because an app that requires a signed envelope answers a raw calibration probe the
  # same way it answers a raw candidate, and an unsigned baseline is "unreachable" (the run is
  # refused before it starts). The hook lets that same app be mined.
  #
  # ORDER — bindings, then the session-slot overlay, then the hook, then byte-exact. Everything
  # the sender would otherwise do to a request AFTER the hook is pulled IN FRONT of it here, so
  # the hook genuinely signs the bytes that ship:
  #   * Session bindings resolve first (injected-candidate spans keep candidates literal; an
  #     evidence run widens to the whole captured request, as `Sender#send` does), so a live
  #     `$TOKEN` is inside what the hook signs.
  #   * The active session slot's header overlay is applied next — by THIS wrapper, because the
  #     sender applies it one transform too late (after `$NAME` expansion, over bytes a hook has
  #     already signed). `Plan.build` builds the inner sender with `slot_overlay: false` when a
  #     hook is present precisely so the two do not both apply it; without a hook the sender
  #     keeps doing it. So `--slot analyst --hook ./sign.sh` against a signed API signs the
  #     slot's identity headers too, instead of shipping an overlay the signature cannot cover.
  # The hook is then the FINAL transform, and its stdout is handed to the inner backend as
  # `all_verbatim` so the sender's own binding pass is a no-op over signed bytes it must not
  # touch (the sender's overlay is off, per above).
  #
  # ONE thing still runs after the hook, and it is a REFUSAL, not a transform: the sender's
  # Sandbox / scope-exclude gate (`Outbound#sweep_block`), which lives with the blocked-count
  # accounting it owns. So a send the gate refuses has already forked the hook — but a mine
  # against a wholly out-of-scope origin fails that gate on its very first baseline probe and is
  # refused before a single candidate is tested (`Engine#orchestrate`'s unreachable-baseline
  # path), so the forks are bounded to calibration, not one per candidate. The cap, which CAN
  # multiply per candidate, is outside this wrapper and refuses before the hook forks.
  #
  # P6 — THE TIMEOUT UNIT IS PER OUTBOUND REQUEST, and it is bounded, not multiplied. Each send
  # forks the command once and gives it `Settings.hook_timeout_secs` (clamped 1..60 by
  # `ProcessHook`), the same budget every other seam shares. A mine over N candidates does NOT
  # get to multiply one timeout by N unseen: the number of hook runs is exactly the number of
  # outbound requests, which the miner already counts (`Progress#sent`) and bounds
  # (`--max-requests`, and the finite bucket+bisection+confirm tree). This wrapper sits INSIDE
  # `CappedBackend`, so once the request budget is spent the cap refuses before the hook forks —
  # no command runs past the ceiling the operator set.
  #
  # WHERE THE COST LANDS — the miner is LATENCY-bound: its request count is small and almost all
  # of its wall clock is time-of-flight (`Engine#drain`'s own note). A hook adds one serial
  # fork+exec+wait to every one of those RTTs, on the worker fiber that owns the send. That is
  # the arithmetic change #818 disclosed for Probe's `exec` running per flow on the analyzer
  # fiber, and it is the same trade here.
  class HookBackend < Fuzz::Backend
    # Prefix on a hook-failure error string so `Miner.permanent_refusal?` can keep a broken
    # command from being RE-forked on every retry — a spawn failure will not fix itself in a
    # `retry_pause`, and a timeout re-run only multiplies the cost. The rest of the string is
    # `ProcessHook::Result#failure`, which names the command and why.
    HOOK_ERROR_PREFIX = "miner hook: "

    def initialize(@inner : Fuzz::Backend, @argv : Array(String), @timeout : Time::Span,
                   @env : Hash(String, String)? = nil)
    end

    def origin : Fuzz::Origin
      @inner.origin
    end

    # Delegated (not defaulted) like every other wrapper backend: this is what the Engine holds
    # through `CappedBackend`, so a `false`/`0`/nil stopping here would misreport every gated
    # or pooled run underneath it. See `Fuzz::Backend#evidence?`.
    def blocked : Int64
      @inner.blocked
    end

    def blocked_reason : String?
      @inner.blocked_reason
    end

    def extra_requests : Int64
      @inner.extra_requests
    end

    def evidence? : Bool
      @inner.evidence?
    end

    def close : Nil
      @inner.close
    end

    def send(bytes : Bytes) : Repeater::Result
      send(bytes, nil)
    end

    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      spans = @inner.evidence? ? Fuzz::Backend.all_verbatim(bytes) : verbatim
      prepared = Gori::Env.expand_bindings(bytes, spans)
      # The active slot's identity headers, BEFORE the hook signs them (the inner sender's own
      # overlay is off — see the class comment). A no-op when no slot is active.
      prepared = Gori::Env.overlay_slot(prepared)
      sent, reason = Inject.hook(prepared, @argv, @timeout, @env)
      if sent.nil?
        # A hook that could not run is a SKIP with a reported reason, never a clean negative:
        # hand back an errored send and let every miner send site count it and refuse to read
        # it as a confirmed absence (#846, and #818's "absence of a finding reads as clean").
        return Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, "#{HOOK_ERROR_PREFIX}#{reason}")
      end
      # The hook's output IS the request now, so nothing below may rewrite it — `all_verbatim`
      # makes the Sender's binding pass a no-op over it.
      @inner.send(sent, Fuzz::Backend.all_verbatim(sent))
    end
  end
end
