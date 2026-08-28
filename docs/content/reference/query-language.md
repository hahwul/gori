+++
title = "Query Language"
description = "The filter syntax used across History, Sitemap, Probe, Issues, Intercept, and the MCP tools."
weight = 30
+++

gori has a small query language (QL) for filtering flows. The same syntax works in the TUI filter bars, in `gori run` (`-q`/`--query`, or positionally), and through the MCP tools. The built-in reference is also available as `gori run history --help` and the `ql_reference` MCP tool.

## Fields

Match a field with `field:value` (substring or exact, depending on the field):

| Field | Matches |
|-------|---------|
| `host` | Request host |
| `path` | Request path |
| `url` | Full URL |
| `method` | HTTP method |
| `scheme` | `http` / `https` |
| `proto` | Protocol: `http`, `ws`, `grpc`, `sse` |
| `src` | Where the flow came from ([below](#src-provenance)) |
| `status` | Response status code |
| `size` | Total request + response bytes |
| `reqsize` / `respsize` | Per-side byte count |
| `dur` | Response time in milliseconds |
| `header` | Substring over the head (request + response headers) |
| `body` | Full-text match over bodies (trigram FTS index) |
| `scope` | `in` / `out` — the project's scope rules ([below](#scope-in-scope-out)) |

```text
host:example.com
method:POST
status:404
```

### One side only: `req.` / `resp.`

`header:` and `body:` search **both the request and the response**. Prefix either with `req.` or
`resp.` to search one side.

| Field | Meaning |
| --- | --- |
| `req.body` / `resp.body` | That side's body only |
| `req.header` / `resp.header` | That side's head only |

```text
resp.body:secrettoken                 a token only the response carries
resp.header:set-cookie                responses that set a cookie
-resp.body:abcd                       responses whose body lacks abcd
req.body~(?i)password                 regex over the request body only
NOT (req.body:token OR resp.body:token)
```

`res.` is a synonym of `resp.`, and `req.size` / `resp.size` are synonyms of `reqsize` /
`respsize`. Fields that only ever have one side (`host`, `method`, `status`, …) take no prefix.

## Source: `src:` {#src-provenance}

`src:` matches flows by **who put the request on the wire**. `src:proxy` is traffic a client
sent through gori; every other value is a request gori itself made, and `src:import` is a
capture read out of somebody else's file.

| Value | Matches |
|-------|---------|
| `proxy` | The capture proxy relayed a client's request — ordinary captured traffic |
| `repeater` | A Repeater send (the TUI, `gori run repeater send --record-history`, MCP `send_request`) |
| `fuzzer` | A fuzz result recorded with `--record-history` / `record_history` |
| `discover` | A crawl fetch (Discover persists by default) |
| `miner`, `sequencer`, `authorize`, `probe` | Reserved — those tools do not record flows yet |
| `import` | Read in from a HAR, Burp export, `--urls`, an OpenAPI document |
| `gori` | Every source gori SENT — the union of the middle rows, and **not** `import` |

```text
src:proxy                             read History as traffic that really happened
-src:proxy                            everything gori put there
src:gori                              …the same set, stated positively
src:repeater status:200               your own resends that came back OK
src:fuzzer resp.body:root:            fuzz hits, so a payload is not mistaken for a finding
```

The History **SRC** column prints a short tag for each of these (`PROXY`, `RPTR`, `FUZZ`,
`CRAWL`, `IMPRT`, …) and `src:` accepts those tags too, so `src:rptr` and `src:repeater` are the
same query. `source:` is accepted as a long spelling of `src:`.

Two things about it are deliberate:

- **An imported flow is not `src:gori`.** gori never put it on a wire; it describes a real
  endpoint somebody else captured. `-src:proxy` keeps it, `src:gori` does not.
- **A flow captured before gori recorded provenance matches NEITHER direction.** Those rows
  hold no source at all — gori was already writing repeater sends, crawls and imports into
  History before the column existed, so filling them in as `proxy` would have invented a fact
  no capture produced. They show `—` in the SRC column, and both `src:proxy` and `-src:proxy`
  skip them, the way a Pending flow falls out of `status:` and `-status:`. Only flows captured
  after the upgrade carry it.

The two common `src:` scopings are also **views** — press `v` in History to pick `History`
(`src:proxy`) or `History + Repeater`, and the list stays narrowed while you type other filters.
`History + Repeater` is what a project opens on. See [Views](/guide/proxy/#views).

## Scope: `scope:in` / `scope:out` {#scope-in-scope-out}

`scope:in` matches the flows inside the project's scope — the same include/exclude boundary the
TUI's `⇧S` lens and `gori run history --in-scope` apply — and `scope:out` matches the ones
outside it. It is an ordinary term, so it negates and it groups:

```text
scope:in status:5xx                   server errors on the target
scope:out -host:cdn                   traffic that leaked out of scope, minus the CDN
(scope:in OR host:staging.example.com) method:POST
```

Three things about it are deliberate:

- **It ignores whether the `⇧S` lens is switched on.** A filter term is a question, not a mode,
  so `scope:in` means the same thing either way. (With the lens ON, it is redundant — the lens
  already ANDs the same predicate over your query — and `scope:out` then matches nothing, since
  the lens has already dropped every out-of-scope row.)
- **With no scope rules configured, both spellings match nothing.** Nothing is in scope, so the
  question has no answer and is not asked. In particular `scope:out` does *not* mean "everything"
  in that state — which is also why `-scope:in`, a negated never-match, is *not* the same as
  `scope:out` on a project with no scope rules. `ql_explain` reports
  `scope_rules_configured: false` and warns, and `gori run history delete` refuses a scope query
  outright rather than risk deleting a project's history over a term that had nothing to answer.
- **`scope:` is per-FLOW.** On the Sitemap that makes it different from `gori run sitemap
  --in-scope`, which selects whole HOSTS (a host is kept if any of its traffic is in scope), so a
  `scope:in` query can keep a host and drop some of its endpoints.

Capture is untouched by any of this: gori records everything either way, and this only narrows
what a query returns.

## Status Classes

`status:` accepts class shorthands:

```text
status:2xx      status:4xx      status:5xx
```

## Comparisons

Numeric fields (`status`, `size`, `reqsize`, `respsize`, `dur`) support comparison operators `<`, `<=`, `>`, `>=`, `=`:

```text
status:>=500        server errors
size:>100000        large exchanges
dur:>500            slower than 500 ms
dur:<2s             faster than 2 s (s / ms suffixes allowed)
```

## Regular Expressions

Use `~` for a regex match on `host`, `path`, `url`, `header`, or `body`. The `~` is its own field/value separator. Do **not** put a colon before it. Matching is case-sensitive; prefix `(?i)` for case-insensitive.

```text
path~/admin/
host~^api\.
header~set-cookie
```

## Combining Terms

- Terms separated by spaces are **AND**-ed together. `AND` may also be written out.
- `OR` matches either side. `NOT` and a `-` prefix both negate.
- Parentheses group. Precedence is `NOT` then `AND` then `OR`.
- A bare word (no `field:`) is free text over method, host, and target.
- A `field:` name that does not exist is not free text you meant to write: `gori run history`, `gori run sitemap` and `gori run probe` **refuse** it, name the nearest real field, and exit non-zero. `--lenient` searches the token as text instead (what every surface used to do silently — `methd:GET` matched nothing, which reads as an empty project). The TUI filter bar still accepts a half-typed name as you type it.

```text
host:example.com status:5xx           both must match
host:api AND status:5xx               the same thing, spelled out
method:POST -status:200               POST, but not 200
host:a.com OR host:b.com              either host
(host:a.com OR host:b.com) -path:/js  either host, no /js
NOT (host:cdn OR host:static)         neither host
login                                 free-text search
```

`AND`, `OR` and `NOT` are recognised uppercase only, so searching for the words
"and", "or" or "not" still works. Quote them to force a literal even in caps.

Double quotes keep spaces inside one term:

```text
host:"my host"                        one host value, space and all
"two words"                           free text for the whole phrase
"OR"                                  the literal word, not the operator
```

A parenthesis inside a value stays literal, so `path:/a(b)` needs no escaping. A `(`
only opens a group at the start of a term, and `)` only closes one at the end.

## Where It Applies

Every filter bar shares the grammar above (fields, comparisons, `~` regex, `AND`/`OR`/`NOT`, parentheses, quoting). What differs is the field set, and only because the surfaces filter different kinds of row.

| Surface | Fields |
|---------|--------|
| History, `gori run history`, MCP | The full table above |
| Sitemap | The same, plus `tag:` for per-node path memos |
| Colour rules (Colormarker) | The same — a colour rule takes the query the History bar takes |
| Intercept catch condition, extract-rule condition | `host`, `path`, `url`, `method`, `scheme`, `status`, `proto`, `header`, `body` — **no `scope:`** |
| Probe | `severity` (`sev`), `status` (`st`), `category` (`cat`), `host`, `code` |
| Issues | `severity` (`sev`), `status` (`st`), `host`, `title`, `cvss` |

`scope:` is the one field a hold gate and an extract-rule condition refuse rather than answer:
they evaluate a live message, and a project's scope rules are not part of one. The condition rows
say so where you type them, and an extract rule carrying `scope:` will not save.

Probe and Issues take severity names (`info`, `low`, `medium`/`med`, `high`, `critical`/`crit`) and triage states (`open`, `confirmed`/`conf`, `false-positive`/`fp`, `resolved`/`done`, plus `closed` for any non-open state). Severity supports comparisons, so `sev:>=high` works. Issues also accepts `cvss:` with numeric comparison operators (`cvss:>=7.0`, `cvss:<4.0`), exact scores (`cvss:7.5`), or vector substrings (`cvss:3.1`).

```text
sev:>=high -status:fp                 Issues: high and critical, no false positives
cvss:>=7.0 status:open                Issues: high or critical CVSS findings still open
cat:cors sev:medium                   Probe: medium CORS findings
host:api.example.com method:POST      Intercept: hold POSTs to one host
body:secret AND -host:cdn             Colour rule: paint leaks, ignore the CDN
```

Both the Intercept and colour-rule bars Tab-complete field names and known values as you type.

### Matching Request and Response Content

`header:` and `body:` search the bytes of a message, so where they work is decided by which bytes exist at the moment the filter is asked:

- **History, Sitemap and colour rules** search a captured flow, so both fields always work, on both sides of the exchange.
- **Intercept and extract-rule conditions** search the message in flight. `header:` works at every gate. `body:` works for a held **WebSocket message** and for an **extract-rule** condition, where the payload is in hand — but not at an HTTP hold gate, because that gate is what decides whether the body gets buffered in the first place.

One deliberate difference between the two, worth knowing before you write a rule:

- In a **query**, `body:` reads a trigram index — fast, but bounded to the first 8 KiB of each side and skipping binary and compressed bodies. `body~regex` scans the stored bytes instead, with no bound.
- In a **colour rule**, `body:` always scans, and reads the first 64 KiB of each side. Indexing happens after capture and a rule has to paint the row that just arrived, so scanning is the only way to be right; the 64 KiB bound is what keeps a screenful of large bodies from stalling the list. A colour rule therefore paints rows the identical query does not list — but a match past 64 KiB is not painted.

Every `body:` term, on every surface, reads the bytes **as they went over the wire**, so none of them finds a string inside a gzipped body. That includes an extract rule's condition, which is evaluated before the response is decoded — only the extraction that follows sees decompressed text. To match on compressed content, match something outside it: a header, the path, or the response size.

## Examples

```bash
# Errors on one host
gori run history -q 'host:api.example.com status:5xx'

# Slow POSTs mentioning a token
gori run history -q 'method:POST dur:>1s body:token'

# Admin paths, excluding static assets
gori run history -q 'path~/admin/ -path~\.(css|js|png)$'

# Scope a passive scan
gori run probe -q 'host:example.com'
```
