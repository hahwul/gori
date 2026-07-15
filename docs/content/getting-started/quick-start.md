+++
title = "Quick Start"
description = "Start the proxy, trust the CA, capture your first flows, and learn the Day-1 keys."
+++

Get from a fresh build to a full capture → inspect → repeater loop in a few minutes. This page is the shortest path through gori's basics; the [Guide](/guide/) goes deeper once traffic is flowing.

## 1. Start gori

Launch the TUI. With no subcommand, gori starts the proxy and opens the interface:

```bash
gori
```

By default the proxy listens on `127.0.0.1:8070`. The first launch runs a short [setup wizard](#first-run-wizard) to pick the global default bind and theme, then offers the interactive [UI tour](#guided-ui-tour). Individual projects can pin a different bind later in the Project tab.

Override the global bind for a single run with flags (not written to disk; a project's own bind still wins when set):

```bash
gori --listen 0.0.0.0 --port 8080
```

## 2. Trust the CA and get traffic in

To intercept HTTPS, clients must trust gori's root certificate (generated on first run under `~/.gori/ca`). Two common paths:

### Option A: Open a pre-trusted browser (recommended)

Inside the TUI:

1. Press `Ctrl-P` to open the **command palette**.
2. Run **Open browser**.
3. Pick an installed browser (Chrome, Chromium, Brave, Edge, Firefox, …).

gori launches it with an isolated profile that already trusts the CA and routes HTTP/HTTPS through the proxy. Browse a site. Flows should land in **History** without a separate system trust step.

Empty History also hints at this path (`^P → Open browser`).

### Option B: Point any client yourself

Print the CA path and import that file into your system or browser trust store as a **trusted root CA**:

```bash
gori ca
```

Then set the client to use `127.0.0.1:8070` as its HTTP **and** HTTPS proxy. For a quick smoke test:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

gori mints per-host leaf certificates from the root on demand, so you only trust the root once.

> gori's private key is a machine secret. It is written with `0600` permissions and never leaves your machine. Rotate it from the palette (**Regenerate CA certificate**) only when you mean to invalidate every prior trust.

## 3. Learn the two discovery surfaces

Almost everything is reachable from two places. Learn these before memorizing tab-specific keys.

| Surface | Key | What it is for |
|---------|-----|----------------|
| **Command palette** | `Ctrl-P` | App-wide control: settings, Open browser, Export CA, jump actions, anything global |
| **Space menu** | `Space` | Actions for whatever has focus right now (History row, detail pane, Repeater, …) |

The palette is the map of the whole tool. The space menu is the map of *this* pane. Both show key hints; if you forget a chord, open one of them.

<figure class="tui-shot">
  <img src="/images/tui/command-palette.svg" alt="gori command palette open over the History tab, listing settings, navigation and export actions with a filter box">
  <figcaption>The command palette (<kbd>Ctrl-P</kbd>): fuzzy-filter every app-wide action, from settings to <em>Open browser</em> to tab jumps.</figcaption>
</figure>

Capture and intercept still have global toggles:

| Key | Action |
|-----|--------|
| `c` | Toggle **capture** (off = traffic passes through without being stored) |
| `i` | Toggle **intercept** (hold matching requests for forward / drop / edit) |
| `s` | Toggle the **scope lens** (filter views to in-scope traffic) |
| `Ctrl-P` → Match & Replace | In-flight request/response rewrite rules (palette; rebindable) |

## 4. Move around the TUI

gori is a row of **tabs**. Default order starts with Project → Sitemap → **History** → Intercept → Repeater → Fuzzer → …

| Key | Action |
|-----|--------|
| `[` / `]` | Previous / next tab |
| `1`-`9` | Jump to the Nth visible tab (with defaults, History is `3`) |
| `Enter` / `↓` | Enter the tab body from the tab bar |
| `Esc` | Pop focus back toward the tab bar |
| `Tab` / `Shift-Tab` | Move focus between the tab bar and panes |

Mouse works when enabled (settings): click a tab, click a row to select, click again to open.

The **Help** tab is a full key cheatsheet inside the app. Use it when this page is not open.

## 5. Watch flows in History

Switch to **History** (`3`, or `[` / `]` until History is active). Every request/response is a *flow*: start line, headers, body (stored up to 2 MiB), plus HTTP/2 frames, WebSocket messages, and decoded JWT / SAML / GraphQL when present.

<figure class="tui-shot">
  <img src="/images/tui/history.svg" alt="gori History tab listing captured HTTP flows with time, method, protocol, host, path, status, type, size and duration columns">
  <figcaption>The <strong>History</strong> tab: every captured flow with method, status, size and timing, filterable with the query language.</figcaption>
</figure>

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
| `Ctrl-R` | Send the flow to **Repeater** (edit and re-send) |
| `Shift-I` | Send the flow to the **Fuzzer** |
| `Shift-F` | Create a **Issue** from it |
| `Space` | Other actions (Comparer, copy, scope host, …) |

### Minimal Repeater loop

1. In History, select a flow → `Ctrl-R` (lands in Repeater).
2. `Enter` or `i` on the request to edit (INS mode); `Esc` back to READ.
3. `Ctrl-R` again to **send**; inspect the response (timing and diff against the previous reply).
4. `Tab` cycles target → request → response.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="gori Repeater tab showing an editable request pane beside the response pane, with a status line reading replayed 200 in 1152ms">
  <figcaption><strong>Repeater</strong> edits any part of a request and re-sends it; the response, timing, and a diff against the last reply sit side by side.</figcaption>
</figure>

### Minimal Fuzzer loop

1. In History, select a flow → `Shift-I`.
2. Mark positions (`Ctrl-A` auto-marks common params, or mark by hand with `§…§`).
3. Attach a wordlist or list in the config pane (`Ctrl-O` focuses it).
4. `Ctrl-R` to run; `Ctrl-X` to stop.

While you browse, **Probe** flags passive issues with no extra traffic. Promote anything worth tracking into **Issues**. Full detail is in [Repeater & Fuzzer](/guide/repeater-and-fuzzer/) and [Scanning & Issues](/guide/scanning/).

## Day-1 key map

Keep this table nearby until the chords stick:

| Key | Where | Action |
|-----|--------|--------|
| `Ctrl-P` | Anywhere | Command palette (settings, Match & Replace, notifications, …) |
| `Space` | Focused pane | Area action menu |
| `c` / `i` / `s` | Anywhere | Capture / intercept / scope lens |
| `[` `]` · `1`-`9` | Anywhere | Switch tabs |
| `/` | History | Query-language filter |
| `Enter` | History | Open flow detail |
| `Ctrl-R` | History | → Repeater |
| `Shift-I` | History | → Fuzzer |
| `Ctrl-R` | Repeater / Fuzzer | Send request / run fuzz |
| `Esc` | Most places | Back out one level |

## First-run wizard

Re-run the guided setup (global proxy bind default, then theme) at any time:

```bash
gori wizard
```

The bind step sets the shared default in `settings.json`, the same layer as **Settings: Network**. It is not a per-project lock; pin a different address per engagement from the Project tab when needed.

## Guided UI tour

A mock-UI walkthrough of tab/pane navigation, the palette, the space menu, and READ/INS edit mode. It is safe to run without a live proxy session. Each lesson shows a short demo and asks you to try the real key; the final step is a hands-on sandbox for all four moves, then a first-session checklist.

```bash
gori tutorial
```

<figure class="tui-shot">
  <img src="/images/tui/tutorial.svg" alt="gori guided tour welcome card explaining the four core moves: tabs and panes, the command palette, the action menu, and edit mode">
  <figcaption>The guided tour walks through tabs and panes, the palette, the space menu, and READ / INS edit mode. Try each key, then practice all four in a harmless sandbox.</figcaption>
</figure>

It is also offered at the end of the first-run wizard.

## Next Steps

- [Configuration](/getting-started/configuration/): storage layout, network settings, and the CA
- [Proxy & History](/guide/proxy/): capture, intercept, scope, import, match & replace
- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): the testing workbench and env tokens
- [Decoder](/guide/decoder/): encode, decode, and hash pipeline
- [Query Language](/reference/query-language/): full filter syntax
- [Hotkeys](/guide/hotkeys/): rebind any of the chords above
