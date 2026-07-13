+++
title = "CLI Reference"
description = "Every gori subcommand and command-line flag."
+++

Reference for the `gori` command line. Running `gori` with no subcommand starts the TUI.

```text
gori [command] [options]
```

| Command | Description |
|---------|-------------|
| `tui` | Start the proxy and terminal UI (default) |
| `run` | Non-interactive suite over a project |
| `mcp` | Model Context Protocol stdio server |
| `export` | Export the root CA certificate |
| `settings` | Show or edit `settings.json` |
| `wizard` | Interactive first-run setup |
| `tutorial` | Guided TUI tour (navigation, palette, space menu, edit mode) |
| `update` | Channel-aware self-update (binary / Homebrew / Snap / AUR) |

Global flags: `-v` / `--version`, `-h` / `--help`.

## gori tui

Start the intercepting proxy and TUI. This is the default when no subcommand is given.

```bash
gori
gori tui --listen 0.0.0.0 --port 8080
```

| Option | Description |
|--------|-------------|
| `-l`, `--listen=HOST` | Listen address (default `127.0.0.1`) |
| `-p`, `--port=PORT` | Listen port, `0`–`65535` (default `8070`) |
| `--db=PATH` | SQLite database path |
| `--ca-dir=PATH` | Directory for the root CA |
| `--headless` | Run without the TUI (capture to STDOUT) |
| `--insecure-upstream` | Do not verify upstream TLS certificates |
| `--export-ca` | Print the root CA certificate path and exit |

> `GORI_HOME` is an environment variable, not a flag. Project selection in the TUI is done through the project picker.

## gori run

The non-interactive suite. Each subcommand operates over a project; with neither `--project` nor `--db` it uses the most-recently-active project.

```bash
gori run <subcommand> [options]
```

| Subcommand | Description |
|------------|-------------|
| `capture` | Run the proxy and stream captured flows to STDOUT |
| `history` (`ls`) | List / query captured flows |
| `show <flow-id>` | Print one flow's request and response |
| `replay <flow-id>` · `list` · `create` | Re-send a captured flow, or list / create Replay workbench sessions |
| `fuzz [<flow-id>]` | Intruder-style fuzzer |
| `mine [<flow-id>]` | Hidden-parameter discovery |
| `prism [QL]` | Passive security scan (no requests) |
| `sitemap [QL]` | Host → path endpoint tree |
| `notes [<n>]` | Read project notes |
| `findings` · `create` · `update` | List / export findings, or write findings |
| `projects` | List known projects |
| `scope` | List / add / delete / enable / disable scope rules |

Common flags across read subcommands: `--project=NAME`, `--db=PATH`, `--format=FMT` (usually `text` or `json`).

### run capture

```bash
gori run capture --port 8070 --format json --for 5m
```

