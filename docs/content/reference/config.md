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

### Other sections

| Section | Description |
|---------|-------------|
| `theme` | Active theme name (default `goridark`) — see the [Themes guide](/guide/themes/) |
| `mouse` | Mouse support toggle |
| `pretty_bodies` | Pretty-print JSON/XML/etc. bodies in the detail view |
| `editor` | External editor `command` and Markdown handling |
| `tabs` | Which TUI tabs are shown/hidden |
| `hostname_overrides` | `/etc/hosts`-style host → IP overrides for dialing |
| `env` | Environment-variable prefix and values injected into replays |
| `hotkeys` | Keybinding overrides (`os` layer + `bindings`) — see the [Hotkeys guide](/guide/hotkeys/) |
| `convert` / `mine` | Saved defaults for the Convert tool and Param Miner |
| `layout` | History preview + Sitemap expand depth — see [layout](#layout) above |

## Per-Project Overrides

A project can override the network settings without editing the global file. These are stored in the project database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`) and edited from the **Project** tab's settings pane. When present, they take precedence over `settings.json` for that project.

## Projects & Database

Each project is a SQLite database (via `crystal-db` / `crystal-sqlite3`) holding flows, WebSocket messages, scope rules, findings, match rules, HTTP/2 frames, replay and fuzz sessions, host overrides, sitemap tags, miner sessions, and Prism issues, plus a full-text index over flow bodies. Request/response bodies are captured up to 8 MiB. Serve any project's database directly with `--db PATH`, or select a named project with `--project NAME`.
