+++
title = "Proxy & History"
description = "Capture traffic, intercept requests, scope your target, and inspect every protocol."
+++

The proxy is the heart of gori. It sits between your client and the upstream server, records each exchange as a *flow*, and stores it in the current project. **History** is where you read those flows back.

## Capturing Traffic

Start gori and point your client at `127.0.0.1:8070` (see the [Quick Start](/getting-started/quick-start/)). Toggle capture at any time with `c` — turning it off lets traffic pass through without being recorded, which is handy while you set up.

Each flow records the full request and response: start line, headers, and body (captured up to 8 MiB). Bodies compressed with gzip, deflate, Brotli, or Zstd are decoded for display.

## Intercept

Press `i` to enable **Intercept**. When on, matching requests (and optionally responses) are held so you can forward, drop, or edit them before they continue. A filter bar at the top of the Intercept tab lets you choose the direction to catch and narrow what gets held with a query-language expression, so you only pause on the traffic you care about.

## Scope

Scope keeps a large session focused on your target. In the **Project** tab you define include/exclude rules by host, string, or regular expression. Toggle the **scope lens** with `s` to filter the views down to in-scope traffic, and use scope to gate what Intercept and the scanners act on.

## Sitemap

The **Sitemap** tab collapses History into a deduplicated tree of `host → path` endpoints, with method chips and scope markers. It's the fastest way to see the shape of a target's attack surface. Numeric path segments can be folded together so `/user/1` and `/user/2` share one node.

## Protocol Support

gori is protocol-aware, not just a byte pipe:

| Protocol | Support |
|----------|---------|
| **HTTP/1.1** | Full capture and replay |
| **HTTP/2** | Transparent relay after ALPN, raw frame log, HPACK decode, stream → flow assembly |
| **WebSocket** | Live message capture and replay (no permessage-deflate) |
| **gRPC** | Framed over HTTP/2 with status trailers; protobuf shown as raw bytes (no `.proto` schema) |
| **Server-Sent Events** | Parsed into discrete events at display time |

On top of the wire protocols, gori decodes common payloads inline so you don't have to reach for another tool:

- **JWT** — header and payload decoded from `Authorization`, cookies, URLs, and bodies (signatures are shown but never verified).
- **SAML** — base64 (and DEFLATE for the redirect binding) decoded for `SAMLRequest` / `SAMLResponse`.
- **GraphQL** — `query`, `operationName`, and `variables` parsed from POST bodies and `?query=` parameters.

## Filtering History

History is searchable with gori's [query language](/reference/query-language/). A few examples:

```text
status:5xx                  flows that errored
host:api.example.com        a single host
method:POST body:password   POST requests mentioning "password"
dur:>500                    responses slower than 500 ms
path:~/admin/               path matching a regex
```

Type a query in the History filter bar, or run it headless:

```bash
gori run history -q 'status:5xx host:api.example.com'
```

## Next Steps

- [Replay & Fuzzer](/guide/replay-and-fuzzer/) — act on the flows you capture
- [Scanning & Findings](/guide/scanning/) — automated and manual analysis
- [Query Language](/reference/query-language/) — the full filter syntax
