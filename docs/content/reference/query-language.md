+++
title = "Query Language"
description = "The filter syntax used across History, Prism, Sitemap, and the MCP tools."
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

Use `~` for a regex match on `host`, `path`, `url`, `header`, or `body`. The `~` is its own field/value separator — do **not** put a colon before it. Matching is case-sensitive; prefix `(?i)` for case-insensitive.

```text
path~/admin/
host~^api\.
header~set-cookie
```

## Combining Terms

- Terms separated by spaces are **AND**-ed together.
- Prefix a field with `-` to **negate** it.
- `OR` separates alternative AND-groups.
- A bare word (no `field:`) is free text over method, host, and path.

```text
host:example.com status:5xx           both must match
method:POST -status:200               POST, but not 200
host:a.com OR host:b.com              either host
login                                 free-text search
```

## Examples

```bash
# Errors on one host
gori run history -q 'host:api.example.com status:5xx'

# Slow POSTs mentioning a token
gori run history -q 'method:POST dur:>1s body:token'

# Admin paths, excluding static assets
gori run history -q 'path~/admin/ -path~\.(css|js|png)$'

# Scope a passive scan
gori run prism -q 'host:example.com'
```
