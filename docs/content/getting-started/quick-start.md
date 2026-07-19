+++
title = "Quick Start"
description = "A hands-on walkthrough: trust the CA, capture a real request, inspect it, and replay it in Repeater."
+++

This is a follow-along tutorial. Work through it top to bottom and you'll go from a fresh install to a captured HTTPS request that you have inspected, sent to **Repeater**, edited, and re-sent, all without leaving the terminal. Set aside about ten minutes.

Each step ends with a **Checkpoint**: what you should see before moving on. If something looks different, that line is where to stop and fix it.

> **Before you begin.** [Install gori](/getting-started/installation/) and have a browser installed. You'll capture your own browsing, so pick a site you are authorized to test (your own app, a staging box, or a deliberately vulnerable practice target). The examples use a stable throwaway target, `example.com`, for the parts that need an exact result.

## 1. Start gori

With no subcommand, gori starts the proxy and opens the interface:

```bash
gori
```

The first launch runs a short [setup wizard](#first-run-wizard) (global bind and theme), then offers a [guided UI tour](#guided-ui-tour). You can take the tour now or skip it and come back; this page covers the same ground against live traffic.

By default the proxy listens on `127.0.0.1:8070`. Override it for a single run (a project's own bind still wins when set):

```bash
gori --listen 0.0.0.0 --port 8080
```

**Checkpoint.** You're looking at the gori TUI: a row of tabs down the side (Project, Target, History, …) and a top bar showing the proxy address, `127.0.0.1:8070`.

## 2. Trust the CA and capture your first flow

To read HTTPS, the client has to trust gori's root certificate (generated on first run under `~/.gori/ca`). The fastest path is a pre-trusted browser.

### Option A: Open a pre-trusted browser (recommended)

Inside the TUI:

1. Press `Ctrl-P` to open the **command palette**.
2. Type `browser` and run **Open browser**.
3. Pick an installed browser (Chrome, Chromium, Brave, Edge, Firefox, …).

gori launches it with a throwaway profile that already trusts the CA and routes HTTP/HTTPS through the proxy. In that browser, visit a site (try `https://example.com`, then a site you're testing).

### Option B: Point any client yourself

Print the CA path and import that file into your system or browser trust store as a **trusted root CA**:

```bash
gori ca
```

Then set the client's HTTP **and** HTTPS proxy to `127.0.0.1:8070`. Quick smoke test from another terminal:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

gori mints per-host leaf certificates from the root on demand, so you trust the root only once.

> gori's private key is a machine secret, written with `0600` permissions, and never leaves your machine. Rotate it from the palette (**Regenerate CA certificate**) only when you mean to invalidate every prior trust.

**Checkpoint.** Switch to **History** (press `3`). You should see at least one row: your `GET https://example.com/` request with a `200` status. If History is empty, capture isn't reaching gori: recheck the proxy setting (Option B) or use **Open browser** (Option A).

## 3. Learn the two discovery surfaces

Before memorizing tab-specific keys, learn the two places almost everything lives.

| Surface | Key | What it is for |
|---------|-----|----------------|
| **Command palette** | `Ctrl-P` | App-wide control: settings, Open browser, Export CA, jump actions, anything global |
| **Space menu** | `Space` | Actions for whatever has focus right now (History row, detail pane, Repeater, …) |

The palette is the map of the whole tool. The space menu is the map of *this* pane. Both show key hints, so if you forget a chord, open one of them.

<figure class="tui-shot">
  <img src="/images/tui/command-palette.svg" alt="gori command palette open over the History tab, listing settings, navigation and export actions with a filter box">
  <figcaption>The command palette (<kbd>Ctrl-P</kbd>): fuzzy-filter every app-wide action, from settings to <em>Open browser</em> to tab jumps.</figcaption>
</figure>

Three global toggles are worth knowing from the start:

| Key | Action |
|-----|--------|
| `c` | Toggle **capture** (off = traffic passes through without being stored) |
| `i` | Toggle **intercept** (hold matching requests to forward / drop / edit) |
| `s` | Toggle the **scope lens** (filter views to in-scope traffic) |

## 4. Move around the TUI

gori is a row of tabs. The default order starts Project → Target → **History** → Intercept → Repeater → Fuzzer → …

| Key | Action |
|-----|--------|
| `[` / `]` | Previous / next tab |
| `1`-`9` | Jump to the Nth visible tab (with defaults, History is `3`) |
| `Enter` / `↓` | Enter the tab body from the tab bar |
| `Esc` | Pop focus back toward the tab bar |
| `Tab` / `Shift-Tab` | Move focus between the tab bar and panes |

Mouse works when enabled (Preferences → **Editor & Keys** → **Editor**): click a tab, click a row to select, click again to open. The **Help** tab is a full key cheatsheet inside the app when this page isn't open.

## 5. Read a flow in History

Make sure History is active (`3`). Every request/response is a *flow*: start line, headers, body (stored up to 2 MiB), plus HTTP/2 frames, WebSocket messages, and decoded JWT / SAML / GraphQL when present.

<figure class="tui-shot">
  <img src="/images/tui/history.svg" alt="gori History tab listing captured HTTP flows with time, method, protocol, host, path, status, type, size and duration columns">
  <figcaption>The <strong>History</strong> tab: every captured flow with method, status, size and timing, filterable with the query language.</figcaption>
</figure>

Try each of these:

| Key | Action |
|-----|--------|
| `↑` / `↓` (or `j` / `k`) | Move the selection |
| `Enter` | Open request/response detail |
| `/` | Filter with the [query language](/reference/query-language/) |
| `f` | Toggle follow-newest (tail) |
| `y` | Copy the selected flow |

Press `/` and type a filter, then `Enter`:

```text
host:example.com
```

History narrows to that host. Clear the filter (`/`, erase, `Enter`) to see everything again. A few more to try later:

```text
status:5xx
method:POST body:password
```

Now select your `example.com` flow and press `Enter`. In the detail view, scroll with `↑` / `↓`, copy with `y`, and toggle `x` / `b` / `p` for hex / whitespace / pretty bodies. `Esc` returns to the list.

**Checkpoint.** You can filter History down to one host and open a flow to read its full request and response.

## 6. Send it to Repeater and re-send (the core loop)

This is the loop you'll spend most of your time in: take a captured request, change something, send it again, and compare.

1. In **History**, select your `example.com` flow.
2. Press `Ctrl-R`. gori copies it into the **Repeater** tab and switches you there.
3. Press `Enter` or `i` on the request pane to edit (INS mode). Change something small, for example add a header line:
   ```http
   X-Gori-Test: 1
   ```
4. Press `Esc` to leave edit mode, then `Ctrl-R` to **send**.
5. The response, its timing, and a diff against the previous reply appear on the right. `Tab` cycles target → request → response.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="gori Repeater tab showing an editable request pane beside the response pane, with a status line reading replayed 200 in 1152ms">
  <figcaption><strong>Repeater</strong> edits any part of a request and re-sends it; the response, timing, and a diff against the last reply sit side by side.</figcaption>
</figure>

**Checkpoint.** The Repeater status line reads something like `replayed 200 in … ms`, and you can re-send with `Ctrl-R` as many times as you like. That is the full capture → inspect → replay loop.

## 7. Where to go next

You now have the core loop. A few directions from here, each covered in depth in the [Guide](/guide/):

- **Fuzz a parameter.** Select a flow, press `Shift-I` to send it to the **Fuzzer**, mark a position (`Ctrl-A` auto-marks common params), attach a wordlist, and `Ctrl-R` to run. See [Repeater & Fuzzer](/guide/repeater-and-fuzzer/).
- **Intercept and edit in flight.** Press `i` to hold matching requests and forward, drop, or modify them before they continue. See [Proxy & History](/guide/proxy/#intercept).
- **Track what you find.** Turn anything worth reporting into an **Issue** with `Shift-F`, and read passive findings on the **Probe** tab as you browse. See [Scanning & Issues](/guide/scanning/).

## Day-1 key map

Keep this table nearby until the chords stick:

| Key | Where | Action |
|-----|--------|--------|
| `Ctrl-P` | Anywhere | Command palette (settings, Match & Replace, notifications, …) |
| `Ctrl-,` | Anywhere | Preferences (all settings in one modal) |
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

The bind step sets the shared default in `settings.json`, the same layer as Preferences → **Network & Tabs** → **Network**. It is not a per-project lock; pin a different address per engagement from the Project tab when needed.

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
- [Query Language](/reference/query-language/): full filter syntax
- [Hotkeys](/guide/hotkeys/): rebind any of the chords above
