+++
title = "Proxy & History"
description = "Capture traffic, intercept requests, scope your target, and inspect every protocol."
+++

The proxy is the heart of gori. It sits between your client and the upstream server, records each exchange as a *flow*, and stores it in the current project. **History** is where you read those flows back.

## Capturing Traffic

Start gori and point your client at `127.0.0.1:8070` (see the [Quick Start](/getting-started/quick-start/)). Toggle capture at any time with `c` — turning it off lets traffic pass through without being recorded, which is handy while you set up.

Each flow records the full request and response: start line, headers, and body (the stored body is capped at 2 MiB; larger bodies still forward byte-exact and report their true size). Bodies compressed with gzip, deflate, Brotli, or Zstd are decoded for display.

<figure class="tui-shot">
  <img src="/images/tui/response-detail.svg" alt="gori flow detail view on the RESPONSE sub-tab, showing an HTTP/2 200 status line and syntax-highlighted response headers">
  <figcaption>Open any flow with <kbd>Enter</kbd> to read the full request and response, with sub-tabs for headers, HTTP/2 frames, and raw bytes.</figcaption>
</figure>

## Intercept

Press `i` to enable **Intercept**. When on, matching requests (and optionally responses) are held so you can forward, drop, or edit them before they continue. A filter bar at the top of the Intercept tab lets you choose the direction to catch and narrow what gets held with a query-language expression, so you only pause on the traffic you care about.

<figure class="tui-shot">
  <img src="/images/tui/intercept.svg" alt="gori Intercept tab with a filter bar for catch direction and a query condition, and a card explaining forward and drop while catch is off">
  <figcaption>The <strong>Intercept</strong> tab: toggle catch with <kbd>i</kbd>, pick a direction, and hold only matching traffic to forward, drop, or edit in flight.</figcaption>
</figure>

## Scope

Scope keeps a large session focused on your target. In the **Project** tab you define include/exclude rules by host, string, or regular expression. Toggle the **scope lens** with `s` to filter the views down to in-scope traffic, and use scope to gate what Intercept and the scanners act on.

## Sitemap

The **Sitemap** tab collapses History into a deduplicated tree of `host → path` endpoints, with method chips and scope markers. It's the fastest way to see the shape of a target's attack surface. Numeric path segments can be folded together so `/user/1` and `/user/2` share one node.

<figure class="tui-shot">
  <img src="/images/tui/sitemap.svg" alt="gori Sitemap tab showing captured hosts expanded into a tree of paths with method chips and per-host path counts">
  <figcaption>The <strong>Sitemap</strong> folds History into a <code>host → path</code> tree with method chips, so a target's surface is one glance.</figcaption>
</figure>

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
- **Form params** — `application/x-www-form-urlencoded` and `multipart/form-data` request bodies, plus the URL query string, decoded into a flat key=value list in the PARAMS pane (multipart file parts are summarised).

## Filtering History

History is searchable with gori's [query language](/reference/query-language/). A few examples:

```text
status:5xx                  flows that errored
host:api.example.com        a single host
method:POST body:password   POST requests mentioning "password"
dur:>500                    responses slower than 500 ms
path~/admin/                path matching a regex
```

Type a query in the History filter bar, or run it headless:

```bash
gori run history -q 'status:5xx host:api.example.com'
```

## Match & Replace

Press `m` (or `Ctrl-P` → **Match & Replace**) to open the rewrite editor. Rules rewrite the **head** (request line + headers) or the **body** of a request/response in flight — a literal substring swap applied to live traffic.

Syntax is one line per rule:

```text
req: User-Agent: x => User-Agent: gori
resp: Set-Cookie => X-Stripped
reqbody: password => hunter2
respbody: "debug":false => "debug":true
```

| Prefix | Target |
|--------|--------|
| `req:` (default) | Request head |
| `resp:` | Response head |
| `reqbody:` | Request body |
| `respbody:` | Response body |

An empty replacement deletes the matched text. A **body** rule buffers the message to rewrite it and re-syncs `Content-Length` automatically (a chunked body is de-chunked and re-framed); head rules keep the body streaming untouched. Body rewriting works on the decoded transfer form — a compressed (`Content-Encoding: gzip`/`br`/…) body isn't decompressed, so a literal pattern simply won't match it — and streaming responses (SSE, close-delimited, WebSocket upgrades) are left to stream. Rules are per-project, can be toggled on/off individually, and apply as soon as you add them — no restart. Use them to strip cookies, inject headers, or rewrite body values before traffic hits History or the scanners.

## Import

You don't have to capture everything live. From the command palette (`Ctrl-P`):

| Action | Source |
|--------|--------|
| **Import: HAR** | Browser or proxy HAR export → full request/response flows |
| **Import: URLs** | Text file, one URL per line → skeleton request flows |
| **Import: OpenAPI** | OpenAPI/Swagger JSON or YAML → one request template per operation |

Malformed entries are skipped rather than aborting the whole import. Imported flows land in History like captured traffic, so you can filter, Replay, Fuzz, and scan them the same way.

## Host Overrides

Host overrides are a `/etc/hosts`-style map: dial a specific IP for a hostname without changing DNS. Two layers exist:

| Layer | Where | Precedence |
|-------|-------|------------|
| **Project** | **Project** tab → HOST OVERRIDES pane (`a` / `e` / `d`) | Wins on collision |
| **Global** | `Ctrl-P` → **Settings: Hostnames**, or `hostname_overrides` in `settings.json` | Fallback |

Useful for staging hosts, IP-based virtual hosts, or pointing a production hostname at a lab box while keeping the `Host` header intact.

## Project Tab

The **Project** home tab is more than a summary. Focusable panes (cycle with `Tab`):

<figure class="tui-shot">
  <img src="/images/tui/project.svg" alt="gori Project tab with overview, at-a-glance status bars, scope, host overrides, environment variables, description, and network panes">
  <figcaption>The <strong>Project</strong> home: overview and status at a glance, plus panes for scope, host overrides, env vars, and per-project network settings.</figcaption>
</figure>

| Pane | Purpose |
|------|---------|
| **SCOPE** | Include/exclude rules (host, string, or regex) |
| **HOST OVERRIDES** | Per-project dial map |
| **ENV** | Per-project `$KEY` variables for outbound requests — see [Replay & Fuzzer](/guide/replay-and-fuzzer/#environment-variables) |
| **DESCRIPTION** | Free-form project notes |
| **SETTINGS** | Per-project network overrides (bind / upstream) |

Scope rules are also scriptable: `gori run scope add --kind=include --type=host --pattern=api.example.com` — full flags in the [CLI Reference](/reference/cli/#run-scope).

## Next Steps

- [Replay & Fuzzer](/guide/replay-and-fuzzer/) — act on the flows you capture
- [Convert](/guide/convert/) — encode / decode / hash without leaving the TUI
- [Scanning & Findings](/guide/scanning/) — automated and manual analysis
- [Query Language](/reference/query-language/) — the full filter syntax
