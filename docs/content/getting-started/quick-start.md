+++
title = "Quick Start"
description = "Start the proxy, trust the CA, capture your first flows, and learn the Day-1 keys."
+++

Get from a fresh build to a full capture → inspect → replay loop in a few minutes. This page is the shortest path through gori's basics; the [Guide](/guide/) goes deeper once traffic is flowing.

## 1. Start gori

Launch the TUI. With no subcommand, gori starts the proxy and opens the interface:

```bash
gori
```

By default the proxy listens on `127.0.0.1:8070`. The first launch runs a short [setup wizard](#first-run-wizard) to pick the bind address and theme, then offers the interactive [UI tour](#guided-ui-tour).

Choose a different address or port with flags:

```bash
gori --listen 0.0.0.0 --port 8080
```

## 2. Trust the CA and get traffic in

To intercept HTTPS, clients must trust gori's root certificate (generated on first run under `~/.gori/ca`). Two common paths:

### Option A — Open a pre-trusted browser (recommended)

Inside the TUI:

1. Press `Ctrl-P` to open the **command palette**.
2. Run **Open browser**.
3. Pick an installed browser (Chrome, Chromium, Brave, Edge, Firefox, …).

gori launches it with an isolated profile that already trusts the CA and routes HTTP/HTTPS through the proxy. Browse a site — flows should land in **History** without a separate system trust step.

Empty History also hints at this path (`^P → Open browser`).

### Option B — Point any client yourself

Print the CA path and import that file into your system or browser trust store as a **trusted root CA**:

```bash
gori export ca-cert
```

Then set the client to use `127.0.0.1:8070` as its HTTP **and** HTTPS proxy. For a quick smoke test:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

gori mints per-host leaf certificates from the root on demand, so you only trust the root once.

> gori's private key is a machine secret — it is written with `0600` permissions and never leaves your machine. Rotate it from the palette (**Regenerate CA certificate**) only when you mean to invalidate every prior trust.

## 3. Learn the two discovery surfaces

Almost everything is reachable from two places. Learn these before memorizing tab-specific keys.

| Surface | Key | What it is for |
|---------|-----|----------------|
| **Command palette** | `Ctrl-P` | App-wide control: settings, Open browser, Export CA, jump actions, anything global |
| **Space menu** | `Space` | Actions for **whatever has focus** right now (History row, detail pane, Replay, …) |

The palette is the map of the whole tool. The space menu is the map of *this* pane. Both show key hints; if you forget a chord, open one of them.

Capture and intercept still have global toggles:

| Key | Action |
|-----|--------|
| `c` | Toggle **capture** (off = traffic passes through without being stored) |
| `i` | Toggle **intercept** (hold matching requests for forward / drop / edit) |
| `s` | Toggle the **scope lens** (filter views to in-scope traffic) |
| `m` | Open **Match & Replace** (rewrite request/response heads in flight) |

## 4. Move around the TUI

gori is a row of **tabs**. Default order starts with Project → Sitemap → **History** → Intercept → Replay → Fuzzer → …

| Key | Action |
|-----|--------|
| `[` / `]` | Previous / next tab |
| `1`–`9` | Jump to the Nth **visible** tab (with defaults, History is `3`) |
| `Enter` / `↓` | Enter the tab body from the tab bar |
| `Esc` | Pop focus back toward the tab bar |
| `Tab` / `Shift-Tab` | Move focus between the tab bar and panes |

Mouse works when enabled (settings): click a tab, click a row to select, click again to open.

The **Help** tab is a full key cheatsheet inside the app — use it when this page is not open.

## 5. Watch flows in History

Switch to **History** (`3`, or `[` / `]` until History is active). Every request/response is a *flow*: start line, headers, body (up to 8 MiB), plus HTTP/2 frames, WebSocket messages, and decoded JWT / SAML / GraphQL when present.

| Key | Action |
|-----|--------|
| `↑` / `↓` (or `j` / `k`) | Move the selection |
| `Enter` | Open request/response detail |
| `/` | Filter with the [query language](/reference/query-language/) |
| `f` | Toggle follow-newest (tail) |
| `y` | Copy the selected flow |

Filter examples once `/` is open:

```text
status:5xx
host:api.example.com
method:POST body:password
```

In detail: scroll with `↑` / `↓`, copy with `y`, and use `x` / `b` / `p` for hex / whitespace / pretty bodies. `Space` still opens the action menu for the focused pane.

## 6. Do something with a flow

Select a flow in History (list or detail), then:

| Key | Action |
|-----|--------|
| `Ctrl-R` | Send the flow to **Replay** (edit and re-send) |
| `Shift-I` | Send the flow to the **Fuzzer** |
| `Shift-F` | Create a **Finding** from it |
| `Space` | Other actions (Comparer, copy, scope host, …) |

### Minimal Replay loop

1. In History, select a flow → `Ctrl-R` (lands in Replay).
2. `Enter` or `i` on the request to edit (INS mode); `Esc` back to READ.
3. `Ctrl-R` again to **send**; inspect the response (timing and diff against the previous reply).
4. `Tab` cycles target → request → response.

### Minimal Fuzzer loop

1. In History, select a flow → `Shift-I`.
2. Mark positions (`Ctrl-A` auto-marks common params, or mark by hand with `§…§`).
3. Attach a wordlist or list in the config pane (`Ctrl-O` focuses it).
4. `Ctrl-R` to run; `Ctrl-X` to stop.

While you browse, **Prism** flags passive issues with no extra traffic. Promote anything worth tracking into **Findings**. Full detail is in [Replay & Fuzzer](/guide/replay-and-fuzzer/) and [Scanning & Findings](/guide/scanning/).

## Day-1 key map

Keep this table nearby until the chords stick:

| Key | Where | Action |
|-----|--------|--------|
| `Ctrl-P` | Anywhere | Command palette |
| `Space` | Focused pane | Area action menu |
| `c` / `i` / `s` / `m` | Anywhere | Capture / intercept / scope lens / match & replace |
| `[` `]` · `1`–`9` | Anywhere | Switch tabs |
| `/` | History | Query-language filter |
| `Enter` | History | Open flow detail |
| `Ctrl-R` | History | → Replay |
| `Shift-I` | History | → Fuzzer |
| `Ctrl-R` | Replay / Fuzzer | Send request / run fuzz |
| `Esc` | Most places | Back out one level |

## First-run wizard

Re-run the guided setup (bind address, then theme) at any time:

```bash
gori wizard
```

## Guided UI tour

A mock-UI walkthrough of tab/pane navigation, the palette, the space menu, and READ/INS edit mode — safe to run without a live proxy session:

```bash
gori tutorial
```

It is also offered at the end of the first-run wizard.

## Next Steps

- [Configuration](/getting-started/configuration/) — storage layout, network settings, and the CA
- [Proxy & History](/guide/proxy/) — capture, intercept, scope, import, match & replace
- [Replay & Fuzzer](/guide/replay-and-fuzzer/) — the testing workbench and env tokens
- [Convert](/guide/convert/) — encode / decode / hash pipeline
- [Query Language](/reference/query-language/) — full filter syntax
- [Hotkeys](/guide/hotkeys/) — rebind any of the chords above
