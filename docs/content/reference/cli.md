+++
title = "CLI Reference"
description = "Every gori subcommand and command-line flag."
weight = 10
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
| `update` | Channel-aware self-update (binary / Homebrew / Snap / AUR / Nix) |

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
| `--insecure-upstream` | Do not verify upstream TLS certificates |

> `GORI_HOME` is an environment variable, not a flag. Project selection in the TUI is done through the project picker. Bind flags only set the global layer for this run. See [Configuration](/getting-started/configuration/#network). For the root CA path, use [`gori ca`](#gori-ca).

## gori run

The non-interactive suite. Each subcommand operates over a project; with neither `--project` nor `--db` it uses the most-recently-active project. See the [Scripting guide](/guide/scripting/) for the working patterns.

```bash
gori run <subcommand> [verb] [options]
```

| Subcommand | Description |
|------------|-------------|
| `capture` | Run the proxy and stream captured flows to STDOUT |
| `history` (`ls`) | List / query captured flows |
| `history delete <id>` · `clear` | Hard-delete one flow, or wipe the project's History (`--yes`) |
| `show <flow-id>` | Print one flow's request and response |
| `compare <id-a> <id-b>` | Diff two flows' request or response |
| `intercept` | Inspect and drive a capturing TUI's live intercept queue |
| `repeater <flow-id>` · `list` · `create` · `send` | Re-send a captured flow, or list / create / execute Repeater sessions (incl. WebSocket) |
| `repeater minimize <id>` | Strip a saved request to the smallest form that keeps the response |
| `repeater h2` | Send a field-native HTTP/2 request from an ordered HPACK field list |
| `fuzz [<flow-id>]` | Intruder-style fuzzer |
| `mine [<flow-id>]` | Hidden-parameter discovery |
| `sequence` (`seq`) `[<flow-id>]` | Grade token randomness (live replay, or `--tokens` for a pasted list) |
| `authorize [<flow-id>…]` | Replay captured flows under several identities and judge each response against a baseline (broken access control) |
| `probe [QL]` | Passive security scan (no requests) |
| `probe issues` · `dismiss` · `promote` · `delete` | Triage persisted Probe findings |
| `probe rules` · `mode` | List / arm scan rules; get or set the scan mode |
| `discover` | Spider and brute-force endpoints into the Sitemap |
| `import` | Bulk-import flows into History from a HAR / URL list / OpenAPI / Postman / Insomnia / Burp file |
| `sitemap [QL]` | Host → path endpoint tree |
| `sitemap tag` | Pin, clear, or list a free-text memo on a sitemap path |
| `oast listen` · `presets` | Out-of-band callback listener (interactsh & friends) |
| `oast list` · `resume` · `release` | List, resume, or release the project's saved OAST listening sessions |
| `oast providers` | List / add / update / enable / disable / delete saved OAST providers |
| `jwt [<token>]` | Decode, re-sign, or generate attack payloads for a JWT |
| `cookie [<cookie>]` | Decode, verify, brute-force, or forge a Flask / Rack / Django session cookie |
| `decoder <chain> [input]` | Run a Decoder encode / decode / hash chain |
| `notes [<n>]` · `create` · `delete` | Read, write, or delete project notes |
| `issues` · `create` · `update` | List / export issues, or write issues |
| `links` · `add` · `delete` | Evidence pointers from an issue or note to a flow, Repeater session, or job |
| `rewriter` · `add` · `rm` · `enable` · `disable` · `preview` | Manage Match & Replace rules |
| `rewriter extract` · `bindings` | Manage session-binding extract rules, and list the `$NAME`s they declare |
| `colormarker` · `add` · `rm` · `enable` · `disable` · `move` · `preview` · `color` | Manage History row-colour rules |
| `project [list]` | List known projects |
| `project create <name>` | Create (or reopen) a project by name |
| `project delete <name>` | Delete a project and everything captured in it (`--yes` to confirm) |
| `project scope` | List / add / update / delete / enable / disable scope rules |
| `project sandbox` | Get / set the hard-containment sandbox gate (`status`, `on`, `off`) |
| `project env` | List / set / delete project env vars (`$KEY` substitution) |
| `project host-override` | List / add / update / delete project host to IP dial overrides |

Common flags across read subcommands: `--project=NAME`, `--db=PATH`, `--format=FMT` (usually `text` or `json`). Global flags go **after** the verb — `gori run rewriter rm 1 --project=x`, not `gori run rewriter --project=x rm 1`, which is rejected as a usage error rather than silently listing.

Read subcommands open the store directly and never take the capture lock, so they are safe to run against a project a live TUI is capturing into.

#### Output contract

STDOUT carries data; warnings, counts, and export confirmations go to STDERR, so a pipe stays clean. A reader that closes the pipe early (`… | head`) exits `0` quietly.

Where a run streams, `json` and `jsonl` are not always the same shape:

| Subcommand | `--format json` | `--format jsonl` |
|------------|-----------------|------------------|
| `capture`, `history` | One JSON object per line | Alias for `json` — same output |
| `fuzz`, `mine`, `discover`, `authorize` | Buffered; one JSON array at the end | One object per line, as each result lands |

| Exit code | Meaning |
|-----------|---------|
| `0` | Success |
| `1` | Error — a failed send, an unreadable project, a mutation that could not be applied |
| `3` | `run fuzz --fail-if-no-matches` completed but nothing matched |
| `130` | Interrupted by SIGINT/SIGTERM — `fuzz`, `mine`, `discover`, `sequence` and `authorize` flush what they collected first, then exit `130` so a scripted `&& next-step` does not treat a truncated run as a finished one |

Without `--fail-if-no-matches`, a fuzz run that matched nothing *and* errored on every send still exits `1`, so "no findings" stays distinguishable from "never reached the target". With the flag, `3` wins.

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
| `--format=FMT` | `text`, `json`, or `har` |

Subcommands: `history show <id>` (same as `run show`), `history delete <id>`, `history clear --yes`.

`--format har` writes the whole result set as one HAR 1.2 log on STDOUT, oldest entry first, so a query can be handed to a teammate or loaded into Burp, Charles, or a browser's network panel. See [HAR export](#har-export).

### run show

```bash
gori run show <flow-id> --format raw
```

`--format` is `text`, `json`, `raw` (exact bytes), or `har` (a one-entry HAR log). `--request-only` / `--response-only` limit the output and do not apply to `har`. Decoded SAML/JWT/GraphQL/params, WebSocket messages, and SSE events are included where present.

#### HAR export

A HAR gori writes imports back into gori as the same flow (`gori run import --har`), so it round-trips. Four things to know:

- **Bodies are the wire bytes**, de-chunked but not decompressed, base64-encoded when they are not valid UTF-8. The `Content-Encoding` header stays in `headers`, so body and head keep describing the same message.
- **A body capped at the capture limit is marked**, never emitted as if complete: `bodySize` and `content.size` stay the true wire size while the text carries only the captured prefix, and a `comment` on `content`/`postData` says so. The command also reports the count on STDERR.
- **A WebSocket flow exports with its messages**: the real `101` handshake, plus the captured transcript beside it in Chrome DevTools' `_webSocketMessages` field, and `gori run import --har` restores it. Direction, opcode (control frames included), bytes (base64 when not valid UTF-8) and millisecond timestamps survive; the per-frame shape (`FIN`/`RSV`/mask key) has no field in the format, so use `--format json` or `raw` when you need it.
- **Flows with no captured response are skipped**, along with a socket whose transcript is empty — the handshake alone is not the exchange. The count and reason go to STDERR; STDOUT stays a pure HAR document.

### run compare

Line diff of two flows, matching the [Comparer tab](/guide/scanning/).

```bash
gori run compare 41 42 --pane response --changes-only
```

| Option | Description |
|--------|-------------|
| `--pane=PANE` | What to diff: `request` or `response` (default) |
| `--changes-only` | Print only added / removed lines, omitting unchanged context |
| `--context=N` | Collapse unchanged runs to `@@ N unchanged lines @@` markers, keeping N lines around each change (mutually exclusive with `--changes-only`) |
| `--format=FMT` | `text` (default) or `json` |

Both sides' `status · size · time` and the A→B delta print above the diff, so a status flip or a size shift is visible before the first line is read. `--format=json` carries the same under `meta`, and a collapsed run becomes `{"kind":"fold","hidden":N}` rather than a gap.

`--changes-only` says *what* changed but erases *where*: a 400-line body with one edit comes back as two lines with no position. `--context` keeps the change in place and states how much it skipped.

### run intercept

Drive the live intercept queue of a TUI holding the capture lock. Interception is TUI-only: a headless `gori run capture` never holds a message, and every subcommand here refuses when no capturing instance is publishing state.

```bash
gori run intercept                              # held items + intercept state
gori run intercept get 3 --format json
gori run intercept forward 3
gori run intercept edit 3 --raw-file edited.txt
gori run intercept direction request
```

| Subcommand | Description |
|------------|-------------|
| `list` (default) | Held items plus catch state, direction, and filter |
| `get <item-id>` | Full detail for one held item |
| `forward <item-id>` | Release a held item byte-exact |
| `drop <item-id>` | Drop it. The client gets a canned 502 |
| `edit <item-id>` | Release with edited bytes: `--raw=RAW` or `--raw-file=PATH`. Forwarded verbatim (no `$KEY` expansion), with `Content-Length` resynced |
| `enable` / `disable` | Arm or disarm the live catch |
| `filter <query>` | Set the conditional-intercept query. Pass `""` to clear it |
| `direction <both\|request\|response>` | Which leg(s) the catch holds |

`list` and `get` redact sensitive header values unless `--include-sensitive` is passed. Write subcommands round-trip through the project database and poll for the TUI's ack.

### run repeater

Re-send one captured flow, or manage the Repeater workbench sessions shared with the TUI.

```bash
gori run repeater <flow-id> --target https://staging.example.com --http2 --diff
```

| Option | Description |
|--------|-------------|
| `--target=URL` | Send to a different origin; path and query are kept |
| `--http2` / `--http1` (`--no-http2`) | Force a protocol; the default follows how the flow was captured |
| `--sni=HOST` | TLS SNI override |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--timeout=SEC` | Per-operation connect + idle timeout |
| `-H`, `--header=HEADER` | Overwrite/add a request header (repeatable). Repeat the same name to send duplicate lines; an explicit `Content-Length` is honoured verbatim, for CL-mismatch testing |
| `--rm-header=NAME` | Delete every header with this name (repeatable). Removing `Content-Length` suppresses the auto-resync; removing `Host` suppresses the `--target` sync |
| `-b`, `--body=BODY` | Request body override |
| `--keep-request-line` | Send the stored request line as-is — do not rewrite an absolute-form line (`GET http://h/p`) to origin-form |
| `--diff` | Diff against the original response |
| `--allow-unscoped` | Send outside the project scope. Sandbox mode and explicit excludes still refuse each send |
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
| `--name=NAME`, `--tags=TAGS` | Custom tab name, and free-text tags that become the TUI subtab label |
| `--http2` / `--http1` (`--no-http2`) | Pick a protocol; `--http1` overrides an h2-captured `--flow` |
| `--no-auto-cl`, `--sni=HOST` | Skip auto `Content-Length`, SNI override |
| `--keep-request-line` | With `--flow`: store the request line as captured, absolute-form included |
| `--ws-keep-key` | WebSocket: send the request's own `Sec-WebSocket-Key` so an absent, short, duplicate, or non-base64 key can be tested |
| `--ws-http-only` | WebSocket: store this session as plain HTTP — the upgrade is sent as an ordinary request and the `101` read as a response |

**`repeater send <repeater-id>`**: execute a saved session, HTTP or WebSocket.

```bash
gori run repeater send 3 --diff
gori run repeater send 5 --message '{"op":"subscribe"}' --idle-ms 5000
```

| Option | Description |
|--------|-------------|
| `--diff` | Diff against the session's last stored response |
| `--verbatim` | Send the stored bytes exactly: no `$VAR` expansion, no bare-LF promotion, no `Content-Length` resync, no HTTP/2→1.1 version fix, no h2 field-name lowercasing |
| `--reframe-grpc` | HTTP/2 only: recompute the gRPC 5-byte length prefix over the body actually being sent, for a unary message an edit changed the length of. Off by default — a prefix that disagrees with its payload is a standard parser test, so it ships as written |
| `--message=TEXT` | WebSocket: outbound text message (repeatable; replaces the session's stored messages) |
| `--message-frame=SPEC` | WebSocket: one frame with an explicit shape. Comma-separated `key=value`: `opcode=text\|bin\|cont\|close\|ping\|pong\|<0-15>`, `fin`, `rsv`, `mask`, `mask_key`, `len`, and one of `hex=`/`b64=`/`text=` |
| `--idle-ms=N` | WebSocket: server-silence timeout after the first inbound frame (100–60000, default 3000) |
| `--http` | WebSocket: send the handshake as an ordinary HTTP request for this send only. Selects the engine, not a rewrite |
| `--ws-keep-key`, `-k`, `--timeout`, `--allow-unscoped`, `--format` | As above |

**`repeater minimize <repeater-id>`**: shrink a request to the smallest form that still reproduces the response. `--apply` writes the result back into the session; `--verbatim` sends the stored bytes as-is (body params stop being candidates, because their framing could not be kept honest); `-k`/`--insecure`, `--allow-unscoped` and `--format` behave as above.

**`repeater h2`**: send a field-native HTTP/2 request from an ordered HPACK field list, so duplicate or misordered pseudo-headers can be scripted.

```bash
gori run repeater h2 --target https://api.example.com --fields fields.json
```

`--fields=FILE` is a JSON file holding either a bare `[[name, value], …]` array or `{"fields": [[name, value], …], "body": "…"}` (`body_base64` for binary). Nothing in the list is normalized — a leading colon, a leading-space value, an uppercase name are the payload. `--target` sets the dial origin, so the `:authority` and `:scheme` fields may deliberately disagree with it.

### run fuzz

Sources: `--flow=ID`, `--request=FILE`, or stdin. Positions: `§…§` markers, `--auto`, or `--mark=TOKEN`.

| Group | Options |
|-------|---------|
| Transport | `--target=URL` (required for `--request`/stdin), `--http2`, `--sni=HOST`, `-k`/`--insecure-upstream` |
| Mode | `--mode=` `sniper` (default), `batteringram`, `pitchfork`, `clusterbomb` |
| Payloads | `-w`/`--wordlist`, `--preset=NAME[:FILE]` (built-in: `sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`), `--payloads=LIST`, `--numbers=FROM-TO[:STEP]`, `--null=N`, `--brute=CHARSET:MIN-MAX` |
| Processors | `--prefix`, `--suffix`, `--encode` (`url`\|`urlall`\|`base64`\|`hex`), `--case` (`upper`\|`lower`), `--hash` (`md5`\|`sha1`\|`sha256`), `--regex-replace=/pat/rep/` |
| Rate | `--concurrency` (20), `--rate=RPS`, `--throttle=MS`, `--timeout=SEC`, `--retries=N`, `--max-requests=N` (hard cap, retries and redirect hops count), `--follow-redirects`, `--no-keep-alive` |
| Framing | `--verbatim` — send the template's `Content-Length` as written, with no resync after payload substitution (for CL / CL-TE desync payloads). `--reframe-grpc` — recompute the gRPC 5-byte length prefix after each payload is spliced into a unary message (off by default: a stale prefix is reported, not repaired) |
| Matchers | `--mc`/`--fc` status, `--mg`/`--fg` gRPC status from the `grpc-status` trailer (`7`, `>0`, `1-16`), `--ms`/`--fs` size, `--mw`/`--fw` words, `--ml`/`--fl` lines, `--mr`/`--fr` body regex, `--extract=REGEX`, `--ac` auto-calibrate |
| Session bindings | `--bind-from=FLOW-ID` — replay that captured flow first so its response fills the project's `$NAME` bindings for the rest of the run |
| Session slot | `--slot=NAME` — send as this [session slot](#run-session): its header overlay, and its binding table for `$NAME`. Applied before `--bind-from` |
| Scope | `--allow-unscoped` — send outside the project scope; Sandbox mode and explicit excludes still refuse each send |
| Output | `--format` (`text`\|`json`\|`jsonl`), `--force`, `--fail-if-no-matches` (exit `3` when nothing matched) |

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
| `--no-keep-alive` | Dial a fresh connection per probe instead of reusing one |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session) — its header overlay, and its binding table for `$NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--format` | `text`, `json`, or `jsonl` |

Connections are reused by default, so a mine pays one TCP (and on https one TLS) handshake per worker rather than one per probe — the `connections · N dialed · M reused` line at the end of a run is where you see whether the target honoured it. Turn it off with `--no-keep-alive` when the target behaves per-connection.

### run sequence

Grade the randomness of a token. **Live**: replay a request and extract the token from each response. **Manual**: analyze a pasted list with `--tokens` (no network). Alias `seq`.

```bash
gori run sequence 42 --cookie SESSIONID --count 500
gori run sequence --tokens tokens.txt          # '-' reads stdin
```

| Option | Description |
|--------|-------------|
| `--flow=ID`, `--request=FILE`, stdin | Request source for live replay (or a bare `<flow-id>`) |
| `--tokens=FILE` | Analyze a pasted token list (one per line, `-` = stdin); no network |
| Token location (pick one) | `--cookie=NAME`, `--header=NAME`, `--regex=RE`, `--position=A:B`, `--jsonpath=EXPR` |
| `--count=N` | Target token count (default 500) |
| `--target`, `--http2`, `--sni`, `-k` | Transport (target required for `--request`/stdin) |
| `--concurrency` (1), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | Rate control (concurrency stays 1 for stateful tokens) |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session) — its header overlay, and its binding table for `$NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--format` | `text`, `json`, `jsonl`, or `markdown` (the report the TUI's Export writes) |

### run authorize

Replay each selected flow under every identity — a header overlay standing in for an admin session, a low-privilege user, an anonymous client — and judge each response against the baseline's. An identity served what the baseline was served is a likely access-control bypass. The headless equivalent of the [Authorize tab](/guide/authorize/).

```bash
gori run authorize 12 13
gori run authorize --query 'host:acme.test method:GET' --identities identities.json
```

| Option | Description |
|--------|-------------|
| `<flow-id>…`, `--flow=ID` | Captured flows to replay, in the order given (repeatable) |
| `-q`, `--query=QL` | Also replay every flow matching this QL query, appended after the ids |
| `-n`, `--limit=N` | Max flows `--query` may contribute (default 50) — every row becomes one request *per identity* |
| `--identities=FILE` | Identity set as JSON (`-` = stdin); default: the project's saved set |
| `--unsafe-methods` | Also replay `POST`/`PUT`/`PATCH`/`DELETE` — each identity re-runs the side effect |
| `--allow-unscoped` | Send even when the target is outside the project scope (sandbox and excludes still apply) |
| `--timeout=SEC`, `-k`/`--insecure-upstream` | Per-request connect + idle timeout; skip upstream TLS verification |
| `--project`, `--db` | Project to read |
| `--format` | `text` (default), `json` (one array at the end), or `jsonl` (streamed) |

Identities come from the project — the TUI Authorize tab's list — unless `--identities` names a file:

```json
[{"name": "anonymous", "remove": ["Cookie", "Authorization"]},
 {"name": "low-priv",  "set": [{"name": "Cookie", "value": "session=…"}]}]
```

`set` upserts headers, `remove` strips them, and the request as captured is the baseline unless an entry carries `"baseline": true`. At least one identity besides the baseline is required, or there is nothing to compare.

Flows that cannot be replayed meaningfully are listed on STDERR before anything is sent, each with its reason (`no identity changes them`, `not a safe method to repeat`, `never completed`, `answered by gori`, `outside project scope`, `already queued`). A selection where every flow was skipped is refused rather than run. If every send was refused before the socket, the run exits `1` and says so instead of reporting a clean result — a run that sent nothing is not evidence that access control works.

### run session

The project's **session slots** — named identities, each a header overlay plus the extract rules whose bound values belong to it. The same list the TUI [Authorize tab](/guide/authorize/)'s identities card edits and MCP's `*_session_slot` tools manage: an Authorize run replays under *every* slot, and a send goes out as the *one* named by `--slot`.

```bash
gori run session                                     # list (values [REDACTED])
gori run session show admin --show-values
gori run session add --name admin --set 'Cookie: session=…' --rule SESSION
gori run session edit admin --clear-set --set 'Cookie: session=new'
gori run session baseline as-captured
gori run session rm admin
```

| Verb | Options |
|------|---------|
| `list` (default) | `--show-values` (print header values instead of `[REDACTED]`), `--format text\|json` |
| `show <name>` | `--show-values`, `--format text\|json` |
| `add` | `--name`, `--set 'Name: value'` (repeatable), `--remove NAME` (repeatable), `--rule NAME` (repeatable), `--baseline` |
| `edit <name>` | The same flags, plus `--clear-set` / `--clear-remove` / `--clear-rules`. A collection flag REPLACES that whole collection; one you omit is left alone |
| `rm`\|`delete <name>` | Any extract rule it claimed goes back to writing the global binding table |
| `baseline <name>` | Move the Authorize baseline (exactly one slot holds it) |

All verbs take `--project=NAME` / `--db=PATH`.

A `--set` value goes through the same header parser the TUI form uses: a name must be an RFC 7230 token and a value may not contain CR or LF, and a line that fails is refused by name rather than dropped.

**There is no `session activate`.** A `gori run` process sends and exits, so the active pointer has nothing to span — and persisting one would resolve into an empty binding table on the next run, sending an overlay whose `$SESSION` is literal. Name the identity on the send instead: `--slot NAME`, on `repeater`, `fuzz`, `mine`, `sequence` and `discover`. The run prints `slot: sending as NAME` on STDERR before its first request.

### run probe

```bash
gori run probe --severity high --category cors
gori run probe -a
```

`--severity` is `info`\|`low`\|`medium`\|`high`\|`critical`; `--category` is `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors`\|`client`\|`active`; `-a`/`--active` includes light-touch active checks; `-q`/`--query` filters with QL.

With `--active`: `--unsafe` also probes unsafe methods (`POST`/`PUT`/`PATCH`/`DELETE`), whose re-sends may mutate server data; `--aggressive` raises the per-rule caps and widens the forbidden-bypass header set (and implies `--unsafe`). Both stay scope-gated unless you also pass `--allow-unscoped`. Use them only against authorized targets.

A bare `probe` scans and prints. The persisted findings behind the TUI's Probe tab are a separate surface:

```bash
gori run probe issues --severity high            # the triage list, with the ids below take
gori run probe promote 12                        # confirm one into Issues
gori run probe dismiss --code missing-hsts       # mute in bulk by rule code or --host
gori run probe delete --all --yes
gori run probe rules --kind active               # list scan rules and which are armed
gori run probe rules enable <rule-id>            # ids come from `probe rules`
gori run probe mode passive                      # off | passive | active | aggressive
```

| Verb | Options |
|------|---------|
| `issues` | `-a`/`--all` (include dismissed / confirmed / resolved), `--severity`, `--category`, `--host` |
| `dismiss <id>` | Or bulk with `--code=CODE` / `--host=HOST` |
| `promote <id>` | Promote a finding to a human-confirmed Issue |
| `delete <id>` | Or `--all --yes` |
| `rules [list\|enable\|disable\|add\|delete]` | `list` takes `--kind=passive\|active\|custom`; `enable`/`disable`/`delete` take a `<rule-id>` from that list; `add` takes `-t`/`--title`, `-p`/`--pattern`, `--description`, `--side` (`request`\|`response`), `--region` (`whole`\|`header`\|`body`), `--regex`, `-s`/`--severity` |
| `mode [off\|passive\|active\|aggressive]` | Print the project's scan mode, or set it |

### run discover

Spider a target and brute-force unlinked paths; findings flow into the Sitemap unless `--no-store`. Sends real, unsolicited traffic, so only run it against authorized targets.

```bash
gori run discover --target https://target.example --max-depth 3 --extensions php,json,bak --format jsonl
```

| Option | Description |
|--------|-------------|
| `--target=URL` | Seed origin or path subtree to explore (required) |
| `--max-depth=N` | Spider depth from the seed (default 4) |
| `--no-spider` / `--no-bruteforce` | Disable link crawling / directory brute-forcing |
| `--wordlist=PATH` | Extra path wordlist, merged with the built-in list |
| `--extensions=LIST` | Also probe these extensions (e.g. `php,json,bak`) |
| `-H`, `--header=HEADER` | Custom header on every probe (repeatable) |
| `--containment=MODE` | `same-origin` \| `scope-aware` (default) \| `host+subdomains` |
| `--concurrency` (20), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | Rate control |
| `--no-keep-alive` | Dial a fresh connection per probe instead of reusing one per origin |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session) — its header overlay, and its binding table for `$NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--allow-unscoped` | Run even if the target is outside the project scope. Waives the up-front (Layer 1) check only — Sandbox mode and explicit exclude rules still refuse each send, and the refusal now names which of the two fired. |
| `--force` | Bypass the unbounded-run safety gate |
| `--no-store` | Do not write findings into the project |
| `--format` | `text`, `json`, or `jsonl` |

Connections are reused per origin by default, so a brute-force pass pays one TCP (and on https one TLS) handshake per worker rather than one per probe. The `connections · N dialed · M reused` line at the end of a run is where you see whether the target honoured it. Turn it off with `--no-keep-alive` when the target behaves per-connection.

### Session bindings from the command line

A session binding (`$SESSION` filled from a login response — see [Session bindings](/guide/proxy/#session-bindings)) lives in the **memory** of the gori process that observed it. It is never written to `settings.json` or to the project database: a restored token is stale by construction, and re-extracting one costs a single request.

`gori run` is one process per invocation, and a sweep is deliberately **not** an extraction source (a response echoing an attack payload back could otherwise rebind your session to it). So a headless `fuzz` / `mine` / `sequence` / `discover` whose template names a declared binding has nothing to resolve it with, and is refused before it sends.

`--bind-from FLOW-ID` is the missing step: it replays one captured flow — the login — through the deliberate-send path, whose response fills the binding table, and then runs the sweep in the same process.

```bash
gori run fuzz 42 --wordlist ids.txt --bind-from 17
# bind-from: flow #17 replayed → bound $SESS
```

Driving two `gori mcp` tool calls over one stdio session works the same way and always has.

### run import

Bulk-import flows into the project's History — the CLI counterpart of the TUI's Import overlay (see [Proxy & History → Import](/guide/proxy/#import)). Exactly one source flag is required. Sends no traffic.

```bash
gori run import --postman api.postman_collection.json --db ./assessment.db --format json
```

| Option | Description |
|--------|-------------|
| `--har=PATH` | A browser/proxy HAR (HTTP Archive) export — full request/response flows |
| `--urls=PATH` | A text file of URLs, one per line (`#` comments and blanks ignored) |
| `--oas=PATH` | An OpenAPI/Swagger spec (JSON or YAML) — one template per operation |
| `--postman=PATH` | A Postman Collection v2 export (JSON) |
| `--insomnia=PATH` | An Insomnia v4 export (JSON) |
| `--burp=PATH` | A Burp Suite item export (XML) — request **and** response, byte-exact |
| `--project=NAME` | Project to import into (default: most-recently-active) |
| `--db=PATH` | Explicit SQLite db file to import into (created if absent) |
| `--format` | `text` (default) or `json` |

Import writes flows, so it resolves its target like `discover`: an explicit `--db` is created or reopened, and without one it writes into an existing project rather than silently creating a default.

A malformed entry is skipped rather than aborting the file; the result reports both counts (`{"count": 12, "skipped": 3}`). Only `--har` and `--burp` carry responses — the rest import request templates that show as `Pending` in History until you send them.

### run sitemap

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL` filters endpoints with the same QL as history (also positional), `-n`/`--limit=N` caps the endpoints scanned (default `SITEMAP_MAX`), `--in-scope` limits to in-scope hosts, `--no-group` disables id folding, `--format` is `text` (tree), `json`, or `paths`.

**`sitemap tag`**: pin a free-text memo onto one path, the same note the TUI's Sitemap shows.

```bash
gori run sitemap tag --host api.example.com --path /v1/users --tag "IDOR candidate"
gori run sitemap tag --host api.example.com --path /v1/users --clear
gori run sitemap tag --list
```

### run oast

Out-of-band listener. `listen` is ad-hoc and store-free (register a payload, print it, stream callbacks); `list` / `resume` / `release` act on the sessions the project persists — the same rows the TUI's RESUME LISTENER picker shows.

```bash
gori run oast presets                          # list built-in public providers
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site --once --json
```

`presets` lists the public providers. `listen` options:

| Option | Description |
|--------|-------------|
| `--provider=KIND` | `interactsh` (default) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--server=URL` | Provider server / base URL (default: the provider's public preset) |
| `--token=TOK` | Optional provider auth token |
| `--interval=SEC` | Poll interval (default 5) |
| `--once` | Poll once and exit |
| `--json` | Emit each callback as a JSON line (same shape as MCP) |

**`oast list` / `resume` / `release`**: the project's saved listening SESSIONS, as opposed to the providers below (a provider is where you listen; a session is one live registration on it). A registration outlives the process that minted it, which is what makes a payload planted yesterday still worth watching.

```bash
gori run oast list                                       # id, provider, payload host, hits, last poll
gori run oast list --format json
gori run oast resume 7                                   # re-arm session #7, stream its callbacks
gori run oast resume 7 --once --json                     # one poll, JSON lines, then exit
gori run oast release 7                                  # deregister it server-side
```

`resume` and `release` take the session **id** (`7`, or the `#7` `list` prints). `resume` re-arms the server-side state so payloads already planted keep resolving, then polls: every callback is written into the project, so the TUI OAST tab shows the same hits, and `last_poll_at` is stamped like a TUI listener's. Ctrl-C stops polling and **keeps** the registration — `release` is the deliberate teardown, and it keeps the stored callbacks either way. Nothing auto-resumes; these run only when you ask.

| Option | Description |
|--------|-------------|
| `--project=NAME` · `--db=PATH` | Which project's sessions (default: most-recently-active) |
| `--format=FMT` | On `list`: `text` (default) or `json` |
| `--interval=SEC` | On `resume`: poll interval (default 5) |
| `--once` | On `resume`: poll once and exit |
| `--json` | On `resume`: emit the payload and each callback as a JSON line |

**`oast providers`**: the saved providers stored with the project, as opposed to the ad-hoc `listen` above. Verbs: `list` (default), `add`, `update`, `enable`, `disable`, `delete` (`rm`).

```bash
gori run oast providers                                  # tokens print as [REDACTED]
gori run oast providers add --name lab --kind custom-http --host https://oast.lab.internal
gori run oast providers enable p_1
```

`enable`, `disable`, `update` and `delete` take the provider **id** (`p_1`, or a bare `1`), not its display name — `add` prints the id it assigned, and `list` shows it.

| Option | Description |
|--------|-------------|
| `--name=NAME` | Display name. Required on `add` |
| `--kind=KIND` | `interactsh` (default) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--host=URL` | Server / base URL (defaults to the kind's public preset) |
| `--token=TOK` | Provider auth token |
| `--enabled` / `--disabled` | Arm or disarm the provider on `add` / `update` |
| `--show-tokens` | On `list`: print tokens instead of `[REDACTED]` |

### run jwt

Decode, re-sign, or generate attack payloads for a JWT. Store-free compute; the token comes from the `<token>` argument or stdin.

```bash
gori run jwt eyJhbGci...                        # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --attacks
```

| Option | Description |
|--------|-------------|
| `--decode` | Decode header / payload / signature (default) |
| `--encode` | Re-sign the token's claims with `--alg` / `--secret` |
| `--attacks` | Generate testing payloads (alg:none, weak-secret, header injection) |
| `--alg=ALG` | Signing alg for `--encode`: `HS256` (default) \| `HS384` \| `HS512` \| `none` |
| `--secret=SECRET` | HMAC secret for `--encode` with an HS algorithm |
| `--format` | `text` (default) or `json` |

### run cookie

Decode, verify, brute-force, or forge a signed Flask / Rack / Django session cookie. Store-free compute; the cookie comes from the `<cookie>` argument or stdin.

```bash
gori run cookie 'eyJ1c2VyIjoi...'                            # decode (default), format auto-detected
gori run cookie 'eyJ1c2VyIjoi...' --crack --wordlist secrets.txt
gori run cookie --forge --type flask --secret s3cret --payload '{"user":"admin"}'
```

| Option | Description |
|--------|-------------|
| `--decode` | Parse into payload / timestamp / signature (default) |
| `--verify` | Verify the signature against `--secret` |
| `--crack` | Brute-force the secret over `--secrets` or `--wordlist` |
| `--forge` | Re-sign `--payload` (or a Rack `--value`) with `--secret` |
| `--type=T` | `flask` \| `rack` \| `django` (default: auto-detect) |
| `--secret=S`, `--secrets=LIST`, `--wordlist=PATH` | The signing secret, a comma-separated candidate list, or a newline-delimited file |
| `--payload=JSON` | Session JSON to sign (Flask / Django `--forge`) |
| `--value=B64` | Base64 Marshal cookie value (Rack `--forge`, opaque) |
| `--salt=SALT` | Flask / Django signing salt |
| `--algorithm=ALG` | Django HMAC algorithm: `sha256` (default) or `sha1` |
| `--timestamp=UNIX` | Unix second to stamp on `--forge` (default: now) |
| `--format` | `text` (default) or `json` |

### run decoder

Run a [Decoder](/guide/decoder/) chain over a value. Steps are separated by `|`, `>`, or `,`.

```bash
gori run decoder 'base64-decode | jwt-decode' "$TOKEN"
echo -n secret | gori run decoder 'sha256 | hex-encode'
gori run decoder list                           # every converter (name, category, direction)
```

| Option | Description |
|--------|-------------|
| `--input=STR` | Value to convert (else the 2nd positional arg, else stdin) |
| `-o`, `--output=MODE` | Render final bytes: `auto` (default) \| `text` \| `base64` \| `hex` |
| `--format` | `text` (default) or `json` (per-step detail) |

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

Notes are readable and writable too. `notes` with no argument lists them (`*` marks the active note); `notes <n>` prints one by index:

```bash
gori run notes                                  # list
gori run notes 2                                # print note 2
gori run notes create --text "SSRF candidate on /fetch"
echo "pasted from a scratchpad" | gori run notes create
gori run notes delete 2
```

| Option | Description |
|--------|-------------|
| `list` | `--all` prints every note in full instead of a summary line |
| `create` | `--text=TEXT`, or a positional argument, or STDIN |
| `delete <n>` (`rm`) | Delete the note at index `n` |

### run links

The evidence an Issue or Note points at: a captured Flow, a Repeater session, or a Fuzz / Miner run. The Markdown issue export resolves these already; this is the surface that lists and edits them.

```bash
gori run links --owner=issue --id=7
gori run links add --owner=issue --id=7 --ref=flow --ref-id=42
gori run links delete --owner=note --id=2 --ref=repeater --ref-id=3
```

| Option | Description |
|--------|-------------|
| `--owner=KIND` | Owner kind: `issue` (default) or `note` |
| `--id=N` | Owner issue / note id. Required |
| `--ref=KIND` | Target kind for `add` / `delete`: `flow`, `repeater`, `fuzz`, `miner` |
| `--ref-id=M` | Target id for `add` / `delete` |
| `--format=FMT` | `text` (default) or `json`, on `list` |

A pointer whose target was pruned lists as `(stale)` rather than disappearing, so "no evidence" and "evidence that is gone" stay distinguishable. `add` is idempotent, and both ends must exist.

### run rewriter

Manage Match & Replace rules from scripts. The same rules the [Rewriter tab](/guide/proxy/) edits, applied to live proxy traffic:

```bash
gori run rewriter                                       # list rules in apply order
gori run rewriter add --op set_header --target request \
  --find X-Forwarded-For --value 127.0.0.1 --host '*.example.com'
gori run rewriter add --op replace --target response --part body \
  --match regex --find 'secret=(\w+)' --value 'secret=[redacted]'
gori run rewriter add --op remove_header --target response \
  --find Content-Security-Policy --scope global          # applies in EVERY project
gori run rewriter preview --op replace --part body --find password --value hunter2
gori run rewriter disable 3
gori run rewriter disable 2 --scope global               # off in THIS project only
gori run rewriter disable 2 --scope global --everywhere  # off by default, everywhere
gori run rewriter rm 3
```

| Option | Description |
|--------|-------------|
| `--op=OP` | `replace` (default), `add_header`, `set_header`, `remove_header`, `short_circuit` |
| `--target=SIDE` | `request` (default) or `response` |
| `--part=PART` | `head` (default), `body`, or `ws` (a WebSocket message). Only meaningful for `replace` |
| `--match=MODE` | `literal` (default) or `regex`, for `replace` and `short_circuit`. Regex replacements take `$1`, `$2`; `$$` is a literal `$` |
| `--response-file=PATH` | `short_circuit`: read the canned response from PATH (`-` = stdin) |
| `--body-file=PATH` | `short_circuit`: serve PATH as the response body, re-read whenever it changes |
| `-f`, `--find=FIND` | Required. The literal, pattern, or header name to act on |
| `-v`, `--value=VALUE` | Replacement text or header value |
| `--host=GLOB` | Limit the rule to matching hosts (substring, `*` wildcard). Omit to apply everywhere |
| `--name=NAME` | Label shown in the rule list |
| `--disabled` | Create the rule without arming it |
| `--scope=SCOPE` | `project` (default) or `global`. A global rule lives in `settings.json` and applies in every project |
| `--everywhere` | On `enable`/`disable` of a global rule: change the rule's own default instead of this project's override |

`preview` takes the same rule flags and reports how many stored flows the rule would have changed, without writing it. `rm` (`delete`), `enable` and `disable` take a rule id from the list — and `--scope`, because the two stores number their rules independently, so an id alone names two different rules. The list prints the scope as a `G`/`P` prefix (`G*` = this project overrides that global rule's default) and shows global rules first, the order the proxy applies them in. See [Global and project rules](/guide/proxy/#global-and-project-rules).

Body rules re-sync `Content-Length` and de-chunk as needed, and an enabled rule forces HTTP/1.1 on hosts it matches. See [Proxy & History](/guide/proxy/) for the interactive editor.

**`rewriter extract`**: the rules that declare [session bindings](/guide/proxy/#session-bindings) — which response a `$NAME` is read from, and where in it. Verbs: `list` (default), `add`, `rm` (`delete`), `enable`, `disable`.

```bash
gori run rewriter extract add --name SESS --kind cookie --selector session --host '*.example.com'
gori run rewriter extract add --name CSRF --kind regex --selector 'name="csrf" value="([^"]+)"'
```

| Option | Description |
|--------|-------------|
| `--name=NAME` | Binding name, without the `$`. Required |
| `--kind=KIND` | `cookie` (default), `header`, `regex`, `position`, `jsonpath` |
| `--selector=SEL` | Cookie / header name, regex, or JSON path |
| `--range=A:B` | `position` only: a half-open byte range of the decoded body |
| `--when=FILTER` | Which messages to read, in intercept-filter syntax (`''` = any) |
| `--host=GLOB` | Limit to a host glob (`''` = all) |
| `--disabled` | Create the rule without arming it |

**`rewriter bindings`**: list the names those rules declare (`--format text|json`). Values are not shown here and cannot be: a binding's value lives in the memory of the running gori and is never written anywhere, so another process has nothing to read. The Rewriter tab's `bindings` sub-tab shows the live table. For a headless sweep, `--bind-from` fills the values in-process — see [Session bindings from the command line](#session-bindings-from-the-command-line).

### run colormarker

Manage **Colormarker** rules — which captured History rows get coloured, and how. Display only: a colour rule never modifies traffic, so unlike a Match & Replace rule it costs a misleading list at worst, never a modified message.

```bash
gori run colormarker                                        # list rules in precedence order
gori run colormarker add --when 'status:>=500' --color red --style full --name 'prod 5xx'
gori run colormarker add --when 'host:cdn' --color blue --style strip --scope global
gori run colormarker move 2 --up                            # higher precedence
gori run colormarker preview --when 'method:DELETE'
gori run colormarker disable 1 --scope global               # off in THIS project only
gori run colormarker disable 1 --scope global --everywhere  # off by default, everywhere
gori run colormarker rm 3
```

| Option | Description |
|--------|-------------|
| `-w`, `--when=FILTER` | Required. The condition a flow must match — see below |
| `--color=NAME` | `red`, `orange`, `yellow` (default), `green`, `blue`, `purple`. Resolved through the active theme, so it reads correctly on light and dark alike |
| `--style=STYLE` | `full` (default) tints the whole row · `strip` paints one colour cell in a narrow column ahead of `TIME` |
| `--name=NAME` | Label shown in the rule list |
| `--disabled` | Create the rule without arming it |
| `--scope=SCOPE` | `project` (default) or `global`. A global rule lives in `settings.json` and applies in every project |
| `--everywhere` | On `enable`/`disable` of a global rule: change the rule's own default instead of this project's override |
| `--up` / `--down` | On `move`: raise or lower the rule's precedence |

**Precedence is the rule set's meaning.** Match & Replace rules *compose* — every enabled rule runs, in order. Colour rules *resolve*: the **first enabled match paints the row** and the rest are never consulted. That is why `move` exists here and not on `rewriter`. Global rules resolve before project ones, so a standing policy outranks a local layer.

`--when` uses the same boolean grammar the conditional-intercept bar speaks — `host:` `path:` `method:` `scheme:` `status:` `proto:`, plus `AND` / `OR` / `NOT`, `-negation` and `(grouping)` — evaluated against the captured flow row. Three caveats, each of which would otherwise fail silently, so gori refuses or warns rather than letting you find out from an empty list:

- **`body:` never matches here.** A History row carries no payload. (Warned, not refused — the term is legal.)
- **`host:` is a substring, not a DNS-label glob.** `host:alpha.test` also matches `xalpha.test`. (Warned.)
- **There is no `header:` / `size:` / `dur:` / `url:` / `stub:`.** Those are History QL fields that need a query, and this is evaluated on the render path. An unknown field is **refused** — left alone it would quietly become a free-text search and the rule would never fire.

A condition that matches *every* flow (empty, or a half-typed `host:`) is refused too.

`preview` reports how many recent flows the condition **matches** and how many it would actually **paint** — the two differ whenever an earlier enabled rule already claims the row. `rm` (`delete`), `enable`, `disable` and `move` take a rule id from the list, and `--scope`, because the two stores number their rules independently, so an id alone names two different rules. The list prints the scope as a `G`/`P` prefix (`G*` = this project overrides that global rule's default).

The tab is **hidden by default** — show it from `settings:tabs`, next to Rewriter. See [Proxy & History](/guide/proxy/) for the interactive editor.

#### colormarker color

The **custom colour palette**: named colours the picker offers in every project on top of the six built-ins. A built-in resolves through the active theme, so it reads correctly on light and dark alike; a custom carries an absolute hex and does not track the theme. That is the trade for a hue the palette does not provide. Colours live in `settings.json` (`colormarker.colors`), so they are global by construction.

```bash
gori run colormarker color list
gori run colormarker color add --name hotpink --hex '#ff69b4'
gori run colormarker color update hotpink --hex '#e0559b'   # recolour, keep the name
gori run colormarker color update hotpink --name fuchsia    # rename, keep the hex
gori run colormarker color rm fuchsia
gori run colormarker add --when 'method:DELETE' --color hotpink
```

The name is the identity — it is what a rule's `--color` stores and what the picker shows — so it is lowercased, must be unique, and may not be one of the built-in words. `update` takes either half alone.

Deleting or **renaming** a colour deliberately does **not** rewrite the rules that name it: they keep the reference and fall back to a visible default, so re-adding the colour restores them. gori cannot reach every project's database from here, and a half-applied cascade would be worse than a dangling name. Recolouring is different — a rule references a colour by name, so it follows the new hex everywhere.

### run project

List, create, or delete projects, or manage project-scoped config (scope rules, env vars, host overrides):

```bash
gori run project --format json
gori run project list
```

#### project create

Create a project without capturing into it first. `gori run capture --project=NAME` also creates on demand; this is the traffic-free way to do it, so scripts can set up scope and env before the proxy starts.

```bash
gori run project create "API test"
gori run project create api-test --description="staging sweep"
gori run project create api-test --format json
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<name>` | Display name. Quote it if it contains spaces |
| `--description=TEXT` | Stored in the project's settings |
| `--format=FMT` | `text` (default) or `json` |

A name that already exists reopens that project instead of failing; `--format json` reports it as `"created": false`. The reopen rewrites the stored display name (so its casing follows the last create) and replaces the description when `--description` is given.

#### project delete

Delete a project directory and everything captured in it (flows, issues, notes, scope, rules). Irreversible, so it takes two steps: without `--yes` it only prints the target and exits non-zero.

```bash
gori run project delete api-test              # preview only, nothing is removed
gori run project delete api-test --format json
gori run project rm api-test --yes            # actually delete
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<name>` | Matches a short id, id prefix, directory slug, or display name |
| `--yes` | Perform the delete. Without it the command removes nothing |
| `--format=FMT` | `text` (default) or `json` |

The preview reports flow and issue counts, on-disk size, and whether a capture is live. Deleting a project another gori instance is capturing into is refused: stop that capture first.

Display names are not unique (two workspaces with the same basename share one). When a name matches more than one project, delete refuses and lists their slugs, since the wrong guess is unrecoverable. Slugs and short ids are unique, so either always resolves.

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

#### project sandbox

Get or set the **hard-containment** sandbox gate, the headless equivalent of the TUI Project NETWORK toggle. When on, the capture proxy forwards only requests the scope allows and blocks everything else. This is distinct from `project scope enable`, which is only the display lens.

```bash
gori run project sandbox                 # show the current state (status is the default)
gori run project sandbox status --format json
gori run project sandbox on              # start blocking out-of-scope traffic
gori run project sandbox off             # stop blocking
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) / `status` | Show the gate state; `--format` is `text` or `json` |
| `on` / `enable` | Block every request the scope does not allow |
| `off` / `disable` | Stop blocking |

> With no include rule, turning the sandbox on blocks **all** captured traffic until you add one (`gori run project scope add …`). The command warns and proceeds, so it can bootstrap containment for CI.

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

Manage **project** host overrides: `/etc/hosts`-style maps that change only the TCP dial target (SNI, certificate hostname, and `Host` header stay the original name). The value may carry a **port** — `IP`, `IP:PORT` or `[v6]:PORT` — so a hostname can be redirected at a listener on a different port; a bare IP keeps the request's own port. Project entries win over the global hostname overrides on collision. Alias: `host-overrides`.

```bash
gori run project host-override                              # list
gori run project host-override --format json
gori run project host-override add --host=api.example.com --ip=10.0.0.1
gori run project host-override add 10.0.0.1 api.example.com   # /etc/hosts order
gori run project host-override add --host=api.example.com --ip=127.0.0.1:8443   # move the port too
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
| `--no-project` | Start unbound even inside a Git workspace (agent picks via list/create/switch) |
| `--insecure-upstream` | `send_request`: skip upstream TLS verification |
| `--read-only` | Disable action tools (`send_request`, create/update issues, fuzz/mine); `switch_project` (and `create_project` when unbound) stay available |
| `--install-claude` | Write Claude Desktop `mcpServers` config |
| `--install-claude-code` | Write Claude Code `~/.claude.json` `mcpServers` entry |
| `--install-codex` | Write OpenAI Codex `~/.codex/config.toml` `[mcp_servers.gori]` |
| `--install-agy` | Write Antigravity `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Write Grok `~/.grok/config.toml` `[mcp_servers.gori]` |

Several `--install-*` flags may be given in one run; each named client is configured and reported separately, and one unwritable config does not stop the others. Every other flag on the command line — `--db`, `--project`, `--no-project`, `--use-active-project`, `--read-only`, `--insecure-upstream`, and the global `--config` — is written into the installed command, with paths made absolute. Existing config files are updated in place: other entries, tables and comments survive, permissions are preserved, and the replacement is atomic.

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

A verb comes first and its flags after it — `gori ca regenerate --ca-dir=DIR`, not `gori ca --ca-dir=DIR regenerate`. The reverse order is a usage error, because the verb would otherwise be dropped and the command would print the CA path as if it had done the work. None of the three forms takes a positional argument.

`gori ca` also reports a root CA that loads but cannot serve — a private key that does not match the certificate, or a key gori cannot sign with — on stderr, since the symptom otherwise appears only at the client as an "unknown CA" or "bad signature" handshake failure. `regenerate` and `import` are the fix, and both work on a CA directory in any state, including one where only one file of the pair survives.

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

The pair is validated before anything is written: the key must match the certificate, the certificate must be a CA (`basicConstraints CA:TRUE`), and gori must be able to sign a leaf certificate with the key. That last check rules out **Ed25519 and Ed448 roots** — gori signs leaves with SHA-256, which those keys do not support — so use an EC P-256 or an RSA root. A rejected pair aborts without touching the current CA. An expired or not-yet-valid certificate imports with a warning. Confirm by typing `import` on a tty, or pass `--yes`. The same action is available from the TUI palette (**Import CA certificate**).

Generate a root with OpenSSL, then import it:

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

Trust only `root.crt.pem` in your clients. Never distribute the private key.

## gori settings

```bash
gori settings                      # print the settings.json path
gori settings --edit               # open it in $EDITOR
gori settings sections             # list the top-level sections
gori settings export [-o FILE]     # write a shareable profile (stdout by default)
gori settings import FILE          # apply a profile's sections
```

### Profiles

`export` and `import` move settings between machines, share them with a team, or check a configuration into a repository for a reproducible run. The unit is the top-level section, listed by `gori settings sections`.

```bash
gori settings export --sections network,scan_rules -o team-profile.json
gori settings import team-profile.json --dry-run     # show what would be applied
gori settings import team-profile.json --sections network
```

`gori settings sections` lists every section gori knows, marking the ones this install has no value for yet:

```
network
scan_rules  (not set — at its default)
env  (holds secrets — excluded unless named; not set — at its default)
```

A section marked *not set* is still a valid name for `--sections`: exporting it simply carries nothing (gori says so on stderr), and importing one writes it for the first time.

| Flag | Applies to | Description |
|------|-----------|-------------|
| `--sections a,b` | both | Comma-separated section names; at least one. Export defaults to everything except secret-bearing sections; import defaults to every section in the file |
| `-o`, `--out FILE` | export | Write to a file instead of stdout |
| `--dry-run` | import | Print which sections would be applied, then exit without writing |

A section you do not select — or that the profile does not carry — is left **exactly as it was**. That is the guarantee `--sections` is choosing between. Within a section the profile *does* carry:

- **List and table sections replace wholesale**: `upstream_rules`, `outbound_tls`, `listeners`, `scan_rules`, `hostname_overrides`, `tabs`, and the rest. A profile carrying `"upstream_rules": []` clears the table — that is how "no rules" is stated.
- **Object-of-scalars sections apply key by key**: `network`, `editor`, `probe`. A key the profile omits keeps its current value, so a team profile that pins `network.upstream_proxy` does not also reset everyone's `bind_port` to a default it never mentioned.

Note that `export` omits a section sitting at its factory default, so a profile is a set of values to *apply*, not a snapshot of a whole configuration: exporting from a machine where a value is default will not reset that value on a machine where it is not. Pass `--dry-run` to see which sections an import would touch — it errs on the side of listing one, so a section it does *not* name is guaranteed to be a no-op.

Import goes through the same writer the TUI uses, so it keeps the atomic write and cannot clobber a concurrently-running gori's edit to — or deletion of — a section it did not touch. Unrecognised sections in the file are reported and ignored: they reach neither the live settings nor the file.

If gori cannot load your `settings.json` — unparseable, unreadable, or a `--config` pointing at something it cannot open — both `export` and `import` refuse rather than proceeding. Every section is at its factory default at that point, so an import would persist those defaults over every section the profile does not name, and an export would write them out as if they were yours. Fix or remove the file first; an unparseable one is kept alongside it as `settings.json.corrupt`. `--dry-run` is the exception: it writes nothing, so it still runs, and says on stderr that the comparison is against defaults.

`env` and `decoder` are excluded from an export by default: `env` holds token values and `decoder` holds your last input and saved sessions. Naming one explicitly (`--sections env`) is how you consent to include it. Note that `upstream_rules` is safe to share — it stores a username and an environment-variable *name*, never a password.

`-o` pointing at your live `settings.json` is refused. An export is not a snapshot — it omits every section at its factory default, and omits `env` and `decoder` unless you name them — so writing one back over the real file would delete those sections rather than update it.

When an export **does** carry one of those sections, `-o FILE` is created `0600` and gori says so, naming what is in the file. Consenting to export a credential is not consenting to leave it world-readable. An ordinary export stays `0644`, and an export that names `env` on an install with no env vars is an ordinary export — the mode follows what the document actually contains, not what you typed.

### `--config PATH`

`--config` points gori at a specific settings file for one run. It works before any subcommand:

```bash
gori --config ./ci-profile.json run capture --target https://api.example.com
gori --config ~/profiles/corp.json          # the TUI, with a different config
```

Resolution order is `--config` → `$GORI_CONFIG` → `$GORI_HOME/settings.json`.

This is deliberately **orthogonal to `GORI_HOME`**: it changes only which settings file is read and written, leaving the CA, the project databases, the themes and the wordlists where they are. Relocating the whole tree was previously the only way to switch configuration.

## gori wizard

```bash
gori wizard
```

Runs the interactive setup (global proxy bind default, then theme, then the Miss Ring mascot). Also runs automatically on first launch. The bind step writes the shared `settings.json` defaults. Projects can still pin their own address in the Project tab; `--listen` / `--port` override for one run only.

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
| Nix (`/nix/store`) | Prints `nix profile upgrade` / flake-update guidance; the store is read-only, so nothing is downloaded |

Paths under `/usr/bin` or `/bin` are classified by package ownership (`pacman -Qo`, `dpkg-query -S`, `rpm -qf`). If a manager owns the file, gori never overwrites it. If probes find no owner, the binary channel self-updates. When no package tools are available, `/etc/os-release` (`ID` / `ID_LIKE`) picks Arch-like / Debian-like / RHEL-like guidance as a fallback.

Release asset names match the [installation guide](/getting-started/installation/) (`gori-v*-linux-*` plain binaries, `gori-v*-osx-*.tar.gz` archives). macOS archive updates require a dedicated layout (e.g. `PREFIX/opt/gori` from the curl installer) so bundled `lib/` is never written under shared roots like `/usr/local/lib`. If no release assets exist yet, the command exits with a clear error pointing at the releases page. It does not silently no-op.
