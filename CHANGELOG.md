# Changelog

## Unreleased

- Discover: a brute-force hit's body is read for endpoints, so finding `swagger.json`, an autoindex page or a config file starts a crawl instead of producing a single row. Only hits are read — the thousands of soft-404s a sweep sends still cost nothing
- Discover: links a response declares in its HEADERS are followed — `Link` (RFC 8288, how a paginated API names its next page and nowhere else), `Content-Location`, `Refresh`, and the subtree a `Set-Cookie` scopes itself to with `Path=`
- Discover: the API-description documents (`openapi.json`, `swagger/v1/swagger.json`, `v3/api-docs`, `v2/api-docs`) and the root `apple-app-site-association` join the well-known set fetched once at the origin, and the whole set is registered as visited so the origin's own directory sweep no longer re-requests each of them
- Discover: a `405` is recorded as proof a path exists. A form target, a JSON API that only takes `POST` and a WebDAV collection each answer `GET` once with `405`, and were dropped
- Discover: linked images, fonts, media and archives are no longer downloaded — a request and a full body each, for bytes no extractor can read, which also spent the crawl's page budget. Their directory is still swept (`/uploads/` because `/uploads/photo.jpg` was linked) and the count is reported as `assets`; `--assets` / `crawl_assets` / the **fetch images/fonts/media** checkbox restores the fetch
- Discover: an html body is scanned into text once for its links and its `<base href>` instead of once each (10% off per-page extraction, 1 MB/response less allocated on a large page), and `--extensions php` no longer probes `admin.php.php` for every already-dotted word in the list
- History: `body~`, `header:` and index-free `body:` no longer run the regex engine over every stored byte. A literal needle is answered by a byte search instead, allocating nothing (`body~` across 500k flows: 4.1s → 0.25s, 688MB → ~1KB; `header:` 199ms → 120ms), and a real regex stops paying to validate each body twice (2-4x, whether the capture holds text or compressed bytes). A `body:`/`header:` needle under three characters also folds case the same way a longer one does now, so it can no longer match fewer rows than the longer needle containing it.
- OAST: `gori run oast listen --save` and MCP `oast_start{persist:true}` keep the registration as a project session, so a headless or agent-driven listener lands in `oast list` / `list_oast_sessions`, is re-openable with `resume`, and — the reason it matters — gives the blind `ssrf_oast` / `xxe_oast` / `cmd_injection_oast` rules a session to mint payloads against. Only the TUI could write one before, so those rules ran inert everywhere else
- MCP: `probe_scan{active:true}` reports an `out_of_band` block when an enabled out-of-band rule had no OAST session to plant against, instead of returning an empty `issues` array that reads as "no blind vulnerability" — the notice `gori run probe` already printed
- OAST: a listener that has stopped REACHING its provider (a rotated api key, an expired webhook token) draws "not answering" instead of a green ●listening and raises a notification, rather than looking busy while every planted payload calls home to nobody
- OAST: webhook.site, BOAST and postbin gave an interaction whose item carried no server-side id a RANDOM dedup key, so on the two providers that re-serve their whole buffer each poll it was re-announced and re-recorded every cycle; the fallback is now a content hash, as interactsh and custom-http already used. postbin's callback destination shows the path that was hit rather than repeating its request id
- Docs: two Reference pages for the artwork — **Brand Kit** (the three logo variants, the brand palette with where each value lives in the TUI and on the site, and the wallpapers, all downloadable) and **Miss Ring** (the character she was drawn from, the 8x3 half-block grid, and every pose and badge). The header's logo menu now links to the kit.
- MCP: `gori mcp --install-pi` configures Pi in `~/.pi/agent/mcp.json`, honoring `PI_CODING_AGENT_DIR`; requires a Pi MCP adapter (#992)
- Docs: an accuracy pass over the English and Korean guides — corrected keys (deleting marked flows, Sitemap tagging), the rule host-scope and colour-rule condition semantics, per-field `Alt-Svc` stripping, undocumented `gori run` flags and MCP tool gating, and restored dropped Korean paragraphs.
- TUI/CLI/MCP: every place gori names the scope-lens key now says `s` — the two `--in-scope` help lines, the History and Probe empty-state hints, the colour-rule advice note and the MCP scope arguments still named `⇧S`, the twin key removed when the lens became the Global `s` (#959)
- Issues: CVSS v2.0 vectors written in the parenthesised form NVD's v2 calculator renders — `(AV:N/AC:L/Au:N/C:P/I:P/A:P)` — are accepted and scored instead of refused (cvss.cr 0.3.0, #994)

## v0.5.0

### New features

- Cookie: a TUI workbench tab for framework signed session cookies (Flask/itsdangerous, Rack, Django) — decode, verify, crack and forge, the JWT tab's sibling (#565)
- Retest: diff two projects at endpoint scale — a Diff sub-tab, `gori run diff`, MCP `diff_projects`, and `⇧F`/`n` to file a row as an Issue or Note (#824, #845)
- Issues: CVSS v3.1/v4.0 scoring with `cvss:>=7` filtering, CVSS-aware exports and SARIF `security-severity` (#575)
- gRPC: proto descriptor sets and server reflection as schema sources, schema-aware field fuzzing (`--field`), gRPC FIELDS editing, and grpc-web outcomes read from the body frame (#823, #841, #849, #984)
- Hooks: pipe bytes through your own command — a Rewriter `pipe` op, a Decoder `exec:` step, a Probe `exec` rule, and `mine --hook` (#838, #853)
- Proxy: outbound TLS fingerprints per destination and per send (`chrome`/`firefox`/`safari`/`curl`), plus `gori settings tls-fingerprint` (#822, #844)
- Proxy: SOCKS5H, project-scoped proxy auth and destination filtering, and an upstream CONNECT proxy over TLS (`http+tls://`) (#858)
- Rewriter: one-keystroke response-modification presets (unhide fields, drop CSP or security headers, disable SRI) installed as ordinary rules (#821)
- Project: an ACTIVITY pane over the event feed, and config changes recorded with who changed what (#864)
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

- Authorize: replay a captured request under saved identities against a baseline, on all three surfaces. Passive replay of what the browser touches, `gori run authorize`, and the MCP tools share one plan (#707, #710)
- History views: `v` picks a named filter that stays on — seven built-ins, project/global saved views, `gori run views` / `--view`, and MCP `*_view`. A project opens on `History + Repeater` (#776)
- History provenance: a SRC column and `src:` name who sent each flow. TUI Repeater sends record by default; Authorize and Probe ignore gori-originated traffic on the unattended path (#770)
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

- Open browser: a browser that never starts is reported as such, with its own error and how it died, instead of `opened` — gori only checked that the process spawned, not that it survived, and closed the browser's stderr, which was the one thing that could have explained the failure. The verdict comes from waiting on the child rather than a deadline, so it holds on a machine slow enough to lose that race. Brave is also launched without `--test-type`, which 1.92+ treats as a unit-test signal and aborts on — Chrome still gets it, to hide the SPKI-pin infobar (#700, #716, #721)
- Scope: a regex EXCLUDE rule no longer fails **open** on a target that is not valid UTF-8 — it scrubbed nothing and `rescue false` read as "does not match", which is scope evasion. The History/Sitemap SQL lens also now agrees with the live gate on bracketed IPv6 hosts, brace globs and non-ASCII case (#688, #699)
- Project settings: a host override reaches gori's own reserved name from either layer and folds case and a trailing root dot into one key, and the TUI refreshes the project env table before writing it back over a peer's edit (#687, #689)
- TUI: the statusline gets its own timeout and reports why it is blank, instead of killing the script that was about to answer (#690)
- Stability: a crash audit across the CLI, TUI, store and MCP — a non-UTF-8 byte no longer aborts a command through PCRE2, a stale read cursor no longer takes the session down, and a poisoned release tag no longer crashes every later launch from cache. An MCP discover job also flushed its findings after going terminal, so a run finishing during a `switch_project` could write them into the project you had just moved to (#699)
- MCP: `gori mcp --install-claude` now writes Claude Desktop's config where the running platform actually keeps it — `$XDG_CONFIG_HOME/Claude/` (default `~/.config/Claude/`) on Linux, not a macOS `~/Library/Application Support/…` path built under a Linux `$HOME` (#718)

## v0.3.1

- Filters: one query grammar on every filter surface, content terms included; `header:`/`body:` now take a side, and the filter bar teaches its own syntax (#668, #674)
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
- Miss Ring: an opt-in companion in the body's corner, and on the project picker delivering the update notice; on `lively` she now also plays one of four idle gestures — a yawn, a smile, a squint or a deadpan — about once a minute, in the status-bar chip as well as the body sprite (#474, #548, #550)

### Changes

- Discover: read the target's well-known documents (OIDC/OAuth discovery, `security.txt`, sitemaps, …) and extract endpoints from JS bundles, JSON, source maps and inline `<script>`; keep each finding's request/response and open them from the findings table; hold and re-measure a drifting soft-404 baseline instead of reporting hundreds of limiter hits; report a real page on a wildcard-200 origin; bound per-response spend and stop a JS literal from buying a brute-force sweep (#605, #638)
- Comparer: per-row change highlighting with `n`/`⇧N` navigation and `f` fold, per-column `status·size·time` headers with the A→B delta, and **Send to Comparer** from the Repeater, Sitemap and Fuzzer rows; `--context=N` fold parity in CLI/MCP
- Rewriter: rules scoped global or project (replacing the s/o preset library), shown on the tab bar by default right of Comparer (#544, #611)
- Probe: passive-rule improvements, the OAST SSRF rule classed CWE-918, and a navigable AFFECTED URLS list in a finding
- Miner: latency-bound scheduling — one work queue for all locations, parallel calibration (~2.4x)
- JWT: the lens switch (`^T`) now shows on the pane it acts on; new `dancheong` (dark) and `hanji` (light) themes
- Project picker: multi-select over the project list — `Tab` / `⇧Tab` mark and step, `⇧↑` / `⇧↓` extend a range, `ctrl-a` marks everything the search shows, `esc` clears. The space menu's **Delete** then acts on the marks if any are set, else the cursor row; it names what it is about to wipe, says how much of the set the current search is hiding, and keeps (rather than silently skips) a project another gori still has open
- `gori ca`: reject a flag written before the verb, repair a CA directory missing one of the key/cert pair, and reject an Ed25519/Ed448 or mismatched-key root with an operator-legible message instead of failing at the first CONNECT
- Fixes: bracketed-paste freeze and poison in the Repeater; the `--` separator dropping subcommand args across ~60 `gori run` sites; colormarker custom-colour persistence and reorder writes; clipboard OSC 52 over tty; project-settings and host-override reload/rollback audit; OAST partial-poll evidence loss; and many dogfood-surfaced bugs

## v0.2.0

- Proxy: upstream connection rules with per-host routing, SOCKS5 and proxy auth; a TLS pass-through list that is never MITM'd; per-destination outbound TLS (client certificates, protocol floor, ciphers); a setting to force HTTP/1.1; transparent listeners and additional listeners alongside the primary bind (#434, #435, #436, #437, #438)
- Proxy: harden the HTTP/2 assembler against CONTINUATION spoofing and stream-slot exhaustion, re-sync framing after a head rewrite so Match&Replace can't smuggle, and reject bare-CR header obfuscation and ambiguous response framing (#341, #403, #409, #412, #417)
- Proxy: serve the CA-download page at a reserved host, `gori.proxy` (#347)
- TUI: multi-select in History, the Intercept queue, the Sitemap tree, and the Issues list, so the space menu acts on N items at once (#442, #459, #460, #461)
- TUI: the Project tab becomes sub-tabs instead of five tiled panes, Network settings gain upstream-rules and outbound-TLS tables, a Keys section picks the command modifier (⌥ reaches the shortcuts Ctrl can't), plus `rosepine` and `tokyonight_day` themes (#440, #454, #458, #462, #463)
- TUI: export the current note to Markdown from the Notes space menu, and ask where to write the Issues report instead of always overwriting `<project dir>/issues.{md,json}`. Export is `⇧E` on both tabs; the Issues list's old `x` is freed, so `x` now means "Select line" everywhere (#432)
- Settings: `--config PATH` plus settings export/import profiles, per-project connect/idle timeouts and capture limit, and a unified retention policy (#439, #440, #441, #448, #450, #455)
- Import: read Postman collections, Insomnia exports, and Burp XML (#453)
- Probe: active-scan rules for open redirect, CRLF/response-header injection, host-header injection, access-control bypass, NGINX-style parameter traversal, GraphQL introspection, SSTI, and Next.js server-action missing authorization; passive rules for JWT weaknesses, source maps, SRI, and directory listing; a manual unsafe-method opt-in and AGGRESSIVE mode (#299, #342, #343, #346, #349, #350, #451)
- CLI/MCP: bring `gori run` and `gori mcp` to TUI parity, and create/delete projects from `gori run project` (#351, #352)
- Performance: move trigram FTS indexing off the capture commit path, and reuse one HTTP/1.1 connection across a fuzz sweep (up to 20x on HTTPS) (#428, #433)
- Security: close request-splicing and scope-gate holes across Discover, Fuzzer, Repeater and Scope — crawled-link splicing, unvalidated redirect `Location`, per-URL probe authorization, fail-open scope, irregular request-line whitespace, and `wss://` targets dialing cleartext (#390-#397, #404-#407, #418-#422)
- Security: keep gori's own files owner-only — the CA private key is now 0600 from creation (it used to land at the umask default and get chmod'd a syscall later, and a key that got loose any other way was never re-tightened) and is re-asserted on every load, and a settings export carrying a secret is written 0600. `--config` and `--ca-dir` no longer re-mode a directory the operator merely named (#466, #467)
- Say what went wrong instead of swallowing it: a TUI session that can't open (a bad `--db`, an unreadable store) reports why on the project picker rather than dropping the operator on "no projects yet"; an unparseable `settings.json` says it is falling back to defaults rather than resetting the bind, upstream rules and TLS pass-through list in silence; and a path that should be a directory but isn't (`--ca-dir notes.txt`) is named as such instead of surfacing as `BIO_new_file(...) failed` or a raw backtrace
- Refactor: a single outbound chokepoint for the active-traffic scope gate, one Plan builder per engine (fuzz, discover, miner, repeater, sequencer) shared by TUI/CLI/MCP, and all 28 TUI modals on one Overlay seam (#354, #355, #356, #361)
- Packaging and docs: Nix flake with an update channel, `AGENTS.md`, `DESIGN.md` with the P0-P8 principles, and an install script that survives GitHub API rate limits (#338, #345, #353, #360, #429)

## v0.1.4

- Proxy: fix HTTPS blank pages / empty History — reflect origin ALPN so h1-only origins load, resolve the system CA trust store for upstream verification, and report TLS-verify failures separately from connect failures (#332, #333, #334, #336)
- Proxy: stop an upstream RST leaving a flow stuck Pending forever (#330)
- Scope-gate every outbound path so Sandbox mode holds: Repeater, Fuzzer, Miner, Sequencer (CLI and TUI), with `--allow-unscoped` opt-out (#322, #330, #339)
- Import: reject CR/LF/NUL smuggling in HAR/OpenAPI, and neutralize control bytes in decoder/JWT text output (#322, #324, #339)
- CLI/MCP parity: add Comparer (`gori run compare` / `compare_flows`), CLI Intercept, CLI WS repeater send, MCP scope/env/host-override mutation and `import_flows`, `gori run probe --active` (#321, #326)
- MCP: fix a credential leak in `get_repeater_context`, cap unbounded h1 capture reads, and surface `PROJECT_BUSY` on rolled-back writes (#335)
- TUI: Repeater `^N` mirrors the target host into the Host header, Fuzzer wordlist field suggests recent and favorited paths, tutorial navigation fixes (#314, #315, #335)
- OAST: support global-scope providers alongside project scope (#313)
- Fix dogfooding-surfaced bugs across QL (`url:`, size and `dur:` units, uppercase schemes), Discover, Sequencer, Repeater, browser CA trust warning, `settings.json` formatting, and multipart form data (#312, #316, #317, #318, #319, #325, #337)

## v0.1.3

- Fix 30 confirmed bugs found across three build-and-dogfood passes: TUI (`--db`, Repeater NUL-truncated bodies, Rewriter hot-reload, Sequencer/Miner/OAST, Scope reload, log redirection), CLI (`oast listen --help` crash, Issues/Sitemap export encoding), proxy (WS close-handshake race, h2 preface on intercept), MCP, Import (HAR/OpenAPI/URL-list CRLF injection), Fuzzer auto-calibration, and more (#301, #307, #310)
- CLI: accept `-V` as a version flag alias (#298)
- TUI: match banner and wordmark gold to the real logo (#308)
- Docs: dynamic landing page, nav/sidebar reorganization, logo download menu, homepage title (#300, #302, #303, #304, #305, #306, #309)

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
