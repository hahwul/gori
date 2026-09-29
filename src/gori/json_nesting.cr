# Loaded FIRST, so stdlib's `JSON::Builder` (and its `max_nesting = 99` initializer) is already
# defined when the reopen below replaces that initializer. Required ahead of it, stdlib's would
# run last and win.
require "json"

# `JSON.parse` accepts a document nested 512 deep, and `JSON::Builder` refused to write one
# past 99 — so every re-emission of a parsed document raised `JSON::Error: Nesting of 100 is
# too deep` on a body 100–512 deep that had just parsed fine. Captured bodies, JWTs, cookies and
# GraphQL requests are the peer's to shape, so `[[[…]]]` 150 deep reached every such site: the
# JWT and cookie tools, redaction (a redacted HAR export stopped mid-document), `jsonpath:`
# columns, retests, extract rules, the OpenAPI export, and — through the depth of the document
# around it — a 33-level protobuf in `get_flow` and `gori run show --format json`. And since the
# builder's error is the PARENT of `JSON::ParseException`, the clauses beside those sites missed
# it. The sitemap JSON writer is hand-rolled for this very cap (`CLI::Output.sitemap_json`).
#
# One default rather than a helper at each site, because `JSON::Any#to_json` and
# `#to_pretty_json` build a fresh builder of their own. It stays FINITE: the parser's 512 plus
# room for the documents gori wraps around a parsed one, and still the guard that turns a cyclic
# `YAML::Any` into a clean `JSON::Error` instead of a stack overflow.
class JSON::Builder
  @max_nesting = 1024
end
