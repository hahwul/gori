require "../proxy/codec/content_decode"
require "../fuzz/matcher"
require "../replay/engine"

module Gori::Miner
  # A decoded view of one response: metrics + the decoded body text + the head text,
  # computed in a SINGLE decode pass (the reflection search reuses the same buffers).
  # Reuses Fuzz::Metrics (the record), but computes word/line counts here because the
  # Matcher's counters are private — and we want one decode, not two.
  record Probe,
    metrics : Fuzz::Metrics,
    body_text : String,
    head_text : String

  module Fingerprint
    def self.probe(raw : Replay::Result) : Probe
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body)
      body = decoded || raw.body || Bytes.empty
      metrics = Fuzz::Metrics.new(
        raw.response.try(&.status), body.size.to_i64,
        count_words(body), count_lines(body), raw.duration_us)
      Probe.new(metrics, String.new(body).scrub, String.new(raw.head).scrub)
    end

    # Word count over decoded bytes, allocation-free (whitespace transitions) — lifted
    # from Fuzz::Matcher (private there) to avoid a second decode pass.
    private def self.count_words(body : Bytes) : Int32
      count = 0
      in_word = false
      body.each do |b|
        if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
          in_word = false
        elsif !in_word
          in_word = true
          count += 1
        end
      end
      count
    end

    private def self.count_lines(body : Bytes) : Int32
      n = 0
      body.each { |b| n += 1 if b == 0x0a_u8 }
      n
    end
  end
end
