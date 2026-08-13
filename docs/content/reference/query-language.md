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
| `status` | Response status code |
| `size` | Total request + response bytes |
| `reqsize` / `respsize` | Per-side byte count |
| `dur` | Response time in milliseconds |
| `header` | Substring over the head (request + response headers) |
| `body` | Full-text match over bodies (trigram FTS index) |

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
| Intercept catch condition, extract-rule condition | `host`, `path`, `url`, `method`, `scheme`, `status`, `proto`, `header`, `body` |
| Probe | `severity` (`sev`), `status` (`st`), `category` (`cat`), `host`, `code` |
| Issues | `severity` (`sev`), `status` (`st`), `host`, `title` |

Probe and Issues take severity names (`info`, `low`, `medium`/`med`, `high`, `critical`/`crit`) and triage states (`open`, `confirmed`/`conf`, `false-positive`/`fp`, `resolved`/`done`, plus `closed` for any non-open state). Severity supports comparisons, so `sev:>=high` works.

```text
sev:>=high -status:fp                 Issues: high and critical, no false positives
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
