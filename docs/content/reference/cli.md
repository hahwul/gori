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
| --------- | ------------- |
| `tui` | Start the proxy and terminal UI (default) |
| `run` | Non-interactive suite over a project |
| `mcp` | Model Context Protocol stdio server |
| `ca` | Print the root CA path / PEM, or regenerate / import the CA |
| `settings` | Show or edit `settings.json` |
| `wizard` | Interactive first-run setup |
| `tutorial` | Guided TUI tour (navigation, palette, space menu, edit mode) |
| `update` | Channel-aware self-update (binary / Homebrew / Snap / AUR / Nix) |

Global flags: `-v` / `-V` / `--version`, `-h` / `--help`.

## gori tui

Start the intercepting proxy and TUI. This is the default when no subcommand is given.

```bash
gori
gori tui --listen 0.0.0.0 --port 8080
```

| Option | Description |
| -------- | ------------- |
| `-l`, `--listen=HOST` | Global bind address for this process (defaults to `settings.json`, else `127.0.0.1`). Not persisted. A project's own bind still wins when set. |
| `-p`, `--port=PORT` | Global bind port for this process, `0`-`65535` (defaults to `settings.json`, else `8070`). Not persisted. Project `net.bind_port` still wins when set. |
| `--db=PATH` | SQLite database path |
| `--ca-dir=PATH` | Directory for the root CA |
| `--insecure-upstream` | Do not verify upstream TLS certificates |

