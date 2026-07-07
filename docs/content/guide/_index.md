+++
title = "Guide"
description = "In-depth guides to the gori workbench — proxy, replay, fuzzing, scanning, and MCP."
+++

In-depth guides to working with gori. Each tab in the TUI is a focused tool; together they cover a full assessment from capture to report.

## Topics

- **[Proxy & History](/guide/proxy/)** — capture traffic, intercept requests, scope your target, and inspect protocols.
- **[Replay & Fuzzer](/guide/replay-and-fuzzer/)** — the request workbench and the Intruder-style fuzzer.
- **[Scanning & Findings](/guide/scanning/)** — the Prism scanner, the Param Miner, and triaging findings.
- **[MCP Server](/guide/mcp/)** — drive gori from an AI agent or script.
- **[Themes](/guide/themes/)** — switch between built-in colour themes or create your own.
- **[Hotkeys](/guide/hotkeys/)** — rebind gori's keyboard shortcuts.

## The Interface at a Glance

gori is organized into tabs; move between them with `[` / `]` or jump with number keys. `Ctrl-P` opens the command palette, which can reach every action and setting.

| Tab | Purpose |
|-----|---------|
| **Project** | Home tab — scope rules, per-project settings, totals |
| **Sitemap** | Deduplicated host → path endpoint tree |
| **History** | Captured flows with full request/response detail |
| **Intercept** | Hold requests/responses for a manual decision |
| **Replay** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (hidden by default) |
| **Convert** | Encode / decode / hash scratch tool |
| **Comparer** | Side-by-side diff of two flows |
| **Prism** | Passive & active security scanner |
| **Findings** | Triage results by severity and status |
| **Notes** | Per-project notes |
| **Help** | Key bindings and links |