| Option | Description |
|--------|-------------|
| `-l`, `--listen`; `-p`, `--port` | Bind address / port |
| `--project=NAME` | Project to write to (default `default`) |
| `--db=PATH` | Database path |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--format=FMT` | `text` or `json` (JSON Lines) |
| `--for=DURATION` | Stop after e.g. `30s`, `5m`, `1h` |
| `--max=N` | Stop after N flows |

### run history / ls

```bash
gori run history -q 'status:5xx' --limit 100 --format json
```

| Option | Description |
|--------|-------------|
| `-q`, `--query=QL` | Query-language filter (also accepted positionally) |
| `-n`, `--limit=N` | Max rows (default 50) |
| `--format=FMT` | `text` or `json` |

### run show

```bash
gori run show <flow-id> --format raw
```

`--format` is `text`, `json`, or `raw` (exact bytes). `--request-only` / `--response-only` limit the output. Decoded SAML/JWT/GraphQL/params, WebSocket messages, and SSE events are included where present.

### run replay

Re-send one captured flow, or manage the Replay workbench sessions shared with the TUI.

```bash
gori run replay <flow-id> --target https://staging.example.com --http2 --diff
```

| Option | Description |
|--------|-------------|
| `--target=URL` | Send to a different URL |
| `--http2` | Use HTTP/2 |
| `--sni=HOST` | TLS SNI override |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `-H`, `--header=HEADER` | Overwrite/add a request header (repeatable) |
| `-b`, `--body=BODY` | Request body override |
| `--diff` | Diff against the original response |
| `--format=FMT` | `text` (default) or `json` |

**`replay list`** — list saved Replay sessions (`--format text|json`).

**`replay create`** — create a Replay session:

```bash
gori run replay create --target https://api.example.com --request-file req.txt --name "login probe"
gori run replay create --flow 42 --name "clone of 42"
```

| Option | Description |
|--------|-------------|
| `-t`, `--target=URL` | Target URL (required unless cloned from `--flow`) |
| `-f`, `--request-file=FILE` | Read the raw HTTP request from FILE |
| `-r`, `--request-raw=RAW` | Verbatim raw HTTP request string |
| `--flow=ID` | Clone request / target / HTTP/2 from a captured flow |
| `--name=NAME` | Custom tab name |
| `--http2`, `--no-auto-cl`, `--sni=HOST` | HTTP/2, skip auto `Content-Length`, SNI override |
| `--mark-transform` | Enable inline `§value¦chain§` substitution on send |

### run fuzz

Sources: `--flow=ID`, `--request=FILE`, or stdin. Positions: `§…§` markers, `--auto`, or `--mark=TOKEN`.

| Group | Options |
|-------|---------|
| Transport | `--target=URL` (required for `--request`/stdin), `--http2`, `--sni=HOST`, `-k`/`--insecure-upstream` |
| Mode | `--mode=` `sniper` (default), `batteringram`, `pitchfork`, `clusterbomb` |
| Payloads | `-w`/`--wordlist`, `--payloads=LIST`, `--numbers=FROM-TO[:STEP]`, `--null=N`, `--brute=CHARSET:MIN-MAX` |
| Processors | `--prefix`, `--suffix`, `--encode` (`url`\|`urlall`\|`base64`\|`hex`), `--case` (`upper`\|`lower`), `--hash` (`md5`\|`sha1`\|`sha256`), `--regex-replace=/pat/rep/` |
| Rate | `--concurrency` (20), `--rate=RPS`, `--throttle=MS`, `--timeout=SEC`, `--retries=N`, `--follow-redirects` |
| Matchers | `--mc`/`--fc` status, `--ms`/`--fs` size, `--mw`/`--fw` words, `--ml`/`--fl` lines, `--mr`/`--fr` body regex, `--extract=REGEX`, `--ac` auto-calibrate |
| Output | `--format` (`text`\|`json`\|`jsonl`), `--force`, `--fail-if-no-matches` |

### run mine

```bash
gori run mine <flow-id> --locations query,headers --wordlist params.txt
```

| Option | Description |
|--------|-------------|
| `--flow`, `--request`, `--target`, `--sni`, `--http2`, `-k` | Request source and transport |
| `--locations=LIST` | `query`, `form`, `json`, `headers`, `cookies` |
| `--wordlist`, `--bucket=N` | Candidate names and bucket size |
| `--concurrency` (10), `--rate`, `--throttle`, `--timeout`, `--retries` (1), `--max-requests=N` | Rate control |
| `--format` | `text`, `json`, or `jsonl` |

### run prism

```bash
gori run prism --severity high --category cors
```

`--severity` is `info`\|`low`\|`medium`\|`high`\|`critical`; `--category` is `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors` (passive only — `active` probes run in the TUI); `-q`/`--query` filters with QL.

### run sitemap

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL` filters endpoints with the same QL as history (also positional), `-n`/`--limit=N` caps the endpoints scanned (default `SITEMAP_MAX`), `--in-scope` limits to in-scope hosts, `--no-group` disables numeric path folding, `--format` is `text` (tree), `json`, or `paths`.

