+++
title = "Guide"
description = "In-depth guides to the gori workbench: proxy, repeater, fuzzing, scanning, and MCP."
weight = 20
+++

In-depth guides to working with gori. Each tab in the TUI is a focused tool; together they cover a full assessment from capture to report.

## Topics

**Core** — the capture-to-triage workflow:

- **[Proxy & History](/guide/proxy/)**: capture, intercept, scope, import, match & replace, host overrides.
- **[Repeater & Fuzzer](/guide/repeater-and-fuzzer/)**: the request workbench, env tokens, and the Intruder-style fuzzer.
- **[Scanning & Issues](/guide/scanning/)**: Probe, Param Miner, Discover (spider & brute-force), Issues, Notes, Comparer.

**Workbenches** — focused, single-purpose analysis tools:

- **[Decoder](/guide/decoder/)**: encode / decode / hash pipeline in the TUI.
- **[JWT](/guide/jwt/)**: decode, re-sign, and attack JSON Web Tokens.
- **[Sequencer](/guide/sequencer/)**: grade the randomness of session and CSRF tokens.
- **[OAST](/guide/oast/)**: catch out-of-band callbacks to confirm blind vulnerabilities.

**Automation**:

- **[MCP Server](/guide/mcp/)**: drive gori from an AI agent or script.

**Customize**:

- **[Settings](/guide/settings/)**: the Preferences modal and every section in it.
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
| **Rewriter** | Match & Replace rules that rewrite traffic in flight (hidden by default) |
| **Repeater** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (hidden by default) |
| **OAST** | Out-of-band callback listener for blind vulnerabilities |
| **Sequencer** | Token randomness / predictability analysis (hidden by default) |
| **Decoder** | Encode / decode / hash pipeline |
| **JWT** | Decode, re-sign, and attack JSON Web Tokens (hidden by default) |
| **Comparer** | Side-by-side diff of two flows |
| **Probe** | Passive & light-touch active security scanner |
| **Issues** | Triage results by severity and status |
| **Notes** | Per-project Markdown notes |
| **Help** | Key bindings and links |

Some tabs are hidden on a fresh install (Rewriter, Miner, Sequencer, JWT) to keep the bar uncluttered; reveal any of them from the tab-bar `⋯` menu, the command palette, or Preferences (`Ctrl-,`) → **Network & Tabs** → **Tabs**. Global lenses that are not tabs: **capture** (`c`), **intercept** (`i`), and the **scope lens** (`s`) toggle from anywhere.
