require "../proxy/codec/content_decode"
require "../fuzz/matcher"
require "../repeater/engine"

module Gori::Miner
  # A decoded view of one response: metrics + the SET of canary tokens that appear in the
  # decoded body or head, collected in a SINGLE byte-scan (reflection membership is then a
  # hash lookup, not a fresh full-body substring search per candidate).
  # Reuses Fuzz::Metrics (the record), but computes word/line counts here because the
  # Matcher's counters are private — and we want one decode, not two.
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
    def self.probe(raw : Repeater::Result) : Probe
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body)
      body = decoded || raw.body || Bytes.empty
      words, lines = count_metrics(body)
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

    # Collect every `gq`+8-lower-hex token (Canary.fresh's exact shape, LEN=10) present in
    # `bytes` into `into`. A verbatim canary occurrence lands at its own start offset, so the
    # set holds exactly the tokens the old per-canary `includes?` would have matched — same
    # reflected set, same echo-control result. No canary can be a substring of another (fixed
    # length), and no lower-hex byte is `g` (0x67), so tokens never overlap.
    private def self.scan_canaries(bytes : Bytes, into : Set(String)) : Nil
      return if bytes.size < Canary::LEN
      last = bytes.size - Canary::LEN
      i = 0
      while i <= last
        if bytes.unsafe_fetch(i) == 0x67_u8 && bytes.unsafe_fetch(i + 1) == 0x71_u8 && canary_tail?(bytes, i + 2)
          into << String.new(bytes[i, Canary::LEN])
        end
        i += 1
      end
    end

    # The 8 bytes after `gq` are all lower-hex (0-9 a-f). `from` + 8 is in bounds by the
    # `i <= last` invariant in scan_canaries, so unsafe_fetch is safe.
    private def self.canary_tail?(bytes : Bytes, from : Int32) : Bool
      8.times do |k|
        b = bytes.unsafe_fetch(from + k)
        return false unless (b >= 0x30_u8 && b <= 0x39_u8) || (b >= 0x61_u8 && b <= 0x66_u8)
      end
      true
    end

    # Word count over decoded bytes, allocation-free (whitespace transitions) — lifted
    # from Fuzz::Matcher (private there) to avoid a second decode pass.
    # Words and lines in ONE pass over the body, which is what `Fuzz::Matcher#count_metrics`
    # already does — this module kept two separate walks long after its twin merged them, so
    # a mine paid three full scans of every response body (words, lines, canaries) where two
    # were enough. Identical answers: same whitespace set, same word-start rule, and `\n` is
    # counted on the same byte both loops already tested for.
    private def self.count_metrics(body : Bytes) : {Int32, Int32}
      words = 0
      lines = 0
      in_word = false
      body.each do |b|
        if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
          in_word = false
          lines += 1 if b == 0x0a_u8
        elsif !in_word
          in_word = true
          words += 1
        end
      end
      {words, lines}
    end
  end
end
