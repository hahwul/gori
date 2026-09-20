# Is a `name:value` token a field use? — the predicate the CLI/MCP refusals have always run
# and the TUI's span highlighter now runs too, which is what makes its cost worth a harness:
# a filter bar repaints EVERY FRAME, once per token, while the operator types.
#
# Four inputs, because they take four different roads through `FilterAst.field_shaped?`:
#
#   known        `host:…`            — the common case, and the first line of the predicate
#   url          `http://a/b`        — rejected on the `//` value, no vocabulary touched
#   typo         `hostt:api`         — identifier, non-port value: shaped, suggester NOT run
#   authority    `localhost:8080`    — the ONE road that runs the suggester, per frame
#
# The authority road is the one this harness exists for, and the one that carries a verdict:
# it is ~460x the common case (8.6 us, 1.15 kB) because it is the only road that runs
# `FilterAst.suggest`, and the allocation is `Levenshtein.find`'s — rewriting the prefix
# `select` as an allocation-free loop moved neither number, so it was left alone. 8.6 us on a
# frame that has ~16 ms is not worth a cache keyed on operator-typed text; this harness is
# here so the next person reads that off a measurement instead of re-deriving it.
# Cited from `FilterAst.suggest`.
require "benchmark"
require "../src/gori"

include Gori

CASES = {
  "known host:"              => {"host", ':', "api.acme.test"},
  "url http://a/b"           => {"http", ':', "//a/b"},
  "typo hostt:api"           => {"hostt", ':', "api"},
  "authority localhost:8080" => {"localhost", ':', "8080"},
}

puts "candidate pool: #{QL::CANDIDATE_FIELDS.size} names"
Benchmark.ips do |x|
  CASES.each do |label, (name, op, value)|
    x.report(label) { QL::FIELD_SHAPED.call(name, op, value) }
  end
end
