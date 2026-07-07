+++
title = "Configuration"
description = "Where gori stores data, how to configure the network, and the root CA."
+++

gori keeps global preferences in a JSON settings file and stores each project as its own SQLite database. This page covers where everything lives and how to change the essentials.

## The gori Home Directory

Everything gori writes lives under a single tree, `GORI_HOME`. It resolves to `$GORI_HOME` when that environment variable is set and non-empty, otherwise `~/.gori`:

```
~/.gori/
├── settings.json       # Global preferences
├── gori.db             # Default database
├── projects/           # One subdirectory per project, each with its own DB
├── ca/                 # Root CA (root.crt.pem + root.key.pem)
├── themes/             # User themes
├── wordlists/          # Fuzzer / miner wordlists
└── active_project      # Marker for the most-recently-used project
```

Point gori at an isolated home for a session:

```bash
GORI_HOME=/tmp/gori-scratch gori
```

## Global Settings

Global preferences are stored in `settings.json`. Print its path, or open it in `$EDITOR`:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

Persisted sections include `network`, `theme` (default `goridark`), `mouse`, `editor`, `tabs`, `hostname_overrides`, `env`, and `hotkeys`. See the [Configuration Reference](/reference/config/) for the full list of keys.

### Network

The `network` section controls how the proxy binds and whether traffic is forwarded through an upstream proxy:

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `bind_host` | `127.0.0.1` | Address the proxy listens on |
| `bind_port` | `8070` | Port the proxy listens on |
| `upstream_proxy` | `""` | `host:port` HTTP proxy to chain through; empty = direct |

Command-line flags such as `--listen` and `--port` override these per run.

### Theme

gori ships **dark** (`goridark`, the default) and light themes. Switch it from the command palette (`Ctrl-P` → theme) or set `theme` in `settings.json`.

## Per-Project Network Overrides

A project can override the network settings without touching the global file. These overrides are stored in the project's own database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`) and edited from the **Project** tab's settings pane — useful when different engagements need different bind addresses or upstream proxies.

## The Root CA

To intercept HTTPS, clients must trust gori's root certificate, kept in `~/.gori/ca` as `root.crt.pem` and `root.key.pem`.

```bash
gori export ca-cert                  # print the certificate path
gori export ca-cert --ca-dir /path   # use a custom CA directory
```

You can rotate the CA from the TUI command palette (**Regenerate CA certificate**) — this is confirm-gated because it invalidates all previously issued trust. The palette can also open a browser pre-trusting the CA and routed through the proxy.

## Full Reference

See the [Configuration Reference](/reference/config/) for every settings key and the [CLI Reference](/reference/cli/) for all command-line flags.