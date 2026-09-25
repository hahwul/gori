# JavaScript reference scan (#1243): what one captured bundle costs `JsRefs.extract`'s two
# halves, and the longest stretch either holds the scheduler. The scan runs on demand off the
# capture path, but in the TUI it runs in a fiber beside the proxy's own (P6), so the number
# that matters is the longest synchronous stretch, not the total.
#
#   * `literals` — `strip_comments` + the ENDPOINT pass. The engine yields between the two and
#                  every YIELD_EVERY matches, so the lex alone (`strip`, printed separately) is the
#                  longest stretch it holds the scheduler for
#   * `resolve`  — `Url.resolve` + `Url.parse` per literal; the engine yields every YIELD_EVERY,
#                  so its stretch is one YIELD_EVERY-sized slice of the total
#
# Measured on an M-series laptop, release: 2 MiB → strip ~5.5 ms, literals ~9 ms in all, a resolve
# slice ~0.15 ms; the non-ASCII 2 MiB bundle → strip ~8 ms (the lexer's `String#chars` path),
# literals ~15 ms in all.
#
# Fixtures: a 256 KiB bundle (the Probe's CLIENT_BODY_CAP, the passive-bench shape), a 2 MiB one
# (`Extract::MAX_SCAN`, the largest body the scan reads), and the 2 MiB one with Hangul in its
# comments, which takes `CommentProbe`'s lockstep walk instead of the byte-aligned read.
#
# Build: crystal build bench/js_refs_bench.cr -o bin/js_refs_bench --release
# Run:   bin/js_refs_bench
require "../src/gori"

private def bundle(bytes : Int32, non_ascii : Bool) : String
  String.build(bytes + 256) do |io|
    i = 0
    while io.bytesize < bytes
      # A minified statement run: one path literal, a template literal, a comment, noise.
      io << %(function f#{i}(a,b){return fetch("/api/v1/resource#{i % 900}?x="+a).then(r=>r.json())}) \
            %(var t#{i}=`/api/items/${b}/sub#{i % 300}`;/* #{non_ascii ? "주석 한글 설명" : "block note"} "/api/old#{i % 50}" */) \
            %(var m#{i}="application/json",d#{i}=2026/7/19,r#{i}=/a\\/b/g;)
      i += 1
    end
  end
end

private def time_ms(runs : Int32, &) : Float64
  yield # warm
  t0 = Time.instant
  runs.times { yield }
  (Time.instant - t0).total_milliseconds / runs
end

base = Gori::Discover::Url.parse("https://shop.test/app").not_nil!

{
  {"256 KiB", bundle(256 * 1024, false)},
  {"2 MiB", bundle(Gori::JsRefs::MAX_SCAN, false)},
  {"2 MiB non-ASCII", bundle(Gori::JsRefs::MAX_SCAN, true)},
}.each do |(name, js)|
  lits = [] of Gori::JsRefs::Literal
  strip_ms = time_ms(5) { Gori::Probe::Passive::JsScan.strip_comments(js) }
  lit_ms = time_ms(5) { lits = Gori::JsRefs.literals(js, Gori::JsRefs::Kind::Js)[0] }
  res_ms = time_ms(5) { lits.each { |l| Gori::JsRefs.resolve(l, base, Gori::JsRefs::Base::Referer) } }
  slice_ms = lits.empty? ? 0.0 : res_ms * Gori::JsRefs::YIELD_EVERY / lits.size
  puts "#{name.ljust(16)} strip #{strip_ms.round(2)} ms · literals #{lit_ms.round(2)} ms (#{lits.size} kept) · " \
       "resolve #{res_ms.round(2)} ms total, #{slice_ms.round(3)} ms per #{Gori::JsRefs::YIELD_EVERY}-literal slice"
end