### run findings / notes / projects

```bash
gori run findings --format markdown --export report.md
gori run notes --all
gori run projects --format json
```

Write findings from scripts with `create` / `update`:

```bash
gori run findings create --title "Reflected XSS on /search" --severity high --host app.example.com --flow 42
gori run findings update 7 --status confirmed --notes "Verified on staging" --severity critical
```

| Option | Description |
|--------|-------------|
| `create` | `-t`/`--title` (required), `-s`/`--severity` (`info`\|`low`\|`medium`\|`high`\|`critical`), `--host`, `--flow=ID` |
| `update <id>` | `-t`/`--title`, `-s`/`--severity`, `-n`/`--notes`, `--status` (`open`\|`confirmed`\|`false-positive`\|`resolved`) |

### run scope

Manage the project's include/exclude scope rules from scripts:

```bash
gori run scope                                          # list rules + enabled state
gori run scope --format json
gori run scope add --kind=include --type=host --pattern=api.example.com
gori run scope add --kind=exclude --type=regex --pattern='.*\.(css|js)$'
gori run scope delete 3
gori run scope enable
gori run scope disable
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | List rules; `--format` is `text` or `json` |
| `add` | `--kind=include\|exclude`, `--type=host\|string\|regex`, `--pattern=…` |
| `delete <rule-id>` | Remove a rule by id |
| `enable` / `disable` | Toggle whether scope filtering is applied |

## gori mcp

MCP stdio server. See the [MCP guide](/guide/mcp/) for tool details.

| Option | Description |
|--------|-------------|
| `--db=PATH` | Serve this database (overrides `--project`) |
| `--project=NAME` | Serve a named project's database |
| `--insecure-upstream` | `send_request`: skip upstream TLS verification |
| `--read-only` | Disable action tools (`send_request`, create/update findings, fuzz/mine) |
| `--install-claude` / `--install-claude-code` / `--install-codex` / `--install-agy` / `--install-grok` | Write the MCP config for that client |

## gori export

```bash
gori export ca-cert [--ca-dir=DIR]
```

Prints the root CA certificate path. `gori --export-ca` is a compatibility alias.

## gori settings

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in $EDITOR
```

## gori wizard

```bash
gori wizard
```

Runs the interactive setup (proxy bind address, then theme). Also runs automatically on first launch.

## gori tutorial

```bash
gori tutorial
```

Interactive tour of the TUI on a mock UI: tab/pane navigation, the command palette (`Ctrl-P`), the space menu (`Space`), and READ/INS edit mode. Offered at the end of `gori wizard`; safe to re-run anytime without a live proxy session. See the [Quick Start](/getting-started/quick-start/).

## gori update

```bash
gori update
gori update --exec   # Homebrew/Snap: run the package-manager command
```

Detects how this `gori` binary was installed and updates accordingly:

| Install channel | Behavior |
|-----------------|----------|
| Standalone binary (curl install, manual download, workspace build) | Downloads the latest GitHub release asset for this OS/arch and replaces the binary (macOS also refreshes sibling `lib/` in a dedicated dir) |
| Homebrew | Prints `brew upgrade gori` (use `--exec` to run it; never overwrites the brew-managed path) |
| Snap | Prints `snap refresh gori` (use `--exec` to run it) |
| AUR / pacman (`/usr/bin/gori`) | Prints AUR helper guidance (`yay` / `paru` / `pacman`) |

Release asset names match the [installation guide](/getting-started/installation/) (`gori-v*-linux-*` plain binaries, `gori-v*-osx-*.tar.gz` archives). macOS archive updates require a dedicated layout (e.g. `PREFIX/opt/gori` from the curl installer) so bundled `lib/` is never written under shared roots like `/usr/local/lib`. If no release assets exist yet, the command exits with a clear error pointing at the releases page — it does not silently no-op.
