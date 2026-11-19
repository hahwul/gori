+++
title = "HTTP Proxy and Web Security Guides"
description = "In-depth gori guides for HTTP interception, Repeater, fuzzing, scanning, and MCP workflows."
weight = 20
+++

## Choose a path {#topics}

New to gori? Run the [Quick Start](/getting-started/quick-start/) first. When you want a task-led walkthrough that crosses several tools, open the [field guide](/playbooks/). The guides here cover one part of the workbench in depth.

## The Interface at a Glance

gori is organized into tabs. Move between them with `[` / `]` or jump with number keys. Two keys reach every action: `Space` opens the **space menu** (what you do most in the focused pane, one letter each), and `Ctrl-P` opens the **command palette** (any action, by typing its name). [Space Menu & Palette](/guide/space-menu-and-palette/) teaches both. Day-1 chords are in the [Quick Start](/getting-started/quick-start/).

| Tab | Purpose |
|-----|---------|
| **Project** | Home: scope, host overrides, env vars, description and tags, network |
| **Target** | Sitemap (host → path endpoint tree) + Discover (spider & directory brute-force) + Diff (retest: two projects at endpoint scale) + Params (parameter inventory per endpoint) |
| **History** | Captured (and imported) flows with full request/response detail |
| **Intercept** | Hold requests/responses for a manual decision |
| **Repeater** | Request workbench (incl. WebSocket & gRPC modes) |
| **Fuzzer** | Intruder-style fuzzer with four attack modes |
| **Miner** | Hidden-parameter discovery (behind `0` by default) |
| **OAST** | Out-of-band callback listener for blind vulnerabilities (behind `0` by default) |
| **Sequencer** | Token randomness / predictability analysis (behind `0` by default) |
| **Decoder** | Encode / decode / hash pipeline (behind `0` by default) |
| **JWT** | Decode, re-sign, and attack JSON Web Tokens (behind `0` by default) |
| **Cookie** | Decode, verify, crack, and re-sign Flask / Rack / Django session cookies (behind `0` by default) |
| **Comparer** | Side-by-side diff of two flows (behind `0` by default) |
| **Rewriter** | Match & Replace rules that rewrite traffic in flight (behind `0` by default) |
| **Colormarker** | Row-colour rules for History, by query (behind `0` by default) |
| **Probe** | Passive & light-touch active security scanner |
| **Authorize** | Replay a request under several identities to find broken access control (behind `0` by default) |
| **Issues** | Triage results by severity and status |
| **Evidence** | Frozen request/response snapshots, project-wide (appears once one exists) |
| **Notes** | Per-project Markdown notes |
| **Help** | Key bindings and links (behind `0`; `?` from anywhere opens its key sheet as a popup) |

The tab bar has nine numbered slots. A fresh install fills them with the tabs you work in
most:

```text
1:Project  2:Target  3:History  4:Intercept  5:Repeater  6:Fuzzer  7:Probe  8:Issues  9:Notes   0:Tabs
```

Press `1`-`9` to jump to a slot and **`0`** to reach any of the other twelve through a
type-to-filter list of the catalog. Behind `0` are the tabs you open now and then
(OAST, Decoder, JWT, Comparer, Rewriter), plus the specialised workbenches (Miner,
Sequencer, Cookie, Colormarker, Authorize) and Help, whose key sheet `?` opens as a popup from anywhere.
**Evidence** is behind `0` as well and is only offered once the project holds its first frozen
snapshot.

Rearrange the nine in Preferences (`Ctrl-,`) → **Network & Tabs** → **Tabs**, or
`settings:tabs` in the palette. The rows above the seam are the nine
slots in order, everything below it is what `0` reaches, and the slot numbers renumber as you
go. `⇧K`/`⇧J` move a row. Moving one up across the seam puts that tab on the bar and pushes the
last slot off. `space` sends a row straight across. For the old
unbounded bar, turn off **Display → Tab bar slots**. `0` keeps working either way.

Outside the tabs, three global lenses toggle from anywhere: **capture** (`c`),
**intercept** (`i`), and the **scope lens** (`s`).