> `GORI_HOME` is an environment variable, not a flag. Project selection in the TUI is done through the project picker. Bind flags only set the global layer for this run. See [Configuration](/getting-started/configuration/#network). For the root CA path, use [`gori ca`](#gori-ca).

## gori run

The non-interactive suite. Each subcommand operates over a project; with neither `--project` nor `--db` it uses the most-recently-active project, and says so once on stderr (`gori run: using project demo (most recently active)`), because creating a project anywhere re-aims every later command. The two are alternatives: passing **both** is a usage error, not a silent win for `--db`. See the [Scripting guide](/guide/scripting/) for the working patterns.

```bash
gori run <subcommand> [verb] [options]
```

| Subcommand | Description |
| ------------ | ------------- |
| `capture` | Run the proxy and stream captured flows to STDOUT |
| `history` (`ls`) | List / query captured flows |
| `history delete <id>` · `delete -q QL` · `clear` | Hard-delete one flow, every flow a query matches (`--yes`), or wipe the project's History (`--yes`) |
| `show <flow-id>` | Print one flow's request and response |
| `compare <id-a> <id-b>` | Diff two flows' request or response |
| `diff --from A --to B` | Retest report: diff two projects at endpoint scale (added / gone / changed / unchanged / removed) |
| `intercept` | Inspect and drive a capturing TUI's live intercept queue |
| `send [URL]` | Send one request built from a URL (curl-shaped) or a raw request, without creating a Repeater session |
| `repeater <flow-id>` · `list` · `create` · `send` | Re-send a captured flow, or list / create / execute Repeater sessions (incl. WebSocket) |
| `repeater minimize <id>` | Strip a saved request to the smallest form that keeps the response |
| `repeater h2` | Send a field-native HTTP/2 request from an ordered HPACK field list |
| `repeater move <id>` · `delete <id>…` | Reorder the workbench strip by tab number, or close one or more saved sessions |
| `fuzz [<flow-id>]` | Intruder-style fuzzer |
| `fuzz save` · `list` · `show` · `delete` | Store a sweep's every result permanently, then page and prune the archive |
| `mine [<flow-id>]` | Hidden-parameter discovery |
| `sequence` (`seq`) `[<flow-id>]` | Grade token randomness (live replay, or `--tokens` for a pasted list) |
| `authorize [<flow-id>…]` | Replay captured flows under several identities and judge each response against a baseline (broken access control) |
| `cache-deception [<flow-id>…]` | Check flows for web cache deception: prime authenticated, re-request anonymously, then compare with a cache-busted anonymous control |
| `probe [QL]` | Passive security scan (no requests) |
| `probe issues` · `dismiss` · `promote` · `delete` | Triage persisted Probe findings |
| `probe rules` · `mode` | List / arm scan rules; get or set the scan mode |
| `discover` | Spider and brute-force endpoints into the Sitemap |
| `import` | Bulk-import flows into History from a HAR / URL list / OpenAPI / Postman / Insomnia / Burp / WSDL file |
| `sitemap [QL]` | Host → path endpoint tree |
| `sitemap tag` | Pin, clear, or list a free-text memo on a sitemap path |
| `sitemap params [QL]` | Per-endpoint parameter inventory: names by location, counts, sample values, reflected values |
| `sitemap export [QL]` | The captured API as an OpenAPI 3.0.3 document (JSON or YAML) |
| `oast listen` · `presets` | Out-of-band callback listener (interactsh & friends) |
| `oast list` · `resume` · `release` | List, resume, or release the project's saved OAST listening sessions |
| `oast providers` | List / add / update / enable / disable / delete saved OAST providers |
| `jwt [<token>]` | Decode, re-sign, or generate attack payloads for a JWT |
| `cookie [<cookie>]` | Decode, verify, brute-force, or forge a Flask / Rack / Django session cookie |
| `decoder <chain> [input]` | Run a Decoder encode / decode / hash chain |
| `notes [<n>]` · `create` · `delete` | Read, write, or delete project notes (`delete` needs `--yes`) |
| `issues` · `create` · `update` · `delete` | List / export issues, or write and remove issues |
| `links` · `add` · `delete` | Evidence pointers from an issue or note to a flow, Repeater session, or job |
| `rewriter` · `add` · `rm` · `enable` · `disable` · `preview` | Manage Match & Replace rules |
| `rewriter preset list` · `add` | List the response-modification presets, and install one as ordinary Match & Replace rules |
| `rewriter extract` · `bindings` | Manage session-binding extract rules, and list the `$BIND.NAME`s they declare |
| `colormarker` · `add` · `update` · `rm` · `enable` · `disable` · `move` · `preview` · `color` | Manage History row-colour rules |
| `views` · `add` · `set` · `rename` · `scope` · `rm` | Manage saved History views: named QL queries the list is narrowed by, as a lens |
| `session` · `add` · `from-flow` · `edit` · `rm` · `baseline` · `show` · `activate` | Session slots: the named identities a send or an Authorize run goes out as |
| `grpc [schema]` · `reflect` · `forget` | The gRPC `.proto` lens: show what is loaded, fetch descriptors by server reflection, drop a cached target |
| `project [list]` | List known projects |
| `project create <name>` | Create (or reopen) a project by name |
| `project export <name>` | Save a compact, WAL-safe `.gori` project archive |
| `project import <archive>` | Add a project archive as a new project |
| `project delete <name>` | Delete a project and everything captured in it (`--yes` to confirm) |
| `project scope` | List / add / update / delete / enable / disable scope rules |
| `project sandbox` | Get / set the hard-containment sandbox gate (`status`, `on`, `off`) |
| `project env` | List / set / delete project env vars (`$ENV.KEY` substitution) |
| `project host-override` | List / add / update / delete project host to IP dial overrides |
| `project network` | List / get / set / unset the project's own network settings (`net.*`: upstream proxy and credentials, destination host, timeouts, capture cap, bind) |

Common flags across read subcommands: `--project=NAME`, `--db=PATH`, `--format=FMT` (usually `text` or `json`). Global flags go **after** the verb: `gori run rewriter rm 1 --project=x`, not `gori run rewriter --project=x rm 1`, which is rejected as a usage error rather than silently listing.

Read subcommands open the store read-only and never take the capture lock, so they are safe to run against a project a live TUI is capturing into. A `body:` query drains the search index and is therefore a write. A `--db` file that is not a gori project (another tool's SQLite database, or an empty file) is refused before anything touches it; commands that create their database (`import --db`, `capture --db`) still initialise an empty file, but refuse one that holds another tool's tables.

Write subcommands share that project's WAL database with the TUI and MCP. They serialize through
the Store writer and can run while the TUI is open, but a capture commit can temporarily own the
SQLite writer slot. A short-lived subcommand gives its SQLite open/writer waits a one-second budget; if the
slot is still busy, the required write exits non-zero and says the project is locked by another gori, with the workaround (retry, or read it with a read-only subcommand).
A subcommand that keeps the project open for a whole run (`discover`, `fuzz`, `import`, `probe`, `retest run`,
`oast listen`/`resume`, `intercept`) keeps the standard five-second wait instead. A
repeater send also fails instead of claiming success when its network response could not be saved,
so a script can distinguish a completed write from a response that needs attention.

#### Output contract

STDOUT carries data; warnings, counts, and export confirmations go to STDERR, so a pipe stays clean. A reader that closes the pipe early (`… | head`) exits `0` quietly.

Where a run streams, `json` and `jsonl` are not always the same shape:

| Subcommand | `--format json` | `--format jsonl` |
|------------|-----------------|------------------|
| `capture`, `history` | One JSON object per line | Alias for `json`, same output |
| `fuzz`, `mine`, `discover`, `authorize` | Buffered; one JSON array at the end | One object per line, as each result lands |

| Exit code | Meaning |
| ----------- | --------- |
| `0` | Success |
| `1` | Error: a failed send, an unreadable project, a mutation that could not be applied |
| `3` | `run fuzz --fail-if-no-matches` completed but nothing matched |
| `130` | Interrupted by SIGINT/SIGTERM. `fuzz`, `mine`, `discover`, `sequence`, `authorize` and `repeater minimize` flush what they collected first, then exit `130` so a scripted `&& next-step` does not treat a truncated run as a finished one |

Without `--fail-if-no-matches`, a fuzz run that matched nothing *and* errored on every send still exits `1`, so "no findings" stays distinguishable from "never reached the target". With the flag, `3` wins.

**A create takes `--format json` and answers with the new row.** `repeater create`, `issues create`, `notes create`, `views add`, `colormarker add`, `rewriter add`, `rewriter extract add`, `probe rules add`, `oast providers add`, `links add`, `project scope add` and `project host-override add` print one object on STDOUT, read back after the write committed, in exactly the shape that family's listing prints for the same row. A script therefore takes the id with `jq .id` instead of scraping it out of a sentence. The id is whatever the rest of that family takes: a number for most, the rule name (`custom_p_7`) for a probe rule and the provider key (`p_3`) for an OAST provider. A view is addressed by name, so its object carries `name` and `key` rather than an id. `notes create` adds `index`, the position the text line names, and `links add` adds `created`, which is `false` for a pair that was already linked (with that link's id). Text output is unchanged.

```bash
issue=$(gori run issues create --title "IDOR on /v1/users/{id}" --severity high --format json | jq .id)
gori run links add --owner=issue --id="$issue" --ref=flow --ref-id=42 --format json
```

### run capture

```bash
gori run capture --port 8070 --format json --for 5m
```

| Option | Description |
| -------- | ------------- |
| `-l`, `--listen`; `-p`, `--port` | Global bind for this process (settings default; project override still wins) |
| `--project=NAME` | Project to write to (default `default`) |
| `--db=PATH` | Database path |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--format=FMT` | `text` or `json` (JSON Lines) |
| `--for=DURATION` | Stop after e.g. `30s`, `5m`, `1h` |
| `--max=N` | Stop after N completed flows; upgraded tunnels count after they close |

### run shell

Open a terminal whose tools go through a live gori and trust its CA, without touching OS settings. It is the terminal counterpart of the palette's **Open browser**.

```bash
gori run shell                            # interactive $SHELL; `exit` to leave
gori run shell -- curl https://target/    # one command, exits with its status
eval "$(gori run shell --print)"          # export lines for the shell you are already in
gori run shell --print --shell fish | source
```

The address comes from the gori capturing the project (its live port, even after a port fallback), and the CA from the one that gori signs with. When nothing is capturing the project, the command refuses unless `--proxy` names an address. When capture is paused, it warns and continues.

| Option | Description |
| -------- | ------------- |
| `--project=NAME`; `--db=PATH` | Which live gori to point at (default: the most recently active project) |
| `--proxy=HOST:PORT` | Use this proxy address instead of looking up a live capture |
| `--ca-dir=DIR` | CA directory (default: the capturing gori's, else `~/.gori/ca`) |
| `--print` | Print `export` lines instead of starting a shell |
| `--shell=SYNTAX` | Syntax for `--print`: `sh` (default; also `bash`, `zsh`) or `fish` |
| `--keep-no-proxy` | Keep the inherited `NO_PROXY` instead of unsetting it |

What gets set: `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` point at gori, and `NO_PROXY`/`no_proxy` are unset so local targets are captured too. `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `AWS_CA_BUNDLE`, `PIP_CERT`, `CARGO_HTTP_CAINFO` and `DENO_CERT` point at a bundle under `~/.gori/shell/`. That bundle holds the store the terminal already trusted (your own `SSL_CERT_FILE`, else the system roots) plus gori's root, because most of these variables replace a tool's trust store rather than add to it. A CA variable you had set for one tool (say `REQUESTS_CA_BUNDLE`) gets its own file with gori's root added, rather than the shared one. `NODE_EXTRA_CA_CERTS` adds gori's root, `NODE_USE_ENV_PROXY=1` turns on Node's proxy support, and `GODEBUG=x509sslcertoverrideplatform=1` makes Go on macOS read `SSL_CERT_FILE`. `GORI_SHELL=1` and `GORI_PROXY=HOST:PORT` mark the shell for your prompt:

```bash
# ~/.zshrc or ~/.bashrc
[ -n "$GORI_SHELL" ] && PS1="(gori) $PS1"
```

Whatever the shell replaces or unsets is recorded as `GORI_SHELL_ORIG_<NAME>` (for example `GORI_SHELL_ORIG_HTTPS_PROXY`). A gori started inside the shell (`gori run send`, a second capture) does not use the shell's proxy variables as its own upstream, so its traffic is not captured twice. It uses the recorded proxy and `NO_PROXY` instead, and an upstream you configure explicitly still applies. A shell started inside a gori shell also starts from the recorded values, so it does not keep trusting the outer gori's CA.

Not covered: Go programs built with a toolchain older than 1.27 on macOS verify through the keychain; Go never proxies `localhost` or loopback addresses; Node uses the proxy only in releases that support `NODE_USE_ENV_PROXY` (stable in v22.21 and v24.10); Java needs a truststore via `JAVA_TOOL_OPTIONS`; tools that pin their own trust store are not covered.

### run history / ls

```bash
gori run history -q 'status:5xx' --limit 100 --format json
```

| Option | Description |
| -------- | ------------- |
| `-q`, `--query=QL` | Query-language filter (also accepted positionally) |
| `-n`, `--limit=N` | Max rows (default 50) |
| `--view=NAME` | Apply a saved [view](#run-views). Its query is **ANDed with** `-q`, never replacing it, exactly as the TUI's `v` picker layers over the filter bar. An unknown name is refused (and names the ones that exist) rather than ignored. Listing only |
| `--in-scope` | Only flows in the project's configured scope: the TUI's `s` lens, opt-in and independent of whether that lens is enabled. Capture still records everything; empty when no scope rules exist |
| `--hide-static` | Leave out images, fonts and audio/video: the TUI's [hide-static lens](/guide/proxy/#hide-static), the same as `-q -static:true`, and independent of whether that lens is on |
| `--lenient` | Don't refuse a query naming an unknown field; search that token as text |
| `--column=SPEC` | Show an extracted value per row (repeatable). `[LABEL=][req\|res:]kind:selector`, e.g. `header:x-request-id`, `RID=req:header:authorization`, `jsonpath:data.id`, `regex:token=(\w+)`, `position:0:32`. Any `--column` **replaces** this project's configured [History columns](/guide/proxy/#columns) |
| `--no-columns` | Don't draw this project's configured History columns |
| `--format=FMT` | `text`, `json` / `jsonl` (both JSON-Lines), or `har` |
| `--include-sensitive` | Emit `Authorization` / `Cookie` / `Set-Cookie` / `Proxy-Authorization` / API-key values — in `json`'s per-row `headers` and in a `header:`/`cookie:` column — instead of `[REDACTED]`. Inert in the other formats, which say so on STDERR |
| `--redact [PROFILE]` | Sanitize request/response **bodies** before writing them, using a [redaction profile](#run-redact). `--format har` only — it is the one listing format that carries a body — and refused on the others rather than ignored |
| `--no-redact` | Write the captured bodies even where redaction is the configured default |
| `--redact-preview` | List what `--redact` would replace, one row per value, and write no HAR |

Subcommands: `history show <id>` (same as `run show`), `history delete <id>`, `history delete -q QL --yes`, `history clear --yes`.

This project's [History columns](/guide/proxy/#columns) are drawn by default, so a headless listing shows what the TUI's History tab shows; `--no-columns` is the way back to the plain listing. In `text` they print as `label=value` after the row (every column, empty ones included; "the descriptor found nothing here" is an answer worth seeing); in `json` they arrive as a `columns` object, absent when no column is defined. A `=` separates the label only when it comes *before* the first `:`, so `regex:token=(\w+)` is the pattern and not a column named `regex:token`. Each column costs one extra read per printed row, and up to 512 KiB of body for the three body-scoped kinds.

Each `json`/`jsonl` row carries the flow's absolute `url` and a compact `headers` object for the request (a repeated header name becomes an array). Bodies are not inlined; that is `run show`.

**Sensitive header values are `[REDACTED]` in that object by default**, and the row is marked `sensitive_headers_redacted: true` when anything was withheld — a listing is an inventory, and one run to answer "what did I capture?" should not put a live session cookie in a terminal log or an agent transcript. `--include-sensitive` returns the exact bytes. Names, wire order and the repeat count survive either way, so the redacted row still says what the request was. An [obs-fold](https://www.rfc-editor.org/rfc/rfc9110#section-5.2) continuation is folded into the field it continues and redacted with it, rather than appearing as a header of its own.

The same redaction covers a `header:` column whose selector names a sensitive header, and every `cookie:` column — a named cookie's value is part of the `Cookie` header the row is already withholding. What it does **not** cover, and cannot: `regex:`, `jsonpath:` and `position:` columns, which can lift a credential out of any byte of the message with nothing in the descriptor to say whether they do; a credential in the query string, which is part of `url` and `target`; and the `text` listing, which is the interactive read rather than the feed a script captures. `--format har` also carries the captured message in full, by design — an interchange document has to be replayable.

Every row also carries `source`, where the flow came from (`proxy`, `repeater`, `fuzzer`, `discover`, `import`, …; `null` on a flow captured before gori recorded provenance), plus `source_surface` (`tui` / `cli` / `mcp`) and `source_ref` when there is one. The text format prints a `[repeater]`-style chip on anything that is not ordinary captured traffic. Filter on it with [`src:`](/reference/query-language/#src-provenance); the same keys are on MCP `list_history` and `get_flow`.

`history delete -q QL` deletes every flow the query matches and needs `--yes`; without it, it prints how many would go and refuses. A query naming a field QL does not know (`methd:`) is refused too, rather than silently matching nothing. With neither an id nor `-q` it refuses; wiping the project is `history clear --yes`.

`--format har` writes the whole result set as one HAR 1.2 log on STDOUT, oldest entry first, so a query can be handed to a teammate or loaded into Burp, Charles, or a browser's network panel. See [HAR export](#har-export).

### run show

```bash
gori run show <flow-id> --format raw
```

`--headers-only` and `--max-body=BYTES` make the `text` and `json` views compact: `--headers-only` replaces each body with a line naming its size (`[body omitted by --headers-only: 149504 bytes]`; in JSON the body object keeps `encoding` and `size` and gains `omitted: true`), and `--max-body` prints the first BYTES of each decoded body followed by `[… truncated by --max-body: showing 2048 of 149504 bytes]` (in JSON `text`/`base64` hold the prefix, `size` the total, `shown_size` the prefix, and `truncated` is true). Either one also leaves out the sections derived from the bodies: decoded views, gRPC messages, WebSocket frames and SSE events. A transcript is still named with its count (`=== SSE EVENTS (40) — not printed under --max-body ===`, or `{"count": 40, "omitted": true}`). They are refused with the other formats, each of which writes the whole message, and with each other.

`--format` is `text`, `json`, `raw` (exact bytes), `har` (a one-entry HAR log), or one of the **request-as-code** serializers: `curl`, `python` (requests), `fetch` (JavaScript), `go` (net/http), `httpie`, and `csrf` (a self-submitting HTML CSRF PoC). Each emits byte-identical text to the TUI's `Space → Y` **Copy as…** row of the same name. `--request-only` / `--response-only` limit the output and do not apply to `har`; every request-as-code format *is* the request, so `--response-only` is refused for all of them. Two caveats go to STDERR rather than into the snippet on STDOUT: a request body cut at the capture cap is carried **short**, and a WebSocket flow serializes as the upgrade handshake with none of its frames. Decoded SAML/JWT/GraphQL/params, WebSocket messages, and SSE events are included where present.

#### Safe evidence export

`--redact [PROFILE]` writes the **sanitized derivative** of the flow instead of the captured bytes: values a [redaction profile](#run-redact) names are replaced by a keyed placeholder, `[REDACTED:3f1c9ab4]`. Equal values get equal tags, so a reader can still see that the token in the request is the token in the response without seeing either. The tag is an HMAC under a secret minted once per install, not a digest of the value — a truncated hash of a 4-digit PIN or a wordlist password is recovered in milliseconds, which would make the placeholder itself the disclosure.

It applies to **every** `--format`, because the flow is sanitized once before anything renders it: `raw`, `text`, `json`, `har`, and all six request-as-code serializers. `--no-redact` writes the captured bytes even when redaction is this project's or this install's default; `--redact-preview` lists what would go — side, JSON Pointer or form key, the rule that fired, the placeholder — and prints no document.

What it covers and what it does not:

- **Bodies only.** Heads, URLs and query strings are untouched, and the sentence on STDERR says so every time. A credential in a `Cookie` header or a `?token=` query string is a different axis with its own consumers (the `url` in a HAR, curl's argument, the row's `target`) and is not part of a profile.
- **The stored bytes never change.** History, the Repeater, the Comparer and `get_response_body_chunk` keep reading the capture exactly. Sanitizing happens on the way out; replay after an export is byte-identical to replay before it.
- **A JSON body is re-serialized**, so a sanitized one carries gori's whitespace and key order rather than the origin's. When the exact framing is the evidence, use `--no-redact`.
- **The head is repaired to describe the sanitized body**: `Content-Length` is rewritten, and a body gori had to decompress or de-chunk to read loses its `Content-Encoding` / `Transfer-Encoding` (reported on STDERR).
- **A body gori cannot read is withheld whole**, not partially sanitized: anything that is not valid UTF-8, and any `multipart/*` (gori does not split its parts yet, so it cannot tell an uploaded file from a form field). The placeholder says how many bytes went and why.
- **A body that does not parse falls back to a conservative text pass** — the profile's own patterns, its field names re-expressed as `"name": "value"` / `name=value` text rules (truncation tolerated), and two built-in shapes that are unambiguous wherever they appear: a JWS/JWE compact serialization and a PEM `PRIVATE KEY` block.

Every caveat, and the count, go to STDERR — STDOUT stays the document, so `gori run show 42 --format har --redact > evidence.har` is still a pure HAR.

#### HAR export

A HAR gori writes imports back into gori as the same flow (`gori run import --har`), so it round-trips. Four things to know:

- **Bodies are the wire bytes**, de-chunked but not decompressed, base64-encoded when they are not valid UTF-8. The `Content-Encoding` header stays in `headers`, so body and head keep describing the same message.
- **A body capped at the capture limit is marked**, never emitted as if complete: `bodySize` and `content.size` stay the true wire size while the text carries only the captured prefix, and a `comment` on `content`/`postData` says so. The command also reports the count on STDERR.
- **A WebSocket flow exports with its messages**: the real `101` handshake, plus the captured transcript beside it in Chrome DevTools' `_webSocketMessages` field, and `gori run import --har` restores it. Direction, opcode (control frames included), bytes (base64 when not valid UTF-8) and millisecond timestamps survive; the per-frame shape (`FIN`/`RSV`/mask key) has no field in the format, so use `--format json` or `raw` when you need it.
- **Flows with no captured response are skipped**, along with a socket whose transcript is empty, since the handshake alone is not the exchange. The count and reason go to STDERR; STDOUT stays a pure HAR document.

### run compare

Line diff of two flows, matching the [Comparer tab](/guide/scanning/).

```bash
gori run compare 41 42 --pane response --changes-only
```

| Option | Description |
| -------- | ------------- |
| `--pane=PANE` | What to diff: `request` or `response` (default) |
| `--changes-only` | Print only added / removed lines, omitting unchanged context |
| `--context=N` | Collapse unchanged runs to `@@ N unchanged lines @@` markers, keeping N lines around each change (mutually exclusive with `--changes-only`) |
| `--format=FMT` | `text` (default) or `json` |

Both sides' `status · size · time` and the A→B delta print above the diff, so a status flip or a size shift is visible before the first line is read. `--format=json` carries the same under `meta`, and a collapsed run becomes `{"kind":"fold","hidden":N}` rather than a gap.

`--changes-only` says *what* changed but erases *where*: a 400-line body with one edit comes back as two lines with no position. `--context` keeps the change in place and states how much it skipped.

### run diff

The retest report: diff two **projects** at endpoint scale, where [`run compare`](#run-compare) diffs two messages. It answers the question half of an engagement is: *what changed since last time?*

```bash
gori run diff --from q1-audit --to q3-retest --format md
```

| Option | Description |
| -------- | ------------- |
| `--from=NAME` | Baseline project, the earlier engagement (name, slug, or short id). Required |
| `--to=NAME` | Newer project (default: the most-recently-active one) |
| `--from-db=PATH` / `--to-db=PATH` | Explicit SQLite files instead of registry projects |
| `-q`, `--query=QL` | Narrow **both** sides with a [QL query](/reference/query-language/) |
| `--in-scope` | Only hosts inside each project's own scope rules |
| `-n`, `--limit=N` | Max endpoint groups to read per side |
| `--verdict=LIST` | List only these verdicts (`added,gone,changed,unchanged,removed`) |
| `--unchanged` | Also list the unchanged endpoints (they are always *counted*) |
| `--no-issues` | Skip the issue retest |
| `--format=FMT` | `text` (default), `json`, or `md` (a section to paste into a retest deliverable) |

**It sends nothing.** This diffs captured traffic on both sides. Re-confirming that a finding still reproduces takes a request, and that stays a deliberate Repeater send.

#### Endpoint identity

Two engagements never capture the same identifiers, so a diff keyed on literal paths reports every row twice (once removed, once added) and says nothing. Endpoints are therefore keyed by the same folded template the [Sitemap](#run-sitemap) draws: `/users/{uuid}`, `/items/{n}`, `/search` (query variants folded onto their path). The fold runs over the **union** of both sides, so a route that met the fold threshold on one side alone still matches itself on the other.

#### The five verdicts

| Verdict | Meaning |
| --------- | --------- |
| `added` | Captured in B, never captured in A |
| `gone` | Captured in both, and every answer B got was `404`/`410` where A was reachable. The only evidence a capture can carry that an endpoint really is gone |
| `changed` | Captured in both; at least one of status class, auth, content type, or size moved beyond tolerance |
| `unchanged` | Captured in both, equivalent |
| `removed` | In A, and **B captured no request to it at all**: a coverage gap, *not* evidence of removal |

The `removed`/`gone` split is the point of the command. A thinner retest visits fewer endpoints, and collapsing those two into one bucket would report a short afternoon as a wave of fixes. Every output leads with that caveat, and the counts always cover all five verdicts even when `--verdict` narrows the listing.

`changed` is judged by a tolerance band (the same calibration `repeater minimize` and `mine` use) rather than byte equality, so a page whose length wanders between captures reads `unchanged`. Status is compared by **class**: a `200` that became a `201` is not a retest finding, a `200` that became a `403` is (and is reported on its own `auth` axis).

#### Issue retest

By default the report closes with each of the baseline's still-open issues and what became of the endpoint it was filed against: "still answers the same way, the finding likely still stands", "answers 404/410 now", "was not requested in the newer capture, retest it before closing". No request is sent; confirming a fix is your call.

#### Coverage and scope

Both sides' flow count, endpoint count, host count and capture window print above the counts, so a reader can see immediately when B's coverage is thinner than A's. When the two projects carry different scope rules the report says so, because an endpoint can be absent because that side's proxy was never recording it.

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
| ------------ | ------------- |
| `list` (default) | Held items plus catch state, direction, and filter |
| `get <item-id>` | Full detail for one held item |
| `forward <item-id>` | Release a held item byte-exact |
| `drop <item-id>` | Drop it. The client gets a canned 502 |
| `edit <item-id>` | Release with edited bytes: `--raw=RAW` or `--raw-file=PATH`. Forwarded verbatim (no `$ENV.KEY` / `$BIND.NAME` expansion), with `Content-Length` resynced unless `--no-update-content-length` keeps the one you declared (the CL-desync primitive) |
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
| -------- | ------------- |
| `--target=URL` | Send to a different origin; path and query are kept |
| `--path=TARGET` | Send to a different request-target (path and query, e.g. `/api/v1/items/42?lang=en`) on the same origin. Everything else on the request line, every header and the body are kept byte-exact; the value goes on the line as written |
| `--http2` / `--http1` (`--no-http2`) | Force a protocol; the default follows how the flow was captured |
| `--sni=HOST` | TLS SNI override |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--timeout=SEC` | Per-operation connect + idle timeout |
| `-H`, `--header=HEADER` | Overwrite/add a request header (repeatable). Repeat the same name to send duplicate lines; an explicit `Content-Length` is honoured verbatim, for CL-mismatch testing |
| `--rm-header=NAME` | Delete every header with this name (repeatable). Removing `Content-Length` suppresses the auto-resync; removing `Host` suppresses the `--target` sync |
| `-b`, `--body=BODY` | Request body override |
| `--keep-request-line` | Send the stored request line as-is; do not rewrite an absolute-form line (`GET http://h/p`) to origin-form |
| `--diff` | Diff against the original response |
| `--allow-unscoped` | Send outside the project scope. Sandbox mode and explicit excludes still refuse each send |
| `--headers-only` | Print the status line and headers only; the body is replaced by one line naming its size |
| `--max-body=BYTES` | Print at most BYTES of the decoded response body, then a marker naming the full size |
| `--format=FMT` | `text` (default) or `json` |

`--headers-only` and `--max-body` shape what is **printed**, never what is sent or stored: the body is replaced by `[body omitted by --headers-only: 149504 bytes]`, or cut and followed by `[… truncated by --max-body: showing 2048 of 149504 bytes]`, so a cut body never reads as a short one. The size is the decoded body's (de-chunked, decompressed), the one an uncut dump prints. In `--format json` the `body` object keeps `size` as the whole decoded size; `--max-body` holds the prefix in `text`/`base64` and adds `shown_size`, with `truncated: true`, and `--headers-only` drops the bytes and adds `omitted: true`. The two flags are refused together. `--headers-only --diff` compares the two heads alone; `--max-body` is refused with `--diff`, whose comparison is of the whole messages. They take the same shape on `repeater send`, `repeater h2`, [`send`](#run-send) and [`show`](#run-show).

**`repeater list`**: list saved Repeater sessions (`--format text|json`).

**`repeater create`**: create a Repeater session:

```bash
gori run repeater create --target https://api.example.com --request-file req.txt --name "login probe"
gori run repeater create --flow 42 --name "clone of 42"
generate-request | gori run repeater create --target https://api.example.com --request-stdin
pbpaste | gori run repeater create --curl - --name "from devtools"
```

The four request sources are mutually exclusive — naming two is refused rather than
resolved by flag order — and a request that arrives empty (an empty file, `--request-raw ''`,
or a pipe that produced nothing) is refused instead of creating a session that cannot be sent.
`--flow` is not one of the four: it doubles as provenance, so it pairs with any one of them.
`--curl` reads one curl command (see [Repeater → Paste cURL](/guide/repeater-and-fuzzer/#repeater))
and supplies `--target` and `--http2` from it unless you pass them.

`--request-stdin` reads a pipe or a redirect (`--request-stdin < req.http`), and refuses a
terminal. A terminal echoes every byte back — the whole raw request, `Cookie` and
`Authorization` with it, into the scrollback and into any captured PTY transcript, which is
the exposure the flag exists to close for the process listing and the shell history. `^D` also
flushes the pending line rather than ending the read there, so a request with no trailing
newline needs two of them and a PTY-driven harness that sends one waits forever.

The same rule covers every stdin road an operator names by **flag** — `issues --notes-stdin`,
and the four that spell stdin `-` (`sequence --tokens -`, `authorize --identities=-`,
`rewriter --response-file=-`, and `-` on any of the `--…-file` flags) — plus a *path* that
resolves to a terminal, such as `--request-file /dev/stdin` under a tty. A **wordlist** path is covered too — `fuzz -w`, `mine --wordlist`
and `discover --wordlist` each refuse `/dev/tty` (and `/dev/stdin` under one) with
`wordlist error: … is a terminal, not a file` instead of blocking forever.

It does **not** cover the stdin sources gori falls back to when no flag was given (`fuzz`,
`mine`, `sequence`, `decoder`, `jwt`, `cookie`, `notes`): there a terminal means "no source was
given", and those commands print their own usage line instead. Those roads do now report an
unreadable stdin (fd 0 closed by a cron or systemd unit) as a sentence rather than a
backtrace, as the flag doors already did.

| Option | Description |
| -------- | ------------- |
| `-t`, `--target=URL` | Target URL (required unless cloned from `--flow`) |
| `-f`, `--request-file=FILE` | Read the raw HTTP request from FILE (mutually exclusive with `--request-raw` / `--request-stdin`) |
| `-r`, `--request-raw=RAW` | Verbatim raw HTTP request string (mutually exclusive with `--request-file` / `--request-stdin`) |
| `--request-stdin` | Read the raw HTTP request from stdin, byte-for-byte as `--request-file` reads a file, keeping it out of the argument vector. Needs a pipe or a redirect; a terminal is refused (mutually exclusive with `--request-file` / `--request-raw`) |
| `--curl=PATH` | Build the request from the curl command in PATH (`-` reads stdin). Supplies the target and HTTP/2 unless given; ignored transport flags are named on stderr |
| `--flow=ID` | Clone request / target / HTTP/2 from a captured flow |
| `--name=NAME`, `--tags=TAGS` | Custom tab name, and free-text tags that become the TUI subtab label |
| `--http2` / `--http1` (`--no-http2`) | Pick a protocol; `--http1` overrides an h2-captured `--flow` |
| `--no-auto-cl`, `--sni=HOST` | Skip auto `Content-Length`, SNI override |
| `--keep-request-line` | With `--flow`: store the request line as captured, absolute-form included |
| `--ws-keep-key` | WebSocket: send the request's own `Sec-WebSocket-Key` so an absent, short, duplicate, or non-base64 key can be tested |
| `--ws-http-only` | WebSocket: store this session as plain HTTP: the upgrade is sent as an ordinary request and the `101` read as a response |
| `--format=FMT` | `text` (default: `Repeater session #7 created successfully.`) or `json`: the new session as `repeater list --format json` prints it (`id`, `tui_index`, `position`, `name`, `target`, `http2`, …) plus `websocket`, the stored `ws_messages` count, and `request_line_rewritten` when a `--flow` seed's line was rewritten |

```bash
id=$(gori run repeater create -t https://api.example.com -f req.http --format json | jq .id)
gori run repeater send "$id"
```

**`repeater send <repeater-id>`**: execute a saved session, HTTP or WebSocket.

```bash
gori run repeater send 3 --diff
gori run repeater send 5 --message '{"op":"subscribe"}' --idle-ms 5000
```

| Option | Description |
| -------- | ------------- |
| `--diff` | Diff against the session's last stored response |
| `--verbatim` | Send the stored bytes exactly: no token expansion (project env vars **and** session bindings; a `$ENV.KEY` or `$BIND.NAME` stays literal on the wire), no bare-LF promotion, no `Content-Length` resync, no HTTP/2→1.1 version fix, no h2 field-name lowercasing. Nothing interprets the sigil grammar, so the `$$ENV.KEY` escape is not consumed either; write `$ENV.KEY`. The active `--slot`'s header overlay still applies, since it answers *as whom*, not *which bytes*. Pass no `--slot` to send the stored headers |
| `--reframe-grpc` | HTTP/2 only: recompute the gRPC 5-byte length prefix over the body actually being sent, for a unary message an edit changed the length of. Off by default, because a prefix that disagrees with its payload is a standard parser test, so it ships as written |
| `--message=TEXT` | WebSocket: outbound text message (repeatable; replaces the session's stored messages) |
| `--message-frame=SPEC` | WebSocket: one frame with an explicit shape. Comma-separated `key=value`: `opcode=text\|bin\|cont\|close\|ping\|pong\|<0-15>`, `fin`, `rsv`, `mask`, `mask_key`, `len`, and one of `hex=`/`b64=`/`text=` |
| `--idle-ms=N` | WebSocket: server-silence timeout after the first inbound frame (100-60000, default 3000) |
| `--http` | WebSocket: send the handshake as an ordinary HTTP request for this send only. Selects the engine, not a rewrite |
| `--record-history` | Also write the outbound request + response to History as a captured flow, and print its flow id on stdout (HTTP only; a Repeater send leaves no flow by default) |
| `--path=TARGET` | Send this request-target (path and query) instead of the stored one, for this send only |
| `--ws-keep-key`, `-k`, `--timeout`, `--allow-unscoped`, `--headers-only`, `--max-body`, `--format` | As above (`--headers-only` / `--max-body` are HTTP-only: a WebSocket exchange prints a transcript) |

`--path` sweeps one session's request across endpoints that differ only in path, without a session per path:

```bash
for n in $(seq 1 38); do
  gori run repeater send 1 --path "/api/v1/items/$n" --headers-only
done
```

It edits a copy of the stored request for this send: the session keeps its own request **and its last response**, because storing another target's answer beside it would show the TUI tab a response to a request it does not hold, and make the next `--diff` compare against the wrong endpoint. So `response_saved` is absent from `--format json`, a `path` field names the target that was sent, and the text status line ends with it (`→ 200 in 218.4ms · /api/v1/items/42`). `--record-history` still records the request as it went out, new path included, and `--diff` compares against the session's stored response.

A send that reached the origin exits `0` even when the writes after it fail, so a shell does not resend it. `--format json` says which: `response_saved` (present once a response was written to the session, `false` with `response_save_error` when the project refused the write or the session was deleted mid-send, in which case a later `--diff` would compare against the previous response) and, under `--record-history`, `history_saved` with `history_error` beside a `recorded_flow_id` that is then absent. Text mode prints the same sentence on STDERR.

**`repeater move <repeater-id>`**: reorder the workbench strip. `--to N` names the 1-based tab number `repeater list` prints; `--up` / `--down` step one place. Pass one of the three. Passing both `--to` and a direction is refused rather than resolved, and a `--to` outside `1-<count>` is refused rather than clamped, so a session never lands somewhere the command did not name. `--format json` reports `from_index` / `to_index` / `moved`.

```bash
gori run repeater move 5 --to 1        # make it the first tab
gori run repeater move 5 --down
```

**`repeater delete <repeater-id> [<repeater-id>…] --yes`**: close one or more saved sessions and renumber the strip. `--yes` is required, and every id is checked before the first delete, so one unknown id refuses the whole call, so a typo cannot half-empty the workbench. Each line names the tab number the session *had* (read once, before anything shifts); `--format json` returns `deleted` (with `was_tui_index`), `failed`, and `remaining`. A session that could not be removed leaves a non-zero exit.

**`repeater minimize <repeater-id>`**: shrink a request to the smallest form that still reproduces the response. `--apply` writes the result back into the session; `--verbatim` sends the stored bytes as-is (body params stop being candidates, because their framing could not be kept honest); `--slot=NAME` sends as that [session slot](#run-session); `-k`/`--insecure`, `--allow-unscoped` and `--format` behave as above.

**`repeater h2`**: send a field-native HTTP/2 request from an ordered HPACK field list, so duplicate or misordered pseudo-headers can be scripted.

```bash
gori run repeater h2 --target https://api.example.com --fields fields.json
```

`--fields=FILE` is a JSON file holding either a bare `[[name, value], …]` array or `{"fields": [[name, value], …], "body": "…"}` (`body_base64` for binary). Nothing in the list is normalized: a leading colon, a leading-space value, an uppercase name are the payload. `--target` sets the dial origin, so the `:authority` and `:scheme` fields may deliberately disagree with it. `-k`/`--insecure-upstream`, `--timeout=SEC`, `--allow-unscoped`, `--tls-preset=NAME`, `--headers-only`, `--max-body` and `--format text|json` behave as on `repeater send`.

### run send

Send one request and print the response, without creating a Repeater session: the headless form of MCP `send_request{url}`, built by the same code. It goes out through the project's upstream proxy, host overrides, scope and Sandbox like every other gori send, and leaves nothing behind unless you pass `--record-history`.

```bash
gori run send https://api.example.com/v1/items/42 -H 'Accept: application/json'
gori run send --url https://api.example.com/v1/items -X POST -b '{"name":"x"}' --record-history
gori run send --url https://api.example.com --request-file req.http --headers-only
```

| Option | Description |
| -------- | ------------- |
| `--url=URL` (or the URL as the only argument) | Absolute `http://` / `https://` URL. Its path and query become the request-target; with a raw request it only names where to dial |
| `-X`, `--method=METHOD` | HTTP method (default `GET`) |
| `-H`, `--header=HEADER` | `Name: value`, repeatable, sent in order. `Host` and `Content-Length` are added only when you leave them out. A header that would split into two lines, or a name that is not a token, is refused: a raw request is the form for malformed bytes |
| `-b`, `--body=BODY` | Request body; `$ENV.KEY` tokens expand |
| `--body-file=FILE` | Request body read byte-for-byte, never expanded |
| `-f`, `--request-file=FILE` · `-r`, `--request-raw=RAW` · `--request-stdin` | Send this raw HTTP request instead of building one. Refused beside `-X`/`-H`/`-b`/`--body-file`, which it would otherwise silently drop. The head's bare LFs are promoted to CRLF unless `--verbatim` |
| `--verbatim` | No token expansion in `-H`, `-b` or a raw request, no bare-LF promotion, and on HTTP/2 no field-name lowercasing. The URL is still expanded: it names where to dial |
| `--http2`, `--sni=HOST`, `--tls-preset=NAME`, `-k`, `--timeout=SEC`, `--slot=NAME`, `--allow-unscoped` | As on `repeater send` |
| `--record-history` | Also write the request and response to History as a flow (`source: repeater`, `source_surface: cli`) and print its id. Off by default, as on `repeater send` |
| `--headers-only`, `--max-body=BYTES`, `--format=FMT` | As on `repeater send` |

A request that is a WebSocket handshake goes out as an ordinary request and its `101` is the answer, which the command says on STDERR. A framed exchange needs a session: `repeater create`, then `repeater send`.

### run fuzz

Sources: `--flow=ID`, `--repeater=ID`, `--request=FILE`, or stdin. Positions: `§…§` markers, `--auto`, `--mark=TOKEN`, or `--field=SPEC` for a schema-known gRPC field.

| Group | Options |
| ------- | --------- |
| Source | `--flow=ID` (a captured flow), `--repeater=ID` (a saved repeater session; a WebSocket one seeds its handshake **and** its stored frames), `--request=FILE`, or a bare `<flow-id>` / stdin |
| Transport | `--target=URL` (required for `--request`/stdin), `--http2`, `--sni=HOST`, `-k`/`--insecure-upstream` |
| Mode | `--mode=` `sniper` (default), `batteringram`, `pitchfork`, `clusterbomb`. The first two draw from **one** payload set, the last two from one per marked position; a set the mode will never draw from is named before the run starts |
| gRPC fields | `--field=SPEC` (repeatable) sweeps a **schema-known field** of a unary gRPC request instead of its octets. `SPEC` is a field name, a path into a nested message (`profile.age`), a field number, or `name[i]` for one occurrence of a repeated field; `name¦chain` runs a Decoder chain over the payload **before** the declared type encodes it. The field must already be present on the captured message (gori replaces an occurrence, never adds one), and payloads for a `bytes` field are read as **hex** (`de ad be ef`). Each payload goes through the field's declaration on its way to bytes (`-3` is a different set of octets as `int32`, `sint32`, `bool` or an enum), every other byte of the message is copied from the capture, and the 5-byte length prefix is recomputed. Needs a descriptor set that resolves the rpc (`gori run grpc schema`). Field positions follow the template's own `§…§` positions in the run's index space, so `--mode` and the payload sets keep their meaning. An undeclared field, one whose wire type the declaration contradicts, and a payload the declared type cannot hold are all refused before the first request |
| Payloads | `-w`/`--wordlist`, `--preset=NAME[:FILE]` (built-in: `sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`, `cache-delimiters`), `--payloads=LIST`, `--numbers=FROM-TO[:STEP]`, `--null=N`, `--brute=CHARSET:MIN-MAX` |
| Encoding | A payload spliced into a **query-string** or **form-urlencoded body** value is URL-encoded by default; path segments, JSON/raw bodies, headers and cookies stay raw. `--no-encode` sends the query/form ones raw too. Use it for a payload that is *already* a percent-escape (`%00` would go out as `%2500`, so the `%00` / `%c0%af` / `%2e%2e%2f` probes aimed at the origin's own decoder arrive as text). An explicit `--encode` replaces the default and applies to every position. `--prefix` / `--suffix` / `--case` / `--hash` / `--regex-replace` do not: they say what the payload is, not how the wire spells it, so their output is still encoded for a query/form position |
| Processors | `--prefix`, `--suffix`, `--encode` (`url`\|`urlall`\|`base64`\|`hex`), `--case` (`upper`\|`lower`), `--hash` (`md5`\|`sha1`\|`sha256`), `--regex-replace=/pat/rep/` |
| Rate | `--concurrency` (20), `--rate=RPS`, `--throttle=MS`, `--timeout=SEC`, `--retries=N`, `--max-requests=N` (hard cap, retries and redirect hops count), `--follow-redirects`, `--no-keep-alive` |
| Race | `--race=N` dials N connections, holds each request one byte short, and releases them together (last-byte sync): a race group is N copies of **one** request, so `--mode` and every payload/position flag are bypassed. `--race-warmup=FILE` first sends and reads this raw request on each connection before it holds the race request |
| Framing | `--verbatim` sends the template's `Content-Length` as written, with no resync after payload substitution and none added to a body that declares none (for CL / CL-TE desync payloads; a body left with no `Content-Length` and no chunked `Transfer-Encoding` is warned about, because an origin reads it as zero-length). `--reframe-grpc` recomputes the gRPC 5-byte length prefix after each payload is spliced into a unary message (off by default: a stale prefix is reported, not repaired) |
| WebSocket | A template declaring an `Upgrade: websocket` handshake is swept as a framed exchange: **one payload = one full RFC 6455 session**. `--message=TEXT` / `--message-frame=SPEC` author the outbound frames (repeatable, in order; `SPEC` is the `gori run repeater send` grammar: `opcode=`, `fin=`, `rsv=`, `mask=`, `mask_key=`, `len=`, and one of `hex=`\|`b64=`\|`text=`) and replace the frames a `--flow`/`--repeater` seed carried. Mark `§…§` positions in the frames; the handshake is a position space too, and both sweep in one run. `--idle-ms=N` per-session silence timeout (100-60000, default 3000), `--ws-keep-key` sends the template's own `Sec-WebSocket-Key`. `--ws-http-only` sweeps the handshake as an ordinary request instead. Rows carry `ws_close_code` and `ws_frames_in`, because a successful upgrade is `101` on every row. `--race`, `--http2` and `--record-history` are refused on the framed path (all three work under `--ws-http-only`, which is an ordinary HTTP sweep and does record); `--follow-redirects`, `--timeout` and `--ac` are inert and reported once. A WebSocket seed with no outbound frames is swept as plain HTTP rather than as an empty framed session |
| Matchers | `--mc`/`--fc` status, `--mg`/`--fg` gRPC status from the `grpc-status` trailer — the HTTP/2 trailer, or grpc-web's in-body trailer frame (`7`, `>0`, `1-16`), `--ms`/`--fs` size, `--mw`/`--fw` words, `--ml`/`--fl` lines, `--mt`/`--ft` round-trip time in **ms** (`--mt '>=5000'`; the only dimension a time-based blind payload moves, and a send that times out counts as a match on it), `--mr`/`--fr` body regex, `--mh`/`--fh` a case-insensitive substring of the response HEAD (`--mh 'x-powered-by: php'`; the body regex never sees a header), `--extract=REGEX`, `--ac` auto-calibrate |
| Stop | `--stop-after-matches=N` ends the run once the matchers have hit N times (`1` = first hit). `--stop-on=DIM:SPEC` (repeatable) ends it when a **separate** condition holds — `DIM` is `status`\|`grpc`\|`size`\|`words`\|`lines`\|`time`\|`header`\|`regex`, and `!DIM` negates it (`--stop-on '!regex:Invalid password'` stops when the body no longer carries it). Either way the run lands the terminal status `condition_met` (not `stopped`), and the CLI exits `0` — the condition was the goal. In-flight requests finish, as on `^C`. Not usable with `--race` |
| Keep | `--keep=all` (default) \| `interesting` — for `fuzz save`, which result rows the archive stores. `interesting` keeps the matched rows plus the ones carrying an observed fact (an error, a re-send, a truncated capture, the stop row), so a large sweep does not write one archive row per request. The run's `sent`/`matched`/`errors` counts stay whole-run and each row keeps its real payload index; `fuzz list`/`show` say `keep:interesting` and how many of how many were kept |
| Session bindings | `--bind-from=FLOW-ID` replays that captured flow first so its response fills the project's `$BIND.NAME` bindings for the rest of the run |
| Session slot | `--slot=NAME` sends as this [session slot](#run-session): its header overlay, and its binding table for `$BIND.NAME`. Applied before `--bind-from` |
| Scope | `--allow-unscoped` sends outside the project scope; Sandbox mode and explicit excludes still refuse each send |
| Output | `--format` (`text`\|`json`\|`jsonl`), `--force`, `--fail-if-no-matches` (exit `3` when nothing matched) |
| Evidence | `--record-history=none\|matched\|all` also writes each sent request + response to History as a flow (default `none`; `matched` records only the rows that matched, `all` every send, capped at 5000). Read them back with `gori run history` / `get_flow` |

#### Permanent fuzz runs

`gori run fuzz …` is still ephemeral. Add the `save` verb before the same source/options to store every result permanently, with its complete rendered request, final wire request, response head, and response body:

```bash
gori run fuzz save 42 --auto --preset sqli
gori run fuzz save --request request.txt --target https://api.example.com --project acme --payloads a,b
```

A file/stdin save needs `--project` or `--db`; gori will not silently write a project-less sweep into whichever project happens to be most recent. `--record-history` remains independent: it controls History flows, not the saved result set.

| Command | Description |
| --------- | ------------- |
| `fuzz list` | List saved runs newest-first. `--session=ID` narrows to one TUI Fuzzer session; `--offset`, `--limit` (default 50, max 1000), `--format text\|json` page/format the list |
| `fuzz show RUN_ID` | Show one run's summary and a scalar-only page of result metrics without loading retained BLOBs. Supports `--offset`, `--limit` (default 200, max 5000), `--matched-only`, and `--format text\|json\|jsonl`; live `--format json` streams one valid array instead of buffering full retained rows |
| `fuzz show RUN_ID RESULT_INDEX` | Show one exact result, including retained request/wire/response bytes. Text neutralizes terminal control sequences; JSON emits invalid UTF-8 as base64. Detail supports `text` or `json`; run metadata marks incomplete pre-current snapshots as legacy |
| `fuzz delete RUN_ID --yes` | Delete one terminal run and all of its stored result rows. An active save is refused; `--force-stale` removes a `running`/`saving` row left by a crashed writer, and must never be used while another gori is saving |

### run mine

```bash
gori run mine <flow-id> --locations query,headers --wordlist params.txt
```

| Option | Description |
| -------- | ------------- |
| `--flow`, `--request`, `--target`, `--sni`, `--http2`, `-k` | Request source and transport |
| `--locations=LIST` | `query`, `form`, `multipart`, `json`, `headers`, `cookies` (multipart off by default, pass it explicitly) |
| `--wordlist`, `--bucket=N` | Candidate names and bucket size |
| `--name=NAME` | Test this name first, ahead of the wordlists (repeatable), for example a name `sitemap params` found on another endpoint |
| `--concurrency` (10), `--rate`, `--throttle`, `--timeout`, `--retries` (1), `--max-requests=N` | Rate control |
| `--no-keep-alive` | Dial a fresh connection per probe instead of reusing one |
| `--hook=ARGV` | Transform each assembled request through an external command (argv, no shell) before it is sent, for signed / HMAC'd APIs. See [Process hooks](/guide/scripting/#process-hooks) |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$BIND.NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session): its header overlay, and its binding table for `$BIND.NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--format` | `text`, `json`, or `jsonl` |

Connections are reused by default, so a mine pays one TCP (and on https one TLS) handshake per worker rather than one per probe. The `connections · N dialed · M reused` line at the end of a run is where you see whether the target honoured it. Turn it off with `--no-keep-alive` when the target behaves per-connection.

### run sequence

Grade the randomness of a token. **Live**: replay a request and extract the token from each response. **Manual**: analyze a pasted list with `--tokens` (no network). Alias `seq`.

```bash
gori run sequence 42 --cookie SESSIONID --count 500
gori run sequence --tokens tokens.txt          # '-' reads stdin
```

| Option | Description |
| -------- | ------------- |
| `--flow=ID`, `--request=FILE`, stdin | Request source for live replay (or a bare `<flow-id>`) |
| `--tokens=FILE` | Analyze a pasted token list (one per line, `-` = stdin — a pipe or a redirect; a terminal is refused); no network |
| Token location (pick one) | `--cookie=NAME`, `--header=NAME`, `--regex=RE`, `--position=A:B`, `--jsonpath=EXPR` |
| `--count=N` | Target token count (default 500) |
| `--target`, `--http2`, `--sni`, `-k` | Transport (target required for `--request`/stdin) |
| `--concurrency` (1), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | Rate control (concurrency stays 1 for stateful tokens) |
| `--no-keep-alive` | Dial a fresh connection per sample instead of reusing one |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$BIND.NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session): its header overlay, and its binding table for `$BIND.NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--format` | `text`, `json`, `jsonl`, or `markdown` (the report the TUI's Export writes) |

### run authorize

Replay each selected flow under every identity (a header overlay standing in for an admin session, a low-privilege user, an anonymous client) and judge each response against the baseline's. An identity served what the baseline was served is a likely access-control bypass. The headless equivalent of the [Authorize tab](/guide/authorize/).

```bash
gori run authorize 12 13
gori run authorize --query 'host:acme.test method:GET' --identities identities.json
```

| Option | Description |
| -------- | ------------- |
| `<flow-id>…`, `--flow=ID` | Captured flows to replay, in the order given (repeatable) |
| `-q`, `--query=QL` | Also replay every flow matching this QL query, appended after the ids |
| `-n`, `--limit=N` | Max flows `--query` may contribute (default 50). Every row becomes one request *per identity* |
| `--identities=FILE` | Identity set as JSON (`-` = stdin — a pipe or a redirect; a terminal is refused); default: the project's saved set |
| `--unsafe-methods` | Also replay `POST`/`PUT`/`PATCH`/`DELETE`; each identity re-runs the side effect |
| `--allow-unscoped` | Send even when the target is outside the project scope (sandbox and excludes still apply) |
| `--timeout=SEC`, `-k`/`--insecure-upstream` | Per-request connect + idle timeout; skip upstream TLS verification |
| `--project`, `--db` | Project to read |
| `--format` | `text` (default), `json` (one array at the end), or `jsonl` (streamed) |

Identities come from the project (the TUI Authorize tab's list) unless `--identities` names a file:

```json
[{"name": "anonymous", "remove": ["Cookie", "Authorization"]},
 {"name": "low-priv",  "set": [{"name": "Cookie", "value": "session=…"}]}]
```

`set` upserts headers, `remove` strips them, and the request as captured is the baseline unless an entry carries `"baseline": true`. At least one identity besides the baseline is required, or there is nothing to compare.

Flows that cannot be replayed meaningfully are listed on STDERR before anything is sent, each with its reason (`no identity changes them`, `not a safe method to repeat`, `never completed`, `answered by gori`, `outside project scope`, `already queued`). A selection where every flow was skipped is refused rather than run. If every send was refused before the socket, the run exits `1` and says so instead of reporting a clean result, because a run that sent nothing is not evidence that access control works.

### run cache-deception

Check each selected flow for **web cache deception**: replay it as its captured (authenticated) identity to prime any cache, re-request the *same* url with no session, then make an anonymous request with a unique cache-busting query parameter as a control. Matching control content supports a public verdict (`served`) only when the control itself has no cache-hit signal. If the control is also a cache hit, the cache may have ignored the query and the verdict is `review`; matching anonymous content with a cache hit and different control content is a likely deception (`cached`). The check sends up to three requests per flow. Borrows the Authorize engine; the crafted paths that trigger it (`;`, `.css`, `%00`, dot-segments) are the Fuzzer's `cache-delimiters` payload set.

```bash
gori run cache-deception 12
gori run cache-deception --flow 12 --flow 13 --format json
```

| Option | Description |
| -------- | ------------- |
| `<flow-id>…`, `--flow=ID` | Captured flows to check, in the order given (repeatable) |
| `--unsafe-methods` | Also check `POST`/`PUT`/`PATCH`/`DELETE`; the side effect can run up to three times (prime, anonymous, control) |
| `--allow-unscoped` | Send even when the target is outside the project scope (sandbox and excludes still apply) |
| `--timeout=SEC`, `-k`/`--insecure-upstream` | Per-request connect + idle timeout; skip upstream TLS verification |
| `--project`, `--db` | Project to read |
| `--format` | `text` (default), `json` (one array at the end), or `jsonl` (streamed) |

Each flow reports one verdict: `cached` (the deception — anonymous served the authenticated response from a cache and the cache-busted control differed), `served` (no cache-hit evidence or a matching control without cache-hit evidence), `review` (similar but not identical, no decisive control, or a matching control that was itself a cache hit), `protected` (anonymous got a different response), `blocked` (gori refused the send), or `errored`. Each trial includes its own cache signal; the top-level `cache` is the anonymous response. Only safe methods (`GET`/`HEAD`/`OPTIONS`) are checked without `--unsafe-methods`.

### run session

The project's **session slots**: named identities, each a header overlay plus the extract rules whose bound values belong to it. This is the same list the TUI [Authorize tab](/guide/authorize/)'s identities card edits and MCP's `*_session_slot` tools manage: an Authorize run replays under *every* slot, and a send goes out as the *one* named by `--slot`.

```bash
gori run session                                     # list (values [REDACTED])
gori run session show admin --show-values
gori run session add --name admin --set 'Cookie: session=…' --rule SESSION
gori run session edit admin --clear-set --set 'Cookie: session=new'
gori run session baseline as-captured
gori run session rm admin
```

| Verb | Options |
| ------ | --------- |
| `list` (default) | `--show-values` (print header values instead of `[REDACTED]`), `--format text\|json` |
| `show <name>` | `--show-values`, `--format text\|json` |
| `add` | `--name`, `--set 'Name: value'` (repeatable), `--remove NAME` (repeatable), `--rule NAME` (repeatable), `--baseline` / `--no-baseline` (clear the flag; the first slot then inherits it) |
| `from-flow <flow-id>` | `--name` (required), `--baseline`, `--show-values`. Build the overlay from a captured login exchange instead of typing it |
| `from-request <flow-id>` | `--name` (required), `--copy-header NAME` (repeatable; at least one), `--baseline`, `--show-values`. Copy selected headers from a captured request |
| `edit <name>` | The same flags, plus `--clear-set` / `--clear-remove` / `--clear-rules`. A collection flag REPLACES that whole collection; one you omit is left alone |
| `rm`\|`delete <name>` | Any extract rule it claimed goes back to writing the global binding table |
| `baseline <name>` | Move the Authorize baseline (exactly one slot holds it) |

All verbs take `--project=NAME` / `--db=PATH`.

A `--set` value goes through the same header parser the TUI form uses: a name must be an RFC 7230 token and a value may not contain CR or LF, and a line that fails is refused by name rather than dropped.

**`from-flow` builds a slot from a captured login.** Point it at the flow that logged in and gori reads that flow's *response* into the overlay: every `Set-Cookie` `name=value` folded into one `Cookie:` header (attributes dropped, and a cookie the response *deletes* skipped), then the response's own `Authorization`, else a top-level `access_token` / `token` / `id_token` string in a JSON body as `Authorization: Bearer <value>`, else the request's own `Authorization`.

```bash
gori run session from-flow 4211 --name admin
gori run repeater 900 --slot admin        # re-send flow 900 as that identity
```

The overlay is **literal**: the bytes login handed back, saved with the project. It does not re-authenticate, so a token that *rotates* (a short-lived JWT, a per-request CSRF value) belongs on the extract-rule path instead: `gori run rewriter extract` plus `--bind-from FLOW`, which re-mints the value once per run. The name is checked before the flow is read, so a duplicate is reported as a name clash rather than as "that flow is not a login".

**`from-request` copies named headers from a captured request.** This is useful when the credential or CSRF material is already on the request, or when you need a deliberately small snapshot rather than every header in a login exchange. Repeat `--copy-header` once per header; at least one is required. `Content-Length`, `Transfer-Encoding` and `Host` are refused: a slot is applied to a message with a different body and target, so copying one would make every later send under the slot misframe or misroute itself. The saved values are literal bytes, stdout redacts them as `[REDACTED]` unless `--show-values` is passed, and provenance on STDERR names the copied headers without printing their values. Slots are **not host-scoped**: every send that explicitly uses `--slot NAME` receives the slot's headers, so keep each slot limited to its intended identity.

```bash
gori run session from-request 4211 --name admin \
  --copy-header Cookie --copy-header X-CSRF-Token
gori run repeater 900 --slot admin        # send with that header snapshot
```

This is a **literal snapshot**, not a login macro: it does not re-authenticate or refresh a rotating token. For short-lived JWTs, per-request CSRF values, or any credential that must be minted again, use `gori run rewriter extract` with `--bind-from FLOW` so the value is extracted anew for each run.

**There is no `session activate`.** A `gori run` process sends and exits, so the active pointer has nothing to span, and persisting one would resolve into an empty binding table on the next run, sending an overlay whose `$BIND.SESSION` is literal. Name the identity on the send instead: `--slot NAME`, on `repeater`, `repeater send`, `repeater minimize`, `fuzz`, `mine`, `sequence` and `discover`. The run prints `slot: sending as NAME` on STDERR before its first request.

### run probe

```bash
gori run probe --severity high --category cors
gori run probe -a
```

`--severity` is `info`\|`low`\|`medium`\|`high`\|`critical`; `--category` is `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors`\|`client`\|`active`; `-a`/`--active` includes light-touch active checks; `-q`/`--query` filters with QL, and `--lenient` accepts a query that names an unknown field instead of refusing it. `--in-scope` reports only issues on hosts in the project's configured scope (the TUI's `s` lens, opt-in and independent of `--active`/`--allow-unscoped`); every flow is still scanned.

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
| ------ | --------- |
| `issues` | `-a`/`--all` (include dismissed / confirmed / resolved), `--severity`, `--category`, `--host` |
| `dismiss <id>` | Or bulk with `--code=CODE` / `--host=HOST` |
| `promote <id>` | Promote a finding to a human-confirmed Issue |
| `delete <id>` | Or `--all --yes` |
| `rules [list\|enable\|disable\|add\|delete]` | `list` takes `--kind=passive\|active\|custom`; `enable`/`disable`/`delete` take a `<rule-id>` from that list; `add` takes `-t`/`--title` (required), `-p`/`--pattern` (required), `--description`, `--side` (`request`\|`response`, default `response`), `--region` (`whole`\|`header`\|`body`, default `body`), `--regex`, `--exec` (run `--pattern` as a [process hook](/guide/scripting/#process-hooks): exit 0 raises the finding, stdout is the evidence), `-s`/`--severity` (default `info`) |
| `mode [off\|passive\|active\|aggressive]` | Print the project's scan mode, or set it |

### run discover

Spider a target and brute-force unlinked paths; findings flow into the Sitemap unless `--no-store`. Sends real, unsolicited traffic, so only run it against authorized targets.

```bash
gori run discover --target https://target.example --max-depth 3 --extensions php,json,bak --format jsonl
```

| Option | Description |
| -------- | ------------- |
| `--target=URL` | Seed origin or path subtree to explore (required) |
| `--max-depth=N` | Spider depth from the seed (default 4) |
| `--no-spider` / `--no-bruteforce` | Disable link crawling / directory brute-forcing |
| `--wordlist=PATH` | Extra path wordlist, merged with the built-in list |
| `--extensions=LIST` | Also probe these extensions (e.g. `php,json,bak`) |
| `-H`, `--header=HEADER` | Custom header on every probe (repeatable) |
| `--containment=MODE` | `same-origin` \| `scope-aware` (default) \| `host+subdomains` |
| `--concurrency` (20), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | Rate control |
| `--no-keep-alive` | Dial a fresh connection per probe instead of reusing one per origin |
| `--assets` | Also fetch the linked images, fonts, media and archives (default: record their directory, skip the download) |
| `-k`, `--insecure-upstream` | Skip upstream TLS verification |
| `--bind-from=FLOW-ID` | Replay that captured flow first so its response fills the project's `$BIND.NAME` session bindings for the rest of the run |
| `--slot=NAME` | Send as this [session slot](#run-session): its header overlay, and its binding table for `$BIND.NAME`. Applied before `--bind-from`, so the seed fills the slot the run then sends as |
| `--allow-unscoped` | Run even if the target is outside the project scope. Waives the up-front (Layer 1) check only. Sandbox mode and explicit exclude rules still refuse each send, and the refusal now names which of the two fired. |
| `--force` | Bypass the unbounded-run safety gate |
| `--no-store` | Do not write findings into the project |
| `--format` | `text`, `json`, or `jsonl` |

Connections are reused per origin by default, so a brute-force pass pays one TCP (and on https one TLS) handshake per worker rather than one per probe. The `connections · N dialed · M reused` line at the end of a run is where you see whether the target honoured it. Turn it off with `--no-keep-alive` when the target behaves per-connection.

### Session bindings from the command line

A session binding (`$BIND.SESSION` filled from a login response; see [Session bindings](/guide/proxy/#session-bindings)) lives in the **memory** of the gori process that observed it. It is never written to `settings.json` or to the project database: a restored token is stale by construction, and re-extracting one costs a single request.

`gori run` is one process per invocation, and a sweep is deliberately **not** an extraction source (a response echoing an attack payload back could otherwise rebind your session to it). So a headless `fuzz` / `mine` / `sequence` / `discover` whose template names a declared binding has nothing to resolve it with, and is refused before it sends.

`--bind-from FLOW-ID` is the missing step: it replays one captured flow, the login, through the deliberate-send path, whose response fills the binding table, and then runs the sweep in the same process.

```bash
gori run fuzz 42 --wordlist ids.txt --bind-from 17
# bind-from: flow #17 replayed → bound $BIND.SESS
```

Driving two `gori mcp` tool calls over one stdio session works the same way and always has.

### run import

Bulk-import flows into the project's History, the CLI counterpart of the TUI's Import overlay (see [Proxy & History → Import](/guide/proxy/#import)). Exactly one source flag is required. Sends no traffic.

```bash
gori run import --postman api.postman_collection.json --db ./assessment.db --format json
```

| Option | Description |
| -------- | ------------- |
| `--har=PATH` | A browser/proxy HAR (HTTP Archive) export. Full request/response flows |
| `--urls=PATH` | A text file of URLs, one per line (`#` comments and blanks ignored) |
| `--oas=PATH` | OpenAPI 3.x or Swagger 2.0 (JSON or YAML); local JSON Pointer refs are resolved, remote refs are reported and not fetched |
| `--postman=PATH` | A Postman Collection v2 export (JSON) |
| `--insomnia=PATH` | An Insomnia v4 export (JSON) |
| `--burp=PATH` | A Burp Suite item export (XML). Request **and** response, byte-exact |
| `--wsdl=PATH` | A WSDL 1.1 service description (XML). One SOAP request template per operation |
| `--curl=PATH` | curl commands, one flow per request; `-` reads stdin (`pbpaste \| gori run import --curl -`). Ignored transport flags are named on stderr (`notes` in JSON) |
| `--project=NAME` | Project to import into (default: most-recently-active) |
| `--db=PATH` | Explicit SQLite db file to import into (created if absent) |
| `--format` | `text` (default) or `json` |

Import writes flows, so it resolves its target like `discover`: an explicit `--db` is created or reopened, and without one it writes into an existing project rather than silently creating a default.

A malformed entry is skipped rather than aborting the file; the result reports both counts (`{"count": 12, "skipped": 3}`). Only `--har` and `--burp` carry responses; the rest import request templates that show as `Pending` in History until you send them.

### run sitemap

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL` filters endpoints with the same QL as history (also positional), `-n`/`--limit=N` caps the endpoints scanned (default `SITEMAP_MAX`), `--in-scope` limits to in-scope hosts, `--hide-static` leaves out images, fonts and audio/video (per flow, like the TUI tree), `--no-group` disables id folding, `--no-fold-query` disables query-string folding (the two are separate axes), `--format` is `text` (tree), `json`, or `paths`, and `--lenient` accepts a query that names an unknown field instead of refusing it.

**`sitemap tag`**: pin a free-text memo onto one path, the same note the TUI's Sitemap shows.

```bash
gori run sitemap tag --host api.example.com --path /v1/users --tag "IDOR candidate"
gori run sitemap tag --host api.example.com --path /v1/users --clear
gori run sitemap tag --list
```

**`sitemap params`**: the parameter inventory, the same one the TUI's [Params sub-tab](/guide/proxy/#params) shows. One row per host, method, path, location and name, with the number of flows that carried it, up to `--samples` distinct values (default 5), and `reflected` when a value of four or more bytes appears verbatim in the first 256 KiB of the decoded response body (an observation, not a finding).

```bash
gori run sitemap params --host api.example.com
gori run sitemap params 'method:POST' --location json,form --format json
gori run mine 42 --wordlist <(gori run sitemap params --host api.example.com --format names)
```

`-q`/`--query=QL` (also positional), `--in-scope` and `--hide-static` narrow the flows read, per flow as in `history`. `--host` is an exact host, `--path=PREFIX` a path prefix, and `--location=LIST` picks locations (default all). Standard browser headers are left out unless `--all-headers`. `--max-flows=N` reads the newest N matching flows (default 2000); a note on stderr says when older ones were skipped. Values of cookies, credential headers and credential-named fields such as `password` or `token` print as `[REDACTED]` unless `--include-sensitive`. Redaction goes by name and by JWT / private-key shape only, so a secret under any other name (a presigned `X-Amz-Signature`, a custom `sig=`) prints in the clear, as does one inside a URL path. `--format` is `text`, `json`, or `names` (one name per line, JSON leaf names, no headers unless `--location` names them), which is a Miner or Fuzzer wordlist.

**`sitemap export`**: the captured API as an OpenAPI 3.0.3 document on stdout, the same one `⇧E` on the TUI's [Sitemap](/guide/proxy/#openapi) writes. What was left out and why goes to stderr.

```bash
gori run sitemap export --host api.example.com > api.json
gori run sitemap export --host api.example.com --format openapi-yaml > api.yaml
gori run sitemap export --in-scope --examples > api.json
```

- **Paths** are templated one path at a time. A numeric, UUID, long-hex or date segment becomes a parameter named after the segment before it, so `/users/123/orders/9f1c2b7d0a4e` becomes `/users/{userId}/orders/{orderId}`. A single captured id is enough; the tree's display folding waits for many. Endpoints whose templates match merge into one operation. Query-string variants of one path are one operation too.
- **Parameters** (query, header, cookie) are `required` only when every sample of the operation carried them. Standard browser headers are left out, and a repeated query key is an array.
- **Bodies**: request bodies and responses per status carry a schema inferred from every sample. A JSON schema merges types (`integer` and `number` become `number`, and genuinely different types become `oneOf`), unions object properties and requires the members every sample had. Forms become object schemas, and other media types a string.
- **Security**: an `Authorization` header becomes an `http` bearer, basic or digest scheme. Another credential header (`X-Api-Key`, `X-Auth-Token`, …) and a session cookie become `apiKey` schemes. Their values are never written.
- **Skipped**: requests gori sent itself (Repeater, Fuzzer, Miner, Discover and the other tools; `--include-gori` keeps them), WebSocket, gRPC, SSE and incomplete flows, and methods OpenAPI has no slot for (CONNECT, WebDAV). Each is counted on stderr. Without that first rule, a Discover brute force would add every path it guessed and a fuzz run would loosen every type.

`-q`/`--query=QL` (also positional), `--in-scope` and `--hide-static` narrow the flows read, per flow as in `history`. `--host` is an exact host, and `--path=PREFIX` is a path prefix. When the flows span several hosts, one document lists every origin under `servers` and each path lists the ones that answered it; use `--host` for one API per document. `--max-samples=N` (default 20) caps the flows read per operation, `--max-flows=N` (default 5000) the flows read in all, and `--max-endpoints=N` (default 1000) the operations kept. A note on stderr says when a cap cut the document short.

There are no `example` values unless `--examples`. Examples come from one sample each and pass the redaction profile (`--redact=PROFILE`, by default the project's, else the global one, else `default`). The profile's field and form-key names apply to query parameters too. A name that reads as a credential (`X-Access-Token`, `apiKey`, `userPassword`, `sig`) is a placeholder whatever the profile says, and cookie values always are. A path id gets an example only when it is a short counter or a date under a segment that does not name a secret; a UUID, hex or token-shaped segment never does, because a credential in a path looks the same. Token-shaped path segments (a JWT, a long random string) and `;jsessionid=`-style matrix parameters never reach the path key. Output is deterministic: exporting the same flows twice gives the same bytes, so `diff` between two exports shows how the API changed.

### run oast

Out-of-band listener. `listen` is ad-hoc and store-free by default (register a payload, print it, stream callbacks); `--save` makes it a project session instead. `list` / `resume` / `release` act on those saved sessions, the same rows the TUI's RESUME LISTENER picker shows.

```bash
gori run oast presets                          # list built-in public providers
gori run oast presets --check                  # …and probe each one for reachability
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site --once --json
gori run oast listen --save                    # …and keep it as a project session
```

`presets` lists the public providers, and `presets --check` PROBES each one over the network and prints the stage it fails at (`dns` / `connect` / `proxy` / `tls-verify` / `tls` / `timeout` / `exchange` / `dial`) — which is what separates a custom trust store or a restricted resolver from a provider outage. It exits non-zero only when nothing answered.

```bash
gori run oast presets --check
gori run oast presets --check --format json
```

| Option | Description |
| -------- | ------------- |
| `--check` | Probe each preset over the network and report reachability |
| `--format=FMT` | `text` (default) or `json` |
| `--project=NAME` · `--db=PATH` | With `--check`: probe the way that project dials (its pinned upstream proxy and timeouts) |

A failed `listen` names the same stage. On `tls-verify` the remedy is this machine's trust store, not another provider: run with `SSL_CERT_FILE=/path/to/ca-bundle.crt` (or `SSL_CERT_DIR=/path/to/certs`) so the private or TLS-inspecting CA is trusted. For gori's own service traffic that bundle is **additive** — the system store is still loaded — so the public presets keep working. There is no `--ca-file` flag.

`listen` options:

| Option | Description |
| -------- | ------------- |
| `--provider=KIND` | `interactsh` (default) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--server=URL` | Provider server / base URL (default: the provider's public preset) |
| `--token=TOK` | Optional provider auth token |
| `--interval=SEC` | Poll interval (default 5) |
| `--once` | Poll once and exit |
| `--save` | Save the registration as a project OAST session (see `oast list`) |
| `--json` | Emit each callback as a JSON line (same shape as MCP) |

`--save` is what turns an ad-hoc listener into a project one, and it changes three things: every callback is written into the project (so the TUI OAST tab shows the same hits), the registration is **kept** on exit so `oast resume ID` can pick it up later, and the out-of-band probe rules (`ssrf_oast`, `xxe_oast`, `cmd_injection_oast`, `rfi_oast`) have a session to mint payloads against — without one they plan nothing and `gori run probe --active` says so. It takes `--project` / `--db` like the session verbs; `oast release ID` is the teardown.

**`oast list` / `resume` / `release`**: the project's saved listening SESSIONS, as opposed to the providers below (a provider is where you listen; a session is one live registration on it). A registration outlives the process that minted it, which is what makes a payload planted yesterday still worth watching.

```bash
gori run oast list                                       # id, provider, payload host, hits, last poll
gori run oast list --format json
gori run oast resume 7                                   # re-arm session #7, stream its callbacks
gori run oast resume 7 --once --json                     # one poll, JSON lines, then exit
gori run oast release 7                                  # deregister it server-side
```

`resume` and `release` take the session **id** (`7`, or the `#7` `list` prints). `resume` re-arms the server-side state so payloads already planted keep resolving, then polls: every callback is written into the project, so the TUI OAST tab shows the same hits, and `last_poll_at` is stamped like a TUI listener's. Ctrl-C stops polling and **keeps** the registration. `release` is the deliberate teardown, and it keeps the stored callbacks either way. Nothing auto-resumes; these run only when you ask.

| Option | Description |
| -------- | ------------- |
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

`enable`, `disable`, `update` and `delete` take the provider **id** (`p_1`, or a bare `1`), not its display name; `add` prints the id it assigned, and `list` shows it.

| Option | Description |
| -------- | ------------- |
| `--name=NAME` | Display name. Required on `add` |
| `--kind=KIND` | `interactsh` (default) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--host=URL` | Server / base URL (defaults to the kind's public preset) |
| `--token=TOK` | Provider auth token |
| `--enabled` / `--disabled` | Arm or disarm the provider on `add` / `update` |
| `--show-tokens` | On `list`: print tokens instead of `[REDACTED]` |

### run jwt

Decode, verify, re-sign, or generate attack payloads for a JWT. Store-free compute; the token comes from the `<token>` argument or stdin. An encrypted five-part token (JWE) decodes to its protected header — gori reads `alg`/`enc`/`kid` and does not decrypt the claims.

```bash
gori run jwt eyJhbGci...                        # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --encode --set role=admin --secret s3cret
gori run jwt eyJhbGci... --encode --alg ES256 --key ./private.pem
gori run jwt eyJhbGci... --verify --key ./public.pem
gori run jwt eyJhbGci... --attacks --key ./public.pem
```

| Option | Description |
| -------- | ------------- |
| `--decode` | Decode header / payload / signature (default) |
| `--encode` | Re-sign the token's claims with `--alg` and `--secret` / `--key` |
| `--verify` | Check the token's own signature against `--secret` / `--key`; prints `verified: yes\|no` (a `no` is an answer, not a failure — exit status stays 0) |
| `--attacks` | Generate testing payloads (alg:none, weak-secret, header injection) |
| `--alg=ALG` | Signing alg for `--encode`: `HS256` (default) \| `HS384` \| `HS512` \| `RS256/384/512` \| `PS256/384/512` \| `ES256/384/512` \| `EdDSA` \| `none` |
| `--secret=SECRET` | HMAC secret, for an HS algorithm |
| `--key=PEM` | PEM key for an RS/PS/ES/EdDSA algorithm — inline PEM text or a path to a `.pem` file. `--encode` needs the PRIVATE key; `--verify` takes a public key, a certificate, or the private key; `--attacks` takes the server's PUBLIC key and adds the algorithm-confusion payloads. Mutually exclusive with `--secret` |
| `--payload=JSON` | `--encode`: replace the claims wholesale before re-signing (mutually exclusive with `--set`) |
| `--set=CLAIM` | `--encode`: patch one claim before re-signing, as `key=value`, repeatable; the value is JSON if it parses (`true`/`3`), else a string |
| `--format` | `text` (default) or `json` |

### run cookie

Decode, verify, brute-force, or forge a signed Flask / Rack / Django session cookie. Store-free compute; the cookie comes from the `<cookie>` argument or stdin.

```bash
gori run cookie 'eyJ1c2VyIjoi...'                            # decode (default), format auto-detected
gori run cookie 'eyJ1c2VyIjoi...' --crack --wordlist secrets.txt
gori run cookie --forge --type flask --secret s3cret --payload '{"user":"admin"}'
```

| Option | Description |
| -------- | ------------- |
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

A step written `exec:COMMAND` is an [external process hook](/guide/scripting/#process-hooks)
instead of a converter: the running value goes to `COMMAND` on stdin and its stdout becomes the
step's output. It is exec'd with no shell, so the three separators cannot appear in its arguments.

```bash
gori run decoder 'base64-decode | jwt-decode' "$TOKEN"
echo -n secret | gori run decoder 'sha256 | base64'
gori run decoder 'base64-decode > exec:./parse-envelope --json' "$BLOB"
gori run decoder list                           # every converter (name, category, direction)
```

| Option | Description |
| -------- | ------------- |
| `--input=STR` | Value to convert (else the 2nd positional arg, else stdin) |
| `-o`, `--output=MODE` | Render final bytes: `auto` (default) \| `text` \| `base64` \| `hex` |
| `--format` | `text` (default) or `json` (per-step detail) |

### run issues / notes

```bash
gori run issues --format markdown --export report.md
gori run issues --format sarif --export issues.sarif    # upload to GitHub code scanning / a CI dashboard
gori run notes --all
```

Write issues from scripts with `create` / `update`:

```bash
gori run issues create --title "Reflected XSS on /search" --cvss 8.8 --host app.example.com --flow 42
gori run issues update 7 --status confirmed --notes "Verified on staging" --severity critical
gori run issues delete 7

# The notes body can come from a file or a pipe instead of the argument vector
gori run issues create --title "IDOR on /v1/users/{id}" --severity high --notes-file writeup.md
report-generator | gori run issues update 7 --status confirmed --notes-stdin
```

`--notes`, `--notes-file` and `--notes-stdin` are mutually exclusive, and the body is read byte-for-byte — multiline UTF-8, CRLF and all (the value of a bound project env var is still masked to `$ENV.NAME` on the way in, as it is for every issue field). A long write-up piped in or read from a file stays out of the process listing and the shell history; on `create` it is written with the issue in one transaction, so a script no longer needs a create-then-update pair. `--notes ''` clears the notes on `update`; a file or a pipe that yields nothing is refused instead, so a report generator that dies cannot silently erase a write-up. `--notes-stdin` needs a pipe or a redirect (`--notes-stdin < notes.md`) and refuses a terminal, for the same reason `--request-stdin` does.

| Option | Description |
| -------- | ------------- |
| `--format` | `text` (default) \| `json` \| `markdown` \| `sarif`, the same reports the TUI's Export writes |
| `--export=PATH` | Write to `PATH` instead of STDOUT (bytes verbatim; STDOUT is escape-scrubbed) |
| `--include-sensitive` | Emit `Authorization` / `Cookie` / `Set-Cookie` / `Proxy-Authorization` / API-key values in `sarif`'s `webRequest`/`webResponse` headers instead of `[REDACTED]`. Inert in the other formats, which say so on STDERR |
| `create` | `-t`/`--title` (required), `--cvss` (score or vector; auto-derives severity), `-s`/`--severity` (`info`\|`low`\|`medium`\|`high`\|`critical`), `--host`, `--flow=ID`, `-n`/`--notes`, `--notes-file=FILE`, `--notes-stdin` |
| `update <id>` | `-t`/`--title`, `--cvss` (new score/vector; empty to clear), `-s`/`--severity`, `-n`/`--notes` (empty to clear), `--notes-file=FILE`, `--notes-stdin`, `--status` (`open`\|`confirmed`\|`false-positive`\|`resolved`) |
| `delete <id>` | Delete the issue and its evidence links. To keep it in the report but mark it closed, use `update <id> --status=resolved` instead |

`--format sarif` writes a [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html) log, the format GitHub code scanning, DefectDojo and Azure DevOps ingest. Each issue becomes one result: its severity maps to a SARIF `level` (with `rank` and the rule's `security-severity` preserving the full five-way scale), a `false-positive` or `resolved` triage status becomes a `suppression` so a dismissed finding does not reappear as open, and a linked flow rides along as `webRequest`/`webResponse` with real headers and (decoded, 64 KiB-capped) bodies.

**Credential header values are `[REDACTED]` in that log by default**, and the message is marked `gori/sensitiveHeadersRedacted: true` when anything was withheld. A SARIF log is made to leave the machine, so it gets the same default as `history --format json` and `evidence show`; `--include-sensitive` writes the exact values. A repeated header is combined the way that field allows: list values with `, `, `Cookie` pairs with `; `. `Set-Cookie` never combines, so its fields are joined with a newline and also listed one per field in the message's `gori/setCookie` property.

Notes are readable and writable too. `notes` with no argument lists them (`*` marks the active note); `notes <n>` prints one by index:

```bash
gori run notes                                  # list
gori run notes 2                                # print note 2
gori run notes create --text "SSRF candidate on /fetch"
echo "pasted from a scratchpad" | gori run notes create
gori run notes delete 2 --yes
```

| Option | Description |
| -------- | ------------- |
| `list` | `--all` prints every note in full instead of a summary line |
| `create` | `--text=TEXT`, or a positional argument, or STDIN |
| `delete <n>` (`rm`) | Delete the note at index `n`; `-y`/`--yes` is required |

A note is prose that exists nowhere else — no capture or re-run reproduces one — and the index is a **list position**, so `notes delete 2` names a different note once an earlier one is gone. `delete` therefore refuses without `-y`/`--yes` (there is no interactive prompt), and the refusal quotes the note's first line, when it has one, so a wrong number is visible before it costs anything.

### run links

The evidence an Issue or Note points at: a captured Flow, a Repeater session, or a Fuzz / Miner run. The Markdown issue export resolves these already; this is the surface that lists and edits them.

```bash
gori run links --owner=issue --id=7
gori run links add --owner=issue --id=7 --ref=flow --ref-id=42
gori run links delete --owner=note --id=2 --ref=repeater --ref-id=3
```

| Option | Description |
| -------- | ------------- |
| `--owner=KIND` | Owner kind: `issue` (default) or `note` |
| `--id=N` | Owner issue / note id. Required |
| `--ref=KIND` | Target kind for `add` / `delete`: `flow`, `repeater`, `fuzz`, `miner` |
| `--ref-id=M` | Target id for `add` / `delete` |
| `--format=FMT` | `text` (default) or `json`, on `list` |

A pointer whose target was pruned lists as `(stale)` rather than disappearing, so "no evidence" and "evidence that is gone" stay distinguishable. `add` is idempotent, and both ends must exist.

### run evidence

An Issue's **frozen** evidence: the immutable copy of one exchange, taken from a captured Flow or a Repeater tab at the moment it proved the finding. `links` is the live-source pointer; this is the archived bytes. The Repeater's next send and History retention cannot reach a copy, so freeze once when a response confirms a finding and again after the retest. One snapshot can be linked to several Issues, and removing its last Issue link leaves it orphaned until it is linked again or explicitly deleted.

```bash
gori run evidence freeze --issue=7 --ref=repeater --ref-id=3       # copy + the live link
gori run evidence freeze --issue=7 --ref=flow --ref-id=42 --no-link
gori run evidence --issue=7                                        # list: source, time, status, size, SHA-256
gori run evidence                                                  # the whole project archive, orphans included
gori run evidence show 12                                          # the copy, credentials redacted
gori run evidence show 12 --include-sensitive --format=json
gori run evidence link 12 --issue=9                                # add another Issue membership
gori run evidence unlink 12 --issue=7                              # snapshot remains if orphaned
gori run evidence delete 12
```

| Option | Description |
| -------- | ------------- |
| `--issue=N` | The Issue to link. Required on `freeze`, `link` and `unlink`; on `list` it narrows to one Issue's copies, and omitting it lists the whole project archive (newest first, orphans included) |
| `--ref=KIND` | Source kind for `freeze`: `flow` or `repeater` — a fuzz or miner session has no single exchange |
| `--ref-id=M` | Source id for `freeze` |
| `--no-link` | `freeze` only copies; by default it also files the live link `links add` would, in the same transaction |
| `--allow-drift` | `freeze` a Repeater tab whose request was edited after its stored response arrived. Refused without it — see below |
| `--include-sensitive` | `show` prints Authorization / Cookie / Set-Cookie / API-key values verbatim instead of `[REDACTED]`. The SHA-256s cover the stored wire bytes, so verifying them needs this |
| `--format=FMT` | `text` (default) or `json`, on `freeze`, `list` and `show` |

A Repeater tab that has never been sent is refused rather than frozen request-only, and so is a flow whose response has not landed. A Repeater copy pairs the tab's saved request (bindings unexpanded) with the last response the store holds for it — a successful send's; freeze right after the send that proved the finding.

**Request drift.** A Repeater tab holds one request and one response, and editing the request does not change the response beside it: send, edit, freeze, and the copy pairs an edited request with an earlier exchange's response. gori records the SHA-256 of the request each send actually went out with, so it can tell — `freeze` refuses such a tab by name and tells you to send it again, `--allow-drift` writes the mismatched pair anyway, and the TUI asks before it writes. A response persisted by a gori older than this one has no recorded digest; those are treated as unknown, not as drift. A WebSocket copy is the handshake; the frame transcript is not copied. A project's frozen evidence is bounded at 256 MB; past that `freeze` refuses until a copy is deleted. `show` decodes bodies and cuts the text form at 64 KB (the stored copy is complete); the JSON form takes the same shape `get_flow` returns.

### run retest

An Issue's **retest**: the ordered Repeater sends that reproduce the finding, each with a role and at most one assertion, plus the bounded record of what happened the last few times it ran. `links` says what is related and `evidence` keeps the bytes that proved it; neither can be *run*. This is what turns "send #4 to log in, then #5 should answer 403" out of an issue's write-up into something CI can execute.

```bash
gori run retest add --issue=7 --repeater=4 --role=setup                        # log in first
gori run retest add --issue=7 --repeater=5 --role=baseline --assert=status:200
gori run retest add --issue=7 --repeater=6 --role=variant  --assert=status:403
gori run retest --issue=7                                                      # the plan, with what each step will send
gori run retest move 9 --to=1                                                  # reorder (ids from --format=json)
gori run retest update 9 --role=control --assert=body:same
gori run retest run --issue=7                                                  # exit 0 only on `pass`
gori run retest runs --issue=7                                                 # the bounded run history
gori run retest show 3                                                         # one run's result table
gori run retest forget 3                                                       # drop one run from the record
```

| Option | Description |
| -------- | ------------- |
| `--issue=N` | The Issue. Required on `steps`, `add`, `clear`, `run` and `runs` |
| `--repeater=M` | `add`: the Repeater session this step sends (ids from `gori run repeater list`) |
| `--role=ROLE` | `setup` \| `baseline` \| `variant` (default) \| `control` \| `cleanup` |
| `--assert=EXPR` | The one expected result (below). Omit — or pass an empty value on `update` — to record the outcome and assert nothing |
| `--to=POS` | `move`: the new 1-based position, clamped to the list |
| `-y`, `--yes` | `run`: confirm a batch that contains a state-changing method. `clear`: confirm the deletion |
| `--allow-cleanup` | `run`: send the cleanup steps even after gori refused a send |
| `--allow-unscoped` | `run`: send outside the project scope. Sandbox and explicit excludes still apply |
| `--no-record-history` | `run`: do not write each send to History (default: record — a retest is evidence) |
| `--slot=NAME` | `run`: send every step as this session slot — its header overlay and its `$BIND.NAME` table |
| `--timeout=SEC` | `run`: per-step connect + idle timeout (default 20) |
| `--limit=N` | `runs`: how many runs to print |
| `--format=FMT` | `text` (default) or `json` |

`forget RUN` drops one run summary and its result rows. The steps that produced it stay, and so do the History flows each send recorded — it removes the report, not the evidence. The history prunes itself to the newest 20, so this is for the run that should not be *on* the record (a batch sent at the wrong target, or under a scope since fixed).

Assertions — one per step:

| Expression | Passes when |
| -------- | ------------- |
| `status:200` | The response status is exactly 200 |
| `status:2xx` | The status is in that class |
| `status:200-299` | The status is in that inclusive range |
| `json:data.user.id` | The JSON field exists (a field whose value is `null` counts — it is there) |
| `json:data.role=admin` | The JSON field equals the literal. The literal is untyped text, so `n=3` matches the number `3` and the string `"3"` |
| `json-absent:data.token` | The JSON field is not there |
| `body:same` | The decoded body is identical to the last `baseline` step's |
| `body:diff` | It differs from it |

A JSON path is the same one `sequence --jsonpath` takes: dotted (`data.items.0.id`) or bracketed (`$.data.items[0]["id"]`). A path gori cannot read — a wildcard, a filter, `..`, an unclosed bracket — is refused when the step is added, so a `json-absent:` can never pass just because its path was never read. A readable path to a field that is not there is an ordinary absence.

A step sends whatever its Repeater tab holds when the run happens — that is what makes a retest track a request as it is fixed, where `gori run evidence` freezes one as it was. Each send goes out under the project's scope and Sandbox gates and is recorded in History as `src:retest` with the issue and step on the row, so a result row still opens the exact response it reported long after the tab moved on. The tab's own stored response is never overwritten.

A `setup` step that fails halts the measurement steps (its precondition is what everything after it measures against) but cleanup still runs. Once gori **refuses** a send — scope, Sandbox, an exclude rule — the rest of the run is skipped, cleanup included, unless `--allow-cleanup` says otherwise; every skipped step still gets a row saying why, so a partial run can never read as a pass. A `body:` assertion is `inconclusive`, never a pass, when there is no baseline behind it — and equally when the last `baseline` step **missed its own expected result**: a baseline that did not establish its reading anchors nothing, so comparing a variant against the 403 error page a `status:200` baseline was handed would otherwise report "the body is unchanged" about two error pages.

The verdict is `pass` only when every step ran and every assertion was decided; `blocked` outranks `fail`, because a run gori refused to finish is a fact about the scope configuration and not about the target. `run` exits `0` on `pass` and `1` otherwise. The newest 20 runs per Issue are kept.

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
gori run rewriter add --op short_circuit --map-dir ./tampered \
  --strip-prefix /static/ --fallthrough                 # missing files reach the origin
gori run rewriter add --op short_circuit --find /api/pay --fault reset
gori run rewriter add --op short_circuit --from-flow 42  # a captured response as the stub
gori run rewriter disable 3
gori run rewriter disable 2 --scope global               # off in THIS project only
gori run rewriter disable 2 --scope global --everywhere  # off by default, everywhere
gori run rewriter rm 3
```

| Option | Description |
| -------- | ------------- |
| `--op=OP` | `replace` (default), `add_header`, `set_header`, `remove_header`, `short_circuit`, `pipe` |
| `--target=SIDE` | `request` (default) or `response` |
| `--part=PART` | `head` (default), `body`, or `ws` (a WebSocket message). Only meaningful for `replace` and `pipe` |
| `--match=MODE` | `literal` (default) or `regex`, for `replace`, `pipe` and `short_circuit`. Regex replacements take `$1`, `$2`; `$$` is a literal `$` |
| `--response-file=PATH` | `short_circuit`: read the canned response from PATH (`-` = stdin — a pipe or a redirect; a terminal is refused) |
| `--body-file=PATH` | `short_circuit`: serve PATH as the response body, re-read whenever it changes |
| `--map-dir=DIR` | `short_circuit`: serve the file the request path names from DIR (Map Local). `--value` becomes an optional head template |
| `--strip-prefix=PATH` | With `--map-dir`: the URL prefix removed before the path is joined under DIR (`/static/`). Without `--find`, the rule matches this prefix on the request line |
| `--fallthrough` | With `--map-dir`: a request whose file is missing goes to the origin instead of a `502` |
| `--fault=KIND` | `short_circuit`: answer with no response: `close`, `reset` or `hang` |
| `--hang=MS` | With `--fault=hang`: how long to hold before closing (default 30000) |
| `--delay=MS` | `short_circuit`: wait before answering (max 120000) |
| `--from-flow=ID` | `short_circuit`: copy flow ID's captured response into the rule. `--find`, `--host` and `--value` override what it drafts |
| `-f`, `--find=FIND` | Required, except with `--from-flow` or `--map-dir --strip-prefix`. The literal, pattern, or header name to act on |
| `-v`, `--value=VALUE` | Replacement text, header value, or (with `--op=pipe`) the COMMAND to run. See [Process hooks](/guide/scripting/#process-hooks) |
| `--host=GLOB` | Limit the rule to a host and its subdomains (`example.com` also matches `api.example.com`, but not `xexample.com`); `*` is the explicit wildcard. Omit to apply everywhere |
| `--name=NAME` | Label shown in the rule list |
| `--disabled` | Create the rule without arming it |
| `--scope=SCOPE` | `project` (default) or `global`. A global rule lives in `settings.json` and applies in every project. On the bare listing: show only that store's rules (default: both) |
| `--everywhere` | On `enable`/`disable` of a global rule: change the rule's own default instead of this project's override |

`preview` takes the same rule flags and reports how many stored flows the rule would have changed, without writing it. `rm` (`delete`), `enable` and `disable` take a rule id from the list, plus `--scope`, because the two stores number their rules independently, so an id alone names two different rules. The list prints the scope as a `G`/`P` prefix (`G*` = this project overrides that global rule's default) and shows global rules first, the order the proxy applies them in. See [Global and project rules](/guide/proxy/#global-and-project-rules).

Body rules re-sync `Content-Length` and de-chunk as needed, and an enabled rule forces HTTP/1.1 on hosts it matches. See [Proxy & History](/guide/proxy/) for the interactive editor.

**`rewriter preset`**: install a [response-modification preset](/guide/proxy/#rewriter-presets), a named starting point that writes ordinary Match & Replace rules. Verbs: `list` and `add <name>`.

```bash
gori run rewriter preset list
gori run rewriter preset add unhide-hidden-fields
gori run rewriter preset add remove-csp --scope global --disabled
```

Names are `unhide-hidden-fields`, `enable-disabled-fields`, `remove-length-limits`, `strip-validation`, `remove-csp`, `remove-security-headers` and `disable-sri`. `add` takes `--scope=project|global` and `--disabled` (install without arming, to review them first). The rules it writes go through the same path `rewriter add` does, so they are listed, editable and deletable afterwards. Installing the same preset twice duplicates visibly rather than merging.

**`rewriter extract`**: the rules that declare [session bindings](/guide/proxy/#session-bindings): which response a `$BIND.NAME` is read from, and where in it. Verbs: `list` (default), `add`, `rm` (`delete`), `enable`, `disable`.

```bash
gori run rewriter extract add --name SESS --kind cookie --selector session --host '*.example.com'
gori run rewriter extract add --name CSRF --kind regex --selector 'name="csrf" value="([^"]+)"'
```

| Option | Description |
| -------- | ------------- |
| `--name=NAME` | Binding name, without the `$`. Required |
| `--kind=KIND` | `cookie` (default), `header`, `regex`, `position`, `jsonpath` |
| `--selector=SEL` | Cookie / header name, regex, or JSON path |
| `--range=A:B` | `position` only: a half-open byte range of the decoded body |
| `--when=FILTER` | Which messages to read, in intercept-filter syntax (`''` = any) |
| `--host=GLOB` | Limit to a host glob (`''` = all) |
| `--disabled` | Create the rule without arming it |

**`rewriter bindings`**: list the names those rules declare (`--format text|json`). Values are not shown here and cannot be: a binding's value lives in the memory of the running gori and is never written anywhere, so another process has nothing to read. The Rewriter tab's `bindings` sub-tab shows the live table. For a headless sweep, `--bind-from` fills the values in-process; see [Session bindings from the command line](#session-bindings-from-the-command-line).

### run grpc

The gRPC [`.proto` lens](/guide/proxy/#proto-schema) from the command line: what schema this project renders captured gRPC through, and where each piece came from.

```bash
gori run grpc                                  # what is loaded (schema is the default verb)
gori run grpc schema --format json
gori run grpc reflect https://api.test:443     # ACTIVE: ask the target for its descriptors
gori run grpc forget https://api.test:443      # drop one cached target (`rm` is accepted)
gori run grpc forget --all
```

`schema` and `forget` touch nothing outside the project database. `reflect` is the one that sends: it asks the target's `grpc.reflection.v1` service (falling back to `v1alpha`, still what most deployed servers expose) for the services, then the file declaring each one, then their imports until the graph closes, and caches the result in the project. It goes through the same scope gate every other active `gori run` command does, so an out-of-scope target is refused before the dialer. A server that answers neither reflection version says so rather than failing quietly, and nothing ever re-fetches on its own.

| Option | Description |
| -------- | ------------- |
| `--format=FMT` | `text` (default) or `json`, on `schema` and `reflect` |
| `--allow-unscoped` | `reflect`: send even though the target is outside the project scope |
| `-k`, `--insecure-upstream` | `reflect`: do not verify the target's TLS certificate |
| `--timeout=SECONDS` | `reflect`: per-operation timeout (default: the project's io timeout) |
| `--all` | `forget`: drop every cached reflection target |

A descriptor-set **file** (Project settings → Proto schema) is not unloaded by `forget`; clear the path in the project's settings instead. Where a file and a reflection fetch disagree about a declaration, the count is reported as `redefined` and the target's own word wins.

### run colormarker

Manage **Colormarker** rules: which captured History rows get coloured, and how. Display only: a colour rule never modifies traffic, so unlike a Match & Replace rule it costs a misleading list at worst, never a modified message.

```bash
gori run colormarker                                        # list rules in precedence order
gori run colormarker add --when 'status:>=500' --color red --style full --name 'prod 5xx'
gori run colormarker add --when 'host:cdn' --color blue --style strip --scope global
gori run colormarker update 2 --color orange                # edit in place, keeping precedence
gori run colormarker move 2 --up                            # higher precedence
gori run colormarker preview --when 'method:DELETE'
gori run colormarker preview --when 'resp.body:secret' --scope global
gori run colormarker disable 1 --scope global               # off in THIS project only
gori run colormarker disable 1 --scope global --everywhere  # off by default, everywhere
gori run colormarker rm 3
```

| Option | Description |
| -------- | ------------- |
| `-w`, `--when=FILTER` | Required. The condition a flow must match; see below |
| `--color=NAME` | `red`, `orange`, `yellow` (default), `green`, `blue`, `purple` — resolved through the active theme, so they read correctly on light and dark alike — **or** the name of a custom colour (see below), which carries an absolute hex |
| `--style=STYLE` | `full` (default) tints the whole row · `strip` paints one colour cell in a narrow column ahead of `TIME` |
| `--name=NAME` | Label shown in the rule list |
| `--disabled` | Create the rule without arming it |
| `--scope=SCOPE` | `project` (default) or `global`. A global rule lives in `settings.json` and applies in every project. On the bare listing: show only that store's rules (default: both) |
| `--everywhere` | On `enable`/`disable` of a global rule: change the rule's own default instead of this project's override |
| `--up` / `--down` | On `move`: raise or lower the rule's precedence |
| `--limit=N` | On `preview`: how many recent flows to scan (default 500) |

On `update` every field is optional and defaults to the rule's current value, so `--color` alone is a recolour and `--when` alone a re-aim. Use it rather than delete + re-add: a colour rule's **position is its meaning** (the first enabled match paints the row), and a re-added rule lands at the end of its scope block, outranking nothing it used to outrank. `enable` / `disable` stay separate, because for a global rule they are a statement about *this* project rather than the library.

**Precedence is the rule set's meaning.** Match & Replace rules *compose*: every enabled rule runs, in order. Colour rules *resolve*: the **first enabled match paints the row** and the rest are never consulted. That is why `move` exists here and not on `rewriter`. Global rules resolve before project ones, so a standing policy outranks a local layer.

`--when` is a **History QL** condition — the same grammar, the same field set and the same answers as the filter bar above the list it paints, `~regex` and `AND` / `OR` / `NOT` / `-negation` / `(grouping)` included. A term the captured row can answer (`host:` `path:` `url:` `method:` `scheme:` `status:` `proto:`) is matched in memory with no query at all; the rest (`body:` `header:` `size:` `dur:` `stub:` `static:` `src:` `scope:`) resolve against the project database in one batched query per repaint. Four caveats, each of which would otherwise fail silently, so gori refuses or warns rather than letting you find out from a list that never turns colour:

- **`body:` *scans* here, it does not read the text index.** So a colour rule reaches binary bodies the filter bar's `body:` skips — but only the first **64 KiB of each side**, and the bytes are as *captured*, so a match past that bound or inside a compressed body is not painted. (Warned.)
- **`host:` is a substring, not a DNS-label glob.** `host:alpha.test` also matches `xalpha.test`. (Warned.)
- **A flow with no response yet has no status.** A `status:` rule paints the row once the response lands. (Warned.)
- **`scope:` follows the project's scope rules and ignores the `s` display lens.** With no scope rules configured *nothing* is in scope, so `scope:in` and `scope:out` both paint nothing — while a negated one (`-scope:in`) paints every row. (Warned.)

Refused, rather than warned: an unknown field (`hsot:` — left alone it becomes a free-text search and the rule never fires), a `~` pattern that will not compile, a term whose value that field does not take (`size:>bogus`, which would be *dropped* and leave the rule painting more than it says), and a condition that matches *every* flow (empty, or a half-typed `host:`).

`preview` reports how many recent flows the condition **matches** and how many it would actually **paint**. The two differ whenever an earlier enabled rule already claims the row — which is why `preview` takes `--scope` as well: every global rule resolves before every project one, so no project rule can claim a row from a `--scope=global` candidate. `update`, `rm` (`delete`), `enable`, `disable` and `move` take a rule id from the list, and `--scope`, because the two stores number their rules independently, so an id alone names two different rules. The list prints the scope as a `G`/`P` prefix (`G*` = this project overrides that global rule's default).

The tab is **off the bar by default**; `0` opens it, or `settings:tabs` gives it a slot next to Rewriter. See [Proxy & History](/guide/proxy/) for the interactive editor.

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

The name is the identity (it is what a rule's `--color` stores and what the picker shows), so it is lowercased, must be unique, and may not be one of the built-in words. `update` takes either half alone.

Deleting or **renaming** a colour deliberately does **not** rewrite the rules that name it: they keep the reference and fall back to a visible default, so re-adding the colour restores them. gori cannot reach every project's database from here, and a half-applied cascade would be worse than a dangling name. Recolouring is different: a rule references a colour by name, so it follows the new hex everywhere.

### run views

Manage **History views**: named QL queries the History list narrows to. A view is a *lens*: it is ANDed over whatever else is filtering rather than replacing it, so `gori run history --view History -q 'status:5xx'` means both. Seven built-ins ship with every project: the source trio `All` / `History` (`src:proxy`) / `History + Repeater` (the default), plus `WebSocket`, `gRPC`, `SSE` and `Errors`. Saved views live in two stores exactly as colour rules do.

```bash
gori run views                                              # list; the TUI's active view is marked ●
gori run views --scope global --format json
gori run views add 'acme errors' -q 'host:api.acme.test status:5xx'
gori run views add 'proxied' -q 'src:proxy' --scope global
gori run views set 'acme errors' -q 'status:>=500'          # new query, same name
gori run views rename 'acme errors' --to 'acme 5xx'
gori run views scope 'acme 5xx' --to global                 # re-home between the two stores
gori run views rm 'acme 5xx' --scope global
```

| Option | Description |
| -------- | ------------- |
| `-q`, `--query=QL` | Required on `add` and `set`. The view's query, in the same History QL the filter bar and `run history -q` take |
| `--scope=SCOPE` | `project` (default) or `global`. A global view lives in `settings.json` and appears in every project. On the bare listing it also accepts `builtin`, and shows only that store's views |
| `--to=NAME` | On `rename`: the new name |
| `--to=SCOPE` | On `scope`: the destination store, `project` or `global` |

A view is addressed by **name**, because that is what `--view` and the picker take; an id would be a second spelling of one thing. Names are unique *within* a scope and may collide across them; `--view` then resolves **project → global → built-in**, the same precedence project env vars and host overrides already follow. Every mutator takes `--scope` for the same reason `colormarker rm` does: the two stores are independently addressable, and guessing which one you meant would edit the wrong view. The listing prints the scope as a `G`/`P`/`·` prefix.

The query is validated **on the way in**, not when it runs. A query naming an unknown field, holding a broken regex, or one whose every term would be dropped is refused. That last one is the important one, because a view that narrows nothing would still show a `v:` chip claiming it does. The same check runs at all three surfaces, so a view the TUI refuses is not one the CLI accepts.

Built-in views cannot be edited or deleted, and a saved view may not take a built-in's name: it would shadow it, and `--view` could never reach the built-in again.

Deleting the view a project is currently looking through drops that project back to `All`. Another project's pointer at a *global* view you delete stays inert: ids come from a monotonic counter and are never reused, so nothing can inherit it. See [Proxy & History](/guide/proxy/#views) for the interactive picker.

### run project

List, create, export, import, or delete projects, or manage project-scoped config (scope rules, env vars, host overrides):

```bash
gori run project --format json
gori run project list
gori run project list --all
gori run project list --query=acme
```

| Option | Description |
|--------|-------------|
| `--all` | Include projects with nothing captured in them |
| `--query=TEXT` | Keep only the projects whose display name, directory slug, short id or bound workspace path contains TEXT (case-insensitive) |
| `--format=FMT` | `text` (default) or `json` |

`list` hides the **empty** projects (zero captured flows), because a project per worktree or per checkout accumulates into hundreds of them and buries the two or three holding traffic. Emptiness is counted, not inferred from file size: a project created a second ago is the same size as a leftover from March. Two are always listed however empty they are, and marked: `◆` is the project a `--project`-less `gori run` reads, `◇` the one the TUI last opened. In `--format json` those are the `current` and `tui_active` fields, beside a `flows` count and the project `description` (read in the same pass as the count, so it costs no extra open); the count of what was hidden goes to stderr, so a JSON pipe stays a clean array.

`--query` is the other half of that: a **substring** of any spelling that addresses a project, so a half-remembered name finds it — looser than `--project`, which wants an exact name, slug or short id. It is applied **before** the flow census, which opens every listed project's database, so a query is also the fast path on a host holding hundreds. It is orthogonal to `--all`, and it narrows the row source rather than the display, so what it excludes is said on stderr: a query that matched nothing reports how many projects the host actually has, and a query that filtered out the `◆` project names it — unlike the empty-hiding default, `--query` does not pin that row. `--format json` carries the bound `workspace` beside the rest, so a consumer can filter on the same fact the query does. The same narrowing is MCP `list_projects{query}`, over the same predicate.

#### project create

Create a project without capturing into it first. `gori run capture --project=NAME` also creates on demand; this is the traffic-free way to do it, so scripts can set up scope and env before the proxy starts.

```bash
gori run project create "API test"
gori run project create api-test --description="staging sweep"
gori run project create api-test --format json
```

| Option / subcommand | Description |
| --------------------- | ------------- |
| `<name>` | Display name. Quote it if it contains spaces |
| `--description=TEXT` | Stored in the project's settings |
| `--format=FMT` | `text` (default) or `json` |

A name that already exists reopens that project instead of failing; `--format json` reports it as `"created": false`. The reopen rewrites the stored display name (so its casing follows the last create) and replaces the description when `--description` is given. A new name that is already another project's directory slug or short id is refused, since `--project` could not then reach the project it made.

#### project export

Export one project's database, including committed writes still in its WAL, to a compact archive. The source project stays open and unchanged.

```bash
gori run project export "API test" -o engagement.gori
gori run project export api-test --output=before-clear.gori --force
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<name>` | Project display name, directory slug, or short id |
| `-o PATH`, `--output=PATH` | Destination archive path (required) |
| `--force` | Replace an existing destination file |

Before writing, gori prints flow, session-slot and project env-var counts, and whether project upstream credentials are set, to stderr. The archive copies the full database as stored, without redaction, and is created with owner-only file permissions. Existing files are refused unless `--force` is given; the destination cannot be inside the source project directory.

#### project import

Validate an archive and register it as a separate project. Import never replaces or reopens an existing project.

```bash
gori run project import engagement.gori
gori run project import engagement.gori --name "API test copy"
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<archive>` | Path to a `.gori` project archive |
| `--name=NAME` | Display name for the imported project (defaults to the archived name) |

Before creating the project, gori prints the archive's flow, session-slot and env-var counts, and whether project upstream credentials are set, to stderr. An existing display name, directory slug, or short id is refused; choose a different `--name` to resolve a conflict. The imported project gets a new short id and no machine-local workspace binding or lock files. Older database schemas migrate when the project is first opened; a schema newer than this build supports is rejected. Import adds the project to the registry but does not open it.

#### project delete

Delete a project directory and everything captured in it (flows, issues, notes, scope, rules). Irreversible, so it takes two steps: without `--yes` it only prints the target and exits non-zero.

```bash
gori run project delete api-test              # preview only, nothing is removed
gori run project delete api-test --format json
gori run project rm api-test --yes            # actually delete
```

| Option / subcommand | Description |
| --------------------- | ------------- |
| `<name>` | Matches a short id, id prefix, directory slug, or display name |
| `--yes` | Perform the delete. Without it the command removes nothing |
| `--format=FMT` | `text` (default) or `json` |

The preview reports flow and issue counts, on-disk size, and both of the locks the delete honours: whether a capture is live (`capture_lock_held`) and whether any other gori instance has the database open (`open_in_another_instance` — an MCP server takes no capture lock and still writes to it). `deletable` is the verdict those two add up to, and the closing line says whether `--yes` would go through. Deleting a project either one covers is refused: stop that capture, or close it there, first. A `capture_lock_held` of `null` means the lock could not be read at all (an unwritable project directory), which the delete also refuses.

Display names are not unique (two workspaces with the same basename share one). When a name matches more than one project, delete refuses and lists their slugs and short ids, as every `--project` does, since the wrong guess is unrecoverable. Slugs and short ids are unique, so either always resolves.

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
| --------------------- | ------------- |
| (default) | List rules; `--format` is `text` or `json` |
| `add` | `--kind=include\|exclude` (default `include`), `--type=host\|string\|regex` (default `host`), `--pattern=…` (required). Prints the new rule's id; `--format json` prints the rule as the listing does (`id`, `kind`, `type`, `pattern`) |
| `update <rule-id>` (`edit`) | Change a rule's `--kind` / `--type` / `--pattern`; a field you omit keeps its value |
| `delete <rule-id>` | Remove a rule by id |
| `enable` / `disable` | Toggle whether scope filtering is applied |

#### project sandbox

Get or set the **hard-containment** sandbox gate, the headless equivalent of the TUI Project settings toggle. When on, the capture proxy forwards only requests the scope allows and blocks everything else. This is distinct from `project scope enable`, which is only the display lens.

```bash
gori run project sandbox                 # show the current state (status is the default)
gori run project sandbox status --format json
gori run project sandbox on              # start blocking out-of-scope traffic
gori run project sandbox off             # stop blocking
```

| Option / subcommand | Description |
| --------------------- | ------------- |
| (default) / `status` | Show the gate state; `--format` is `text` or `json` |
| `on` / `enable` | Block every request the scope does not allow |
| `off` / `disable` | Stop blocking |

> With no include rule, turning the sandbox on blocks **all** captured traffic until you add one (`gori run project scope add …`). The command warns and proceeds, so it can bootstrap containment for CI.

#### project env

Manage **project** env vars used for `$ENV.KEY` substitution in outbound requests (Repeater, Fuzzer, Miner, CLI, MCP). Global vars live in `settings.json` / the TUI Settings. This command only touches the per-project layer. The name is stored bare; which grammar spells it on the wire is global, and [`gori settings env-syntax`](#env-syntax) decides it.

```bash
gori run project env                              # list KEY=value
gori run project env --format json
gori run project env set TOKEN=secret
gori run project env set HOST api.example.com
gori run project env delete TOKEN
```

| Option / subcommand | Description |
| --------------------- | ------------- |
| (default) | List project vars; `--format` is `text` or `json` |
| `set KEY=value` · `set KEY value` | Upsert a project var (KEY must match `[A-Za-z_][A-Za-z0-9_]*`) |
| `delete KEY` | Remove a project var |

#### project host-override

Manage **project** host overrides: `/etc/hosts`-style maps that change only the TCP dial target (SNI, certificate hostname, and `Host` header stay the original name). The value may carry a **port** (`IP`, `IP:PORT` or `[v6]:PORT`), so a hostname can be redirected at a listener on a different port; a bare IP keeps the request's own port. Project entries win over the global hostname overrides on collision. Alias: `host-overrides`.

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
| --------------------- | ------------- |
| (default) | List overrides; `--format` is `text` or `json` |
| `add` | `--host=…` + `--ip=…`, or positional `IP HOST`. `--format json` prints the new override as the listing does (`id`, `host`, `ip`) |
| `update <id>` | `--host=…` + `--ip=…` (both required) |
| `delete <id>` | Remove an override by id |

#### project network

Read and edit the project's **own** network settings, the `net.*` rows the TUI's **Project settings** card writes. A value set here wins over the global `network.*` in `settings.json` for this project only; `unset` returns the key to the global value. See [Per-Project Overrides](/reference/config/#per-project-overrides) for what each key does and where it applies. Alias: `net`.

```bash
gori run project network                                   # every key: its value here, and where it comes from
gori run project network --format json
gori run project network set upstream_proxy=http://proxy.corp.example:3128
gori run project network get upstream_proxy
printf %s "$PROXY_PASS" | gori run project network set upstream_auth alice --password-stdin
gori run project network set capture_max_mib 16
gori run project network unset capture_max_mib
```

| Key (`net.` prefix optional) | Value |
| ------ | ------- |
| `bind_host` · `bind_port` | Proxy listen address and port. Applied only where gori listens: the TUI and `gori run capture` |
| `upstream_proxy` | `http://`, `http+tls://`, `socks5://` or `socks5h://` URI. **Empty pins a direct route**: no global proxy, `upstream_rules` entry or `HTTP(S)_PROXY` applies to the project any more. Credentials in the URI are refused |
| `upstream_destination_host` | Host pattern the project's proxy routing applies to; anything else goes direct. `*` (the default) clears the row |
| `upstream_auth` | Proxy credentials: the value is the username, the password is read from stdin with `--password-stdin` (never the argument vector, which would put it in the process listing). HTTP Basic for an HTTP proxy, RFC 1929 for SOCKS5 |
| `connect_timeout_secs` · `io_timeout_secs` | Outbound connect and idle timeouts, seconds (min 1) |
| `capture_max_mib` | Body bytes captured and stored per message, MiB (1-2047) |

| Subcommand | Description |
| --------------------- | ------------- |
| (default) / `list` | Every key with the value in effect and its source (`· project`, `· global`); `--format json` carries `value` (the project's own row, `null` when unset), `inherited` and `effective` |
| `get KEY` | The value in effect: the project's own, else the inherited one (named on STDERR, so `$(…)` captures the value alone). Credentials print the method and username; the password is never printed |
| `set KEY=VALUE` · `set KEY VALUE` | Pin a value, **even one equal to the global**, which is what keeps a later global edit from reaching the project. (The Project settings card folds a value equal to the global back to inherit when it saves; `set` does not, because it names one key.) |
| `unset KEY` (`rm`) | Drop the project's value so it inherits again. A key that is not set is not an error |

Credentials pin the upstream they were entered for, as they do in the Project settings card: `set upstream_auth` also pins an inherited global upstream to the project, in the same write, so the password can never follow a later global edit or an upstream rule to a different proxy; `set upstream_proxy` moves stored credentials to the new address (re-deriving Basic vs SOCKS5 for it); and `unset upstream_proxy` is refused until `unset upstream_auth`. The multi-row edits are one transaction, so a busy project cannot store a password beside an address it was not validated against. Every edit is recorded in the project's event feed, without the credential.

A gori that already has the project open (a TUI, a capture, an MCP server) read these rows when it opened the project and keeps them until the project is reopened there; the command says so on STDERR when that is the case.

### run redact

Manage the **redaction profiles** that [safe evidence export](#safe-evidence-export) applies, and where they apply.

```bash
gori run redact profiles
gori run redact set pci --json-field card_number --json-field cvv --json-pointer /data/acct
gori run redact use pci
gori run redact default on
```

| Subcommand | Description |
| ---------- | ----------- |
| `profiles` (default) | Every profile available here — the project's first, then `settings.json`'s, then the built-ins — with its scope, its rule counts, a `*` on the one a safe export would use, and whether redaction is on by default. `--format json` for the full rule lists |
| `use <name>` \| `use --none` | Pick the profile a safe export uses. Writes this **project** unless `--global` |
| `default on\|off` \| `default --none` | Whether shareable output is sanitized *without* `--redact`. Project scope unless `--global`; `--none` clears the project's answer so it inherits the global one |
| `set <name>` | Create or **replace** a profile from repeatable rule flags. Project scope unless `--global` |
| `rm <name>` | Delete a profile. A built-in cannot be deleted — define one of the same name to replace it |

`set` takes four kinds of rule, each repeatable, plus `--description`:

| Flag | Matches |
| ---- | ------- |
| `--json-field NAME` | A JSON object member name, case-insensitively, **at any depth**. The workhorse: "whatever it is nested in, a member called `password` does not leave this machine" |
| `--json-pointer PTR` | An [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) pointer, at exactly one location (`/data/user/ssn`) — for the field name too generic to blanket. The array token `-`, which the RFC reserves for "past the last element" and which can never name an element that exists, is read here as **any index**: `/users/-/token` covers the whole array |
| `--form-key KEY` | An `application/x-www-form-urlencoded` key, case-insensitively. The key is percent-decoded before it is matched, and every other segment of the body survives byte-for-byte |
| `--pattern REGEX` | A regex over body text (also over each JSON string leaf and each decoded form value). With a capture group, **group 1** is what is replaced and the rest is the context you matched on — `account=(\d+)` keeps `account=` and takes the digits; with no group, the whole match goes. Compiled **case-insensitively**, like the three name lists above. A pattern that does not compile is refused here rather than reported on every later export |

**Scopes.** A profile lives in the project database or in `settings.json`, and which one is part of what it is. "Never export a `password` field" is the operator's own policy and belongs global; "this target calls it `pwd_hash`, and the account number is at `/data/acct`" is engagement data that must not follow you into the next engagement. Resolution is most-specific-first — project, then global, then built-in — and the first match by name wins, so a project profile shadows a global one and a global one shadows a built-in of the same name.

**The built-in `default`** covers credentials, tokens and the common government/financial identifiers by field name (`password`, `client_secret`, `access_token`, `api_key`, `session_id`, `otp`, `pin`, `ssn`, `card_number`, `cvv`, `iban`, …) and carries no regexes: a shipped pattern that fires on the wrong thing costs a mangled report with no warning, while a shipped *name* that does costs one value that was probably worth losing. It deliberately says nothing about, say, `email` — a default that redacted those would wreck the evidence for the class of finding where the address *is* the finding. Add what you want to a profile of your own, where you can see it.

**`default on` is opt-in, once.** Flipping it under an install that already has scripts reading `gori run show --format raw` would silently change what they get, so gori ships it off; from then on `--no-redact` is the explicit path back to the captured bytes, per invocation. With it on, the **TUI's `Space → Y` copy menu** and **MCP `get_flow`** sanitize too — a copy heading reads `COPY REQUEST AS · SANITIZED (3)`, and `get_flow` returns a `body_redaction` object naming the profile, the counts and what it did not look at. MCP's `include_sensitive: true` turns body redaction off along with the header redaction: one flag, both axes.

**Placeholder tags** are `[REDACTED:<8 hex>]`, an HMAC of the value under a secret minted once per install and kept in `settings.json`. Equal values share a tag so a report can still correlate them; nothing can be recovered from one, and a tag means nothing outside this install. A factory reset keeps the salt — discarding it would break every placeholder in every artifact already written. `gori settings export --sections redaction` carries the salt as well as the rules; hand somebody `gori run redact profiles --format json` instead when you mean to share only the rules.

## gori mcp

MCP stdio server. See the [MCP guide](/guide/mcp/) for tool details.

| Option | Description |
| -------- | ------------- |
| `--db=PATH` | Serve this database (overrides `--project`) |
| `--project=NAME` | Serve a named project's database |
| `--use-active-project` | Ignore Git-workspace selection and explicitly serve the active TUI/MRU project |
| `--no-project` | Start unbound even inside a Git workspace (agent picks via list/create/switch) |
| `--insecure-upstream` | `send_request`: skip upstream TLS verification |
| `--read-only` | Disable action tools (`send_request`, create/update issues, fuzz/mine); `switch_project` (and `create_project` when unbound) stay available |
| `--tools=SPEC` | Advertise only these tools: comma-separated names, globs or profiles (`@minimal`, `@recon`), a leading `-` subtracts (`@recon`, `@minimal,send_request` or `-fuzz_*,-mine_*`). The startup log reports the size of what is served; see [Choosing which tools are exposed](/guide/mcp/#choosing-which-tools-are-exposed) |
| `--install-claude` | Write Claude Desktop `mcpServers` config |
| `--install-claude-code` | Write Claude Code `~/.claude.json` `mcpServers` entry |
| `--install-codex` | Write OpenAI Codex `~/.codex/config.toml` `[mcp_servers.gori]` |
| `--install-agy` | Write Antigravity `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Write Grok `~/.grok/config.toml` `[mcp_servers.gori]` |
| `--install-hermes` | Write Hermes `~/.hermes/config.yaml` `mcp_servers.gori` (or `$HERMES_HOME`) |
| `--install-pi` | Write Pi `~/.pi/agent/mcp.json` `mcpServers.gori` (or `$PI_CODING_AGENT_DIR`); requires an MCP adapter |

Several `--install-*` flags may be given in one run; each named client is configured and reported separately, and one unwritable config does not stop the others. Every other flag on the command line (`--db`, `--project`, `--no-project`, `--use-active-project`, `--read-only`, `--insecure-upstream`, and the global `--config`) is written into the installed command, with paths made absolute. Existing config files are updated in place: other entries, tables and comments survive, permissions are preserved, and the replacement is atomic.

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

A verb comes first and its flags after it: `gori ca regenerate --ca-dir=DIR`, not `gori ca --ca-dir=DIR regenerate`. The reverse order is a usage error, because the verb would otherwise be dropped and the command would print the CA path as if it had done the work. None of the three forms takes a positional argument.

`gori ca` also reports a root CA that loads but cannot serve (a private key that does not match the certificate, or a key gori cannot sign with) on stderr, since the symptom otherwise appears only at the client as an "unknown CA" or "bad signature" handshake failure. `regenerate` and `import` are the fix, and both work on a CA directory in any state, including one where only one file of the pair survives.

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
| -------- | ------------- |
| `--cert FILE` | Root CA certificate PEM to adopt (required) |
| `--key FILE` | Matching private key PEM (required) |
| `--yes`, `-y` | Skip the interactive confirm (required when stdin is not a tty) |
| `--ca-dir=DIR` | CA directory to install into |

The pair is validated before anything is written: the key must match the certificate, the certificate must be a CA (`basicConstraints CA:TRUE`), and gori must be able to sign a leaf certificate with the key. That last check rules out **Ed25519 and Ed448 roots**, because gori signs leaves with SHA-256, which those keys do not support. Use an EC P-256 or an RSA root. A rejected pair aborts without touching the current CA. An expired or not-yet-valid certificate imports with a warning. Confirm by typing `import` on a tty, or pass `--yes`. The same action is available from the TUI palette (**Import CA certificate**).

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
gori settings tls-fingerprint      # the JA3/JA4 gori sends to each destination
gori settings env-syntax [VALUE]   # read or set the env-token grammar
gori settings user-agents          # the list $GEN.USER_AGENT draws from
```

### `gori settings env-syntax` {#env-syntax}

Which grammar spells an env token: `namespaced` (`$ENV.KEY` for env vars, `$BIND.NAME` for session bindings, `$GEN.NAME` for [per-request generators](/guide/repeater-and-fuzzer/#environment-variables)) or `bare` (`$KEY`, `$NAME`, with no generator spelling). A global setting, because it decides how the tokens in **every** project are read. With no argument it prints the value in force and where it came from.

```bash
gori settings env-syntax
# namespaced  (from /Users/me/.gori/settings.json)
#   $ENV.KEY / $BIND.NAME / $GEN.UUID

gori settings env-syntax bare
# env syntax: bare — $KEY / $NAME
# Each project is re-spelled the next time it opens: its stored tokens are rewritten from
# namespaced to bare, a backup is written beside the database, and the run that does it says
# so. Captured evidence is left exactly as it was.
```

Namespaced is the grammar for everyone, so the absence of `env.syntax` in `settings.json` means the file predates namespaces: the next start adopts `namespaced`, re-spells the **global** rewrite rules (keeping a `settings.json.pre-namespaced-<timestamp>` copy) and writes the key. Each **project** is re-spelled the first time it opens after the grammar moved — in the TUI, in any `gori run …`, or in a `gori mcp` server — with a `gori.db.pre-<grammar>-<timestamp>` backup beside the database (`VACUUM INTO`, so the WAL is included) and one line per project on stderr saying how many tokens moved. Rewritten: Repeater drafts (request, target, SNI, name) and their WebSocket messages, Fuzzer templates, Miner and Sequencer requests, rewrite-rule replacements, session-slot header values, and the masked tokens in issue titles/notes and note bodies. Left alone: every row whose provenance is a capture (`flow_id` set — a capture expands nothing), any row the target grammar has no equivalent spelling for, and names that are table keys rather than tokens (env vars, extract rules, rule patterns, payload sets).

`env.syntax = bare` is the opt-out and re-spells each project back on its next open, escaping a literal `$NAME` that would otherwise start resolving. See [Environment Variables](/guide/repeater-and-fuzzer/#environment-variables). `gori settings import` says on stderr when a profile's `env.syntax` differs from this install's: an import never changes the grammar.

### `gori settings user-agents` {#user-agents}

The list [`$GEN.USER_AGENT`](/guide/repeater-and-fuzzer/#environment-variables) draws from. With no flag it prints the list in use under a `#` line naming its source. `--set` reads that same format back, so you can save the output, edit it, and set it again. `--set` **replaces** the built-in list with the file's lines, one User-Agent per line, with blank and `#` lines skipped. A line gori cannot put in a header refuses the whole file and changes nothing. `--reset` goes back to the built-in list.

```bash
gori settings user-agents > ua.txt       # the list in use
gori settings user-agents --set ua.txt   # replace the built-in list
generator | gori settings user-agents --set -
gori settings user-agents --reset        # back to the built-in list
```

Stored as [`user_agents`](/reference/config/#user-agents) in `settings.json`, and editable in the TUI from Preferences → **Editor & Keys** → **User-Agents**.

### Profiles

`export` and `import` move settings between machines, share them with a team, or check a configuration into a repository for a reproducible run. The unit is the top-level section, listed by `gori settings sections`.

```bash
gori settings export --sections network,scan_rules -o team-profile.json
gori settings import team-profile.json --dry-run     # show what would be applied
gori settings import team-profile.json --sections network
```

`gori settings sections` lists every section gori knows, marking the ones this install has no value for yet:

```
statusline  (can carry commands)
network
editor  (can carry commands)
env  (holds secrets: excluded unless named; not set: at its default)
scan_rules  (can carry commands; not set: at its default)
decoder  (holds secrets: excluded unless named; can carry commands; not set: at its default)
rewriter  (can carry commands)
```

A section marked *not set* is still a valid name for `--sections`: exporting it simply carries nothing (gori says so on stderr), and importing one writes it for the first time.

| Flag | Applies to | Description |
| ------ | ----------- | ------------- |
| `--sections a,b` | both | Comma-separated section names; at least one. Export defaults to everything except secret-bearing sections; import defaults to every section in the file |
| `-o`, `--out FILE` | export | Write to a file instead of stdout |
| `--dry-run` | import | Print which sections would be applied, then exit without writing |
| `--allow-commands` | import | Apply rules that run an external command. Required when the profile carries one; without it the import is refused and nothing is written |
| `--json` | tls-fingerprint | Emit the report as JSON, always including the decomposed JA3 string and `ja4_r` |

A section you do not select, or that the profile does not carry, is left **exactly as it was**. That is the guarantee `--sections` is choosing between. Within a section the profile *does* carry:

- **List and table sections replace wholesale**: `upstream_rules`, `outbound_tls`, `listeners`, `scan_rules`, `hostname_overrides`, `tabs`, and the rest. A profile carrying `"upstream_rules": []` clears the table; that is how "no rules" is stated.
- **Object-of-scalars sections apply key by key**: `network`, `editor`, `probe`. A key the profile omits keeps its current value, so a team profile that pins `network.upstream_proxy` does not also reset everyone's `bind_port` to a default it never mentioned.

Note that `export` omits a section sitting at its factory default, so a profile is a set of values to *apply*, not a snapshot of a whole configuration: exporting from a machine where a value is default will not reset that value on a machine where it is not. Pass `--dry-run` to see which sections an import would touch. It errs on the side of listing one, so a section it does *not* name is guaranteed to be a no-op.

Import goes through the same writer the TUI uses, so it keeps the atomic write and cannot clobber a concurrently-running gori's edit to, or deletion of, a section it did not touch. Unrecognised sections in the file are reported and ignored: they reach neither the live settings nor the file.

If gori cannot load your `settings.json` (unparseable, unreadable, or a `--config` pointing at something it cannot open), both `export` and `import` refuse rather than proceeding. Every section is at its factory default at that point, so an import would persist those defaults over every section the profile does not name, and an export would write them out as if they were yours. Fix or remove the file first; an unparseable one is kept alongside it as `settings.json.corrupt`. `--dry-run` is the exception: it writes nothing, so it still runs, and says on stderr that the comparison is against defaults.

`env` and `decoder` are excluded from an export by default: `env` holds token values and `decoder` holds your saved chain library (open sub-tabs live in the project store, not here). Naming one explicitly (`--sections env`) is how you consent to include it. Note that `upstream_rules` is safe to share: it stores a username and an environment-variable *name*, never a password.

`-o` pointing at your live `settings.json` is refused. An export is not a snapshot (it omits every section at its factory default, and omits `env` and `decoder` unless you name them), so writing one back over the real file would delete those sections rather than update it.

When an export **does** carry one of those sections, `-o FILE` is created `0600` and gori says so, naming what is in the file. Consenting to export a credential is not consenting to leave it world-readable. An ordinary export stays `0644`, and an export that names `env` on an install with no env vars is an ordinary export. The mode follows what the document actually contains, not what you typed.

### Profiles that carry commands

Five sections can hold a **command** rather than data. They export like any other setting, because a team standardising on one re-signing hook is what hooks are for. Both ends say what is in the file.

| Section | What carries it | How it runs |
| --------- | ----------------- | ------------- |
| `rewriter` | a rule with `op: pipe` | argv, no shell. Runs on matching proxied traffic |
| `scan_rules` | an entry with `kind: exec` | argv, no shell. Runs on every analyzed flow |
| `decoder` | a `chains` spec step written `exec:…` | argv, no shell. Runs when the chain is run |
| `statusline` | `command` | **`/bin/sh -c`**. Runs every `interval` seconds |
| `editor` | `command` | argv. Runs on `gori settings --edit` and the TUI's `^E` |

The first three are [process hooks](/guide/scripting/#process-hooks). `statusline` is the sharpest of the five: it is a full shell rather than an argv exec, it carries its own `enabled` in the same section so a profile arms it outright, and it fires on a timer with no traffic needed. An `editor` command is only reported when the profile sets one; an empty value means gori falls through to your own `$VISUAL`/`$EDITOR`/`vi`.

`export` counts them on stderr, leaving the profile on stdout clean:

```
note: 5 entries in this profile run a local command (2 rewriter pipe, 1 scan_rules exec, 1 statusline sh -c, 1 editor exec); whoever imports it runs them with their own privileges
```

`import` lists them one per line, argv included, and refuses to write until you acknowledge them. `--dry-run` prints the same list and writes nothing either way:

```
$ gori settings import team-profile.json
5 entries in this profile run a local command here, with your privileges:
  rewriter pipe     resign body    ./resign.sh --key $TOKEN
  rewriter pipe     (unnamed)      /usr/local/bin/hmac  [disabled]
  scan_rules exec   leak detector  ./detect.py
  statusline sh -c  command        gori-status --project
  editor exec       command        nvim
importing them is the same trust decision as running the author's script
gori settings import: refused. The 5 entries listed above run a local command with your privileges. Read them, then pass --allow-commands. Nothing was written.
```

Read the commands, then pass `--allow-commands`. There is no interactive prompt, so a scripted import stays scriptable; the flag *is* the acknowledgement. An entry the profile carries but leaves off is marked `[disabled]`: it runs nothing until someone arms it, and it is still in the file. Narrowing with `--sections` narrows this too: an import that applies only `network` arms nothing, so it neither lists an entry nor asks for the flag.

### `gori settings tls-fingerprint`

Prints the **JA3 and JA4 fingerprint of the ClientHello gori actually sends**, per destination: the offer an anti-bot stack (Cloudflare, Akamai, DataDome, PerimeterX) reads before it decides whether to challenge you. It is the check for the [`outbound_tls`](/reference/config/#outbound-tls) fingerprint fields: OpenSSL will only ever tell you what got *negotiated*, never what was offered, so without this the settings are unverifiable.

```bash
gori settings tls-fingerprint                    # every rule, plus the no-rule default
gori settings tls-fingerprint shop.example.com   # the one policy that host would get
gori settings tls-fingerprint --json             # machine-readable, with the raw lists

# …and what a PER-SEND override would send instead, the same narrowing a Repeater tab's
# ␣P or a `--tls-preset` run applies, without touching settings.json:
gori settings tls-fingerprint shop.example.com --preset curl
```

```
shop.example.com  (matched rule "shop.example.com")
  preset          chrome
  groups          X25519:P-256:P-384
  …
  tunnelled (gori offers h2): ALPN h2, http/1.1
    JA3  c99e92e692ba483e2602b38b3c0a5645
         771,4865-4866-…,65281-0-11-10-35-5-16-22-13-43-45-51-21,29-23-24,0
    JA4  t13d1513h2_8daaf6152771_afafd945c4ab
         t13d1513h2_002f,0035,…_0005,000a,…_0403,0804,…
```

Each policy is reported for **two legs**, and the difference between them is real. gori offers `h2` on a decrypted MITM connection; on a leg it is going to speak HTTP/1.1 on (the forward-proxy dial, the Repeater, WebSocket) it drops `h2` from the offer, and with no `alpn` configured it sends no ALPN extension at all, so those legs carry different ClientHellos. The second line under each digest is the list it hashes: that is where you see *which* field a setting moved, and it is the half worth comparing against a browser.

The context the report reads is the same one a dial builds, so it cannot describe a handshake gori does not make. A `groups` or `sigalgs` string this OpenSSL rejects is reported on stderr for that rule and the rest still print.

`--preset NAME` narrows every reported policy the way a **per-send override** does (see [Per-send TLS fingerprints](#per-send-tls-fingerprints)), so you can check what `--tls-preset curl` will actually put on the wire for a host that already has a `chrome` rule. The client certificate, protocol range and `permissive` flag stay the destination's; only the ClientHello shape is replaced. An unknown name is refused rather than reported as an empty hello.

### Per-send TLS fingerprints

`outbound_tls` is keyed by destination host, which is right for a standing policy and wrong for the question the fingerprints exist to answer: **does this endpoint answer differently as `chrome` than as `curl`?** That is an A/B on one host, and doing it by editing a global rule between two sends makes the two sends incomparable, and changes the handshake for every other tab and background capture hitting that host at the same time.

A per-send override names a preset for **one send or one run**, resolved at dial time, without touching the destination table:

```bash
gori run repeater 42 --tls-preset chrome           # replay a captured flow as Chrome
gori run repeater 42 --tls-preset curl             # …and again as curl, comparably
gori run repeater send 7 --tls-preset firefox      # override a saved session for one send
gori run repeater create --tls-preset chrome …     # store it on the session
gori run fuzz --flow 42 --auto --tls-preset chrome # the whole sweep, one handshake
```

In the TUI it is `␣P` on a Repeater tab (a `␣P:…` chip on the TARGET band), persisted with the tab so a reopened one sends what it sent before, and the Fuzzer's **TLS fingerprint** row on the `^O` advanced card. Over MCP it is `send_request{tls_preset}` and `fuzz_start{tls_preset}`, both echoed back so a result set says which handshake produced it.

The override **narrows** the destination policy rather than replacing it:

| Field | Under an override |
| ------- | ------------------- |
| `preset`, `groups`, `sigalgs`, `ciphers`, `ciphersuites`, `alpn`, `session_tickets`, `ocsp_stapling` | **replaced** by the named preset's. This is the ClientHello shape, and merging would leave the destination's own values winning |
| `client_cert`, `client_key` | **kept**. An override says what the hello looks like, not who gori is; dropping the certificate would turn "chrome vs curl" into "authenticated vs anonymous" |
| `min_version`, `max_version` | **kept**. The version range is a reachability fact about that destination |
| `permissive` | **kept**. An override can neither grant nor revoke security level 0 |

Two sends differing only in the override dial two separate SSL contexts, so they really are two handshakes. `https` only: a plaintext leg sends no ClientHello, and gori will not report one it did not send. As with the destination-level presets, these are **approximations** (extension order and GREASE placement are OpenSSL's), so check one with `gori settings tls-fingerprint HOST --preset NAME` rather than assuming it.

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

Runs the interactive setup (global proxy bind default, then theme, then the Miss Ring mascot). Also runs automatically on first launch. The bind step writes the shared `settings.json` defaults and warns when something already listens on the chosen port (press `Enter` again to keep it anyway). Projects can still pin their own address in the Project tab; `--listen` / `--port` override for one run only. `Esc` twice skips the wizard; the rows are also clickable.

## gori tutorial

```bash
gori tutorial
```

Interactive tour of the TUI on a mock UI: tab/pane navigation, the command palette (`Ctrl-P`), the space menu (`Space`), and READ/INS edit mode. Each lesson demos the move and prompts you to try the key; practice has six optional checks across those four moves. The last card guides you from the screen you return to: picker, a `--db` project (with picker fallback), shell, or current session. Offered at the end of `gori wizard`, and available inside a session as the palette command **Guided tour** (`Ctrl-P`); safe to re-run anytime without a live proxy session. See the [Quick Start](/getting-started/quick-start/).

## gori update

```bash
gori update
gori update --exec   # Homebrew/Snap: run the package-manager command
```

Detects how this `gori` binary was installed and updates accordingly:

| Install channel | Behavior |
| ----------------- | ---------- |
| Standalone binary (curl install, manual download, workspace build, or a manual copy into `/usr/bin` that no package manager owns) | Downloads the latest GitHub release asset for this OS/arch and replaces the binary (macOS also refreshes sibling `lib/` in a dedicated dir) |
| Homebrew | Prints `brew upgrade gori` (use `--exec` to run it; never overwrites the brew-managed path) |
| Snap | Prints `snap refresh gori` (use `--exec` to run it) |
| pacman / AUR | Prints `yay` / `paru` / `pacman` guidance |
| deb (dpkg) | Prints `apt` upgrade guidance |
| rpm | Prints `dnf` / `yum` / `zypper` guidance |
| Nix (a store path) | Prints `nix profile upgrade` / flake-update guidance; the store is read-only, so nothing is downloaded |

A store path is `/nix/store/…`, and also a relocated store: a rootless install keeps one under `~/.local/share/nix/root`, and `NIX_STORE_DIR` moves it anywhere. Off the default prefix it is the store-hash shape that identifies one, so a directory you happen to have called `nix/store` is still an ordinary binary install.

Paths under `/usr/bin` or `/bin` are classified by package ownership (`pacman -Qo`, `dpkg-query -S`, `rpm -qf`). If a manager owns the file, gori never overwrites it. If probes find no owner, the binary channel self-updates. When no package tools are available, `/etc/os-release` (`ID` / `ID_LIKE`) picks Arch-like / Debian-like / RHEL-like guidance as a fallback.

Release asset names match the [installation guide](/getting-started/installation/) (`gori-v*-linux-*` plain binaries, `gori-v*-osx-*.tar.gz` archives). macOS archive updates require a dedicated layout (e.g. `PREFIX/opt/gori` from the curl installer) so bundled `lib/` is never written under shared roots like `/usr/local/lib`. If no release assets exist yet, the command exits with a clear error pointing at the releases page. It does not silently no-op.
