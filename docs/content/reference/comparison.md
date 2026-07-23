+++
title = "Gori vs Burp Suite, Caido & ZAP"
description = "A feature-by-feature comparison of Gori against Burp Suite, Caido, and OWASP ZAP."
weight = 40
+++

Gori, [Burp Suite](https://portswigger.net/burp), [Caido](https://caido.io), and [OWASP ZAP](https://www.zaproxy.org) all sit between a client and a target as an intercepting proxy. This page compares them feature by feature. Burp Suite has a free Community edition and a paid Professional edition; where they differ, both are noted.

## At a Glance

| | Gori | Burp Suite | Caido | ZAP |
|---|------|------------|-------|-----|
| **Interface** | Terminal (TUI), CLI, MCP | Java desktop GUI | Desktop app / web UI | Java desktop GUI |
| **License / cost** | Free, Apache 2.0 | Community: free. Pro: paid | Free tier. Pro: paid | Free, Apache 2.0 |
| **Platforms** | macOS, Linux | Windows, macOS, Linux | Windows, macOS, Linux | Windows, macOS, Linux, Docker |
| **Extension model** | None (single binary) | BApp Store, Bambdas, BChecks | JS/Python plugins, visual Workflows | Add-on marketplace, scripting |
| **Automation surface** | `gori run` (CLI), MCP server | Extensions API | REST API, Workflows | Automation Framework, API/daemon |

## Feature Matrix

| Capability | Gori | Burp Suite | Caido | ZAP |
|------------|------|------------|-------|-----|
| **Intercepting proxy** | Yes, HTTP/1.1, HTTP/2, WebSocket, gRPC, SSE | Yes, HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE via extensions | Yes, HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE via plugins | Yes, HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE via add-ons |
| **Manual intercept (hold/edit/forward/drop)** | Yes, with a query-language catch condition | Yes | Yes | Yes |
| **Repeater-style workbench** | Yes: Repeater, incl. WebSocket & gRPC modes | Yes: Repeater | Yes: Replay | Yes: Manual Request Editor |
| **Intruder-style fuzzer** | Yes: Fuzzer, 4 modes, headless + MCP | Yes: Intruder (rate-limited in Community) | Yes: Automate | Yes: Fuzzer |
| **Automated vulnerability scanner** | Probe: passive checks + light-touch, safe-method active checks | Pro only: full passive + active scanner | Official Scanner plugin: template-based passive/active checks | Full passive + active scanner (core) |
| **Hidden-parameter discovery** | Yes: Param Miner | Extension (Param Miner BApp) | Plugin | Extension |
| **Spider / content discovery** | Yes: Discover (spider + brute-force, soft-404 calibration) | Yes: crawler (Pro) | Via plugins/Workflows | Yes: 3 spiders (traditional, AJAX, Client) |
| **Match & Replace** | Yes: Rewriter tab, per-project rules | Yes | Yes | Yes (Replacer add-on) |
| **JWT / SAML / GraphQL tooling** | Inline decode for all three; dedicated JWT workbench with re-signing and attack payloads | Extensions (BApp Store) | GraphQL Analyzer plugin; JWT via plugins | Extensions |
| **Out-of-band (OOB) detection** | Yes: built-in OAST tab and listener | Yes: Burp Collaborator | Via third-party OOB services | Via OAST add-on (Interactsh-based) |
| **Token randomness analysis** | Yes: Sequencer | Yes: Sequencer (Pro) | No built-in equivalent | No built-in equivalent |
| **Flow diffing** | Yes: Comparer | Yes: Comparer | Diff view in History | Yes: Compare Requests |
| **Custom detection rules** | Probe custom rules (string/regex matches) | BChecks (Pro) | Custom Scanner checks | Custom scan rules (scripting) |
| **Headless / CI use** | `gori run` mirrors every TUI action | Burp CI / REST API (Enterprise) | Headless mode, REST API | Daemon mode, API, GitHub Actions |
| **AI agent integration** | Native MCP server: read tools + action tools, live intercept co-pilot | Burp AI (Pro) | No native MCP server | No native MCP server |
| **Team collaboration** | No (single-user, local project) | Yes (Pro, shared scans) | Yes (shared projects, real-time sync) | No built-in equivalent |

## Where Gori Differs

- **Terminal-native.** No GUI to run; Gori is one binary, keyboard-driven, and works over SSH.
- **One engine, three entry points.** The TUI, `gori run`, and `gori mcp` drive the same project and database, so a manual session and a scripted or agent-driven one see identical state.
- **MCP is a first-class seam**, not an extension. An agent gets the same tool surface a human has, including a live co-pilot role in Intercept.
- **Probe is deliberately quiet.** Its active checks are safe-method-only and run once per surface. It is not a substitute for Burp's or ZAP's full active scanner.

## Where Gori Doesn't Compete

- No plugin or extension ecosystem. Burp's BApp Store, Caido's plugins, and ZAP's add-on marketplace all outnumber anything Gori ships out of the box.
- No full automated active scanner. Reach for Burp Pro or ZAP if that is the primary workflow.
- No team features: no shared projects, no real-time sync, no built-in reporting beyond Markdown/JSON export.
- No Windows build and no GUI, by design.

## Next Steps

- [Getting Started](/getting-started/): install Gori and capture your first request
- [Scanning & Issues](/guide/scanning/): Probe, Param Miner, and Discover in depth
- [MCP Server](/guide/mcp/): what an AI agent can do inside a Gori project
