require "../request_macro/lane"
require "../fuzz/engine"

module Gori::Miner
  # A run's request-time macro (#1350), wired as a `Fuzz::Backend` DECORATOR — the same seam
  # `HookBackend` uses, and for the same reason: a mine's requests do not all leave from one
  # place. Baseline calibration, every bucket probe and every finding's confirmation go through
  # `@backend.send`, so wrapping the backend is the one seam that reaches all of them — and it
  # MUST reach the baseline, because an app that rotates a token per request answers an
  # un-tokened calibration probe with the same 403 it gives a candidate, and a baseline of 403s
  # makes every real response look like a finding.
  #
  # Each `send` is one request as far as the macro's cadence is concerned: the miner has no
  # fixed candidate list (its probes are a search, each depending on the last), so the unit the
  # cadence counts is the request the engine puts on the wire. `every 1` therefore gives every
  # probe a value of its own, and — through `Lane`'s epochs — runs the mine one probe at a time.
  # The plan says so (`Plan#request_macro_info`) before the first request.
  #
  # Wrapped OUTSIDE the raw sender (and outside `HookBackend`, so a hook signs bytes that already
  # carry the fresh value) and INSIDE the engine's `CappedBackend`: the cap refuses a send before
  # the macro's steps run once the budget is spent, and the steps are charged to the same cap.
  class MacroBackend < Fuzz::Backend
    def initialize(@inner : Fuzz::Backend, @lane : Gori::RequestMacro::Lane)
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

    def http2? : Bool
      @inner.http2?
    end

    def pooled? : Bool
      @inner.pooled?
    end

    def close : Nil
      @inner.close
    end

    def send(bytes : Bytes) : Repeater::Result
      send(bytes, nil)
    end

    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      @lane.around do |entry|
        if entry.send?
          @inner.send(bytes, verbatim)
        else
          # The cap charged this probe on its way in — before the steps could fail — and it
          # never reached the wire, so the charge goes back (`Lane#refund_candidate`).
          @lane.refund_candidate
          # A refusal is a SKIP with a reported reason, never a clean negative: an errored send
          # that every miner send site counts and refuses to read as a confirmed absence, the
          # contract `HookBackend` states for a hook that could not run.
          Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, entry.error)
        end
      end
    end
  end
end
