+++
title = "Guide"
description = "In-depth guides to the gori workbench: proxy, repeater, fuzzing, scanning, and MCP."
weight = 20
+++

## Choose a path {#topics}

New to gori? Run the [Quick Start](/getting-started/quick-start/) first. When you want a task-led walkthrough that crosses several tools, open the [field guide](/playbooks/); use the guides here to understand one part of the workbench in depth.

## The Interface at a Glance

gori is organized into tabs; move between them with `[` / `]` or jump with number keys. Two discovery surfaces cover almost everything: `Ctrl-P` opens the **command palette** (app-wide), and `Space` opens the **space menu** (actions for the focused pane). Day-1 chords live in the [Quick Start](/getting-started/quick-start/).

| Tab | Purpose |
|-----|---------|
| **Project** | Home: scope, host overrides, env vars, description, network |
| **Target** | Sitemap (host → path endpoint tree) + Discover (spider & directory brute-force) + Diff (retest: two projects at endpoint scale) |
| **History** | Captured (and imported) flows with full request/response detail |
| **Intercept** | Hold requests/responses for a manual decision |
| **Repeater** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (hidden by default) |
| **OAST** | Out-of-band callback listener for blind vulnerabilities |
| **Sequencer** | Token randomness / predictability analysis (hidden by default) |
| **Decoder** | Encode / decode / hash pipeline |
| **JWT** | Decode, re-sign, and attack JSON Web Tokens (hidden by default) |
| **Cookie** | Decode, verify, crack, and re-sign Flask / Rack / Django session cookies (hidden by default) |
| **Comparer** | Side-by-side diff of two flows |
| **Rewriter** | Match & Replace rules that rewrite traffic in flight |
| **Colormarker** | Row-colour rules for History, by query (hidden by default) |
| **Probe** | Passive & light-touch active security scanner |
| **Authorize** | Replay a request under several identities to find broken access control (hidden by default) |
| **Issues** | Triage results by severity and status |
| **Notes** | Per-project Markdown notes |
| **Help** | Key bindings and links |

Some tabs are hidden on a fresh install (Miner, Sequencer, Cookie, Colormarker, Authorize) to keep the bar uncluttered; reveal any of them from the tab-bar `⋯` menu, the command palette, or Preferences (`Ctrl-,`) → **Network & Tabs** → **Tabs**. Global lenses that are not tabs: **capture** (`c`), **intercept** (`i`), and the **scope lens** (`s`) toggle from anywhere.
