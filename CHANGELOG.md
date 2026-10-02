# Changelog

## Unreleased

- Editors: READ mode can now delete and paste. Select a line with `x`, then `d` deletes it and `y` copies it, and `p` pastes after the caret (the vim keyset uses `dd`, `yy` and `p`); `p` pastes gori's last copy or delete, and stays Pretty bodies in read-only panes (#1461)
- Settings: gori no longer writes over a `settings.json` it could not read (it warns instead), the first save after starting with no settings file keeps the sections another gori wrote meanwhile, and a Hotkeys save keeps bindings the editor does not show, including one whose key name this build does not recognise (#1458)
- Settings profiles: `gori settings export` leaves OAST provider tokens out unless `--sections oast_providers` names them, an import no longer changes the token prefix or the redaction salt, imported rewriter and colormarker rules and saved views get fresh ids so a project's old override cannot switch one on, and a profile with a malformed upstream rule is refused instead of losing it (#1458)
- Project: saving the network pane keeps a pin set by `gori run project network set` (an empty upstream means direct) and refuses a malformed bind address, and stored out-of-range ports and timeouts are read within the editors' limits (#1458)
- Listeners: a reverse listener on a wildcard address can forward to a remote origin on the same port instead of being refused as a loop (#1458)
- TUI: a new editor keyset applies without a restart, saving a settings section no longer resets the session's pretty-print toggle, ^R on the Tabs, Theme or Hotkeys row keeps unsaved edits in other sections, saving the tab layout from a project without snapshots keeps your Evidence tab, and the OAST tab says when a provider change could not be saved (#1458)
- CLI: `compare`, `diff`, `repeater send --diff`, `repeater list`/`delete`, the WebSocket transcript, `cache-deception`, `session --show-values`, `retest`, `colormarker` and `sitemap tag --list` show control bytes from captured or remote text as visible markers instead of handing them to the terminal, and `cache-deception --format json` stays valid JSON for a non-UTF-8 URL (#1459)
- CLI: `repeater send -H 'Content-Length: N'` sends the length you gave, `fuzz --record-history` rows carry the `flow_id` they were recorded as (text rows also say `matched`), `show --format json` adds `head_lossy`/`head_base64` for a non-UTF-8 head as MCP `get_flow` does, `oast listen --json` opens with a JSON payload record, and a `--config` after `--` reaches the `shell` child instead of being read by gori (#1459)
- CLI: `jwt --format json` exits `1` for a non-JWT, `grpc reflect`/`forget` exit `1` when the cache write did not commit, `sequence` exits `1` when no response carried a token and ignores a byte-order mark in `--tokens`, and `cache-deception` stops on Ctrl-C with what it already checked (#1459)
- Authorize: `--identities` and MCP `identities` refuse a `set`, `remove`, `rules` or `baseline` of the wrong type, which used to be dropped so the identity went out with the captured credentials and read as a bypass (#1459)
- CLI: `evidence delete` needs `--yes`, `links rm` and MCP `remove_link` remove a link whose flow retention pruned, and flags that were silently ignored are refused by name: `jwt --alg` off `--encode` or a key on a decode, `oast listen --project` without `--save`, `repeater move --up --down`, `diff --unchanged --verdict`, `rewriter add --from-flow --match literal`, a second `--wordlist` on `mine`/`discover`, `sitemap js --max-flows` without `--scan`, `intercept edit --raw` with `--raw-file`, a blank `issues update --title`, `sitemap tag` host or path, or `capture --listen` (#1459)
- CLI: `capture --project` takes a project's short id as the read commands do, `session add` keeps the row it prints in step with what it saved, `-d @FILE` on `send` says it is sent as text and names `--body-file`, `wordlist rename` can change only a list's case on macOS, and `session refresh` and `grpc reflect` name `--allow-unscoped` when scope refuses them (#1459)
- MCP: values `get_flow` withholds are withheld by its siblings too — a JWT decoded from an `Authorization`/`Cookie` header, a `list_history` column naming a credential header or a cookie (new `include_sensitive`), a sensitive chunked trailer in `get_response_body_chunk`'s raw pages, and bodies under the project's redaction profile in `compare_flows` and `get_evidence`; `compare_flows` decides `identical` on the captured values, so two requests sent as different users no longer compare as identical (#1460)
- MCP: write tools keep what you did not ask to change — `update_session_slot` reads a `null` list as absent instead of clearing it, `update_rule` refuses a bad `enabled` before saving the edit and lets a file or directory stub switch to another op, blank `add_scope_rule` kinds take the default, and `create_repeater` refuses an `issue_id` whose flow differs from the `flow_id` passed; errors name the extract-rule `selector` and an OAST provider's stored kind (#1460)
- MCP: `send_request{repeater_id}` writes the response back to the session as the TUI and `gori run repeater send` do, honours the session's HTTP-only WebSocket setting, and `verbatim` leaves a structured send's headers and body unexpanded; `send_websocket` reports a refused handshake as delivered (#1460)
- MCP: a `max_requests` of 0 or less no longer lifts the ceiling on `mine_start` and `discover_start`, `fuzz_start`/`mine_start` check scope against the template's path, `run_retest{allow_unscoped}` and `gori run retest --allow-unscoped` still honour exclude rules, `discover_start{max_depth:0}` crawls only the seed, `discover_results` findings carry their `flow_id`, `authorize_results` lists every bypass past the 500th request, and `list_retest_runs` says `has_more` (#1460)
- MCP: `switch_project` to the project already bound keeps unread operator messages and `ask_operator` answers, a bare `operator_messages` reads past pages of already-carried rows and reports `has_more`, a confirmed `delete_project` is on the activity feed, an unopenable project is `INVALID_ARGUMENT` rather than `INTERNAL`, and id lists accept `3.0` like single ids do (#1460)
- History: a forward-proxy request held at Intercept and forwarded unedited or dropped, rewritten by a body rule, or refused or failed after a Match&Replace rule fired keeps the client's own request line (`GET http://host/p`) instead of the origin-form line gori sends upstream (#1424)
- Rewriter: the rule form scrolls on a short terminal, so its Save row is drawn at 80×24, and a click on the form's preview line or border no longer saves the rule (#1420)
- Repeater: on a terminal too short for the REQUEST and RESPONSE panes, focus moves to TARGET and keys no longer edit a request that is off screen, and the space under TARGET says the panes need a taller window (#1421)
- Authorize: each row keeps its verdict on the card in a narrow terminal, and a wide one shows the whole Δ vs baseline (#1433)
- TUI: the Fuzzer's response detail has one blank line between head and body, a shrunk Repeater no longer leaves its caret on the borders, and the Env empty state names the palette for Change prefix (#1433)
- Intercept: a held response names the method of the request as you edited it, turning catch on no longer warns about an HTTPS→HTTP/1.1 downgrade gori stopped doing, and `gori run intercept direction` and MCP `intercept_set_direction` accept the `requestonly`/`responseonly` that `intercept list` reports (#1433)
- Decoder: a saved chain that calls itself names only its own cycle in the error, not whichever chain reached it first (#1433)
- TUI: key chips and empty-state hints follow rebound keys, the Repeater keeps ↑ in INS at the first line and `^Home`/`^End`/`^PgUp`/`^PgDn` in its response pane move the caret, not just the view (⇧ extends the selection), Global shortcuts work from sub-tab strips without typing through, and capture-off is marked in yellow (#1374, #1375, #1425)
- QL: `id:N`, `flow:N` and `flow_id:N` are refused with a hint to use the surface's id selector instead of matching zero rows, and queries with uncompilable terms report which term failed and why. `path:` reads the path of a plaintext proxy flow too, so `path~^/admin` finds it and `path:http` no longer matches every such flow (#1369, #1410, Refs #1379)
- Store: issue notes and retest assertions read byte-for-byte, including embedded NULs, and issue JSON escapes those bytes instead of truncating them (#1412)
- Notes: a TUI save writes only the notes you changed, so another session's edit or delete of a different note is no longer reverted, whether you were typing in Notes or adding a note from another tab (#1415)
- Project: the Scope and Host overrides lists stay on the row you selected when another session deletes a row above it, and a confirmed delete removes the row the prompt named, or says it is already gone (#1431)
- CLI: `notes` shows each note's stable id beside its list position, and `links` adds `--note-position` while retaining `--note` as an id for existing scripts (#1412)

- Sequencer: an all-digit token set is classified as 'digits' rather than 'lower-hex', and the live collection cursor follows samples all the way to the end instead of stopping short (#1390, #1429)
- TUI: `Home`/`End`/`PgUp`/`PgDn` jump and page the Sequencer's SAMPLES, the Fuzzer's RESULTS and the Miner's FINDINGS lists, where they did nothing (#1419, #1443)

- CLI: `gori run send` takes curl's `-d` as the body (a `POST` with a form `Content-Type` unless `-X` or `-H` say otherwise) and `-b` as a cookie — `-b` used to be the body, so a `-b` value with no `=` is now refused and pointed at `-d`. `repeater <flow-id>` gains `-X`, `-d`, `-b`, `--verbatim` and `--record-history`, both one-shot send forms can save a Repeater session with `--save-as-repeater`, `repeater send` takes per-send `-H`/`-b`, all three take `--apply-rules`, and their `--format json` adds MCP's `error_kind`, `error_code`, `retryable`, `delivered` and the parsed response `headers` (#1383, #1384)
- CLI: `--format json` is one JSON document on every command (`history` and `capture` printed JSON Lines for it — use `--format jsonl` for that), `fuzz`'s array is in index order, `--json` works wherever `--format json` does, and `gori run import` reads `-` (stdin) for every source (#1386)
- CLI: `discover` exits `1` when no request got an answer, as `fuzz`, `mine` and `sequence` do, and `mine` counts the failed sends of an unreachable baseline instead of reporting `0 errors` (#1385)
- CLI: pin the project a `--project`-less command reads with `GORI_PROJECT=NAME` or `gori run project switch NAME`, instead of the most recently active project, which one write elsewhere moved; a pin naming no project is refused (#1387)
- CLI: `capture --ca-dir`, `notes update` / `append`, `history delete` of several ids at once, `probe --fail-on=LEVEL` (exit `3`) as a CI gate, the active-send gate state in `project scope`, and the Authorize "no identities" message naming `gori run session add` (#1388)
- CLI: an unknown subcommand or option prints one line with the nearest real name and a `--help` pointer instead of the whole usage, the request-line rewrite note waits until the request is sent, and curl and code exports drop the proxy's `Proxy-Connection` header; `authorize --unsafe`, `rewriter --side`, `sequence --token-header`/`--token-cookie` and `links --issue`/`--note` join the flags whose meaning differed across commands (#1389)
- Sitemap: one root per origin (`http://127.0.0.1:19021`, `https://127.0.0.1:8443`) instead of one per host, and what you do from a row stays on that origin, so Discover from a host row no longer crawls `https://<host>`. `gori run sitemap` paths and JSON, parameter inventories and History's HOST column now show the scheme and port, and `--origin` (MCP `origin`) narrows `sitemap params` and `sitemap export` to one (#1371, #1372)
- Sitemap: `gori run sitemap -q` and MCP `list_sitemap` accept the tree's `tag:` path-memo filter (`tag:auth`, `-tag:done`) and keep the same endpoints the TUI Sitemap does, instead of refusing it as an unknown query field (#1411)
- Repeater: sending several marked sub-tabs at once ends each result with its sub-tab's number and name unless it is the one on screen, so another tab's `500` no longer reads as the focused request's answer (#1410)
- Repeater: a send that errors after receiving a response head shows the received head alongside the error, and its hex view displays the raw bytes instead of claiming the request was not sent (#1428)
- Repeater: the hex view of a typed or pasted request shows and sends the CRLF line endings a text-mode send uses, so opening it just to look no longer puts a bare-LF head on the wire (#1427)
- History: a request line with a stray space (`POST /a b HTTP/1.1`) sent from the Repeater, `gori run send`, the Fuzzer or MCP `send_request` is recorded the way the proxy records it, with the whole line as the path and no HTTP version (over HTTP/2, the `/a b` path it was sent with), instead of as `/a` with version `b`; frozen Repeater evidence does the same (#1423)
- TUI: in the Discover, Mine, Sequencer and active-scan popups `Enter` starts from any row and `Space` toggles the focused one, as their hints say (`Enter` used to flip the row under the cursor), and Discover's `start at:` row shows the chosen path instead of a `{path, url}` pair (#1373)
- Probe: `probe_scan{persist: true}` and `gori run probe --persist` write the scan's findings into the triage list, so `probe_issues`, promote and dismiss work on a project no TUI ever scanned; MCP `--tools=@recon` now serves `probe_scan`, passive only (#1392)
- Intercept: a request you edit before forwarding reads `EDIT` in History's SRC column and keeps the client's original request in a new ORIGINAL detail pane (`intercept_edited` in `gori run history --format json` and MCP), a dropped message says it was dropped at Intercept instead of `upstream error`, and the receipt for an edit forwarded by `gori run intercept edit` or MCP `intercept_forward_edit` names the request that was sent instead of the one held (#1378, #1430); with an agent attached, time on the Intercept tab now counts as watching a hold, so stepping away briefly no longer auto-forwards it (#1418)
- Intercept: editing a held message in the TUI expands only the `$ENV`/`$GEN` tokens you type; tokens and `$$` escapes the client sent go out as they arrived, so a one-byte header edit can no longer put a project secret in the body (#1416)
- TUI: with Content-Length sync on, `Ctrl-Z` takes back a body edit and the length synced for it in one step; in Intercept it did nothing, and in the Repeater every other press showed a length the send would not use. Leaving the Repeater's hex editor after an edit that changes the body length now shows, and says, the length the send will use (#1417, #1426)
- Capture: an interim `1xx` the origin sends before its response (a `103 Early Hints`, a `100 Continue`) is recorded with the flow over HTTP/1.1 and HTTP/2, printed ahead of the final response by `gori run show --format raw`, listed as `interim` by `--format json` and MCP `get_flow`, and shown in a new INTERIM detail pane (#1413)
- Probe: promoting a finding to an issue fills the issue's notes with the finding's CWE, detail, remediation (or custom rule description) and affected URLs, and links each affected URL's captured flow as evidence, so the issue is report-ready (#1377)
- MCP: an object's id is accepted under the name the neighbouring tools use — `flow_id` on `get_flow`/`delete_flow`, `repeater_id` on the repeater tools, `enabled` on `intercept_toggle` — and `get_repeater_context` rows carry `id` beside `db_id` (#1393)
- MCP: smaller answers by default — `get_flow` and a recorded `send_request` inline 8 KB of a body with a pointer to the rest, `list_sitemap` and `list_params` page 50 rows, every `limit` states its default and maximum in the schema, `export_openapi{output_path}` writes the document to a file instead of the reply, and the `fuzz_start`, `send_request` and `mine_start` schemas are about a fifth shorter (#1394)
- MCP: clearer errors and results — a job id of the wrong kind names the tool that reads it, stopping a finished job answers `already_finished`, `create_repeater {}` names every seed source, agent-action events link the flow a send recorded, denied permission attempts appear in Activity once per tool/group and project binding, `jwt_attacks` and three list tools answer `{items}`, and `preview_rule` and `fuzz_results` say when a default hid something (#1395, #1409)
- QL: a term a query cannot use (`status:abc`) is named in `ignored_terms` by `list_history`, `list_sitemap`, `diff_projects` and the other MCP query tools instead of silently widening the result, and Authorize and an active Probe scan (all surfaces) refuse such a query rather than send requests for more flows than asked (#1410)
- MCP: cancelling a slow `send_request` or `send_websocket` closes its active socket, so a silent target releases the serial worker and the next call runs without waiting for its timeout (#1391)
- Import: `import_flows` takes any format as `text`, not only curl, and every surface notes when a file of the same name was imported into the project before, since imports are not deduplicated (#1395)
- Cookie: a real Django `signed_cookies` session cookie verifies, cracks and forges under the session salt; gori derived that salt's key with a prefix Django applies only to `set_signed_cookie`, so the right secret read as a bad key (#1410)
- Import: a URL-list or HAR entry with a port outside 1–65535 or a scheme missing a slash (`http:/host/x`) is skipped as malformed, instead of imported with that port or against a host named `http` (#1410)
- Projects: creating a project whose name differs from an existing one only in letter case reopens it without renaming it, and a very long name gets a shortened directory slug instead of failing with "File name too long" (#1410)
- CLI: `gori run show --format json` gives a body cut by the capture cap its whole size as `source_size`, as MCP `get_flow` does, and `--format raw`'s truncation note points there instead of at `size`, which is only the stored prefix (#1410)
- Export: an httpie command whose body it cannot carry (a NUL, or bytes that are not UTF-8) says to run it with the body on stdin (`< FILE`), instead of an `--raw < FILE` httpie refuses (#1410)
- JWT: every failed verify now gives a reason, and `--format json` and MCP `jwt_verify` add a `code` such as `signature_mismatch` or `unsigned`. `gori run jwt --verify` exits 1 unless the token verifies, and both surfaces refuse a check that names no key (#1370)
- Fuzzer/Miner: a **request-time macro** replays saved Repeater sessions before a candidate, so a per-request CSRF token or nonce is fresh when it resolves its `$BIND.NAME` (`--macro`, MCP `macro_steps`, the Fuzzer's ADVANCED rows and the mine popup); `--macro-every` sets how often, and a per-request macro runs the sweep one candidate at a time. A macro that fails never sends the candidate, ends the run after three failures in a row (the first with `--macro-on-failure stop`), and each step is recorded in History as `src:macro` (#1350)
- Fuzzer/Miner: **payload sources from captured project data** — `--payload-from '<QL> <projection>'` (MCP `payload_from`, and a Project type in the Fuzzer's payload editor) builds a set from the project's own parameter names or values, path segments, JavaScript endpoints or extract-rule values, and Miner names read this way are tested before the built-in list. Sources are strict, bounded and reproducible, read the project and send nothing, keep credential material out unless you opt in, and report what each read but never a value (#1352)
- Wordlists: a list saved once under `GORI_HOME/wordlists` is picked by name (`-w common.txt`, `--wordlist common.txt`, MCP `wordlist`) by the Fuzzer, Miner and Discover, and by Cookie cracking on the CLI and MCP, from any directory (the current directory first; a path is read as given). Manage lists with `gori run wordlist`, the MCP `list_wordlists` … `delete_wordlist` tools, or `Ctrl-S` in the Fuzzer's List editor; values are never printed unless asked, saves are atomic and owner-only (the Params `w` export included, which now takes the next free name instead of replacing), and nothing is overwritten unless you say so (#1353)
- Fuzzer: results group by response shape, one representative row per distinct answer with payload echoes, ids, numbers and volatile headers ignored, rare shapes first (TUI **Display… → Group by shape**, `gori run fuzz show --clusters`, MCP `fuzz_results` / `get_fuzz_run` with `clusters: true`) (#1351, #1422)
- Import: hostile HAR, Burp, OpenAPI YAML and Postman/Insomnia files can no longer crash gori or lock a project — an out-of-range or impossible timestamp gets the import time (a project already holding one opens again), and a non-string YAML key, a `!!binary` value or a self-multiplying `{{variable}}` is refused with a message
- JSON 100–512 levels deep in a captured body, JWT, cookie, GraphQL request or imported example (or a protobuf message ~33 levels deep) no longer fails with "Nesting of 100 is too deep" in the JWT and cookie tools, redaction, `jsonpath:` columns, retests, extract rules, `get_flow`, `gori run show --format json` or the OpenAPI export
- TUI: an error while opening a project — reading a tab's stored data or drawing the first frame — is reported in the status line and `gori.log` like any later one, instead of ending gori before its first frame
- CLI: a `--ca-dir` or `GORI_HOME` gori cannot create, and `gori settings user-agents --set` naming a directory, print one line saying so instead of a backtrace
- Update: `gori update` saves a release file byte for byte when the server marks it gzip-encoded, instead of unpacking it and skipping the completeness check, refuses a redirect from https to plain http, prints one line instead of a backtrace when the reply is not HTTP, and says why it skipped the GitHub API; a clock that ran ahead no longer silences the startup update notice (#1457)
- Proxy: a response head that ends its lines with a bare LF (embedded devices, legacy CGI) reaches the client and History byte-exact with its status and headers, instead of arriving empty or after a 30 s stall, and the Repeater and active tools read it too. Its connection is not reused, response Match&Replace rules leave it byte-exact, and the new passive Probe rule `bare_lf_response` flags it (#1414)
- Network: an absolute-form `https://` request sent to the plain proxy listener reaches its origin over TLS instead of in cleartext while History recorded https, a forwarded absolute-form target is rewritten without touching the rest of the request line (`GET http://h/p?a b HTTP/1.1` lost its version), and a request head over 256 KiB is answered `431` and recorded instead of resetting with nothing captured (#1410)
- TLS: certificates gori mints are valid from a day earlier, so a client whose clock runs a little behind no longer rejects them; the CA download page and `gori ca --pem` give out the root this gori signs with even after `gori ca regenerate` in another shell; two gori processes starting at once no longer leave a mismatched CA pair; and the TUI's CA import reads `~/` paths (#1456)
- Network: an HTTP/2 or WebSocket frame that declares a large length and then stalls holds only the bytes that actually arrived, instead of the declared 16 MB per connection, so a client or origin can no longer run gori out of memory with a few bytes per connection
- Fuzzer: a cluster bomb over tens of thousands of positions — `auto_mark` on a large captured form body reaches that — runs instead of overflowing the stack and ending gori
- Fuzzer: RESULTS under `o:index` while a run streams, and MCP `fuzz_results`, list rows in index order like a reopened saved run instead of completion order, and the selection stays on its row as earlier results land (#1432)
- OAST: malformed provider URLs now report a clean configuration error instead of crashing before the HTTP transport (#1359)
- Repeater: **GraphQL: insert introspection query** (and its legacy variant for older servers) in the `Ctrl-P` palette rewrites the tab's request into a POST of the introspection query to the same endpoint, keeping its other headers and their captured line endings (#1355)
- Probe: passive scans recover dropped or failed flows, active work is coalesced and retried instead of disappearing on queue bursts, differential probes reject timed-out evidence, and large JSON API specs get a bounded late-body check.
- MCP: `minimize_repeater` reports a refusal by a configured scope as `scope_decision: out_of_scope`, as `send_request` does, instead of calling every scope refusal `unscoped` (#1349)
- TUI: the Preferences group strip (General, Appearance, …) draws its unselected groups on the card's own background instead of a black band hugging each label (#1346)
- History: flow and HTTP/2 connection ids are never reused, so after a clear or deleting the newest flows a mark, link, evidence source or MCP cursor can no longer name a different flow, and an MCP `list_history` cursor keeps tailing instead of being sent back to the start. The first open after upgrading switches over in milliseconds, or rebuilds the History table once (about 5–7 s per GB) on a SQLite that refuses the in-place change (#1343, #1345)
- Repeater and Sequencer tabs, issues, Probe findings, custom Probe rules, project Rewriter rules, scope rules, host overrides and saved fuzz runs never reuse an id, so after deleting the newest or wiping, an id an agent, a script or another gori still holds is refused as gone instead of acting on the new row, and a recreated custom Probe rule no longer inherits the deleted one's suppressions and dismissals. Closing a Repeater tab also clears it from the Probe findings it raised, so promoting one no longer links another tab (#1344, #1354)
- Saved views: deleting one from the TUI, `gori run views rm` or MCP `delete_view` resets the project's active view whenever it names that view, even if another gori made it active, and deletes nothing when that reset is refused; removing a link in the TUI Links overlay removes that link rather than whatever a peer's edits left under its row (#1344, #1347)
- TUI: a paste while the space menu, Copy as… or Send selection to… is open is ignored instead of running as keys, where a pasted `zc` could close the menu and stop capture (#1342)
- History: after a clear, a new HTTP/2 connection's raw frame log no longer mixes in the frames of a connection the browser kept open (#1342)
- Import: OpenAPI operations honor their path item's or their own `servers`, with server `{variables}` filled from their defaults, so a multi-host document from gori's OpenAPI export re-imports against the right hosts, and percent-encoded `$ref` pointers such as `#/paths/~1users~1%7Bid%7D` resolve (#1342, #1410)
- Redaction: a profile pattern whose capture group sits in a lookahead no longer writes the secret back out after its placeholder (#1342)
- Network: HTTPS interception mints a new host's certificate context in ~0.1 ms instead of ~3.7 ms and ~1 MB less memory (it no longer loads the system CA bundle into each), caches up to 1024 of them, and upstream DNS answers are reused for 10 seconds, so an `/etc/hosts` edit or a rebinding record can take that long to be seen (#1340)
- Performance: capture stalls less on SQLite checkpoints, an idle gori hands its freed memory back to the OS, and idle keep-alive connections and large captured bodies hold far less memory (#1340)
- History/MCP: filters that match few rows (`host:`, `path:`, `src:`, `status:2xx`, size ranges) and Sitemap listings answer from covering indexes on large projects, e.g. `src:repeater` 1 s → 7 ms and a `list_sitemap` page 1.2 s → 0.2 ms, and `body~` regex filters run about twice as fast; the first open after upgrading builds the indexes once, which takes a few seconds on a multi-GB project (#1340)
- TUI: `^F` over a large one-line body no longer rescans the whole line for every drawn row (60–150 ms a frame → under 1 ms), pastes into the Decoder, JWT and Cookie editors land in one step (160 KB: 15 s → 0.5 s) and a long paste no longer redraws per key, and the Repeater diff and Comparer word diff of large bodies stay responsive (#1340)
- Performance: capture spends less time on the fiber the proxy shares — Content-Type and header scans, HPACK decoding, chunk-size lines and WebSocket messages no longer re-parse or copy per flow — and passive Probe scans run 2–3× faster on HTML and JavaScript bodies (#1337)
- TUI: the Probe tab no longer re-reads and parses every finding on each tick while traffic flows, which cut proxy throughput up to 4× with the tab open, and large Notes stop copying their whole text every frame (#1337)
- History: deleting many flows holds the capture writer for milliseconds instead of seconds, deleting an HTTP/2 flow no longer fails, and opening or closing a large project no longer scans every stored body (#1337)
- Import: Burp exports import in linear time (an 11 MB export in 0.1 s instead of 12–46 s), and messages whose base64 is wrapped in CDATA are imported instead of skipped (#1337)
- Discover: `--http2` reuses one connection per worker instead of dialling per request and no longer sends a `connection: close` header that makes an h2 request malformed; a large wordlist no longer materializes every probe up front, and Fuzzer redirect hops reuse the keep-alive connection (#1337)
- CLI/MCP: redacting a large non-ASCII body takes milliseconds instead of seconds, `get_response_body_chunk` stops re-decoding a compressed body for every page, and headless Authorize runs keep response heads but not bodies of finished targets (#1337)
- Docs: the landing walks from capture to issue beside its captures as you scroll, the Guide and Reference indexes become tiles with a TUI capture per tool, pages gain gold accents on section rules and a gliding table-of-contents marker in light and dark, and search metadata now uses descriptive titles, multilingual alternates, and noindex 404 handling.
- Docs: both Brand Kit wallpapers (with and without the mark) now come at the 1920 × 1080 desktop size, the landing hero is painted from the plain one, and both are regraded to the palette: indigo clouds, and the marked cut's logo in the brand gold (#d9c28b).
- Guided tour: `gori tutorial` teaches the space menu before the palette, with its second cards (`>` **Send flow to…**, `esc` back a level) and the palette search that lists a tab's own actions with the key or menu path that reaches each, and gains lessons on the proxy address and CA trust, capture, intercept, and Help and quitting; every key it names is read from your keymap, and the docs gain a **Space Menu & Palette** guide with a five-minute exercise (#1333, #1382). It no longer teaches `↵` as leaving INS or `i` as INS outside an editor, a lesson's ✓ waits for the whole move, and at 80×24 Miss Ring stands aside instead of narrowing the card (#1380, #1381)
- Probe: a headless active scan (`gori run probe --active`, MCP `probe_scan`) probes each request surface once however many times it was captured, instead of re-probing every repeat and spending its active budget on it (#1332)
- Probe: the live active scanner reuses one keep-alive connection across a flow's rules rather than opening a fresh one per rule (#1332)
- Probe: passive scanning no longer scrubs and pattern-scans a binary response body (images, fonts, audio/video, wasm) — a mislabelled text body is still read — so a captured image costs ~3µs instead of ~600µs on the fiber capture shares (#1332)
- Network: on macOS 27 a refused connection is no longer taken for an open one, so a host whose first address refuses (`localhost` resolving `::1` first) falls through to its next address instead of failing (#1329)
- Miss Ring keeps an agent's reply up until your next key or click, and later notices no longer push it out (Settings → Companion → Agent replies). MCP `reply_to_operator` now tells the agent whether a gori window was open to show it, and replies sent while none was are summed up in one note when the next one opens (#1328, #1322)
- CLI: `gori run notify` puts a line from a script in the gori TUI's notification ring and Miss Ring, and says whether a window was open to show it (#1323)
- MCP: `ask_operator` puts a question with two to four choices in front of the operator; they answer from the ring, the `ask:` chip or Answer the agent…, and the answer, a dismissal or an expiry comes back to the agent as an operator message (#1324)
- MCP: Preferences → AI → MCP permissions switches off what an attached agent may do, one group at a time (send traffic, intercept control, project edits, scope and sandbox changes, project management); every group stays on by default and reading the capture is always allowed (#1327, #1348)
- TUI: new `solarized_dark` (dark) and `everforest_light` (light) themes, and the theme picker lists `dancheong` and `hanji` right after `goridark` and `goriday` (#1325)
- CLI: `gori run oast resume` waits for a busy project as long as `oast listen --save` does, instead of giving up after one second while it saves callbacks (#1321)
- Network: environment proxy selection applies its loopback and NO_PROXY CIDR exceptions to resolver-recognized numeric IPv4 aliases (#1318)
- Repeater: differential **timing analysis** of two request variants — send the A/B pair many times (synchronized single-packet/last-byte race, or interleaved) and get a verdict (which is consistently slower) from the response order and per-variant quartiles, never a single number. `Space` → `B` over two marked sub-tabs, `gori run repeater timing <idA> <idB>`, and MCP `timing_requests` (#1246)
- TUI: `>`, `?`, `{` and `}` work in terminals that report Shift along with a shifted punctuation key, where they did nothing before (#1295)
- TUI: no space-menu row is `c` or `i` on a tab that leaves that letter to the global keys, so a press that loses its `Space` no longer stops capture or holds all traffic. Set status, Duplicate rule, Clear markers and JWT's Copy attack token move to `C`, and Diff's Add issue to `F` (#1295)
- TUI: on the nine tabs with a sub-tab strip, the strip's actions are one `T` **Sub-tabs…** row in a pane's space menu (Mark all sub-tabs is now `T T` from a pane), and stay drawn in full with the strip focused; the menu gains **Mark sub-tab** on `t`, the Repeater's Tag moves to `g`, Paste cURL keeps its own `U` row, and the strip renames on `e`, the menu's Rename letter, instead of `r`, which now does nothing there (#1274, #1295)
- History: the flow detail stays on screen behind the command palette (`Ctrl-P`) and the cards opened over it (delete, link, add issue, mock this response, active scan), and cancelling one of those cards goes back to the flow instead of the list (#1341)
- TUI: typing in the command palette (`Ctrl-P`) also finds the focused tab's actions, listed first under `THIS TAB` with their key and the marks count in the title, and the space menu drops 37 rarely used rows that the palette now finds: ones that repeat a direct key (Mark word `Ctrl-K`, rule reorder `⇧K`/`⇧J`) or configure once a session (Minimize request, Use as refresh for slot…). Their keys are unchanged, and Help shows `^P → <name>` for the ones with none (#1282)
- TUI: no space-menu row is lettered `h`, `j`, `k` or `l` any more, so inside the menu those keys always move the selection. Link… and Manage links are `L` on every tab, Add host to scope is `H`, Activity's Filter by level is `v`, the workbench clears are `K`, load decoded is `L`, OAST listen and resume are `r`/`R`, and Probe's bulk dismissals are `G`/`H` (#1274)
- TUI: the JWT, Cookie and Decoder clears ask before wiping a session, and destructive rows always sit last in the space-menu card (#1274)
- TUI: the view toggles (hex, pretty, diff, folds, static assets, follow, columns, Probe's show closed, the Params tab's all headers…) and the Repeater/Fuzzer transport toggles (HTTP/2, SNI, auto Content-Length, gRPC, TLS fingerprint…) move into two sticky space-menu cards, `Z` **Display…** and `P` **Protocol…**, that show each toggle's state and open with a bare `⇧Z` or `⇧P` too; hex is `Z x` on every pane, and `Ctrl-X` in either Repeater pane, whose rows both show it. The detail's Copy flow row folds into Copy as… → Raw request, and direct keys are unchanged (#1274, #1295)
- TUI: the space menu gets a second level. Sending the selected flow to another tool is one `>` **Send flow to…** row whose card gives each tool one letter on every tab (Repeater `r`, Fuzzer `f`, Comparer `c`, Miner `m` (the Params tab's Mine parameters too), Sequencer `s`, Authorize `a`, Discover `D`, browser `b`), and `esc` goes back a level; a bare `>` opens the card without the `Space`. Send to Repeater keeps its own letter too, History and detail Delete move to `d`, and direct keys like `Ctrl-R` and `⇧I` are unchanged (#1274, #1295)
- Project picker: the space menu uses the app's letters and letter case (rename `e`, export `⇧E`, clear marks `⇧N`), keeps one row order when projects are marked, and closes on a key it does not bind, like the in-app menu (#1274)
- TUI: a bare key that belongs to one pane acts only there. The Repeater's `p` (pretty bodies) and `⇧D` (diff) work in the response pane, and the Fuzzer's `m` (matched only) and `v` (distribution sidebar) in RESULTS, so they no longer fire in the request or template pane (#1274, #1295)
- TUI: Help, hint strips, toasts and the Repeater's border chips (`␣Pr:FRAME`, `␣Pw:KEY`, `␣Pt`) take space-menu letters and keys from the menu itself, fixing the rows that named the wrong key (Repeater Tag sub-tab, gRPC reframe, OAST add issue, Sitemap `tag:` help, the Rewriter's enable/disable, the Fuzzer's sort, and the Issue detail's Retest `⇧R` and links `L`) (#1274, #1295)
- TUI: an action that recurs across tabs has one space-menu letter everywhere: list filters are `/` (the Miner's findings filter keeps `F`), export `E`, insert marker `I` and the Sequencer's File as issue `a`, and the Fuzzer's Save results moves from `⇧S` to `⇧E`, the Export key elsewhere. `X` only ever wipes, so Rewriter/Colormarker **Enable/disable everywhere** is `T` (#1274, #1295)
- Sitemap: scan captured JavaScript for the endpoints it references and draw the ones nobody requested as dimmed `js` rows, resolved against the page (via `Referer`) and sending nothing. `Space` → `J` in the Sitemap, `gori run sitemap js --scan`, `gori run sitemap --js-refs`, and MCP `scan_js_endpoints` / `list_js_endpoints` / `list_sitemap include_unrequested` (#1243)
- Session slots: a slot can log itself back in by replaying Repeater sessions you choose, on demand or just before a send when its token is about to expire, and never by retrying after a 401 (#1233)
- Sitemap: export the captured API as an OpenAPI 3.0.3 document with templated paths, parameters, inferred request and response schemas, servers and security schemes, leaving out gori's own requests, never with credential values, and with redacted examples only on request. Use `gori run sitemap export`, MCP `export_openapi` or `⇧E` on the Sitemap (#1241)
- TUI/CLI: control and invisible Unicode characters display with names, and JSON pretty-print preserves escapes until `u` reveals them (#1248)
- Repeater: race several DISTINCT requests together to hit a multi-endpoint TOCTOU window — N requests on the wire in one narrow release (HTTP/1.1 last-byte sync over N connections, HTTP/2 single-packet attack over one). Mark two or more sub-tabs and run **Race marked sub-tabs** in the TUI, `gori run repeater race <id…>`, or MCP `race_requests`; every member shares one origin and connection shape, and the result shows each response with its release-relative timing. An oversized but otherwise valid HTTP/2 response only fails its own stream when HPACK stays synchronized (#1236)
- History: the first row of the `v` picker hides static assets (images, fonts, audio/video) from History and the Sitemap; SVG, CSS, JS, errors and redirects stay. It is backed by a new `static:` QL field and by `--hide-static` on `gori run history`/`sitemap`/`sitemap params` and `hide_static` on MCP `list_history`/`list_sitemap`/`list_params`. Opening an existing project classifies its flows once (#1239)
- Fuzzer: a run can stop itself early — after the matchers hit N times, or when a separate condition holds (a body regex present or absent, a status, a header, a time) — landing its own `condition_met` status with the result that tripped it recorded, while `keep: interesting` archives only the matched rows plus the ones carrying a fault (error, re-send, truncation, the stop row). `gori run fuzz --stop-after-matches/--stop-on/--keep`, MCP `fuzz_start{stop_on, keep}` and `get_fuzz_run.stop_index`, and the Fuzzer Advanced overlay (#1240, #1270)
- Decoder: add NFC/NFD/NFKC/NFKD, RFC 2047 encoded-word Q/Base64, codepoint-overflow bytes, and Windows Best-Fit previews by code page (#1245)
- Cache: web cache testing helpers. A `cache:` QL field (`hit`/`miss`/`dynamic`/`none`) reads response cache headers and shows CACHE in History for explicit `cache:` queries; `cache_deception_check` (MCP) and `gori run cache-deception` compare authenticated and anonymous responses with a cache-busted control, returning `review` if the control is itself a cache hit; and the `cache-delimiters` Fuzzer payload set sweeps paths with cache-key delimiters (#1247, #1256, #1268)
- Import: paste a curl command to get a request. Repeater's Paste cURL opens it as a sub-tab and Import: cURL adds it to History, as do `gori run import --curl`, `gori run repeater create --curl` and MCP `import_flows{kind: "curl"}` / `create_repeater{curl}`; the importer follows curl for URL credentials, auth option order, Transfer-Encoding framing and quoted multipart parameters, refuses local form-header files and HEAD bodies, and names ignored transport flags (#1244, #1251)
- Copy as cURL: a path with `..` segments now carries `--path-as-is`, and a body captured without a Content-Type carries `-H 'Content-Type:'`, so the command sends what was captured instead of curl's rewrite (#1244)
- Shell: `gori run shell` and the palette's **Open shell** start a terminal whose curl, git, Python, Go and Node traffic goes through a live gori and trusts its CA without touching OS settings, using a bundle that keeps the terminal's existing roots; `--print` emits the `export` lines for another pane (#1238)
- Sitemap: a parameter inventory lists every captured input name per endpoint with its location, counts, sample values and whether a value is reflected, in the new Target → Params sub-tab, `gori run sitemap params` and MCP `list_params`. It exports Miner wordlists, and a mine started from Params or History tests the names seen on the host's other endpoints first (`gori run mine --name`, `mine_start names` on the other surfaces) (#1231)
- Rewriter: unknown rule labels and extra keys stay visible and inert, survive settings saves, refuse reordering, and treat unknown operations as executable on settings import (#1242)
- Rewriter: a short-circuit rule can serve files from a local directory, answer with a captured response (History `Space` `M`, `gori run rewriter add --from-flow`, MCP `from_flow_id`), or inject a close, reset or hang fault, each with an optional delay; the flow names the rule that answered. Switching the env token syntax no longer rewrites `$NAME` text inside a stub (#1237)
- Projects: export and import compact, WAL-safe `.gori` snapshots from the CLI, the picker and MCP `export_project` / `import_project`, with a sensitive-data inventory. Archives stay unredacted; imports disable executable/file-backed rules, reset project routing, Probe mode and slot auto-refresh, and reject archives over 2 GiB or with an exhausted id counter, and an MCP import only previews until `confirm:true` (#1230, #1250, #1253, #1271, #1347)
- TUI: `Ctrl-F` in the project picker searches every project's captured flows by host, path or body text, and `Enter` on a hit opens that project on the flow's detail; the search reads each database without migrating or writing to it (#1229)
- gRPC reflection: a fetch stays live in this process when a busy project cannot save it, a cut-short reply names the requests it left unanswered, and an out-of-range `error_code` no longer aborts the fetch (#1234)
- Protobuf: a varint overflowing 64 bits reads as malformed, and enum values read as int32, so a negative packed enum lists as -1 instead of 18446744073709551615 (#1234)
- Repeater: an unedited grpc-web-text body, and a gRPC field applied unchanged in the FIELDS form, are sent exactly as captured (#1234)
- gRPC: grpc-web messages and status are read through an HTTP `Content-Encoding` on every surface, and neither a 0x80 frame in a native gRPC body nor a malformed `grpc-status` such as `+0` is reported as the call status (#1234)
- Fuzzer: a gRPC field whose `¦chain` runs an `exec:` hook no longer runs that hook once per payload while the run is planned (#1234)
- MCP: a running server picks up another gori process's changes to session slots, global env vars, the User-Agent list and the global view, rule and colour libraries on its next call, so a rotated or deleted credential stops going out without a restart; a running TUI now follows global env vars and User-Agents too (#1215, #1216, #1217, #1218)
- Proxy: HTTP/2 response rules now use each stream's `:authority` on coalesced connections, so host-scoped rewrites apply to the matching response (#1222)
- CLI: `gori run capture --max` counts WebSocket and other upgraded flows after their tunnel closes, once their captured transcript is complete (#1221)
- Proxy: `text/event-streaming` and other media types that only share the SSE prefix are treated as ordinary bodies, so response rules still apply (#1220)
- Proxy: host-scoped body rules no longer buffer unrelated request and response bodies before streaming them (#1219)
- MCP: `list_history` flags stale `since` cursors even when History is empty, so clients can reset after a clear (#1199)
- TUI: History refreshes path and colour data after a peer clears or deletes flows, including when returning to the tab, and no longer carries a mark or the preview over to a new flow that reuses a cleared flow's id, where a batch Delete would have destroyed it (#1202, #1342)
- History: deleted flows detach retest and frozen-evidence links, and MCP fuzz results omit stale flow IDs before reuse (#1208, #1212)
- Proxy: malformed response status lines use explicit body framing and retire the origin connection (#1207)
- HTTP/2: refuse duplicate pseudo-headers and conflicting `:authority`/`host` fields under the sandbox, and check a stream that names another port than its tunnel's against the tunnel's own port too, so a port-scoped exclude cannot be walked around (#1210, #1342)
- Proxy: reject incomplete upstream CONNECT replies and keep the failure reason on the CONNECT flow (#1211)
- Proxy: reject nonnumeric CONNECT ports with a recorded 400 instead of defaulting to 443 (#1213)
- Proxy: frame lowercase extension methods by their response headers instead of treating them as HEAD or CONNECT (#1214)
- Issues: the SARIF export keeps each `Set-Cookie` field separate instead of comma-joining cookies into one fabricated value, joins repeated `Cookie` fields with `; `, and writes credential header values as `[REDACTED]` unless `gori run issues --include-sensitive` asks for them (#1190, #1191)
- Import: generated Insomnia, Postman, and OpenAPI query parameters now stay before URL fragments (#1184)
- CLI: piped decoder and minimized request output stay byte-exact, while forged cookies and encoded JWTs retain a trailing newline for text pipelines (#1185)
- Decoder: Base32 rejects impossible tail lengths and malformed padding while Base32 and Base64 accept decodable tails with non-zero unused bits (#1186)
- Postman: URL variables replace path placeholders only, leaving query and fragment values intact (#1187)
- CLI: a `--db` file that is not a gori project (another tool's SQLite database, or an empty file on a read command) is refused before anything touches it, instead of having gori's schema migrated into it (#1171)
- Projects: a name that points at two projects (one's slug and another's display name, or a display name two projects share) is refused on every `--project`, MCP `switch_project`, `delete_project` and `diff_projects` with each one's slug and short id, instead of silently picking one, and create or rename refuses a name that is already another project's slug or short id (#1163)
- Retest: deleting a Repeater session marks the issue retest steps that used it as deleted, so they keep refusing to run instead of silently re-binding to the next session that reuses its id (#1160); `json:` and `json-absent:` read the same JSON paths as `--jsonpath` and bindings (`$.data.items[0]`, `items.0`), and a path none of them can read (`..`, `*`, a filter, an unclosed bracket) is refused instead of passing `json-absent:` (#1201)
- Sitemap: CLI and MCP tags on paths with a trailing slash now match and display on the captured endpoint (#1165)
- CLI: invalid UTF-8 arguments now receive command errors instead of PCRE2 backtraces (#1170)
- Env: `project env set` and both TUI editors preserve assignment values, including empty and surrounding whitespace (#1172)
- HAR: imports preserve duplicate and malformed Content-Length probes; exports and re-imports preserve colonless request and response headers, and an export no longer fails on a cookie whose `Expires` is an impossible date (#1161, #1164, #1312)
- Import: OpenAPI 3.x and Swagger 2.0 resolve local refs and seed request bodies from the media type's `example` or the schema — JSON objects with their properties, and form and multipart bodies in both versions; remote refs are reported and never fetched (#1166, #1410)
- Proxy, Repeater and Fuzzer keep bytes from incomplete or oversized response heads and do not automatically replay those requests (#1167)
- Env: `$GEN.USER_AGENT` fills in a real desktop browser User-Agent that follows the request's TLS preset, `$GEN.USER_AGENT_CHROME`/`_FIREFOX`/`_SAFARI` pick one browser, and Settings → User-Agents or `gori settings user-agents` replaces the built-in list. `$U` + ↹ now completes to it rather than `$GEN.UUID` (#1112, #1152, #1153, #1154)
- Probe: SQL injection detection reaches the blind cases — a new boolean-based rule confirms a true/false differential (SimHash-guarded so a dynamic page is not mistaken for an oracle), and a new time-based rule (off by default, since it deliberately waits) confirms an injected `SLEEP`/`pg_sleep`/`WAITFOR` delay that scales across a baseline and two increasing delays (#1110)
- Probe: the active scanner can confirm remote file inclusion out of band by planting a language-marked OAST resource in include-shaped file, page, template and locale parameters (#1111)
- MCP: a malformed JSON-RPC envelope is refused instead of answered — `"jsonrpc"` must be the string `2.0`, and a request id must be a string, a number or null (#1138)
- MCP: every tool schema now advertises the contract the server enforces (`additionalProperties: false`), so a validating client rejects a typo before the call leaves it (#1140)
- MCP: `--tools` adds required workflow companions but refuses conflicting exclusions, while `--read-only` hides operator replies and OAST session tools that cannot work in that mode (#1139, #1141)
- MCP: an unbound server tells a typo from a tool `--tools` hid (both stay JSON-RPC `-32602`, not `NO_PROJECT`), and every "pick a project" hint — errors, instructions, `project_info`, the startup log — names only the tools that server actually serves, or says plainly that a restart is the only way out (#1136, #1142)
- MCP: `gori mcp --tools=@recon` or `--tools=@minimal` serves a small named catalogue instead of the whole workbench, and every start logs how large the served `tools/list` is (#1137)
- CLI: OAST subcommands no longer mistake option values for verbs, and missing `--project`/`--db` values are rejected (#1144)
- TUI: `esc` leaves every tab body and the footer names where it lands — it did nothing at all on the Diff sub-tab (where `↑` was dead too) or on an empty Fuzzer, several tabs never advertised it, the Repeater, Fuzzer, Miner and Colormarker lines named the wrong destination, and the Fuzzer's results footer printed a raw `{fuzz.sort}` for a key that was never bound (#1147)
- Notes: a Markdown heading marker no longer rides into the note's title — the sub-tab chip, `gori run notes`, the MCP listing and the exported filename all drop the leading `#` (#1147)
- CLI: `gori run project network` lists, reads, pins and unsets a project's own network settings (`net.*`: upstream proxy and credentials, destination host, timeouts, capture cap, bind), so a per-project proxy no longer means editing the database by hand (#1115)
- CLI: `gori run send` sends one request from a URL (curl-shaped) or a raw request without creating a Repeater session, and `--path` sends a session or a captured flow to another path for one send (#1116)
- CLI: `--headers-only` and `--max-body=BYTES` keep a large response out of the terminal on `repeater send`, `repeater <flow-id>`, `repeater h2`, `send` and `show`, with a marker naming the full size (#1119)
- CLI: every create and add subcommand (`repeater create`, `issues create`, `notes create`, `views add`, `colormarker add`, `rewriter add`, `rewriter extract add`, `probe rules add`, `oast providers add`, `links add`, `project scope add`, `project host-override add`) takes `--format json` and prints the new row as its listing does, id included; `scope add` names the id in text too, and `links add` no longer calls a link a busy project did not save "already linked" (#1117)
- Comparer: two same-size binary bodies no longer compare as "no differences" (the placeholder carries a digest), and a diff cut at the line cap or by the capture cap no longer calls the pair identical, in the Comparer and Repeater diff tabs, `gori run compare` (whose JSON gains `identical` and `source_truncated`, as MCP has) and `repeater send --diff` (#1162)
- JWT: a claim number past 64 bits (`18446744073709551615`, `1.5e400`) no longer blanks the payload — decode keeps its digits, and re-signing or `--set` keeps every other claim, refusing a payload it cannot read instead of rebuilding it from `{}`; the passive JWT checks no longer go blind on such a token (#1169)
- TLS: the `chrome` preset sends Chrome's `sec-ch-ua`, `sec-ch-ua-mobile` and `sec-ch-ua-platform` hints on `https` requests gori sends, computed from that request's own User-Agent, and adds none when you typed any of them (#1174)
- TLS: gori's root CA and the certificates it mints carry key identifiers and key usage, so Python 3.13+ and other strict clients accept them — a root minted by an older gori still needs `gori ca regenerate`, which `gori ca` now points out (#1168)
- Discover: a `<meta http-equiv="refresh">` is followed whatever its attribute order and when its URL is quoted and relative (`content="0; url='next'"`) (#1182)
- Miner: JSON probes add their candidate keys to the captured body instead of re-serializing it, so duplicate members, number spellings and escapes reach the target as captured; the active scanner's JSON injection does the same, and a number past 64 bits no longer hides a body's JSON parameters (#1183)
- Miner: a run whose every named location does not apply to the request (`json` on a GET) is refused before any request is sent, and a partly inapplicable one drops those locations from its name count, reported as `not-applicable` in MCP's `skipped` (#1203)
- OAST: resuming a saved session polls with the provider it was started with, even when two saved providers share an endpoint with different tokens (#1192)
- Cookies: session bindings, the Sequencer `--cookie`, display columns and `session from-flow` read the cookie a client would hold — the last `Set-Cookie` for a name, and none once a later field expires it — instead of the first, so a `sid=deleted` before a fresh `sid` no longer binds the tombstone (#1206)
- JSON: a number past 64 bits (`18446744073709551615`) no longer makes a captured body "not JSON" to Retest, `--jsonpath`, bindings and columns, the Minimizer, GraphQL and MIME probes, the pretty view, or Flask/Django cookies, and each keeps its digits (#1200)
- Sequencer: random UUIDv4 tokens rate Secure instead of Weak or Critical, since a column confined to a few values (the variant nibble) is now treated as structure and credited its own entropy (#1198)
- Fuzzer: auto-mark wraps a whole JSON number, exponent included, so `1e5` no longer sends every payload with a trailing `e5` (#1205)
- Fuzzer: `--max-requests` / `max_requests` now bounds a race too, refusing a larger group (warm-ups included) before any dial instead of sending it whole, and the huge-run gate counts the requests a capped run can send rather than its candidates (#1204, #1209)
- TUI: at 80–110 columns the History detail header stays inside its border, History drops TIME's date before it narrows PATH, a tab bar with tabs hidden past its right end shows `›`, and a value the companion covers ends in `…` instead of reading as a shorter number (#1376)
- TUI: filter bars take `Ctrl-A`/`Ctrl-E`/`Ctrl-U`/`Ctrl-W`, a Miner run that finds nothing says "done — nothing found", the Repeater send toast shows the same `519µs` as its pane, the setup wizard names the address a `-l`/`-p` flag binds this run to, and the Sitemap keeps a query-folded path in order among its siblings (#1379)

## v0.7.1

- Network: outbound requests honor `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` and `NO_PROXY` (CIDR included) when no gori upstream is set, loopback stays direct, an empty proxy host fails closed, and the banner, `settings:network` and the statusline name the variable that is routing (#1114)
- CLI: a write that did not land is reported, not assumed — `repeater send --format json` carries `response_saved`/`history_saved` with the reason, a refused `discover` batch exits 1, MCP reports it as `unsaved_flows`, and a short-lived write keeps its bounded SQLite wait and names the gori holding the project (#1118)
- TUI: a double-width glyph (`✅ ⭐ ⚡` and the rest of `EastAsianWidth=W`) no longer shifts every row below it out of place for the rest of the session (#1125)
- TUI: a click places the caret without entering INSERT, a double-click takes the word in READ, and a paste aimed at a READ pane inserts instead of being refused (#1124)
- TUI: a READ selection no longer outlives its document — a sub-tab switch, a peer's rewrite, `^E` or a project switch drops the band (#1123)
- Issues: an open writeup keeps its scroll position and caret, and saving no longer reports a peer conflict against your own write (#1122, #1123)
- CLI: `gori run notes delete <n>` and `gori run issues delete <id>` require `--yes`, and the note refusal quotes the note's first line (#1120, #1317)
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
