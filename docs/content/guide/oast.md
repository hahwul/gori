+++
title = "OAST"
description = "Catch out-of-band callbacks (interactsh & friends) to confirm blind SSRF, XXE, and injection."
+++

Some bugs never show up in the response. A blind SSRF, a blind XXE, an out-of-band SQL injection, or a stored payload that only fires in a back-office browser all reach out to *some other server* instead of answering you. **OAST** (Out-of-band Application Security Testing) gives you that server: gori registers a payload URL with an interaction listener, you plant the payload in a request, and any DNS, HTTP, or SMTP callback the target makes to it shows up as a hit.

The **OAST** tab is visible by default (next to Fuzzer). It has two sub-tabs: **Callbacks** (the hits, default) and **Providers** (the listeners you've configured).

<figure class="tui-shot">
  <img src="/images/tui/oast.svg" alt="gori OAST tab listening on an interactsh payload, with a Callbacks table of four decrypted callbacks: two DNS A lookups and two HTTP GET requests, each with a source IP and the payload as destination">
  <figcaption>The <strong>OAST</strong> tab registers a payload and lists every DNS, HTTP, or SMTP callback the target makes to it, decrypted and timestamped.</figcaption>
</figure>

## The Loop

1. On the **OAST** tab, press `Ctrl-R` to start listening. gori registers with a provider and mints a **payload** (a unique hostname/URL).
2. Copy the payload with `g` (get payload) or `y`, or insert it straight into a request from **Repeater** / **Fuzzer** (`Space` → **Insert OAST payload** drops it at the cursor). From **History**, `Space` → **Copy OAST payload**.
3. Plant it wherever the target might dereference a URL or resolve a hostname: a URL parameter, a `Host`/`X-Forwarded-For` header, an XML entity, a webhook field.
4. When the target's infrastructure resolves the name or connects back, the callback lands in **Callbacks** with its protocol (`dns` / `http` / `smtp`), source IP, timestamp, and the full sub-identifier so you can tell which payload fired.

A callback is proof the target reached a server it shouldn't have. No callback is not proof of safety (egress may be filtered), only that this path stayed quiet.

## Providers

Each listener is a **provider**. Add one from the **Providers** sub-tab (`a` add, `e` edit, `t` set type, `d` delete); a public preset auto-fills the server host when you pick its type.

| Provider | What it is |
|----------|-----------|
| `interactsh` | Self-hosted or public [interactsh](https://github.com/projectdiscovery/interactsh) servers. Catches encrypted **DNS, HTTP, and SMTP** callbacks. Public presets: `oast.pro`, `oast.live`, `oast.site`, `oast.fun`, `oast.me`. Default. |
| `custom-http` | A plain HTTP endpoint you control and poll for hits. |
| `webhook.site` | The public [webhook.site](https://webhook.site) service (HTTP only). |
| `BOAST` | A [BOAST](https://github.com/firebasextended/boast) server (public preset `odiss.eu`). |
| `postbin` | A PostBin instance (`postb.in`). |

With interactsh, gori generates an RSA key pair locally, registers the public key, and decrypts each callback (the private key is stored `0600` in the project database and never logged). The payload id is derived locally from the correlation id, so you can mint many payloads from one registration without another round trip.

Callbacks are durable per-project history. A listener can be resumed manually (its key is persisted); there is no automatic resume on restart.

## Keys

| Key | Action |
|-----|--------|
| `Ctrl-R` | Start listening (register a payload and begin polling) |
| `Ctrl-X` | Stop the active listener |
| `g` | Get / copy the current payload |
| `y` | Copy the selected callback |
| `/` | Filter the callback list |
| `a` / `e` / `t` / `d` | Providers sub-tab: add / edit / set type / delete |

## Headless

`gori run oast` is an ad-hoc, store-free listener: it registers a payload, prints it to stdout, then streams callbacks until you stop it.

```bash
gori run oast presets                          # list the built-in public providers
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site   # a different provider
gori run oast listen --once --json             # poll once, emit JSON lines
```

See the [CLI Reference](/reference/cli/#run-oast) for every flag. Over MCP, an agent drives the same engine with `oast_presets` / `oast_payload` / `oast_poll` (read) and `oast_start` / `oast_stop` (action).

> A callback means the target contacted a third-party interaction server, and public interactsh/webhook servers see that callback's metadata. Only run OAST against systems you are authorized to test, and prefer a self-hosted server for sensitive engagements.

## Next Steps

- [Repeater & Fuzzer](/guide/repeater-and-fuzzer/): plant payloads and fuzz them across positions
- [Scanning & Issues](/guide/scanning/): promote a confirmed callback into an Issue
- [MCP Server](/guide/mcp/): let an agent register a payload and poll for hits
