require "../proxy/codec/content_decode"
require "../fuzz/matcher"
require "../repeater/engine"

module Gori::Miner
  # A decoded view of one response: metrics + the SET of canary tokens that appear in the
  # decoded body or head, collected in a SINGLE byte-scan (reflection membership is then a
  # hash lookup, not a fresh full-body substring search per candidate).
  # Reuses Fuzz::Metrics (the record) and `Fuzz::Matcher.count_metrics` over its own decode —
  # one decode, not two.
  record Probe,
    metrics : Fuzz::Metrics,
    canaries : Set(String) do
    # Whether `needle` (a `gq`+8-hex canary) was reflected. The ONE place reflection
    # membership is decided — both decide() (candidate detection) and the Baseline echo-API
    # control call this, so the suppression control can't drift from the detection it gates.
    # Old code ran an O(body) `includes?` PER candidate (K = 128–256 per bucket); now the
    # body+head are scanned ONCE into `canaries` and this is an O(1) set lookup.
    def reflects?(needle : String) : Bool
      canaries.includes?(needle)
    end
  end

  module Fingerprint
    # Cap the INFLATE at the capture ceiling for the same reason `Fuzz::Matcher#decode`
    # does — this and that were the two decode sites in the active engines still taking
    # `ContentDecode`'s 32 MiB default, so a compressible response inflated ~4x past the
    # 8 MiB the capture read already bounds, once per in-flight worker.
    def self.probe(raw : Repeater::Result) : Probe
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body, Proxy::Codec::Body::CAPTURE_READ_MAX)
      body = decoded || raw.body || Bytes.empty
      words, lines = Fuzz::Matcher.count_metrics(body)
      metrics = Fuzz::Metrics.new(
        raw.response.try(&.status), body.size.to_i64, words, lines, raw.duration_us)
      # One scan of body + head collects every canary-shaped token, replacing both the K
      # per-candidate `includes?` passes AND the two `String.new(...).scrub` allocations the
      # old body_text/head_text strings required (they fed only `reflects?`).
      found = Set(String).new
      scan_canaries(body, found)
      scan_canaries(raw.head, found)
      Probe.new(metrics, found)
    end

    # Collect every canary token present in `bytes` into `into`. A verbatim canary occurrence
    # lands at its own start offset, so the set holds exactly the tokens the old per-canary
    # `includes?` would have matched — same reflected set, same echo-control result. The scan
    # (and the `gq`+8-lower-hex shape it recognises) is `Canary.each_token`, shared with
    # `Inject`'s JSON span finder so the two cannot disagree about what a canary looks like.
    private def self.scan_canaries(bytes : Bytes, into : Set(String)) : Nil
      Canary.each_token(bytes) { |i| into << String.new(bytes[i, Canary::LEN]) }
    end
  end
end
