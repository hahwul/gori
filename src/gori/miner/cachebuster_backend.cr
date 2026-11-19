require "../fuzz/engine"
require "./inject"

module Gori::Miner
  # A unique cache-buster on every probe, wired as a `Fuzz::Backend` DECORATOR — the same seam
  # `HookBackend` and `MacroBackend` use, and for the same reason: a mine's requests do not all
  # leave from one place. Baseline calibration (`Baseline`), each bucket probe
  # (`Engine#process_bucket`) and every finding's confirmation (`Engine#confirm`) go through
  # `@backend.send`, so wrapping the backend is the ONE home that reaches them all — and it MUST
  # reach the baseline, because a baseline served from a shared cache measures the cache, not the
  # origin, and every later probe would then diff against a stale body.
  #
  # WHY per request, not once on the seed: a single fixed buster busts the key real users hit, but
  # the mine's OWN probes would then share one key, so the second probe onward could be answered
  # from the first's cached response — the miner reading a cache it filled. A fresh value per send
  # gives every probe its own key: nothing it sends is served from, nor stored into, the cache a
  # real user shares.
  #
  # ORDER — OUTSIDE the hook/macro and INSIDE the engine's `CappedBackend`. Outside the hook so a
  # signed API signs the busted request line (a signature over the query must cover `__gcb`, or the
  # target rejects every probe); inside the cap so a cache-buster send still counts against
  # `--max-requests` and the cap refuses before the value is minted.
  #
  # NOT a canary value. `Fingerprint` decides reflection by scanning the response for `gq`+8-hex
  # canary tokens, so a canary-shaped buster that the endpoint echoes in its URL would read as a
  # reflected candidate. Lower-hex can never contain `g`, so a 16-hex buster is canary-safe by
  # construction; its fixed length also keeps every probe byte-identical in size to its control, so
  # a buster reflected into the body moves no length/word/line metric.
  class CachebusterBackend < Fuzz::WrapperBackend
    # The query parameter name. Underscore-prefixed to stay clear of a real application parameter,
    # and short so it costs almost nothing against the per-request URL byte budget.
    PARAM = "__gcb"

    # Hex chars of randomness (16 → 64 bits): collision-free across any run gori will ever send,
    # from one `Random::Secure.hex` draw per outbound request. One `getrandom` per send is nothing
    # against the round trip it precedes (the miner is latency-bound — `Engine#drain`), so unlike
    # the per-name canaries this needs no batching.
    VALUE_HEX = 8

    def initialize(@inner : Fuzz::Backend)
    end

    def send(bytes : Bytes, verbatim : Array({Int32, Int32})?) : Repeater::Result
      busted, at, delta = Inject.cachebuster(bytes, PARAM, Random::Secure.hex(VALUE_HEX))
      # Shift the injected-candidate spans the inner sender protects from binding expansion: a span
      # at or past the insertion point moved by `delta`, one before it (a query candidate) did not —
      # the rule `Inject.cachebuster` documents and `Inject.sync_spans` already applies.
      if verbatim && delta > 0
        verbatim = verbatim.map { |(a, b)| a >= at ? {a + delta, b + delta} : {a, b} }
      end
      @inner.send(busted, verbatim)
    end
  end
end
