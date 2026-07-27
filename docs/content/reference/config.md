+++
title = "Configuration"
description = "The settings.json keys and the GORI_HOME storage layout."
weight = 20
+++

gori stores global preferences in `settings.json` and each project as its own SQLite database. See the [Configuration guide](/getting-started/configuration/) for a walkthrough; this page is the key-by-key reference.

## Storage Layout

Everything lives under `GORI_HOME` (`$GORI_HOME` if set and non-empty, otherwise `~/.gori`):

| Path | Contents |
|------|----------|
| `settings.json` | Global preferences |
| `gori.db` | Default project database |
| `projects/` | One subdirectory per named project, each with its own DB |
| `ca/` | Root CA: `root.crt.pem` and `root.key.pem` |
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
| `bind_host` | string | `127.0.0.1` | Global default listen address (used when a project has no `net.bind_host`) |
| `bind_port` | integer | `8070` | Global default listen port (used when a project has no `net.bind_port`) |
| `upstream_proxy` | string | `""` | Global default upstream (`host:port`); empty = direct. Project `net.upstream_proxy` wins when set |
| `verify_upstream` | bool | `true` | Verify upstream TLS certificates against the system CA trust store, resolved automatically from standard locations (honouring `SSL_CERT_FILE` / `SSL_CERT_DIR`); if none is found, HTTPS verification fails — set `SSL_CERT_FILE` or turn this off. Toggling it re-syncs the running proxy, the active prober, and the Repeater / Fuzzer / Miner senders without a restart. `--insecure-upstream` seeds it off for one session |
| `serve_landing` | bool | `true` | Serve the built-in info / CA-download page, both when the listen address is hit directly and at the reserved host `http://gori.proxy/` (or `http://gori/`) for a client already pointed at the proxy |
| `connect_timeout_secs` | integer | `30` | Upstream connect timeout in seconds (minimum `1`) |
| `io_timeout_secs` | integer | `30` | Upstream read / write idle timeout in seconds (minimum `1`) |
| `capture_max_mib` | integer | `2` | Largest body stored per message, in MiB. Larger bodies still forward byte-exact; only the stored copy is truncated, and the true wire size is recorded |
| `http2` | string | `"auto"` | `auto` reflects the origin's ALPN; `off` forces HTTP/1.1 on every tunnelled connection. See [http2](#http2) below |
| `tls_passthrough` | array | `[]` | Hosts to relay without decrypting. See [tls_passthrough](#tls_passthrough) below |

CLI `--listen` / `--port` override these for the current process only (not written to disk). See [Per-Project Overrides](#per-project-overrides).

#### http2

`auto` (the default) reflects the origin's ALPN: gori advertises HTTP/2 to the client only when the origin speaks it. `off` never advertises it, so every tunnelled connection takes the HTTP/1.1 path.

Pinning the version matters because h1-vs-h2 differences are often the *subject* of a test — request framing, header-name handling, smuggling — and holding the protocol constant is how the difference gets isolated.

Before this setting, the only lever was an implementation detail: gori downgrades to HTTP/1.1 when Match & Replace rules are live, so the way to force h1 was to enable a no-op rule. That also turned on head rewriting, and was easy to leave behind.

`off` takes effect on the next tunnelled connection, and skips the origin ALPN probe entirely (one fewer connection per origin). It does **not** override the downgrades gori performs for correctness — the Sandbox, per-host interception, and live Match & Replace rules still force HTTP/1.1 regardless, because the HTTP/2 relay genuinely bypasses those seams. A cleartext-HTTP/2 (`h2c`) tunnel inside `CONNECT` is refused rather than relayed when `off`: the client has already committed to h2 by sending the preface, so there is nothing to downgrade.

There is no `force` mode. It would need a defined fallback for an origin that turns out not to speak HTTP/2, and no need for it has come up; the string form leaves room to add it without a compatibility shim.

#### tls_passthrough

A CONNECT whose host matches is answered `200` and then relayed as an opaque byte tunnel: no certificate is minted for it, nothing is decrypted, and nothing is captured. The client validates the origin's own certificate, exactly as if gori were not in the path.

This is the escape hatch for a client that pins certificates — a mobile app, an auto-updater, a desktop agent — sharing the proxy with your actual target. Without it, that traffic breaks. Scope does not help here: scope decides what is *recorded* and acted on, never whether TLS is intercepted, so an out-of-scope host is still decrypted.

```json
{
  "network": {
    "tls_passthrough": ["updates.example.com", "*.push.apple.com"]
  }
}
```

Patterns use the same dialect as scope `host` rules: `example.com` covers that host **and its subdomains**, `*.push.example.com` is a glob (subdomains only, not the bare host), and an IPv6 literal matches bracketed or bare. Matching is case-insensitive. Entries are bare hosts — a scheme, a path, or a `:port` is rejected when you save, because such an entry could never match.

Empty (the default) means everything is intercepted, which is how gori behaved before this setting existed. Plaintext HTTP is unaffected: there is no TLS there to pass through.

Because a bypassed host produces no flow, gori writes one line to its log the first time each host is relayed, so a host missing from History has a traceable reason. Edit the list from Preferences → **Network & Tabs** → **Network** → **TLS passthrough** (comma-separated).

### upstream_rules

Per-destination upstream routing. `network.upstream_proxy` is a single address for *everything*; a rule table can say "route `*.corp.internal` through the internal proxy, everything else direct", carry credentials, and reach a SOCKS proxy.

Rules are **ordered** and the **first match wins**, so specific rules go above general ones. Edit them with `gori settings --edit`.

```json
{
  "upstream_rules": [
    { "host": "intranet.corp.internal", "kind": "direct" },
    {
      "host": "*.corp.internal",
      "kind": "http",
      "addr": "proxy.corp.internal:3128",
      "username": "alice",
      "password_env": "CORP_PROXY_PASS"
    },
    { "host": "*.onion", "kind": "socks5", "addr": "127.0.0.1:9050" }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | Host pattern, same dialect as scope `host` rules: `corp.internal` covers that host and its subdomains, `*.corp.internal` is a glob, `*` is the catch-all. Case-insensitive |
| `kind` | string | `direct`, `http`, or `socks5`. An unknown kind drops the rule rather than being treated as `direct`, which would quietly disable an intended proxy |
| `addr` | string | Proxy `host:port`. Port defaults to `8080` for `http` and `1080` for `socks5`. Must be absent for `direct` |
| `username` | string | Optional. Sent as HTTP Basic (RFC 7617) for `http`, or via the RFC 1929 exchange for `socks5` |
| `password_env` | string | Optional. The **name** of an OS environment variable holding the password |

**Credentials are never stored in `settings.json`.** Only the username and the environment-variable *name* are written; the password is read from the OS environment at dial time, so `export CORP_PROXY_PASS=…` takes effect without a restart. gori's own `env` section is deliberately not used for this — those variables live in `settings.json` in plaintext, which would put the secret in the file by another route and defeat sharing or exporting a config (see [#439](https://github.com/hahwul/gori/issues/439)). A `password_env` containing `$` is rejected: it holds a variable name, not a value.

For `socks5`, a hostname target is sent as `ATYP DOMAIN` so the **proxy** resolves it (the `socks5h` behaviour). That is what makes Tor and a jump host into an otherwise unreachable network work; gori does not resolve names on the dial path itself.

Precedence, highest first:

| Priority | Source |
|----------|--------|
| 1 (highest) | Project `net.upstream_proxy` — an explicit per-project pin, which bypasses the table wholesale |
| 2 | `upstream_rules`, first host match |
| 3 | `network.upstream_proxy` — the implicit catch-all |
| 4 (lowest) | Direct |

A rule is matched against the **original** hostname, before any [host override](#hostname_overrides) is applied — an override only changes which IP is dialled.

### outbound_tls

Per-destination TLS policy for the connections gori **makes**: a client certificate to present, and the protocol/cipher floor to negotiate with. Ordered, first match wins, same host-pattern dialect. Edit with `gori settings --edit`.

This is a separate table from [`upstream_rules`](#upstream_rules) on purpose. Both are keyed by destination host, but they answer different questions, and folding them together would make the common shape inexpressible — "everything through the corporate proxy, plus a client certificate for one host" would need the proxy address duplicated onto that host's row, because one first-match table can only apply a single row per host.

```json
{
  "outbound_tls": [
    {
      "host": "mtls.example.com",
      "client_cert": "/home/you/certs/client.crt.pem",
      "client_key": "/home/you/certs/client.key.pem"
    },
    {
      "host": "legacy-appliance.internal",
      "min_version": "tls1.0",
      "ciphers": "ALL:@SECLEVEL=0",
      "permissive": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | Host pattern, as in `upstream_rules`. `*` is the catch-all |
| `client_cert` | string | Path to a PEM certificate chain to present (mutual TLS) |
| `client_key` | string | Path to the matching PEM private key. Both halves are required, or neither |
| `min_version` | string | Lowest protocol to negotiate: `tls1.0`, `tls1.1`, `tls1.2`, `tls1.3`. Empty leaves the default |
| `ciphers` | string | OpenSSL cipher list for TLS 1.2 and below. Empty leaves the default |
| `permissive` | bool | Talk to broken/legacy servers: drops the OpenSSL security level to 0 and allows renegotiation |

**Why `min_version` exists.** gori cannot reach a TLS 1.0/1.1-only appliance out of the box, and `verify_upstream: false` does not help — that turns off certificate *verification*, not protocol negotiation. Crystal's TLS client context disables TLS 1.0 and 1.1 in its constructor, so lowering the floor here is the only way. A legacy appliance usually needs `permissive: true` as well, because distributions build OpenSSL at a security level that rejects the old cipher suites outright.

**Certificates are file paths, not inline material.** A private key does not belong in `settings.json`, which is shareable and exportable ([#439](https://github.com/hahwul/gori/issues/439)). A passphrase-protected key is rejected at save time: OpenSSL would prompt for the passphrase on the terminal the TUI owns, so gori would simply appear to hang. Decrypt it first with `openssl pkey -in key.pem -out plain.pem`.

The policy is looked up on the **dialled** host, not on an SNI override — a certificate and a protocol floor belong to the machine actually being talked to, whereas the Repeater's SNI field deliberately lies about the name for domain-fronting and vhost tests.

### layout

Per-area TUI layout prefs (command palette → **Settings: Layout**). Omitted when both values are factory defaults.

```json
{
  "layout": {
    "history_preview": false,
    "probe_preview": false,
    "issues_preview": false,
    "history_list_order": "newest",
    "sitemap_expand_depth": -1
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `history_preview` | bool | `false` | History list page shows a bottom Req\|Res preview for the selected flow |
| `probe_preview` | bool | `false` | Probe list page shows a bottom summary of the selected issue |
| `issues_preview` | bool | `false` | Issues list page shows a bottom summary of the selected issue |
| `history_list_order` | string | `"newest"` | List sort: `"newest"` (newest at top) or `"oldest"` (oldest at top) |
| `sitemap_expand_depth` | integer | `-1` | How deep the Sitemap tree opens after reload: `-1` = all expanded; `0`-`3` = expand only nodes shallower than this depth |

### statusline

An opt-in extra row at the very bottom of the TUI (Preferences → **General** → **Statusline**). When enabled, gori runs a shell command on an interval and renders its stdout as that row. Think of it as a customizable status bar, inspired by Claude Code's status line. Disabled by default; the section is omitted from `settings.json` until you change it.

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
| `command` | string | `""` | Shell command, run via `/bin/sh -c`. Its first line of stdout becomes the row |
| `interval` | integer | `3` | Seconds between runs (minimum `1`) |

The command's stdout is parsed for ANSI/SGR colour escapes (16-colour, 256-colour, and truecolor, plus bold/underline/etc.), so you can produce coloured segments. Only the first line is used; output is truncated to the terminal width. A run that exceeds `interval` seconds is terminated, and a failing command simply leaves the row blank. It never blocks the UI.

Each run receives a JSON context on stdin describing the live session, so scripts can display proxy state without querying gori:

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

### display

Message-body and chrome prefs (command palette → **Settings: Display**). Omitted when every value is a factory default.

```json
{
  "display": {
    "detail_pane": "request",
    "history_time_format": "absolute",
    "show_gutter": true,
    "preview_body_kib": 64,
    "resource_meter": true,
    "terminal_title": "project"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `detail_pane` | string | `"request"` | Which pane a freshly-opened History flow shows first: `"request"` or `"response"` |
| `history_time_format` | string | `"absolute"` | History list time column: `"absolute"` (MM-DD HH:MM:SS) or `"relative"` (3s/5m/2h) |
| `show_gutter` | bool | `true` | Line-number gutter on the message body views |
| `preview_body_kib` | integer | `64` | How many body bytes the History list preview reads (display only, not the capture limit) |
| `resource_meter` | bool | `true` | CPU/memory readout for gori's own process, at the far right of the bottom bar |
| `terminal_title` | string | `"project"` | Terminal window title: `"project"` → `Gori - <project> - <tab>`, `"tab"` → `Gori - <tab>`, `"off"` → gori never writes the title (leave it to your shell or tmux) |

### hostname_overrides

Global dial map (project-level overrides win on collision). Same idea as `/etc/hosts`:

```json
{
  "hostname_overrides": [
    { "host": "api.prod.internal", "ip": "10.0.0.42" }
  ]
}
```

Edit from Preferences → **Network & Tabs** → **Network** → **Hostname overrides**, or the Project tab for per-project entries. See [Proxy & History](/guide/proxy/#host-overrides).

### env

Tokens like `$TOKEN` expand at send time in Repeater, Fuzzer, Miner, Intercept, CLI, and MCP:

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

See [Environment Variables](/guide/repeater-and-fuzzer/#environment-variables).

### general

Preferences → **General** → **General**:

```json
{
  "general": {
    "clipboard_osc52": true,
    "confirm_quit": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `clipboard_osc52` | bool | `true` | Copy through the OSC 52 terminal escape, so `y` reaches your local clipboard over SSH |
| `confirm_quit` | bool | `false` | Ask before quitting |

### notifications

How background jobs (Miner, Fuzzer, Probe, Discover) announce their results. Preferences → **General** → **Notifications**:

```json
{
  "notifications": {
    "bell": false,
    "toast": true,
    "retention": 100
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell` | bool | `false` | Ring the terminal bell when a background job produces a result |
| `toast` | bool | `true` | Show a transient toast for the same events |
| `retention` | integer | `100` | How many notifications the notification center keeps |

### probe

```json
{
  "probe": {
    "active_notify": "when-found"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `active_notify` | string | `"when-found"` | When an active scan notifies: `"when-found"`, `"always"`, or `"off"` |

### discover

Saved defaults for a Discover run. Written only once you save the discover options, so the section is absent until then:

```json
{
  "discover": {
    "containment": "scope-aware",
    "max_depth": 4,
    "concurrency": 20,
    "spider": true,
    "bruteforce": true,
    "extensions": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `containment` | string | `"scope-aware"` | How far a run may wander: `"same-origin"`, `"scope-aware"`, or `"host+subdomains"` |
| `max_depth` | integer | `4` | Spider depth cap |
| `concurrency` | integer | `20` | Parallel requests |
| `spider` | bool | `true` | Follow links found in responses |
| `bruteforce` | bool | `true` | Brute-force paths from the wordlist |
| `extensions` | bool | `false` | Also probe extension variants of each candidate |

### mine

Saved Param Miner defaults, written only once you save the mine options:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `locations` | array | `[]` | Where to inject: `query`, `form`, `multipart`, `json`, `headers`, `cookies`. Empty means auto-detect per request |
| `concurrency` | integer | `10` | Parallel requests |
| `notify` | string | `"when-found"` | `"when-found"`, `"always"`, or `"off"` |

### scan_rules

Your own Probe match rules, global across every project. Project-scoped rules live in the project database instead. Edit them in Probe → **Rules** → CUSTOM:

```json
{
  "scan_rules": [
    {
      "id": "a1b2c3d4",
      "title": "Internal hostname leak",
      "description": "Build-server hostname in a response body",
      "side": "response",
      "region": "body",
      "kind": "regex",
      "pattern": "build-\\d+\\.corp\\.internal",
      "severity": "medium",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | Random hex token assigned at creation |
| `title` | string | Finding title |
| `description` | string | Shown in the finding detail |
| `side` | string | `request` or `response` |
| `region` | string | `whole`, `header`, or `body` |
| `kind` | string | `string` or `regex` |
| `pattern` | string | Literal or regex to match |
| `severity` | string | `info`, `low`, `medium`, `high`, or `critical` |
| `enabled` | bool | Whether the rule runs |

Parsing is tolerant. An entry missing `id`, `title`, or `pattern` is dropped, and an out-of-range `side` / `region` / `kind` / `severity` falls back to the safest value rather than failing the load.

### Other sections

| Section | Description |
|---------|-------------|
| `theme` | Active theme name (default `goridark`). See the [Themes guide](/guide/themes/) |
| `mouse` | Mouse support toggle |
| `pretty_bodies` | Pretty-print JSON/XML/etc. bodies in the detail view |
| `editor` | External editor `command` and Markdown handling |
| `tabs` | Which TUI tabs are shown/hidden |
| `hostname_overrides` | Global host → IP dial map. See [hostname_overrides](#hostname_overrides) above |
| `env` | Env-token prefix and global values. See [env](#env) above |
| `hotkeys` | Keybinding overrides (`os` layer + `bindings`). See the [Hotkeys guide](/guide/hotkeys/) |
| `decoder` | Last input and chain, plus saved Decoder sessions and named chains |
| `mine` | Saved Param Miner defaults. See [mine](#mine) above |
| `layout` | History / Probe / Issues previews + Sitemap expand depth. See [layout](#layout) above |
| `statusline` | Bottom status row that runs a command on an interval. See [statusline](#statusline) above |
| `display` | Default detail pane, list time format, line-number gutter, preview body cap, `resource_meter` (the CPU/memory readout at the far right of the bottom bar, on by default), and `terminal_title` |

## Per-Project Overrides

A project can pin its own network settings without editing the global file. These are stored in the project database (keys `net.bind_host`, `net.bind_port`, `net.upstream_proxy`) and edited from the **Project** tab's settings pane.

**Effective bind / upstream** for an open project:

| Priority | Source |
|----------|--------|
| 1 (highest) | Project DB `net.bind_host` / `net.bind_port` / `net.upstream_proxy` when set |
| 2 | CLI `--listen` / `--port` (process-only override of the global layer) |
| 3 | `settings.json` `network.*` |
| 4 (lowest) | Factory defaults `127.0.0.1:8070` / direct |

Saving a Project-tab field that equals the current global value deletes that KV key, so the project keeps inheriting future global edits instead of freezing a duplicate.

## Projects & Database

Each project is a SQLite database (via `crystal-db` / `crystal-sqlite3`) holding flows, WebSocket messages, scope rules, issues, match rules, HTTP/2 frames, repeater and fuzz sessions, host overrides, sitemap tags, miner sessions, and Probe issues, plus a full-text index over flow bodies. Stored request/response bodies are capped at 2 MiB; larger bodies are truncated in the database, but their true wire size is still recorded. Serve any project's database directly with `--db PATH`, or select a named project with `--project NAME`.
