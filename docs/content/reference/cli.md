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
| `ca` | Print the root CA path / PEM, or regenerate / import the CA |
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
| `-l`, `--listen=HOST` | Global bind address for this process (defaults to `settings.json`, else `127.0.0.1`). Not persisted. A project's own bind still wins when set. |
| `-p`, `--port=PORT` | Global bind port for this process, `0`-`65535` (defaults to `settings.json`, else `8070`). Not persisted. Project `net.bind_port` still wins when set. |
| `--db=PATH` | SQLite database path |
| `--ca-dir=PATH` | Directory for the root CA |
| `--headless` | Run without the TUI (capture to STDOUT) |
| `--insecure-upstream` | Do not verify upstream TLS certificates |

> `GORI_HOME` is an environment variable, not a flag. Project selection in the TUI is done through the project picker. Bind flags only set the global layer for this run. See [Configuration](/getting-started/configuration/#network). For the root CA path, use [`gori ca`](#gori-ca).

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
| `repeater <flow-id>` · `list` · `create` | Re-send a captured flow, or list / create Repeater workbench sessions |
| `fuzz [<flow-id>]` | Intruder-style fuzzer |
| `mine [<flow-id>]` | Hidden-parameter discovery |
| `probe [QL]` | Passive security scan (no requests) |
| `sitemap [QL]` | Host → path endpoint tree |
| `notes [<n>]` | Read project notes |
| `issues` · `create` · `update` | List / export issues, or write issues |
| `project [list]` | List known projects |
| `project scope` | List / add / delete / enable / disable scope rules |
| `project env` | List / set / delete project env vars (`$KEY` substitution) |

Common flags across read subcommands: `--project=NAME`, `--db=PATH`, `--format=FMT` (usually `text` or `json`).

### run capture

```bash
gori run capture --port 8070 --format json --for 5m
```

| Option | Description |
|--------|-------------|
| `-l`, `--listen`; `-p`, `--port` | Global bind for this process (settings default; project override still wins) |
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

### run repeater

Re-send one captured flow, or manage the Repeater workbench sessions shared with the TUI.

```bash
gori run repeater <flow-id> --target https://staging.example.com --http2 --diff
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

**`repeater list`**: list saved Repeater sessions (`--format text|json`).

**`repeater create`**: create a Repeater session:

```bash
gori run repeater create --target https://api.example.com --request-file req.txt --name "login probe"
gori run repeater create --flow 42 --name "clone of 42"
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
| `--locations=LIST` | `query`, `form`, `multipart`, `json`, `headers`, `cookies` (multipart off by default, pass it explicitly) |
| `--wordlist`, `--bucket=N` | Candidate names and bucket size |
| `--concurrency` (10), `--rate`, `--throttle`, `--timeout`, `--retries` (1), `--max-requests=N` | Rate control |
| `--format` | `text`, `json`, or `jsonl` |

### run probe

```bash
gori run probe --severity high --category cors
```

`--severity` is `info`\|`low`\|`medium`\|`high`\|`critical`; `--category` is `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors` (passive only, `active` probes run in the TUI); `-q`/`--query` filters with QL.

### run sitemap

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL` filters endpoints with the same QL as history (also positional), `-n`/`--limit=N` caps the endpoints scanned (default `SITEMAP_MAX`), `--in-scope` limits to in-scope hosts, `--no-group` disables numeric path folding, `--format` is `text` (tree), `json`, or `paths`.

### run issues / notes

```bash
gori run issues --format markdown --export report.md
gori run notes --all
```

Write issues from scripts with `create` / `update`:

```bash
gori run issues create --title "Reflected XSS on /search" --severity high --host app.example.com --flow 42
gori run issues update 7 --status confirmed --notes "Verified on staging" --severity critical
```

| Option | Description |
|--------|-------------|
| `create` | `-t`/`--title` (required), `-s`/`--severity` (`info`\|`low`\|`medium`\|`high`\|`critical`), `--host`, `--flow=ID` |
| `update <id>` | `-t`/`--title`, `-s`/`--severity`, `-n`/`--notes`, `--status` (`open`\|`confirmed`\|`false-positive`\|`resolved`) |

### run project

List known projects, or manage project-scoped config (scope rules, env vars, host overrides):

```bash
gori run project --format json
gori run project list
```

#### project scope

Manage the project's include/exclude scope rules from scripts:

```bash
gori run project scope                                          # list rules + enabled state
gori run project scope --format json
gori run project scope add --kind=include --type=host --pattern=api.example.com
gori run project scope add --kind=exclude --type=regex --pattern='.*\.(css|js)$'
gori run project scope delete 3
gori run project scope enable
gori run project scope disable
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | List rules; `--format` is `text` or `json` |
| `add` | `--kind=include\|exclude`, `--type=host\|string\|regex`, `--pattern=…` |
| `delete <rule-id>` | Remove a rule by id |
| `enable` / `disable` | Toggle whether scope filtering is applied |

#### project env

Manage **project** env vars used for `$KEY` substitution in outbound requests (Repeater, Fuzzer, Miner, CLI, MCP). Global vars live in `settings.json` / the TUI Settings. This command only touches the per-project layer.

```bash
gori run project env                              # list KEY=value
gori run project env --format json
gori run project env set TOKEN=secret
gori run project env set HOST api.example.com
gori run project env delete TOKEN
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | List project vars; `--format` is `text` or `json` |
| `set KEY=value` · `set KEY value` | Upsert a project var (KEY must match `[A-Za-z_][A-Za-z0-9_]*`) |
| `delete KEY` | Remove a project var |

#### project host-override

Manage **project** host overrides — `/etc/hosts`-style maps that change only the TCP dial target (SNI, certificate hostname, and `Host` header stay the original name). Project entries win over global `Settings: Hostnames` on collision. Alias: `host-overrides`.

```bash
gori run project host-override                              # list
gori run project host-override --format json
gori run project host-override add --host=api.example.com --ip=10.0.0.1
gori run project host-override add 10.0.0.1 api.example.com   # /etc/hosts order
gori run project host-override update 1 --host=api.example.com --ip=10.0.0.9
gori run project host-override delete 1
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | List overrides; `--format` is `text` or `json` |
| `add` | `--host=…` + `--ip=…`, or positional `IP HOST` |
| `update <id>` | `--host=…` + `--ip=…` (both required) |
| `delete <id>` | Remove an override by id |

## gori mcp

MCP stdio server. See the [MCP guide](/guide/mcp/) for tool details.

| Option | Description |
|--------|-------------|
| `--db=PATH` | Serve this database (overrides `--project`) |
| `--project=NAME` | Serve a named project's database |
| `--use-active-project` | Ignore Git-workspace selection and explicitly serve the active TUI/MRU project |
| `--insecure-upstream` | `send_request`: skip upstream TLS verification |
| `--read-only` | Disable action tools (`send_request`, create/update issues, fuzz/mine) |
| `--install-claude` | Write Claude Desktop `mcpServers` config |
| `--install-claude-code` | Write Claude Code `~/.claude.json` `mcpServers` entry |
| `--install-codex` | Write OpenAI Codex `~/.codex/config.toml` `[mcp_servers.gori]` |
| `--install-agy` | Write Antigravity `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Write Grok `~/.grok/config.toml` `[mcp_servers.gori]` |

## gori ca

```bash
gori ca
gori ca --pem
gori ca --ca-dir=DIR
gori ca regenerate
gori ca regenerate --yes
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

Prints the path to gori's root CA certificate (creates it on first use). Use this when trusting the CA in a browser or system store, or when pointing a client at `--cacert`.

| Option | Description |
|--------|-------------|
| `--ca-dir=DIR` | CA directory (default `~/.gori/ca`, or `$GORI_HOME/ca`) |
| `--pem` | Print the certificate PEM to stdout instead of the path |

### gori ca regenerate

Replaces the on-disk root CA with a freshly minted one. **Destructive**: every client that trusted the old CA must re-trust the new certificate. Any already-running gori process keeps the old CA in memory until restarted.

| Option | Description |
|--------|-------------|
| `--yes`, `-y` | Skip the interactive confirm (required when stdin is not a tty) |
| `--ca-dir=DIR` | CA directory to regenerate |

Without `--yes`, the command prompts on a tty and expects you to type `regenerate` (same word as the TUI confirm). Scripts and CI should pass `--yes`. On success the new cert path is printed to stdout.

### gori ca import

Adopts an externally-created root CA (a certificate + matching private key, both PEM) in place of gori's own, for sharing one CA across a team or machines, or reusing an organization CA. gori needs both files because it signs per-host leaf certificates on the fly; clients trust only the certificate. **Destructive**, like `regenerate`: it replaces the on-disk root and voids prior trust.

| Option | Description |
|--------|-------------|
| `--cert FILE` | Root CA certificate PEM to adopt (required) |
| `--key FILE` | Matching private key PEM (required) |
| `--yes`, `-y` | Skip the interactive confirm (required when stdin is not a tty) |
| `--ca-dir=DIR` | CA directory to install into |

The pair is validated before anything is written: the key must match the certificate and the certificate must be a CA (`basicConstraints CA:TRUE`). A bad pair aborts without touching the current CA. An expired or not-yet-valid certificate imports with a warning. Confirm by typing `import` on a tty, or pass `--yes`. The same action is available from the TUI palette (**Import CA certificate**).

Generate a root with OpenSSL, then import it:

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

Trust only `root.crt.pem` in your clients. Never distribute the private key.

## gori settings

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in $EDITOR
```

## gori wizard

```bash
gori wizard
```

Runs the interactive setup (global proxy bind default, then theme). Also runs automatically on first launch. The bind step writes the shared `settings.json` defaults. Projects can still pin their own address in the Project tab; `--listen` / `--port` override for one run only.

## gori tutorial

```bash
gori tutorial
```

Interactive tour of the TUI on a mock UI: tab/pane navigation, the command palette (`Ctrl-P`), the space menu (`Space`), and READ/INS edit mode. Each lesson demos the move and prompts you to try the key; a final practice step requires all four before finishing, then points you at a first real session. Offered at the end of `gori wizard`; safe to re-run anytime without a live proxy session. See the [Quick Start](/getting-started/quick-start/).

## gori update

```bash
gori update
gori update --exec   # Homebrew/Snap: run the package-manager command
```

Detects how this `gori` binary was installed and updates accordingly:

| Install channel | Behavior |
|-----------------|----------|
| Standalone binary (curl install, manual download, workspace build, or a manual copy into `/usr/bin` that no package manager owns) | Downloads the latest GitHub release asset for this OS/arch and replaces the binary (macOS also refreshes sibling `lib/` in a dedicated dir) |
| Homebrew | Prints `brew upgrade gori` (use `--exec` to run it; never overwrites the brew-managed path) |
| Snap | Prints `snap refresh gori` (use `--exec` to run it) |
| pacman / AUR | Prints `yay` / `paru` / `pacman` guidance |
| deb (dpkg) | Prints `apt` upgrade guidance |
| rpm | Prints `dnf` / `yum` / `zypper` guidance |

Paths under `/usr/bin` or `/bin` are classified by package ownership (`pacman -Qo`, `dpkg-query -S`, `rpm -qf`). If a manager owns the file, gori never overwrites it. If probes find no owner, the binary channel self-updates. When no package tools are available, `/etc/os-release` (`ID` / `ID_LIKE`) picks Arch-like / Debian-like / RHEL-like guidance as a fallback.

Release asset names match the [installation guide](/getting-started/installation/) (`gori-v*-linux-*` plain binaries, `gori-v*-osx-*.tar.gz` archives). macOS archive updates require a dedicated layout (e.g. `PREFIX/opt/gori` from the curl installer) so bundled `lib/` is never written under shared roots like `/usr/local/lib`. If no release assets exist yet, the command exits with a clear error pointing at the releases page. It does not silently no-op.
