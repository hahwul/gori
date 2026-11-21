# Changelog

## Unreleased

- Probe: the request-smuggling rule adds the 0.CL-by-`Expect: 100-continue` desync (plain and obfuscated) as a High timing lead, sent as a complete POST so a conformant server answers fast and only a front-end/back-end split hangs; still off by default and behind unsafe (#1945).

- Import GraphQL introspection JSON (`data.__schema` or top-level `__schema`) into unsent POST templates, one per query or mutation, with typed variables and bounded selections from the TUI, CLI and MCP; subscriptions are omitted with a count (#1948).

- CBOR shows the correct UTC second for fractional timestamps before 1970 and in the last second of year 9999 (#1954)

- MCP: `list_issues` exports Markdown and SARIF reports, and `get_flow` exports curl, Python, fetch, Go, httpie and CSRF PoCs, with credential and body redaction and read-only access. Reports page whole issues within 64 KiB and mark shortened evidence separately (#1947).

- JWT: find HS256/HS384/HS512 signing secrets offline with `gori run jwt --crack` or MCP `jwt_crack`, using inline candidates, files or saved wordlists and reporting the candidates tried. MCP `jwt_crack` and `cookie_crack` stop between candidates when cancelled (#1946).

- MCP: `race_requests`, `timing_requests` and `minimize_repeater` take `background:true`, which returns a `job_id` at once so other calls are answered while the run goes on; `get_job` returns the call's usual result and `stop_job` cancels it (#1944).

- TUI: an upstream proxy that does not answer is named once on the status row and in Notifications, with the setting that chose it, instead of only inside each failed flow's detail (#1944).

- TUI: `/` on the tab bar of a tab with no filter says so and points at `^P` before the next letters reach the global keys, a function key says gori binds none instead of doing nothing, and Comparer `←` diffs the requests and `→` the responses instead of both toggling (#1944).

- TUI: the Target → Params list has a `/` filter over parameter name, location and endpoint (#1944).

- TUI: long choice lists, including the Evidence issue picker, respond to Page Up, Page Down, Home, and End (#1960)

- TUI: OAST callbacks show when they arrived in the local time History uses, as a TIME column on a wide enough pane and in the detail, which printed UTC (#1944).
- `gori run history`: `--since ID` tails newer flows oldest first and `--before-id ID` pages older ones, as MCP `list_history` does, so a script continues from the last row's id (#1944).

- Notes: deleting a note through MCP or the CLI keeps the active note selected when it survives and selects its neighbour when it is removed (#1949).

- `gori run notes <n>`, `update`, `append` and `delete` refuse, under `--json`, an `<n>` that is also the id of a note at another position, so a script passing the id `--json` prints no longer reads or changes a different note; without `--json` `<n>` is the list position as before, and `--id N` and `--position N` name one or the other on all four (#1944).

- MCP: `gori mcp --install-*` writes `--tools=@recon` when no `--tools` is given, so a fresh install loads about a fifth of the full catalogue's tool schemas; `--tools='*'` installs every tool, and a hand-run `gori mcp` is unchanged, as is an existing entry until it is reinstalled. The printed `Command:` quotes glob and spaced arguments for copying into a shell (#1943, #1944).

- History: "size" means request + response bytes everywhere. The TUI SIZE column shows the total that `size:` filters on and the CLI and MCP print, and `--sort=largest` (MCP `sort:"largest"`) ranks by it; `respsize:` still filters on the response alone (#1943).

- TUI: when a History filter fills its loaded page, marking all and the delete confirmation say the marks cover only the loaded rows (#1943).

- Large projects: a `body:` search returns its first page in milliseconds instead of reading every match first, `path:` and `proto:grpc` scans run up to 40% faster, and the retention sweep removes the oldest flows a bounded chunk at a time, so capture and the TUI no longer freeze while a project over its `retention.max_flows` cap is trimmed (#1942).

- Opening a project that holds more flows than `retention.max_flows` now says how many the sweep will delete as capture runs and how to keep them, in the TUI and on the stderr of `gori run capture`, `import`, `discover` and `fuzz --record-history` (#1943, #1944).

- TUI: pasting a large wordlist into a Fuzzer payload set, or a large body into an Intercept held request, no longer freezes the app, and a filtered History re-runs its whole query less often under capture (#1942).

- `gori run`: an invalid `~` regex in a query is an error, as its help and MCP say, and `--strict` refuses a term QL would drop (#1942).

- Regex searches and rules (`body~`, `llm:`, Rewriter, Probe and Fuzzer patterns) no longer drop real matches on a busy machine: their 50 ms budget counts the CPU gori spends, not time spent waiting for a core (#1944).

- `gori run`: a mistyped `probe`, `history` or `sitemap` verb is refused instead of searched, `fuzz -w -` reads stdin, every delete accepts `--yes`, and under `--json` a not-found, pre-send, usage, unreadable request file or `intercept` refusal prints the error object (an `intercept` refusal also goes to stderr in text mode) and `project delete`/`repeater delete` say `ok` (#1942, #1944).

- `gori run cache-deception` refuses a missing flow id with `NOT_FOUND` under `--json` before sending any request (#1944).

- A settings factory reset also clears unknown fields saved inside rule, saved-view and Decoder chain libraries (#1950).

- Settings saves preserve a file that becomes unreadable during a session and can be retried once it is readable (#1957)

- TUI: startup warnings show at once instead of behind the greeting and stay in Notifications: a fallback port, capture off, a project dir gori cannot write (no longer blamed on another window), a corrupt settings.json under `--db`, and flows a crash left incomplete. Other action messages no longer wait behind a companion bubble either (#1942).

- Fuzzer: the TUI completion line counts errors as the CLI does, and a run where every request failed ends as `all N failed` instead of a green ✓ (#1942).

- TUI: an import that duplicates an earlier one, or did not commit every flow, says so on the status row ahead of the path and keeps the warning in Notifications (#1942).

- Repeater: stopping a send reads as stopped instead of a red `Closed stream` error, and a response gori cut short names the cause (its read budget, its 8 MiB capture cap, an idle origin) instead of a bare `(stopped)` or `(incomplete)`. A send still waiting for its response says it is sending, for how long and how to stop it, instead of "not sent yet" (#1942, #1943).

- TUI: the Intercept queue hint calls `/` the catch condition it sets, not a filter, and held response rows show status before the path so it remains visible on narrow screens. Coming back to Decoder lands on INPUT instead of typing into the chain, and the footer under a sub-tab filter being typed shows the filter's keys instead of strip letters that now type. The Issues list marks a resolved issue `res`, not `done` (#1942, #1943).

- Evidence: freezing an exchange an issue already holds with the same bytes writes no second copy; the TUI and `gori run evidence freeze` name the existing copy and MCP `freeze_evidence` returns it with `already_frozen: true`, now named in the tool description. A source whose bytes changed still freezes a new copy (#1942, #1944).

- Extract rules: a rule that re-binds the same value on every response no longer makes another rule's `extract_miss` warning repeat on most captured flows (#1942).

- Proxy: capture keeps up under load. A new connection is answered during a sustained burst instead of waiting seconds for it to end, the streams of one HTTP/2 connection no longer wait for each other's database write, and a chatty WebSocket no longer waits for each message's (#1942).

- Fuzzer: recording a run to History (`--record-history`, MCP `record_history`) commits its flows in chunks instead of two writes per request, so a recording sweep uses about a third of the CPU it did; a recorded row prints once its chunk lands (#1942).

- CLI: `gori run` and `gori mcp` start with about 30% less work, because Probe's passive rules are compiled on the first scan instead of at every launch, and an HTTPS send with `-k` no longer loads the CA bundle (#1942).

- CLI: a `gori run` whose output file fills the disk now says so in one line and exits 1, instead of printing a backtrace (#1942).

- TUI: Tab in project tag fields completes only a visible suggestion. Resizing the terminal keeps the highlighted tag and the completion in sync (#1951).

- Project lists and automatic project selection now distinguish activity within the same second (#1952).

- TUI: typed input is no longer lost or changed behind your back. A Repeater or Fuzzer TARGET being edited takes Ctrl-A/E/U/W itself and returns to READ when you leave it, issue and rule forms ask once before `esc` or a click outside discards an edit, `esc` in Project settings cancels the edit instead of saving it, and a Rewriter stub keeps its line endings when it is opened and closed (#1938, #1941).

- TUI: Find counts every occurrence and scrolls to the match, centred on an unwrapped line, a new History filter puts the cursor on the newest match, Issues export writes the marked or filtered issues and says which, and the `Space` menu shows all its rows again after the terminal grows (#1938, #1941).

- Fuzzer: the payload card shows all eight types and refuses a bound that is not a number until a second `esc` closes it unapplied, the CONFIG card follows its cursor on a short terminal, a refused run stays in Notifications, and Tab on an empty processor chain lists the converters, which `esc` closes without dropping the chain (#1938, #1941).

- Palette: `Ctrl-P` finds actions by Burp Suite and Caido words such as `replay`, `send to intruder`, `findings`, `httpql` and `preferences` (#1938).

- Param Miner: every probe now carries a unique cache-busting query parameter so mining a cacheable endpoint is neither served a stale cached response nor poisoned into a shared cache; on by default, opt out with `gori run mine --no-cachebuster`, MCP `cachebuster:false`, or the TUI mine config overlay checkbox (#1930).

- Source maps: an opt-in step fetches the `.map` a JS response points at (or parses an inline `data:` one), recovers the endpoints hidden in its original sources, and feeds them into the existing JS endpoint listing — via `unpack_sourcemap` (MCP), `gori run sitemap js --unpack`, and the History "Unpack source map" action (#1932).

- Probe: the request-smuggling detector adds CL.0 and the HTTP/2 downgrade classes H2.CL and H2.TE. HTTP/2 flows are now probed with the downgrade variants, and CL.0 rides the aggressive differential confirm. Off by default (#1931).

- Probe: CSP findings now account for CSP3 script element and event handler directives and the combined restrictions of multiple enforcing policies (#1937).

- Probe: passive checks detect credentials in cross-origin Referer headers, cleartext SAML bearer assertions, and more GitLab token formats. Accepted cross-site WebSockets carrying cookies appear as informational findings (#1939).

- TUI: unsaved issue drafts require a save or an explicit discard, simultaneous edits to a note are preserved as separate notes, and closing a note with links requires confirmation (#1929).

- TUI: project-wide search restores its results and selection after viewing a flow and blocks opening hidden results, while project-name search supports caret movement and click-to-edit. The Comparer and link pickers find older flows and keep the filter open when it has no matches (#1929).

- TUI: the command palette keeps the selected result visible in short terminals. If the palette or Space menu no longer fits, resize to resume or press Esc to close it (#1928).

- TUI: History Copy uses URLs for marked flows, and selecting more than two flows leaves the current comparison intact. Notifications and Activity report when a linked result is gone (#1927).

- TUI: leaving a project asks before discarding temporary JWT, Cookie and Comparer work. Short config forms scroll to the selected field, hidden forms cannot start a run, and Retest keeps its run and close keys visible (#1925).

- TUI: Find keeps its input visible in narrow terminals and lets you click to move the caret. History cancels delayed detail opens when you leave the list and explains how to search from Hex view (#1926).

- Fuzzer: agents can prepare a sub-tab with `create_fuzzer` while Send traffic is off, and scripts can use `gori run fuzz create`; the operator reviews and runs the saved request, payloads, processors and WebSocket script in the TUI (#1910).

- LLM targets: QL `llm:true` finds LLM API calls and `llm:claude` narrows by model name, and the Fuzzer's body regex also matches a streamed reply as reassembled text, so a word split across SSE deltas is found. **Copy as… › LLM transcript** and `gori run show --format transcript` write a call as Markdown for a report (#1912)

- Probe: `llm_prompt_injection` also flags an MCP `tools/list` result whose tool description hides itself from the user (#1912)

- Probe: passive OAuth checks flag successful password grants and token responses without `Cache-Control: no-store` (#1936).

- Fuzzer: a run whose only payload sets are null payloads needs no `§…§` position and sends the request as it stands N times (`--null=20`), to read a hit rate off a target whose answer varies (#1912)

- Session bindings: an extract rule whose condition reads `header:` or `body:` fires on a Repeater send, a slot's refresh step and a macro step, not only on proxied traffic (#1912)

- Docs: the **Test an AI target** playbook covers LLM and MCP targets end to end, including an MCP session carried by a slot's refresh steps; it is also an MCP prompt (#1912)

- MCP: project binding replies include engagement guidance, capped at 2,000 characters with the full text in `project_info`; handshake instructions point agents to it before acting (#1911).

- MCP: `--tools=@analysis` serves five capture readers, and `list_history` can select row metadata with `fields` while retaining provenance and pagination context (#1916).

- Eval: run capture-analysis tasks with Codex as well as Claude Code, with shared grading and separate agent/model reports (#1914).

- Repeater/Fuzzer: scripted WebSocket sends can opt into permessage-deflate with independent messages; transcripts and Fuzzer matching use bounded decoded replies, while explicitly shaped frames, including saved Repeater seeds, stay verbatim. CLI text transcripts retain received frames on decode errors (#1897)

- History: a DNS-over-HTTPS body (`application/dns-message`) renders as JSON in the detail pane, `gori run show --format json` and MCP `get_flow` (#1899)

- Proxy: with a Match & Replace body rule, a body extract rule or the response intercept on its host, a chunked `multipart/x-mixed-replace` stream reaches the client at once, and a chunked NDJSON, Connect or gRPC-Web stream that has not ended after 5 seconds is released instead of stalling. On HTTP/2 an NDJSON body that declares its length is rewritten, and a stream a rule skipped says so on the flow (#1899, #1901, #1902)

- Proxy: `network.strip_extended_connect` keeps a browser's WebSockets off HTTP/2, so per-message intercept and Match & Replace apply to them (#1896, #1903)

- Proxy: `network.strip_available_dictionary` removes a request's `Available-Dictionary` so the origin answers in a coding gori decodes, and a `dcb`/`dcz` body's decode note names the dictionary and the setting (#1898, #1904)

- Proxy: an HTTP/2 body still gets its Match & Replace rule when its empty final DATA frame arrives while another stream's spill waits for the client to read it (#1906)

- Proxy: an HTTP/1.1 flow keeps its request advisory, such as a Match & Replace body rule skipped on a compressed request, when the response adds one of its own (#1905, #1907)

- Docs: transparent mode says to block UDP 443 so an HTTP/3 client falls back to TCP (#1899)

## v0.9.4

- TUI: quieter screens: cards drop their outer frame, a filter not being typed in takes no row, a flow's status and sizes sit on the detail's border, and Miss Ring stays out of the content; an 80×24 Repeater shows 11 rows instead of 7 (#1851, #1863, #1864)
- TUI: clearer first steps: empty cards and `Space` menus offer only what can run next, hints and footers name keys that work and keep the important ones on a narrow terminal, and the first-run wizard is shorter (#1843–#1860, #1871, #1873, #1874, #1877, #1878)
- TUI: closing a workbench session, quitting after a failed save, discarding a hotkey rebind or turning Intercept off over an edit asks first; confirmations scroll long warnings, hidden dialogs cannot commit on a tiny terminal, and quitting stops Android setup before its next ADB command (#1873, #1874, #1882–#1887, #1889, #1890)
- TUI: text fields take Ctrl-A/E/U/W, move and delete whole emoji and combining characters, and IME previews render once beside the caret (#1888, #1891, #1892, #1893)
- TUI: `^P` finds tabs by other tools' names (intruder, scanner, collaborator) and everyday words, `?` opens the shortcuts as a popup on the current tab, and `/` on the tab bar opens that tab's filter (#1852, #1876, #1878, #1880)
- CLI: under `--json`, a failed call (not found, busy, no project, duplicate) prints the MCP error object on stdout, deletes answer `{"ok":true,"deleted":true,…}`, and an MCP tool name is answered with its `gori run` command (#1876, #1878, #1879, #1881)
- CLI: `gori ca info`, `gori ca --der`, `gori update --check` (exits 10 when an update is available), and JSON output for `probe promote` and `sitemap tag --list` (#1783, #1784, #1866, #1867)
- MCP: paged lists return `next_offset`, tool annotations mark read-only, additive and idempotent tools, and a refused `fuzz_start`, `mine_start` or `sequence_start` shows the right argument shape (#1876, #1878, #1879)
- Workbench: the Sequencer rates fewer than 20 tokens INCONCLUSIVE, JWT and Cookie decode a value pasted straight from a header, Authorize counts only requests on the wire, and `fuzz --fail-if-no-matches` exits 1 when every send errored (#1875)
- Probe: faster passive checks, XHTML read as a document, and wildcard CORS lowered to informational (#1895)
- Proxy: the CA page at `http://gori.proxy/` shows the SHA-256 fingerprint and trust steps for Linux, iOS and Android (#1862)
- Settings: names match across Project settings, Preferences and the palette, the live listen port shows when `-p` or `--listen` moved it, and dim columns stay readable on the selection band in every theme (#1861, #1872, #1877)
- Docs: a tighter README (#1894)

## v0.9.3

- History: a wide flow detail shows the request beside the response (`⇧Z` → Request beside response turns it off), and `esc` from a detail's text steps back to its pane strip before it closes the detail (#1835)
- TUI: Notes, Issue notes and the Project and Probe descriptions wrap between words instead of mid-word (#1833)
- TUI: a selected Fuzzer hit keeps its ✓, a restored fuzz run no longer toasts over another tab, filter bars name their fields only once `/` opens them, and the `^P` query line, the tab-bar footer and Intercept's empty card are clearer (#1833, #1836)
- TUI: the header keeps the project name on a narrow terminal, and sub-tab names use the strip's width instead of stopping at about 16 columns (#1834)

## v0.9.2

- TUI: leaner screens: pane borders show only what is on, footers name the focused pane's keys, Probe groups a check seen on several hosts, Sitemap folds one-child folder chains, and Settings, Fuzzer Advanced and Repeater menus are regrouped (#1820, #1821)
- Repeater: `Space` → **Past sends…** restores what a tab sent, and a running TUI picks up sub-tab names and tags set elsewhere (#1807, #1808)
- MCP: list replies held to about 40 KB, `list_history{sort}` and `gori run history --sort`, and QL hints that `host:`/`path:`/`url:`/`header:` match a substring (#1823, #1824, #1828, #1829)
- Redaction: a redacted `Set-Cookie` keeps its name and attributes, and `gori run repeater show` withholds credential headers unless `--include-sensitive` is passed (#1809, #1827)
- Export: each HAR entry names its flow in `_goriFlowId` (#1825)
- Decoder: SHA3-256/512 and `html-encode-all`; Probe fingerprints WordPress (#1780, #1781, #1782)
- History: Pretty bodies fold an HTTP/2 request's split `cookie` fields into one line (#1817)
- Proxy: TLS stays in userspace when the system OpenSSL turns on kernel TLS (#1812)
- Long sessions no longer hold memory for finished work (#1819)

## v0.9.1

- MCP: leaner probe findings and list rows, a passive scan in about a third of the memory that stays cancellable, and `--install-codex`/`--install-grok` raise the tool timeout to 10 minutes (#1790, #1791, #1795)
- MCP: a client that dies mid-call stops its jobs cleanly, a cancelled `send_request` is finalized, and fixes to job lifecycle, paging, reply budgets and rule warnings (#1796, #1802)
- Issues: `gori run issues` and MCP `list_issues` filter with the Issues tab's query, and the CLI adds `issues show`, `--count` and several ids on `update`/`delete` (#1776, #1778, #1799)
- Rewriter: a regex that does not compile names the reason on the CLI and MCP (#1785, #1793)
- Repeater: a target that names an env var (`http://$ENV.BASE`) is saved as written and resolves on each send (#1774, #1775)
- Probe: the secrets rule detects Hugging Face and DigitalOcean tokens (#1779, #1794)
- TUI: fixes from a defect audit: paste guards, Intercept Tab edits, stale picks and a background Cookie crack (#1797, #1801)
- CLI: `gori run show --format csrf-poc` is accepted as an alias for `csrf` (#1777)
- Docs: a redrawn landing page (#1773, #1800)

## v0.9.0

### New features

- WebSocket: live Repeater sessions, `gori run repeater ws` and MCP `ws_session_*`, and frame injection into a socket the proxy is relaying (#1630, #1660)
- SSE: streams are captured and shown live while still open, and every send stops after a bounded number of events or seconds (#1631)
- gRPC: Connect protocol, compressed messages, and editing a whole message as JSON (#1629, #1632)
- Rewriter: `json_set`/`json_remove` ops, a record of which rules rewrote a flow with its original bytes, and body rules that keep HTTP/2 (#1589, #1599, #1628, #1635, #1637)
- Projects: a request budget shared by every run, surface and process, tags, and `project prune`, `rename` and `describe` (#1601, #1703, #1756, #1757)
- MCP: an **ask** permission approved from the TUI, docs playbooks as prompts, `wait_ms` long-polling, `graphql_schema`, body search with `find`, and `count_only` (#1585, #1596, #1648, #1740, #1742, #1743)
- MCP: captured traffic is marked by `origin` as untrusted data, and a passive rule flags text aimed at an LLM (#1586)
- History: decoded JSON-RPC/MCP and OpenAI/Anthropic LLM calls, and QL `ws:`, `rpc:`, `via:` and `port:` (#1587, #1588, #1590, #1767)
- Sitemap: per-endpoint test coverage (`touched_by`, `--untested`) (#1741)
- Fuzzer: named extractors and `--verbatim` (#1592, #1764)
- `$GEN.TOTP` one-time codes, and GraphQL batching and alias multiplication in the Repeater (#1591, #1595)
- Probe: weak OAuth/OIDC and client-side path traversal rules (#1597, #1598)
- CLI: `gori run android setup`, `browser` (with an opt-in DevTools port), and `repeater show`/`update` (#1594, #1600, #1665, #1681)
- Proxy: `GORI_SSLKEYLOGFILE` writes TLS secrets for Wireshark (#1593)

### Changes

- MCP: list replies are held to about 64 KB, and the tool catalogue is ~25% smaller (#1649, #1729, #1730)
- An unset `$ENV.KEY` in a request you wrote is refused before it dials (#1666, #1689)
- `gori run fuzz save --json` prints one `{"results":[…],"run_id":…}` object instead of a bare array (#1682)

### Fixes

- HTTP request path audit: abnormal requests you wrote keep their bytes across Repeater, Fuzzer, HTTP/2 sends, Intercept edits and Copy as cURL (#1762, #1763, #1764)
- Fixes from feature audits, crash sweeps, and dogfooding the TUI, `gori run` and `gori mcp` (#1621, #1623, #1624, #1626, #1656, #1753, #1754, #1755, #1758, #1766, #1767, #1768, #1769, #1770, #1771)

## v0.8.1

- MCP: `--pin-project`, `switch_project` with `unbind:true`, a joined `url` on flow and sitemap rows, and a **Run local commands** permission (#1508, #1556, #1558, #1560, #1584)
- MCP: `decode` with a bare name such as `base64` now decodes; spell `base64-encode` to encode (#1554)
- Security: runaway regexes time out, `.gori` imports refuse triggers and views, and redaction covers more exports (#1584)
- Fixes from a feature audit, bug and crash sweeps, and dogfooding `gori run` and `gori mcp` (#1549, #1552, #1573, #1578, #1579, #1580)
- Docs: accuracy passes, an access-control playbook, and Windows Terminal guidance (#1564, #1574, #1575, #1583)

## v0.8.0

### New features

- Windows: native x86_64 builds, a self-contained `.exe` that `gori update` replaces in place, and Chocolatey packages (#1510)
- Repeater: race several distinct requests in one release, and differential timing analysis of an A/B pair (#1236, #1246)
- Fuzzer/Miner: request-time macros, payloads from captured project data, named wordlists, results grouped by response shape, and runs that stop on a condition (#1240, #1350, #1351, #1352, #1353)
- Sitemap: one root per origin, a parameter inventory, JavaScript endpoint discovery, and OpenAPI 3.0.3 export (#1231, #1241, #1243, #1371)
- Rewriter: short-circuit rules serve local files, a captured response or a fault (#1237)
- Projects: `.gori` snapshot export/import, and cross-project flow search with `Ctrl-F` in the picker (#1229, #1230)
- Import: paste a curl command into Repeater or History (#1244)
- Session slots log back in by replaying Repeater sessions (#1233)
- Probe: blind SQL injection, out-of-band RFI and bare-LF response rules, and promoted findings become report-ready issues (#1110, #1111, #1377, #1414)
- Cache testing: a `cache:` QL field, a cache-deception check and `cache-delimiters` payloads (#1247)
- Capture: interim `1xx` responses are recorded, `static:` hides static assets, and an Intercept edit keeps the original request (#1239, #1378, #1413)
- MCP: `ask_operator`, per-group permissions, and `--tools=@recon`/`@minimal` (#1137, #1324, #1327)
- CLI: `gori run send`, `shell`, `notify` and `project network` (#1115, #1116, #1238, #1323)
- `$GEN.USER_AGENT`, and Unicode normalization, RFC 2047 and Best-Fit in the Decoder (#1112, #1245)
- TUI: a two-level space menu (`>` Send flow to…, `Z` Display…, `P` Protocol…, `T` Sub-tabs…), tab actions in the `Ctrl-P` palette, READ-mode delete/paste and `hjkl`, a keyset playground, and new themes (#1274, #1282, #1295, #1325, #1478)

### Changes

- Intercept holds requests only by default (#1505)
- First run: projects open on History, a four-step wizard, an untrusted-CA notice and guided empty states (#1512, #1513, #1514, #1515, #1516, #1524)
- CLI: `--format json` is one JSON document everywhere (`--format jsonl` for lines), `send -d` is the body and `-b` a cookie, and `GORI_PROJECT` pins the project (#1383, #1386, #1387)
- Flow, issue, rule and session ids are never reused (#1343, #1344)
- Performance: indexed History/Sitemap filters, cheaper HTTPS interception and lower memory use (#1337, #1340)
- MCP: smaller default answers, and sensitive values withheld consistently across tools (#1394, #1460)
- Settings from before v0.3 are no longer migrated; upgrade through v0.7 first (#1490)

### Fixes

- Hardened against hostile imports, deep JSON, oversized numbers and malformed proxy traffic (#1200, #1414, #1497)
- Fixes from audits of the CLI, MCP, settings, TUI, import and workbench tools (#1458, #1459, #1460, #1491, #1493, #1495, #1496, #1534)

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
