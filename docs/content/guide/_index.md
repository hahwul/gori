+++
title = "Guide"
description = "In-depth guides to the gori workbench: proxy, repeater, fuzzing, scanning, and MCP."
+++

In-depth guides to working with gori. Each tab in the TUI is a focused tool; together they cover a full assessment from capture to report.

## Topics

- **[Proxy & History](/guide/proxy/)**: capture, intercept, scope, import, match & replace, host overrides.
- **[Repeater & Fuzzer](/guide/repeater-and-fuzzer/)**: the request workbench, env tokens, and the Intruder-style fuzzer.
- **[Decoder](/guide/decoder/)**: encode / decode / hash pipeline in the TUI.
- **[Scanning & Issues](/guide/scanning/)**: Probe, Param Miner, Discover (spider & brute-force), Issues, Notes, Comparer.
- **[MCP Server](/guide/mcp/)**: drive gori from an AI agent or script.
- **[Themes](/guide/themes/)**: switch between built-in colour themes or create your own.
- **[Hotkeys](/guide/hotkeys/)**: rebind gori's keyboard shortcuts.

## The Interface at a Glance

gori is organized into tabs; move between them with `[` / `]` or jump with number keys. Two discovery surfaces cover almost everything: `Ctrl-P` opens the **command palette** (app-wide), and `Space` opens the **space menu** (actions for the focused pane). Day-1 chords live in the [Quick Start](/getting-started/quick-start/).

| Tab | Purpose |
|-----|---------|
| **Project** | Home: scope, host overrides, env vars, description, network |
| **Target** | Sitemap (host → path endpoint tree) + Discover (spider & directory brute-force) |
| **History** | Captured (and imported) flows with full request/response detail |
| **Intercept** | Hold requests/responses for a manual decision |
| **Repeater** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (hidden by default) |
| **Decoder** | Encode / decode / hash pipeline |
| **Comparer** | Side-by-side diff of two flows |
| **Probe** | Passive & light-touch active security scanner |
| **Issues** | Triage results by severity and status |
| **Notes** | Per-project Markdown notes |
| **Help** | Key bindings and links |

Global lenses that are not tabs: **Match & Replace** (`m`) rewrites request/response heads and bodies in flight; **capture** (`c`), **intercept** (`i`), and the **scope lens** (`s`) toggle from anywhere.
