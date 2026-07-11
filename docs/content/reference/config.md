+++
title = "Configuration"
description = "The settings.json keys and the GORI_HOME storage layout."
+++

gori stores global preferences in `settings.json` and each project as its own SQLite database. See the [Configuration guide](/getting-started/configuration/) for a walkthrough; this page is the key-by-key reference.

## Storage Layout

Everything lives under `GORI_HOME` — `$GORI_HOME` if set and non-empty, otherwise `~/.gori`:

| Path | Contents |
|------|----------|
| `settings.json` | Global preferences |
| `gori.db` | Default project database |
| `projects/` | One subdirectory per named project, each with its own DB |
| `ca/` | Root CA — `root.crt.pem` and `root.key.pem` |
| `themes/` | User themes |
| `wordlists/` | Fuzzer / miner wordlists |
| `active_project` | Marker for the most-recently-used project |

## settings.json

`settings.json` is JSON. Find or edit it with `gori settings` / `gori settings --edit`.

### network

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bind_host` | string | `127.0.0.1` | Proxy listen address |
| `bind_port` | integer | `8070` | Proxy listen port |
| `upstream_proxy` | string | `""` | `host:port` HTTP proxy to chain through; empty = direct |

### layout

Per-area TUI layout prefs (command palette → **Settings: Layout**). Omitted when both values are factory defaults.

```json
{
  "layout": {
    "history_preview": false,
    "prism_preview": false,
    "findings_preview": false,
    "history_list_order": "newest",
    "sitemap_expand_depth": -1
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `history_preview` | bool | `false` | History list page shows a bottom Req\|Res preview for the selected flow |
| `prism_preview` | bool | `false` | Prism list page shows a bottom summary of the selected issue |
| `findings_preview` | bool | `false` | Findings list page shows a bottom summary of the selected finding |
| `history_list_order` | string | `"newest"` | List sort: `"newest"` (newest at top) or `"oldest"` (oldest at top) |
| `sitemap_expand_depth` | integer | `-1` | How deep the Sitemap tree opens after reload: `-1` = all expanded; `0`–`3` = expand only nodes shallower than this depth |

### statusline

An opt-in extra row at the very bottom of the TUI (command palette → **Settings: Statusline**). When enabled, gori runs a shell command on an interval and renders its stdout as that row — think of it as a customizable status bar, inspired by Claude Code's status line. Disabled by default; the section is omitted from `settings.json` until you change it.

```json
{
  "statusline": {
    "enabled": true,
    "command": "printf 'proj:%s flows:%s' \"$(jq -r .project)\" \"$(jq -r .flows)\"",
    "interval": 3
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Whether the statusline row is shown |
| `command` | string | `""` | Shell command, run via `/bin/sh -c`. Its **first line** of stdout becomes the row |
| `interval` | integer | `3` | Seconds between runs (minimum `1`) |

The command's **stdout is parsed for ANSI/SGR colour escapes** (16-colour, 256-colour, and truecolor, plus bold/underline/etc.), so you can produce coloured segments. Only the first line is used; output is truncated to the terminal width. A run that exceeds `interval` seconds is terminated, and a failing command simply leaves the row blank — it never blocks the UI.

Each run receives a **JSON context on stdin** describing the live session, so scripts can display proxy state without querying gori:

```json
{
  "version": 1,
  "project": "acme",
  "capturing": true,
  "flows": 1234,
  "proxy": { "host": "127.0.0.1", "port": 8070, "addr": "127.0.0.1:8070" },
  "upstream": ""
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | Context schema version (currently `1`) |
| `project` | string | Active project name |
| `capturing` | bool | Whether the proxy is currently capturing |
| `flows` | integer | Number of captured flows |
| `proxy.host` / `proxy.port` / `proxy.addr` | string / integer / string | The address the proxy is actually listening on |
| `upstream` | string | Upstream proxy `host:port`, or empty when connecting directly |

### hostname_overrides

Global dial map (project-level overrides win on collision). Same idea as `/etc/hosts`:

```json
{
  "hostname_overrides": [
    { "host": "api.prod.internal", "ip": "10.0.0.42" }
  ]
}
```

Edit from `Ctrl-P` → **Settings: Hostnames**, or the Project tab for per-project entries. See [Proxy & History](/guide/proxy/#host-overrides).

### env

Tokens like `$TOKEN` expand at send time in Replay, Fuzzer, Miner, Intercept, CLI, and MCP:

```json
{
  "env": {
    "prefix": "$",
    "vars": [
      { "key": "TOKEN", "value": "eyJhbGciOi…" }
    ]
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `prefix` | string | `"$"` | Token prefix (`$KEY`) |
| `vars` | array | `[]` | Global key/value pairs; project vars (Project tab → ENV) override on collision |

See [Environment Variables](/guide/replay-and-fuzzer/#environment-variables).

### Other sections

| Section | Description |
|---------|-------------|
| `theme` | Active theme name (default `goridark`) — see the [Themes guide](/guide/themes/) |
| `mouse` | Mouse support toggle |
| `pretty_bodies` | Pretty-print JSON/XML/etc. bodies in the detail view |
| `editor` | External editor `command` and Markdown handling |
| `tabs` | Which TUI tabs are shown/hidden |
| `hostname_overrides` | Global host → IP dial map — see [hostname_overrides](#hostname_overrides) above |
| `env` | Env-token prefix and global values — see [env](#env) above |
| `hotkeys` | Keybinding overrides (`os` layer + `bindings`) — see the [Hotkeys guide](/guide/hotkeys/) |
| `convert` / `mine` | Saved defaults for the Convert tool and Param Miner |
| `layout` | History / Prism / Findings previews + Sitemap expand depth — see [layout](#layout) above |
| `statusline` | Bottom status row that runs a command on an interval — see [statusline](#statusline) above |

## Per-Project Overrides

A project can override the network settings without editing the global file. These are stored in the project database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`) and edited from the **Project** tab's settings pane. When present, they take precedence over `settings.json` for that project.

## Projects & Database

Each project is a SQLite database (via `crystal-db` / `crystal-sqlite3`) holding flows, WebSocket messages, scope rules, findings, match rules, HTTP/2 frames, replay and fuzz sessions, host overrides, sitemap tags, miner sessions, and Prism issues, plus a full-text index over flow bodies. Request/response bodies are captured up to 8 MiB. Serve any project's database directly with `--db PATH`, or select a named project with `--project NAME`.
