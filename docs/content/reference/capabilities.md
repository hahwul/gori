+++
title = "Capability Matrix"
description = "What gori can capture, intercept, replay, and fuzz across protocols and entry points."
weight = 5
+++

gori has three entry points over shared project data and engine modules: the interactive TUI,
the headless `gori run` CLI, and the MCP server. Sharing an engine means the same request policy
and analysis apply where a workflow is exposed; it does **not** mean every UI gesture is a CLI
command or an MCP tool.

## Protocols and operations

Where support is partial, the cell names the boundary. Replay and fuzz are gori-originated
requests and pass through the same outbound scope, Sandbox, and explicit-exclude gates on every
surface.

| Protocol | Capture | Intercept | Replay | Fuzz |
|----------|---------|-----------|--------|------|
| **HTTP/1.1** | Full request and response flows | Requests and finite responses; upgrades, SSE, and close-delimited responses stream through | Yes | Yes |
| **HTTP/2** | Per-stream flows plus raw frame log | Per stream; a declared body up to 1 MiB can be edited, otherwise the hold is head-only | Yes, over a real h2 connection | Yes |
| **WebSocket over HTTP/1.1** | Handshake and message transcript | Messages when the filter explicitly contains `proto:ws` | Yes, message scripts | Yes, handshake and message positions |
| **WebSocket over HTTP/2 (RFC 8441)** | Handshake, h2 frames, and message transcript | Handshake only; messages are not held | Yes, message scripts; the socket is reopened with the capture's own extended `CONNECT` | Yes, handshake and message positions |
| **gRPC over HTTP/2** | Framed messages, trailers, and protobuf projections | Unary/small declared bodies can be edited; streaming bodies are head-only | Yes; unary calls can be schema-aware | Yes; schema-known unary fields or raw request positions |
| **Server-Sent Events** | The response is captured and projected as events | The request can be held; the streaming response cannot | As an HTTP request | As an HTTP request |
| **HTTP/3** | No | No | No | No |

The [Proxy & History guide](/guide/proxy/) explains the buffering, WebSocket, gRPC, and HTTP/3
details. “Full” capture is still subject to the configured body-storage cap: traffic continues
byte-exact after the cap and the flow reports both captured and wire sizes.

## Entry points

| Capability | TUI (`gori`) | Headless (`gori run`) | MCP (`gori mcp`) |
|------------|--------------|-----------------------|-------------------|
| Start a capture proxy | Yes | `gori run capture` | No |
| Own the live intercept queue | Yes | No; headless capture never holds messages | No |
| Inspect or decide a live intercept item | Directly | `gori run intercept`, while a capturing TUI publishes the queue | Intercept tools, while a capturing TUI publishes the queue |
| Read History, Sitemap, Probe findings, Issues, and Notes | Yes | Yes | Yes |
| Replay and active-send requests | Yes | Yes | Yes |
| Run Fuzzer, Miner, Discover, Sequencer, and Authorize engines | Yes | Yes | Yes |
| UI navigation, pane focus, themes, and hotkey editing | Yes | Not applicable | Not applicable |

The exact command and tool inventories live in the [CLI reference](/reference/cli/) and
[MCP guide](/guide/mcp/). MCP starts without a listener and normally attaches to an existing
project; `--read-only` removes mutation and live-request tools as another deliberate surface
difference.

## Current boundaries

- **HTTP/2 body rules can cost the protocol.** A matching Match & Replace body rule, a
  body-scoped extract rule, or a short-circuit rule forces the next connection for that host onto
  HTTP/1.1. An HTTP/2-only client, including gRPC, cannot use that host while the downgrade
  applies. Head rules, Intercept, and the Sandbox stay on h2.
- **RFC 8441 messages cannot be intercepted or rewritten live.** gori captures a WebSocket over
  HTTP/2 and reopens it in Repeater/Fuzzer, but per-message Intercept and Match & Replace on
  messages are HTTP/1.1 only: both would have to reframe a DATA payload to a different length,
  which deadlocks against the peer's flow-control window. Replay dials h2, waits for the
  origin's `SETTINGS_ENABLE_CONNECT_PROTOCOL`, and treats the `2xx` — not a `101` — as the
  socket opening; an origin that does not advertise the setting is a refusal naming it rather
  than an empty transcript.
- **HTTP/3 is outside the proxy.** `network.strip_alt_svc` can remove response fields advertising
  h3, but cannot intercept QUIC or a route learned from DNS.
- **An upstream `https://` spelling is legacy, not TLS to the proxy.** Bare `host:port`,
  `http://…`, and `https://…` currently all mean a plaintext HTTP CONNECT proxy. Origin HTTPS
  still runs inside that tunnel. `socks5://` and `socks5h://` select SOCKS instead.
- **TLS fingerprint presets are approximations.** They control the value-level ClientHello
  fields OpenSSL exposes, but not extension order or GREASE placement, so they do not promise a
  byte-exact browser JA3/JA4 match.

These are capability limits, not permission to send around the active-traffic gate. Keep every
target inside the engagement you are authorised to test.
