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

Persisted sections include `network`, `theme` (default `goridark`), `mouse`, `editor`, `tabs`, `layout`, `statusline`, `hostname_overrides`, `env`, `hotkeys`, `convert`, and `mine`. See the [Configuration Reference](/reference/config/) for the full list of keys.

### Network

The `network` section is the **global default** for how the proxy binds and whether traffic is forwarded through an upstream proxy. Projects without their own network overrides inherit these values:

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
| `bind_host` | `127.0.0.1` | Global default listen address |
| `bind_port` | `8070` | Global default listen port |
| `upstream_proxy` | `""` | Global default upstream (`host:port`); empty = direct |

**Precedence** (highest first):

1. **Per-project overrides** (`net.bind_*` in the project DB) — when set, they win for that project only.
2. **CLI flags** (`--listen` / `--port`) — override `settings.json` for the current process only; not written to disk.
3. **`settings.json` `network`** — the shared default (what the first-run wizard and Settings: Network edit).
4. **Factory defaults** — `127.0.0.1:8070` when nothing else is set.

### Theme

gori ships thirteen built-in colour themes (`goridark` is the default) and supports your own JSON themes. Switch it from the command palette (`Ctrl-P` → `settings:theme`) or set `theme` in `settings.json` — see the [Themes guide](/guide/themes/).

### Hotkeys

Every keyboard shortcut is rebindable from the command palette (`Ctrl-P` → `settings:hotkeys`) and persisted under the `hotkeys` key — see the [Hotkeys guide](/guide/hotkeys/).

### Statusline

An opt-in extra row at the bottom of the TUI (command palette → **Settings: Statusline**, or the `statusline` key). When enabled, gori runs a shell command on an interval and shows its (ANSI-coloured) stdout — a customizable status bar inspired by Claude Code's status line. The command receives a JSON snapshot of the live session (project, capture state, flow count, proxy address) on stdin. Disabled by default; see the [Configuration Reference](/reference/config/#statusline) for the keys and the stdin contract.

## Per-Project Network Overrides

A project can pin its own bind address, port, and upstream without touching the global file. These live in the project database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`) and are edited from the **Project** tab's settings pane — useful when different engagements need different ports or upstream proxies.

When a field matches the current global value, gori drops that override so the project keeps inheriting later global changes. Clearing a pin therefore means “use Settings / CLI again,” not “leave the last value frozen forever.”

## The Root CA

To intercept HTTPS, clients must trust gori's root certificate, kept in `~/.gori/ca` as `root.crt.pem` and `root.key.pem`.

```bash
gori ca                       # print the certificate path
gori ca --pem                 # print the PEM to stdout
gori ca --ca-dir /path        # use a custom CA directory
gori ca regenerate --yes      # replace the root CA (scripts/CI; voids prior trust)
```

You can also rotate the CA from the TUI command palette (**Regenerate CA certificate**), or interactively with `gori ca regenerate` (type `regenerate` to confirm). Both paths are confirm-gated because rotation invalidates all previously issued trust; any already-running gori keeps the old CA until restarted.

### Bring your own CA

To reuse one CA across a team or machines, generate a root externally and import it (cert **and** key — gori signs leaf certificates with the key; clients trust only the cert):

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

The same action is available from the palette (**Import CA certificate**). gori checks the key matches the cert and that it is a CA before adopting it. Distribute only `root.crt.pem` to trust; keep `root.key.pem` secret. See [`gori ca import`](/reference/cli/#gori-ca-import).

The palette's **Open browser** action launches an installed browser with an isolated profile that already trusts the CA and routes through the proxy — the fastest path on a fresh machine (see the [Quick Start](/getting-started/quick-start/)).

## Full Reference

See the [Configuration Reference](/reference/config/) for every settings key and the [CLI Reference](/reference/cli/) for all command-line flags.