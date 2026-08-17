+++
title = "OAST"
description = "Catch out-of-band callbacks (interactsh & friends) to confirm blind SSRF, XXE, and injection."
weight = 70

[extra]
group = "Workbenches"
+++

Some bugs never show up in the response. A blind SSRF, a blind XXE, an out-of-band SQL injection, or a stored payload that only fires in a back-office browser all reach out to *some other server* instead of answering you. **OAST** (Out-of-band Application Security Testing) gives you that server: gori registers a payload URL with an interaction listener, you plant the payload in a request, and any DNS, HTTP, or SMTP callback the target makes to it shows up as a hit.

The **OAST** tab is visible by default (next to Fuzzer). It has two sub-tabs: **Callbacks** (the hits, default) and **Providers** (the listeners you've configured).

<figure class="tui-shot">
  <img src="/images/tui/oast.svg" alt="gori OAST tab with a Callbacks table of four decrypted hits on an interactsh payload: two DNS A lookups and two HTTP GET requests, each with a source IP and the payload as destination">
  <figcaption>The <strong>OAST</strong> tab registers a payload and lists every DNS, HTTP, or SMTP callback the target makes to it, decrypted and timestamped.</figcaption>
</figure>

## The Loop

1. On the **OAST** tab, press `Ctrl-R` to start listening. gori registers with a provider and mints a **payload** (a unique hostname/URL).
2. Copy the payload with `g` (get payload) or `y`, or insert it straight into a request from **Repeater** / **Fuzzer** (`Space` → **Insert OAST payload** drops it at the cursor). From **History**, `Space` → **Copy OAST payload**.
3. Plant it wherever the target might dereference a URL or resolve a hostname: a URL parameter, a `Host`/`X-Forwarded-For` header, an XML entity, a webhook field.
4. When the target's infrastructure resolves the name or connects back, the callback lands in **Callbacks** with its protocol (`dns` / `http` / `smtp`), source IP, timestamp, and the full sub-identifier so you can tell which payload fired.

A callback is proof the target reached a server it shouldn't have. The absence of one is not proof of safety (egress may be filtered), only that this path stayed quiet.

## Providers

Each listener is a **provider**. Add one from the **Providers** sub-tab (`a` add, `e` edit, `t` set type, `d` delete); a public preset auto-fills the server host when you pick its type.

The bar above the callbacks table selects which provider `g` and `Ctrl-R` act on — `←` / `→` cycle it (the bar draws the pick as `‹ name ›`), and **All** shows every provider's callbacks at once. Getting a payload or starting a listener needs one provider, so on **All** with two or more providers enabled, `g` and `Ctrl-R` open a picker card; pick a row with `↵` and the bar follows. With a single enabled provider there is nothing to ask, and the action just runs.

| Provider | What it is |
|----------|-----------|
| `interactsh` | Self-hosted or public [interactsh](https://github.com/projectdiscovery/interactsh) servers. Catches encrypted **DNS, HTTP, and SMTP** callbacks. Public presets: `oast.pro`, `oast.live`, `oast.site`, `oast.fun`, `oast.me`. Default. |
| `custom-http` | A plain HTTP endpoint you control and poll for hits. |
| `webhook.site` | The public [webhook.site](https://webhook.site) service (HTTP only). |
| `BOAST` | A [BOAST](https://github.com/firebasextended/boast) server (public preset `odiss.eu`). |
| `postbin` | A PostBin instance (`postb.in`). |

With interactsh, gori generates an RSA key pair locally, registers the public key, and decrypts each callback (the private key is stored `0600` in the project database and never logged). The payload id is derived locally from the correlation id, so you can mint many payloads from one registration without another round trip.

## Resuming a Listener

The callbacks that matter most arrive late: a stored payload that only fires when someone opens a back-office page, a webhook a nightly job replays, an injection behind a queue. So a listener outlives the session that started it.

`Ctrl-X` stops polling but **keeps the registration**, and so does quitting gori or leaving the project. The payloads you already planted keep resolving. Press `r` to open **RESUME LISTENER**, pick a saved session, and gori starts polling it again — every callback the provider buffered while you were away lands on the next poll, and the session's existing callbacks are still there under it.

| Key | In the picker |
|-----|---------------|
| `↵` | Resume polling this session |
| `x` | Release it — deregister the server-side state for a finished engagement. Its callbacks stay. |

Callbacks are durable per-project history. Resume is a deliberate action, not something gori does on startup: reopening a project does not put you back on a third-party provider without asking.

All three surfaces resume the same sessions. `gori run oast list` / `resume` / `release` and the MCP `list_oast_sessions` / `oast_resume` / `oast_release` act on the rows this picker shows, and a resumed headless listener writes its callbacks into the project — so the tab, a script, and an agent are reading one table. What stays ad-hoc is `gori run oast listen` and MCP `oast_start`: they register with no project behind them, and those registrations end with the process.

No surface resumes on its own. Opening a project, binding an MCP server, or starting a `gori run` never re-arms a listener; someone asks for it.

## Keys

| Key | Action |
|-----|--------|
| `Ctrl-R` | Start listening (register a payload and begin polling) |
| `Ctrl-X` | Stop polling (the session is kept — resume it with `r`) |
| `r` | Resume a saved listener |
| `g` | Get / copy the current payload (asks which provider on **All**) |
| `←` / `→` | Cycle the provider the bar acts on |
| `y` | Copy the selected callback |
| `Shift-F` | File the selected callback as an Issue |
| `/` | Filter the callback list |
| `a` / `e` / `t` / `d` | Providers sub-tab: add / edit / set type / delete |

## Filing a Callback

A callback is the strongest evidence this tool produces: the target's own infrastructure reached a server it was never given a reason to reach. `Shift-F` (or `Space` → **Add issue**) files the selected callback as an **Issue**, prefilled with its protocol and source and carrying the raw interaction in as the notes. It opens at **HIGH** — Tab re-rates it before you commit.

## Headless

`gori run oast listen` is an ad-hoc, store-free listener: it registers a payload, prints it to stdout, then streams callbacks until you stop it.

```bash
gori run oast presets                          # list the built-in public providers
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site   # a different provider
gori run oast listen --once --json             # poll once, emit JSON lines
```

The project's saved sessions — the ones the picker above resumes — are reachable headlessly too:

```bash
gori run oast list                             # id, provider, payload host, hits, last poll
gori run oast resume 7                         # re-arm session #7 and stream its callbacks
gori run oast resume 7 --once --json           # one poll, JSON lines, then exit
gori run oast release 7                        # deregister it; its callbacks stay
```

`resume` keeps the registration on exit (Ctrl-C stops polling, nothing more) and persists every callback it catches into the project, so the OAST tab shows the same hits. `release` is the deliberate teardown.

See the [CLI Reference](/reference/cli/#run-oast) for every flag. Over MCP, an agent drives the same engine with `oast_presets` / `oast_payload` / `oast_poll` / `list_oast_sessions` (read) and `oast_start` / `oast_stop` / `oast_resume` / `oast_release` (action). `oast_resume` returns a `session_id` that `oast_poll` and `oast_payload` take, and its polls are persisted like the CLI's; `oast_stop` on a resumed session stops polling but keeps it resumable, exactly as `Ctrl-X` does.

> A callback means the target contacted a third-party interaction server, and public interactsh/webhook servers see that callback's metadata. Only run OAST against systems you are authorized to test, and prefer a self-hosted server for sensitive engagements.

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): plant payloads and fuzz them across positions
- [Scanning & Issues](/guide/scanning/): promote a confirmed callback into an Issue
- [MCP Server](/guide/mcp/): let an agent register a payload and poll for hits
