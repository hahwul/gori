# Changelog

## Unreleased

- Env: `$GEN.USER_AGENT` fills in a real desktop browser User-Agent, drawn at random per send from a list built into gori; `$U` + ↹ now completes to it rather than `$GEN.UUID` (#1112)
- Probe: SQL injection detection reaches the blind cases — a new boolean-based rule confirms a true/false differential (SimHash-guarded so a dynamic page is not mistaken for an oracle), and a new time-based rule (off by default, since it deliberately waits) confirms an injected `SLEEP`/`pg_sleep`/`WAITFOR` delay that scales across a baseline and two increasing delays (#1110)
- Probe: the active scanner can confirm remote file inclusion out of band by planting a language-marked OAST resource in include-shaped file, page, template and locale parameters (#1111)
- MCP: a malformed JSON-RPC envelope is refused instead of answered — `"jsonrpc"` must be the string `2.0`, and a request id must be a string, a number or null (#1138)
- MCP: every tool schema now advertises the contract the server enforces (`additionalProperties: false`), so a validating client rejects a typo before the call leaves it (#1140)
- MCP: `--tools` keeps required workflow companions together, and `--read-only` hides operator replies and OAST session tools that cannot work in that mode (#1139, #1141)
- MCP: an unbound server tells a typo from a tool `--tools` hid (both stay JSON-RPC `-32602`, not `NO_PROJECT`), and every "pick a project" hint — errors, instructions, `project_info`, the startup log — names only the tools that server actually serves, or says plainly that a restart is the only way out (#1136, #1142)
- MCP: `gori mcp --tools=@recon` or `--tools=@minimal` serves a small named catalogue instead of the whole workbench, and every start logs how large the served `tools/list` is (#1137)
- CLI: OAST subcommands no longer mistake option values for verbs, and missing `--project`/`--db` values are rejected (#1144)
- TUI: `esc` leaves every tab body and the footer names where it lands — it did nothing at all on the Diff sub-tab (where `↑` was dead too) or on an empty Fuzzer, several tabs never advertised it, the Repeater, Fuzzer, Miner and Colormarker lines named the wrong destination, and the Fuzzer's results footer printed a raw `{fuzz.sort}` for a key that was never bound (#1147)
- Notes: a Markdown heading marker no longer rides into the note's title — the sub-tab chip, `gori run notes`, the MCP listing and the exported filename all drop the leading `#` (#1147)

## v0.7.1

- Network: outbound requests honor `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` and `NO_PROXY` (CIDR included) when no gori upstream is set, loopback stays direct, an empty proxy host fails closed, and the banner, `settings:network` and the statusline name the variable that is routing (#1114)
- CLI: a write that did not land is reported, not assumed — `repeater send --format json` carries `response_saved`/`history_saved` with the reason, a refused `discover` batch exits 1, MCP reports it as `unsaved_flows`, and a short-lived write keeps its bounded SQLite wait and names the gori holding the project (#1118)
- TUI: a double-width glyph (`✅ ⭐ ⚡` and the rest of `EastAsianWidth=W`) no longer shifts every row below it out of place for the rest of the session (#1125)
- TUI: a click places the caret without entering INSERT, a double-click takes the word in READ, and a paste aimed at a READ pane inserts instead of being refused (#1124)
- TUI: a READ selection no longer outlives its document — a sub-tab switch, a peer's rewrite, `^E` or a project switch drops the band (#1123)
- Issues: an open writeup keeps its scroll position and caret, and saving no longer reports a peer conflict against your own write (#1122, #1123)
- CLI: `gori run notes delete <n>` requires `--yes`, and the refusal quotes the note's first line (#1120)
- Docs: an Apple `container` section in the install guide (macOS 26+), mirroring the docker recipes (#1121)

## v0.7.0

### New features

- MCP: **Messages to the agent** — send a one-line message with any marked flows into an attached agent's own session (the Claude Code inbox socket, a live Codex thread, the `claude/channel` preview, or the next tool result), answered with `reply_to_operator` (#1090)
- MCP: `get_current_context` reports what the operator marked in the TUI — the rows, the sub-tab chips and the filter they were marked under — and `list_history{ids}` fetches the whole set in one call (#1091)
- MCP: the stateless **`2026-07-28`** revision — `server/discover`, per-request version negotiation, `resultType`, `tools/list` cache hints, `subscriptions/listen`, and `annotations.readOnlyHint` on every tool (#1100, #1101, #1105)
- MCP: cancelling a request stops the work — `probe_scan`, `minimize_repeater` and `run_retest` stop sending at the next flow, candidate or step (#1103)
- Session: `gori run session from-request` and `create_session_slot{from_request_flow_id}` build a slot from selected captured headers, redacted, and a value copied off the wire stays byte-literal at send time (#1086)
- Probe: new passive rules — exposed API documentation and schemas, a session identifier in the URL, a permissive Flash/Silverlight policy — and new active rules: 429 and HTTP-method access-control bypass, TRACE/XST, and CRLF injection through form and JSON bodies (#1109)
- Probe: a WebSocket carried by an HTTP/2 extended CONNECT (RFC 8441) is scanned like any other socket (#1083)
- CLI/MCP: `project list --query` and `list_projects{query, limit, offset}` narrow over display name, directory slug, short id and bound workspace path (#1085)
- TUI: Miss Ring ships on by default, and turning her off is written to `settings.json` (#1096)

### Changes

- TUI: a misspelled filter field is named ("unknown field `hostt:` — did you mean `host:`?") instead of reading as an empty list, and a pasted URL is no longer painted as a typo (#1106)
- Project: the picker finds a project by slug, short id or workspace path, tells two same-named projects apart, and says why a create or rename was refused; `description` is readable from JSON output and `project_info` (#1108)
- Project: the ACTIVITY feed reaches every row it holds, its retention cap runs on event inserts too, and a write that changed nothing is no longer recorded as a change (#1084)
- Probe: four rules stop guessing — PHP `Warning`/`Notice` output, CORS reflection on any `Vary: Origin` endpoint, a two-segment NGINX alias, and DOM clobbering on the `window.X = window.X || {}` preamble (#1098)
- WebSocket: a stored or replayed h1 handshake reads the exact `websocket` member across repeated `Upgrade` fields, and `gori run capture` prints an RFC 8441 socket once instead of counting every frame toward `--max` (#1113)
- MCP: `--read-only --tools=SPEC` starts, three argument refusals name what the caller sent, and every start reports the tool count it will advertise instead of promising tools it does not have (#1102, #1105)
- CLI: `grpc reflect --timeout` and the Fuzzer/Discover/Miner/Sequencer `--rate` reject non-finite values as usage errors, named by the command that took them (#1104)
- TUI: the setup wizard explains local and device access, the guided tour ends with a first-session checklist, and an Issues RELATED reload keeps the same row selected (#1038, #1081)
- Discover: a `-H` header name that is not an RFC 7230 token is refused instead of written onto the wire (#1086)

## v0.6.1

- Repeater: a `$BIND.`/`$GEN.` token typed into a tab opened from History resolves at send time again — only the names the capture itself arrived with stay literal, instead of the whole tab being switched off (#1080)
- Repeater: a stored request whose head never terminates (`\r\n\r`, what shell `$(…)` leaves behind) is now said — `head_unterminated` on `repeater create`/`send`/`list`, the TUI send toast and four MCP tools. The bytes still go out verbatim; h2 and WS are exempt (#1075)
- Robustness: seven ways ordinary data ended the process — a non-UTF-8 HAR byte, a bad port or self-referential anchor in an OpenAPI spec, a drifted `match_rules` enum, a huge `"time"`, a far-future timestamp under a non-UTC `TZ` — now report what they met instead of raising (#1079)
- MCP: `create_issue` takes `notes`, so a finding is filed with its body in one call (#1076)

## v0.6.0

### New features

- Evidence: freeze an exchange as an immutable copy, so what proved a finding survives the next send and History's retention sweep — an **Evidence** tab with compare, redacted copy and export, `Space` → **Link…** freezing as it links, plus `gori run evidence` and six MCP tools (#1038, #1039)
- Retest: an Issue carries the ordered Repeater sends that reproduce it — a role per step (`setup`/`baseline`/`variant`/`control`/`cleanup`) and one assertion (`status:`, `json:`, `body:same`) — runnable from the card, from `gori run retest run` (exit 0 only on `pass`) and from ten MCP tools (#1036)
- Redaction: `--redact` replaces the values a *redaction profile* names with a keyed `[REDACTED:…]` placeholder — profiles per project and global, every `--format` covered, the stored bytes untouched — with the TUI copy menu and MCP `get_flow` following (#1035)
- Env: tokens gain namespaces — `$ENV.KEY`, `$BIND.NAME`, and `$GEN.NAME` for a fresh send-time UUID, random value or timestamp — so a GraphQL `$id` in a body needs no escape; existing projects are re-spelled on first open, with a backup beside the database (#1069)
- TUI: the tab bar is nine numbered slots — `1`-`9` jump from anywhere, `0` opens a type-to-filter **Go to tab…**, `⇧1`-`⇧9` are the same two gestures on the sub-tab strip, and `settings:tabs` is one ordered list where the position carries the visibility
- TUI: an **Editor keyset** (`helix-ish`/`vim-ish`) respells every text pane's READ grammar at once, on top of an editor scope that makes every pane key an ordinary rebindable verb
- JWT: RS/PS/ES 256-512 and EdDSA signing and verification with a PEM key you supply, `--verify` answering under the alg the token declares, the algorithm-confusion attack family, and a JWE shown by its header (#1010, #1015)
- Decoder: Java serialization, ASP.NET ViewState, PHP `serialize()` and Python pickle read as labelled JSON trees, in the tab and the detail pane; a pickle is disassembled, never executed (#1011)
- WebSocket: Socket.IO/Engine.IO, SignalR, STOMP, SockJS and Action Cable get a detail pane named after the framing and a `ws_proto` key in `show --format json` and `get_flow`, with raw frames still the truth (#1009)
- Discover: a brute-force hit's body is read for endpoints, header-declared links are followed (`Link`, `Content-Location`, `Refresh`, `Set-Cookie Path=`), the API-description documents join the well-known set, a `405` is proof a path exists, and linked assets are no longer downloaded (`--assets` restores)
- OAST: `oast listen --save` and `oast_start{persist:true}` keep a headless registration as a project session, so the blind SSRF/XXE/command-injection rules have something to plant against; plus `oast presets --check` and registration failures named by stage (#1020)
- TUI: the statusline sees what gori is about to do — `scope`, `intercept`, `probe`, `issues` and `jobs` in the stdin context, each read from the source its chip renders from — and a timed-out command gets `SIGTERM` before `SIGKILL` (#1058)
- History: `gori run history --format json` redacts sensitive header values and marks the row; `--include-sensitive` returns the exact bytes (#1002)
- CLI: `colormarker update` edits a rule in place, `issues create -n/--notes-file/--notes-stdin` writes the body in one transaction, and `repeater create --request-stdin` takes a raw request off a pipe (#1001, #1018, #1019)
- MCP: `gori mcp --install-pi` configures Pi in `~/.pi/agent/mcp.json` (#992)
- Docs: Brand Kit and Miss Ring reference pages, and a statusline guide whose every command is printed above a shot of the row it produced

### Changes

- Keys: one letter, one meaning — `d` only destroys, `y` always copies, `o` is only `↵`'s alias, `t` toggles a rule, `s` goes to the source, `r` sends and `^R` runs; the sub-tab verbs are one bucket drawn on all nine strips, and a key the registry binds is the key that fires (#1053, #1055, #1056)
- Issues: one concept for what backs a finding — the primary flow is RELATED's first row on every surface, `↵` shows a row's exchange in place, `s` goes to its source, **Link…** keeps the bytes, and failed removals are reported honestly (#1038)
- Issues, Probe: RELATED and AFFECTED URLS become bordered panes with focus of their own, remediation text scrolls instead of truncating, and both `/` bars complete the way History's does
- TUI: a pane stops shouting the name the chip above it already carries, drill-ins step with one `⇧N`/`⇧P` pair, and a measured walk through the core loop fixed a dozen hint strips naming a key that was not there (#1040, #1061)
- Performance: literal History body/header search by byte scan (`body~` over 500k flows 4.1s → 0.25s), the proxy's head read and framing decision (~26µs → ~18µs a request), Sequencer analysis (153ms → 71ms), Miner's JSON spans (~117ms → ~1ms a probe), and the Discover, Fuzzer and Probe scan paths (#997, #999, #1064, #1065, #1067, #1070)
- Colormarker: a reused `flows.id` no longer paints a new row in a deleted flow's colour, the `matches N of M` line answers for the scope being edited, a duplicate keeps the original's enabled state, and the editor prints the caveats the other two surfaces already did (#1032)
- Sequencer: six numbers that looked right and answered something else — an empty `position` range, a hex counter at concurrency > 1, a manual paste reporting its own goal, reconfigure losing its settings, and MCP not saying why a run found no tokens (#1030)
- Decoder: a hostile back-reference no longer raises out of a reader, `decoder list` measures its columns, and MCP `decode` names the converters that undo what ran, in the order that undoes it (#1011, #1031)
- Cookie: `--verify`/`--crack` and the MCP tools read Django's HMAC algorithm off the signature length, as the TUI badge already did, instead of assuming `sha256` (#1027)
- CLI: a wordlist that names a terminal is refused instead of hanging, an unreadable stdin reads as a sentence, and a refusal the arguments alone settle comes before the pipe is drained (#1034)
- MCP: the handshake `instructions` stop calling the project a pin — they are sent once and cached, so after `switch_project` they went on naming the project the server started on (#1003)
- Docs: an accuracy pass over the English and Korean guides — keys, rule host scope, colour-rule conditions, per-field `Alt-Svc` stripping, undocumented `gori run` flags and MCP tool gating
- Fixes: the scope lens is named `s` on every surface (#959), CVSS v2 vectors in NVD's parenthesised form are accepted (#994), OAST dedup keys are content hashes on every provider, and `scripts/seed_demo.cr` is type-checked in CI

## v0.5.0

### New features

- Cookie: a TUI workbench for framework signed session cookies (Flask/itsdangerous, Rack, Django) — decode, verify, crack and forge, the JWT tab's sibling (#565)
- Retest: diff two projects at endpoint scale — a Diff sub-tab, `gori run diff`, MCP `diff_projects`, and `⇧F`/`n` to file a row as an Issue or Note (#824, #845)
- Issues: CVSS v3.1/v4.0 scoring with `cvss:>=7` filtering, CVSS-aware exports and SARIF `security-severity` (#575)
- gRPC: proto descriptor sets and server reflection as schema sources, schema-aware field fuzzing (`--field`), gRPC FIELDS editing, and grpc-web outcomes read from the body frame (#823, #841, #849, #984)
- Hooks: pipe bytes through your own command — a Rewriter `pipe` op, a Decoder `exec:` step, a Probe `exec` rule, and `mine --hook` (#838, #853)
- Proxy: outbound TLS fingerprints per destination and per send (`chrome`/`firefox`/`safari`/`curl`), plus `gori settings tls-fingerprint` (#822, #844)
- Proxy: SOCKS5H, project-scoped proxy auth and destination filtering, and an upstream CONNECT proxy over TLS (`http+tls://`) (#858)
- Rewriter: one-keystroke response-modification presets (unhide fields, drop CSP or security headers, disable SRI) installed as ordinary rules (#821)
- Project: an ACTIVITY pane over the event feed, with config changes recording who changed what (#864)
- Fuzzer: save a complete run — every request/wire/response byte — with run history, bounded restore, `gori run fuzz save/list/show/delete` and MCP `save_results` (#897)
- Repeater/Fuzzer: replay a WebSocket captured over HTTP/2 (RFC 8441 extended CONNECT)
- Probe: passive takeover, cleartext-credential, shared-cache and internal-host checks; blind OS command injection and XXE over OAST (#970, #974)
- MCP: `--tools=SPEC` picks which of the 160 tools the server advertises, so a client parks the catalogue it needs instead of ~43k tokens
- TUI: `/` filters on the Discover, Miner and Authorize lists plus Help and Hotkeys; sub-tab multi-select; `y` copy on nine more lists; double-click parity; opt-in tab numbers; a Mouse settings section (#683, #860)
- Nix: the flake gains an overlay, and `gori update` recognises a relocated Nix store (#893)
- Docs: a terminal-inspired reading layout with a book-style Playbooks space in English and Korean (#991)

### Changes

- Keys: `⇧X` clears any clearable tab, `t` marks, `[`/`]` cycle tabs, `d` no longer crawls from the Sitemap, and confirm cards answer `↵` with their own verb; every hint, chip and Help row names the effective keymap, and the Copy verbs are rebindable (#898, #899, #902)
- TUI: History search yields, `^F` highlighting is byte-linear, idle settings reloads leave the render fiber, Notes takes a paste as one edit, and modals stay answerable on a small terminal (#967, #975, #976, #977)
- Writes: a rule, tag, note or intercept edit the store refused is reported as refused instead of painted as saved, on every surface (#980, #990)
- QL: `NOT(…)`/`-(…)` negates the group, `status:5XX` folds, `method~`/`scheme~` take regexes, and a field the backend cannot answer is refused instead of searched as text
- MCP: paging truth for `list_history`/`list_sitemap`, both ends of the capture window in `project_info`, cut bodies flagged in `get_flow`/`compare_flows`/`get_response_body_chunk`, and OAST transport failures marked retryable (#906, #918, #981)
- CLI: `gori run` refuses a stray positional, says when `--limit` cut the listing, pads columns in terminal cells, and names an unbound `$NAME` in the mine/sequence/minimize summaries
- Protocol: an h2 trailer can no longer restate the status, a decoded h2 response survives a transport failure, `Connection` tokens are read across repeated lines, and a refused response head is kept on the flow
- Authorize: a run whose baseline was itself refused reads `review`, not BYPASS; leaving a project stops the engine; slot names collide case-insensitively
- Export/Import: the code a "Copy as" row hands over runs, and a HAR round-trip keeps the framing the source stated
- Repeater: `--verbatim` stops a session binding too, the Sandbox gate is taken on the bytes that go on the wire, and h2 header names go out byte-exact (#910)
- Docker: gori no longer runs as PID 1 (so `docker stop` exits 143), `tzdata` ships, and `WORKDIR` is `/data`
- Fixes: 27 Decoder defects, Sequencer sample top-up, Miner framing and stop-ends-retries, Discover character references in links, Probe truncated-body false positives, and the Export request-line framing guard (#985–#990)

## v0.4.0

### New features

- Authorize: replay a captured request under saved identities against a baseline, on all three surfaces — passive replay of what the browser touches, `gori run authorize`, and the MCP tools share one plan (#707, #710)
- History views: `v` picks a named filter that stays on — seven built-ins, project/global saved views, `gori run views` / `--view`, and MCP `*_view`. A project opens on `History + Repeater` (#776)
- History provenance: a SRC column and `src:` name who sent each flow; TUI Repeater sends record by default, and Authorize and Probe ignore gori-originated traffic on the unattended path (#770)
- Proxy: a `socks5` inbound listener, and `network.strip_alt_svc` so a browser cannot leave for HTTP/3 (#786)
- Fuzzer: WebSocket session sweep, last-byte-sync race over HTTP/1.1, and URL-encoding of query/form payloads by default (#705, #795)
- Import: WSDL 1.1 becomes one SOAP template per operation (#794)
- Decoder: brotli, zstd, MessagePack and CBOR; MessagePack/CBOR bodies render as JSON in the detail pane (#786)
- Session: build a slot from a captured login (`session from-flow` / `create_session_slot{flow_id}`) (#719)
- Sitemap: query-string variants fold into one path node (`⇧G` restores the literals) (#750)
- Probe: shared insertion points, plus COOP, CSP `base-uri`, JWT key-injection, broad-domain cookie, MIME-confusion and error-based SQLi (#788, #793)
- Export: HAR round-trips WebSocket messages; Issues export SARIF (#719, #792)
- JWT: `--payload`/`--set` on the CLI, MCP set parity, tab visible by default (#747)
- QL: `scope:` makes the in-scope lens a query term (#754)
- MCP: `--install-hermes` writes `~/.hermes/config.yaml` (#785)

### Changes

- TUI: empty-tab cards; a ⌕ sub-tab picker; Help as palette cards; clickable filter chips; `Space ⇧B` opens a decoded body in the desktop opener; `^G`/`^F` find in Decoder and Fuzzer; factory reset; `y` with no selection copies the pane (#691–#704, #759, #782, #796, #801)
- CLI: hide empty projects by default; `history show --format curl`; json/jsonl rows carry `url` and `headers`; `history delete -q`; leftover verbs after `--project` no longer silently list or scan (#722, #750)
- Store: a capturing TUI no longer shares SQLite's writer with a read-only peer; live Match&Replace, extract rules and probe mode pick up a peer's edit on the tick (#752)
- Miner: refuse a phantom baseline, skip names the request already carries, retry calibration
- MCP: an unreadable integer is refused by name before the work; `rate` is fractional (#724)
- Fixes: Comparer phantom diffs; Decoder OUTPUT folding newlines; JWT weak-secret re-signs under the token's HMAC alg; host overrides reach Authorize and Probe; OAST release/poll honesty; Colormarker refused writes; Match & Replace obs-fold; HTTP/2 intercept that cannot re-encode; 33 engine defects from a source audit; TLS / WS-over-h2 / compressed-rewrite protocol gaps (#729, #741, #751, #802–#807)

## v0.3.2

A hotfix release: the bug fixes written since v0.3.1, cherry-picked onto it. The features on the way to the next minor are not in it.

- Open browser: a browser that never starts is reported with its own error and how it died, instead of `opened` — the verdict comes from waiting on the child rather than a deadline. Brave is launched without `--test-type`, which 1.92+ aborts on; Chrome still gets it, to hide the SPKI-pin infobar (#700, #716, #721)
- Scope: a regex EXCLUDE rule no longer fails **open** on a target that is not valid UTF-8 — `rescue false` read as "does not match", which is scope evasion. The History/Sitemap SQL lens also now agrees with the live gate on bracketed IPv6 hosts, brace globs and non-ASCII case (#688, #699)
- Project settings: a host override reaches gori's own reserved name from either layer and folds case and a trailing root dot into one key, and the TUI refreshes the project env table before writing back over a peer's edit (#687, #689)
- TUI: the statusline gets its own timeout and reports why it is blank, instead of killing the script that was about to answer (#690)
- Stability: a crash audit across the CLI, TUI, store and MCP — a non-UTF-8 byte no longer aborts a command through PCRE2, a stale read cursor no longer takes the session down, a poisoned release tag no longer crashes every later launch from cache, and an MCP discover job no longer flushes its findings into the project you switched to mid-run (#699)
- MCP: `--install-claude` writes Claude Desktop's config where the running platform actually keeps it — `$XDG_CONFIG_HOME/Claude/` on Linux, not a macOS path built under a Linux `$HOME` (#718)

## v0.3.1

- Filters: one query grammar on every filter surface, content terms included; `header:`/`body:` take a side, and the filter bar teaches its own syntax (#668, #674)
- Decoder: recognize GraphQL/gRPC bodies by media-type essence, decode HTML entities, and cover WS subscriptions and both-side protobuf (#663)
- Probe: scan binary WebSocket frames for credential shapes, stop DOM-XSS pairing on shapes that carry no taint, and fix two rule gates that failed silently (#671, #672, #676)
- TUI: a copy key in INS mode (`y` there types a `y`), a wrap-lines toggle with horizontal scrolling back, sandbox togglable from the palette, and a deeper brand gold in the light theme (#652, #657, #670, #677, #680)
- Performance: chunked imports, a fast path for parked TLS sockets, cheaper discover fingerprinting, n-ary miner bisection, probe findings in one writer round-trip, and probe lists paged in SQL (#655, #665, #666, #667, #669, #673, #675)
- Stability: ~40 ways gori could crash, hang, overrun a stop or lose a run's results; an MCP server that survives the three things that killed it; project delete/`--db`/durable-write and intercept ack fixes (#651, #654, #658, #659, #678, #679)
- Docs: a Playbooks section that teaches gori's workflows by doing them, AUTOMATION split into Run and MCP with a new Scripting guide, and a refreshed landing hero (#650, #664, #682)

## v0.3.0

### New features

- Colormarker: a new tab for row-colour rules in History — global and project scope, custom colours defined, recoloured and renamed in place, reorder, painted consistently across TUI/CLI/MCP (#632, #640)
- Cookie workbench: parse, verify, brute-force, and forge Flask, Rack, and Django session cookies (#569)
- HTTP/2, first-class: hold, edit and drop individual streams at intercept, a complete HPACK encoder, Match&Replace on h2 heads, a per-stream sandbox, and a field-native send path for the shapes h1 head text cannot express (#510, #512, #513, #515, #649)
- WebSocket: Match & Replace over messages, and hold/edit/drop at intercept with `proto:ws` (#500, #533, #537)
- Session bindings: extract a value from proxy traffic once, resolve `$NAME` from it at send time (#501, #530, #535)
- Proxy: reverse-proxy listener mode, transparent listeners that read the kernel's original destination, and a short-circuit rule op that answers a request without dialing upstream (#509, #520, #528)
- Decoder: schema-less protobuf/gRPC wire decoder, new encodings (quoted-printable, punycode, base36/62, xml/shell/c escapes, homoglyph/typo), saved chains callable by name, and a named library with a picker (#505, #558, #567)
- Fuzzer: built-in payload preset sets (SQLi and more), selectable across TUI/CLI/MCP (#568)
- OAST: blind SSRF — plant a payload, promote the finding when the target calls home (#609)
- Export: HAR export, with the import-side fields to round-trip it (#506)
- Miss Ring: an opt-in companion in the body's corner, and on the project picker delivering the update notice; on `lively` she also plays one of four idle gestures about once a minute, in the status-bar chip as well as the body sprite (#474, #548, #550)

### Changes

- Discover: read the target's well-known documents (OIDC/OAuth discovery, `security.txt`, sitemaps, …) and extract endpoints from JS bundles, JSON, source maps and inline `<script>`; keep each finding's request/response and open them from the findings table; hold and re-measure a drifting soft-404 baseline; report a real page on a wildcard-200 origin; and bound per-response spend so a JS literal cannot buy a brute-force sweep (#605, #638)
- Comparer: per-row change highlighting with `n`/`⇧N` navigation and `f` fold, per-column `status·size·time` headers with the A→B delta, **Send to Comparer** from the Repeater, Sitemap and Fuzzer rows, and `--context=N` fold parity in CLI/MCP
- Rewriter: rules scoped global or project (replacing the s/o preset library), shown on the tab bar by default right of Comparer (#544, #611)
- Probe: passive-rule improvements, the OAST SSRF rule classed CWE-918, and a navigable AFFECTED URLS list in a finding
- Miner: latency-bound scheduling — one work queue for all locations, parallel calibration (~2.4x)
- JWT: the lens switch (`^T`) shows on the pane it acts on; new `dancheong` (dark) and `hanji` (light) themes
- Project picker: multi-select over the project list — `Tab`/`⇧Tab` mark and step, `⇧↑`/`⇧↓` extend a range, `ctrl-a` marks what the search shows, `esc` clears. **Delete** then acts on the marks, names what it is about to wipe, says how much of the set the search is hiding, and keeps a project another gori has open
- `gori ca`: reject a flag written before the verb, repair a CA directory missing one of the key/cert pair, and reject an Ed25519/Ed448 or mismatched-key root with a legible message instead of failing at the first CONNECT
- Fixes: bracketed-paste freeze and poison in the Repeater; the `--` separator dropping subcommand args across ~60 `gori run` sites; colormarker custom-colour persistence and reorder writes; clipboard OSC 52 over tty; project-settings and host-override reload/rollback audit; OAST partial-poll evidence loss; and many dogfood-surfaced bugs

## v0.2.0

- Proxy: upstream connection rules with per-host routing, SOCKS5 and proxy auth; a TLS pass-through list that is never MITM'd; per-destination outbound TLS (client certificates, protocol floor, ciphers); a setting to force HTTP/1.1; transparent listeners and additional listeners alongside the primary bind (#434–#438)
- Proxy: harden the HTTP/2 assembler against CONTINUATION spoofing and stream-slot exhaustion, re-sync framing after a head rewrite so Match&Replace cannot smuggle, and reject bare-CR header obfuscation and ambiguous response framing (#341, #403, #409, #412, #417)
- Proxy: serve the CA-download page at a reserved host, `gori.proxy` (#347)
- TUI: multi-select in History, the Intercept queue, the Sitemap tree and the Issues list, so the space menu acts on N items at once (#442, #459, #460, #461)
- TUI: the Project tab becomes sub-tabs instead of five tiled panes, Network settings gain upstream-rules and outbound-TLS tables, a Keys section picks the command modifier (⌥ reaches the shortcuts Ctrl cannot), plus `rosepine` and `tokyonight_day` themes (#440, #454, #458, #462, #463)
- TUI: export the current note to Markdown from the Notes space menu, and ask where to write the Issues report instead of always overwriting `<project dir>/issues.{md,json}`. Export is `⇧E` on both tabs, which frees the Issues list's old `x`, so `x` now means "Select line" everywhere (#432)
- Settings: `--config PATH` plus settings export/import profiles, per-project connect/idle timeouts and capture limit, and a unified retention policy (#439, #440, #441, #448, #450, #455)
- Import: read Postman collections, Insomnia exports, and Burp XML (#453)
- Probe: active-scan rules for open redirect, CRLF/response-header injection, host-header injection, access-control bypass, NGINX-style parameter traversal, GraphQL introspection, SSTI, and Next.js server-action missing authorization; passive rules for JWT weaknesses, source maps, SRI, and directory listing; a manual unsafe-method opt-in and AGGRESSIVE mode (#299, #342, #343, #346, #349, #350, #451)
- CLI/MCP: bring `gori run` and `gori mcp` to TUI parity, and create/delete projects from `gori run project` (#351, #352)
- Performance: move trigram FTS indexing off the capture commit path, and reuse one HTTP/1.1 connection across a fuzz sweep (up to 20x on HTTPS) (#428, #433)
- Security: close request-splicing and scope-gate holes across Discover, Fuzzer, Repeater and Scope — crawled-link splicing, unvalidated redirect `Location`, per-URL probe authorization, fail-open scope, irregular request-line whitespace, and `wss://` targets dialing cleartext (#390–#397, #404–#407, #418–#422)
- Security: keep gori's own files owner-only — the CA private key is 0600 from creation and re-asserted on every load, and a settings export carrying a secret is written 0600. `--config` and `--ca-dir` no longer re-mode a directory the operator merely named (#466, #467)
- Say what went wrong instead of swallowing it: a TUI session that cannot open (a bad `--db`, an unreadable store) says why on the project picker instead of "no projects yet"; an unparseable `settings.json` announces the fallback instead of silently resetting the bind, upstream rules and pass-through list; and `--ca-dir notes.txt` is named as a non-directory rather than surfacing as `BIO_new_file(...) failed`
- Refactor: a single outbound chokepoint for the active-traffic scope gate, one Plan builder per engine (fuzz, discover, miner, repeater, sequencer) shared by TUI/CLI/MCP, and all 28 TUI modals on one Overlay seam (#354, #355, #356, #361)
- Packaging and docs: a Nix flake with an update channel, `AGENTS.md`, `DESIGN.md` with the P0–P8 principles, and an install script that survives GitHub API rate limits (#338, #345, #353, #360, #429)

## v0.1.4

- Proxy: fix HTTPS blank pages / empty History — reflect origin ALPN so h1-only origins load, resolve the system CA trust store for upstream verification, and report TLS-verify failures separately from connect failures (#332, #333, #334, #336)
- Proxy: stop an upstream RST leaving a flow stuck Pending forever (#330)
- Scope-gate every outbound path so Sandbox mode holds: Repeater, Fuzzer, Miner, Sequencer (CLI and TUI), with `--allow-unscoped` opt-out (#322, #330, #339)
- Import: reject CR/LF/NUL smuggling in HAR/OpenAPI, and neutralize control bytes in decoder/JWT text output (#322, #324, #339)
- CLI/MCP parity: add Comparer (`gori run compare` / `compare_flows`), CLI Intercept, CLI WS repeater send, MCP scope/env/host-override mutation and `import_flows`, `gori run probe --active` (#321, #326)
- MCP: fix a credential leak in `get_repeater_context`, cap unbounded h1 capture reads, and surface `PROJECT_BUSY` on rolled-back writes (#335)
- TUI: Repeater `^N` mirrors the target host into the Host header, Fuzzer wordlist field suggests recent and favorited paths, tutorial navigation fixes (#314, #315, #335)
- OAST: support global-scope providers alongside project scope (#313)
- Fix dogfooding-surfaced bugs across QL (`url:`, size and `dur:` units, uppercase schemes), Discover, Sequencer, Repeater, browser CA trust warning, `settings.json` formatting, and multipart form data (#312, #316–#319, #325, #337)

## v0.1.3

- Fix 30 confirmed bugs found across three build-and-dogfood passes: TUI (`--db`, Repeater NUL-truncated bodies, Rewriter hot-reload, Sequencer/Miner/OAST, Scope reload, log redirection), CLI (`oast listen --help` crash, Issues/Sitemap export encoding), proxy (WS close-handshake race, h2 preface on intercept), MCP, Import (HAR/OpenAPI/URL-list CRLF injection), Fuzzer auto-calibration, and more (#301, #307, #310)
- CLI: accept `-V` as a version flag alias (#298)
- TUI: match banner and wordmark gold to the real logo (#308)
- Docs: dynamic landing page, nav/sidebar reorganization, logo download menu, homepage title (#300, #302–#306, #309)

## v0.1.2

- MCP: start **unbound** outside a Git workspace so `gori mcp --install-*` always connects; agents bind via `list_projects` / `create_project` / `switch_project`. Traffic tools return `NO_PROJECT` until bound, and `--no-project` forces unbound inside a workspace (#295)
- TUI: show a startup update-available notice on the project picker (#293)
- TUI: make the NOR/INS editor mode badge more discoverable with click-to-toggle (#294)
- TUI: fix clickable OAST callbacks, pane navigation, and Rewriter preview (#296)
- Tests: expand spec coverage across pure and harness-testable modules (#297)

## v0.1.1

- Fix wide-character/emoji rendering and caret placement in the TUI editors with a per-grapheme width model (#281, #285, #289, #291)
- Fix proxy self-loop guards under wildcard binds, serve the CA cert page to LAN clients, and show a dialable bind address (#279, #284, #287)
- Stop background reconcile from resetting the caret in Repeater and Notes (#277, #286)
- Add Snap packaging and publish workflow (#276)
- Docs: install command picker, sidebar regrouping, AI setup guide, landing refresh (#275, #282, #283, #288, #290)

## v0.1.0

First Release
