+++
title = "Quick Start"
description = "Start the proxy, trust the CA, and capture your first request."
+++

Get from a fresh build to live traffic in a couple of minutes.

## 1. Start gori

Launch the TUI. With no subcommand, gori starts the proxy and opens the interface:

```bash
gori
```

By default the proxy listens on `127.0.0.1:8070`. The first launch runs a short [setup wizard](#first-run-wizard) to pick the bind address and theme.

Choose a different address or port with flags:

```bash
gori --listen 0.0.0.0 --port 8080
```

## 2. Trust the Root CA

To intercept HTTPS, your client must trust gori's root certificate. gori generates one on first run and stores it under `~/.gori/ca`. Print its path:

```bash
gori export ca-cert
```

Import that certificate into your system or browser trust store as a **trusted root CA**. gori mints per-host leaf certificates from it on demand, so you only trust it once.

> gori's private key is a machine secret — it is written with `0600` permissions and never leaves your machine.

## 3. Point Your Client at the Proxy

Set your browser or HTTP client to use `127.0.0.1:8070` as its HTTP **and** HTTPS proxy. For quick tests:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

## 4. Watch the Flows Land

Switch to the **History** tab (press `3`, or use `[` / `]` to move between tabs). Every request/response is captured as a *flow* with full detail — headers, bodies, HTTP/2 frames, WebSocket messages, and decoded JWT/SAML/GraphQL where present.

A few keys to get moving:

| Key | Action |
|-----|--------|
| `Ctrl-P` | Open the command palette (everything is reachable here) |
| `c` | Toggle capture on/off |
| `i` | Toggle intercept (hold requests for a decision) |
| `s` | Toggle the scope lens |
| `[` / `]` | Previous / next tab |
| `1`–`9` | Jump to the Nth tab |

## 5. Do Something With a Flow

Select a flow and send it onward:

- **Replay** it in the request workbench to tweak and re-send.
- Feed it to the **Fuzzer** to test parameters with payload sets.
- Let **Prism** flag passive issues automatically as you browse.
- Triage anything interesting into **Findings**.

## First-Run Wizard

You can re-run the guided setup at any time:

```bash
gori wizard
```

## Next Steps

- [Configuration](/getting-started/configuration/) — storage layout and network settings
- [Proxy & History](/guide/proxy/) — capture, intercept, and scope in depth
- [Replay & Fuzzer](/guide/replay-and-fuzzer/) — the testing workbench