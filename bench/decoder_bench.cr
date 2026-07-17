# Decoder codec micro-benchmarks. The Decoder tab re-runs the whole chain on EVERY
# keystroke (decoder_controller#recompute), so each converter's per-call cost is on
# the interactive hot path when editing a large pasted blob.
#
# Build: crystal build bench/decoder_bench.cr -o bin/decoder_bench --release
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/decoder"

include Gori::Decoder

# A realistic "large pasted blob" for each codec: ~256 KiB of source bytes.
BLOB = Bytes.new(256 * 1024) { |i| (i * 7 + 13).to_u8! }
TEXT = String.build { |io| 16_000.times { |i| io << "café#{i} " } } # multibyte, for unicode

B64   = Base64.strict_encode(BLOB)
B64WS = B64.gsub(/(.{76})/, "\\1\n") # MIME-wrapped (whitespace every 76 cols)
HEX   = BLOB.hexstring
B32   = Codecs.base32_encode(BLOB)
UNI   = Codecs.unicode_escape(TEXT)

puts "blob=#{BLOB.size}B  b64=#{B64.size}B  hex=#{HEX.size}B  b32=#{B32.size}B  uni=#{UNI.size}B\n\n"

Benchmark.ips do |x|
  x.report("base64_decode (no ws)") { Codecs.base64_decode(B64) }
  x.report("base64_decode (ws)") { Codecs.base64_decode(B64WS) }
  x.report("hex_decode") { Codecs.hex_decode(HEX) }
  x.report("base32_decode") { Codecs.base32_decode(B32) }
  x.report("base32_encode") { Codecs.base32_encode(BLOB) }
  x.report("unicode_unescape") { Codecs.unicode_unescape(UNI) }
end
