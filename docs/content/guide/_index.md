+++
title = "Guide"
description = "In-depth guides to the gori workbench — proxy, replay, fuzzing, scanning, and MCP."
+++

In-depth guides to working with gori. Each tab in the TUI is a focused tool; together they cover a full assessment from capture to report.

## Topics

- **[Proxy & History](/guide/proxy/)** — capture, intercept, scope, import, match & replace, host overrides.
- **[Replay & Fuzzer](/guide/replay-and-fuzzer/)** — the request workbench, env tokens, and the Intruder-style fuzzer.
- **[Convert](/guide/convert/)** — encode / decode / hash pipeline in the TUI.
- **[Scanning & Findings](/guide/scanning/)** — Prism, Param Miner, Findings, Notes, Comparer.
- **[MCP Server](/guide/mcp/)** — drive gori from an AI agent or script.
- **[Themes](/guide/themes/)** — switch between built-in colour themes or create your own.
- **[Hotkeys](/guide/hotkeys/)** — rebind gori's keyboard shortcuts.

## The Interface at a Glance

gori is organized into tabs; move between them with `[` / `]` or jump with number keys. Two discovery surfaces cover almost everything: `Ctrl-P` opens the **command palette** (app-wide), and `Space` opens the **space menu** (actions for the focused pane). Day-1 chords live in the [Quick Start](/getting-started/quick-start/).

| Tab | Purpose |
|-----|---------|
| **Project** | Home — scope, host overrides, env vars, description, network |
| **Sitemap** | Deduplicated host → path endpoint tree |
| **History** | Captured (and imported) flows with full request/response detail |
| **Intercept** | Hold requests/responses for a manual decision |
| **Replay** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (hidden by default) |
| **Convert** | Encode / decode / hash pipeline |
| **Comparer** | Side-by-side diff of two flows |
| **Prism** | Passive & active security scanner |
| **Findings** | Triage results by severity and status |
| **Notes** | Per-project Markdown notes |
| **Help** | Key bindings and links |

Global lenses that are not tabs: **Match & Replace** (`m`) rewrites request/response heads in flight; **capture** (`c`), **intercept** (`i`), and the **scope lens** (`s`) toggle from anywhere.
