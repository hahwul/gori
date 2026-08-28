# Changelog

## Unreleased

- Rewriter: response-modification presets — one keystroke installs the Burp-style options every tester writes by hand (unhide hidden form fields, enable disabled/readonly controls, remove `maxlength`, strip client-side validation, drop CSP, drop security headers, disable SRI). A preset installs ordinary, visible, editable, disable-able Match & Replace rules through the same write path as manual authoring — nothing hidden, nothing magic — so they can be edited or deleted like any other rule. `p` on the Rewriter tab, `gori run rewriter preset list|add <name>`, and the MCP `list_rule_presets` / `create_rule_from_preset` tools all install from the one static catalog; the regex rules stay conservative about markup and never run a command (#821)
- External process hooks: pipe bytes through your own command instead of a plugin API — a Rewriter `pipe` op, a Decoder chain `exec:` step, and a Probe `exec` rule, all one primitive. The command is exec'd directly with no shell and runs with YOUR privileges (unsandboxed, the same trust level as any Rewriter rule); every run has a hard timeout (`hooks.timeout_secs`, default 5s) and a 32 MiB stdout cap, and on timeout, non-zero exit, failed spawn or oversized output the original bytes pass through unchanged with a notice — the proxy never stalls on a hook. The MCP `decode` tool refuses `exec:` steps: it stays pure compute (#818)
- Retest: diff two projects at endpoint scale — what is new, gone, or answering differently since the last engagement. A Diff sub-tab under Target, `gori run diff` (text/json/md), and the MCP `diff_projects` tool; endpoints are keyed by the Sitemap's folded template, and an endpoint the newer capture never requested is reported as a coverage gap rather than as removed (#824)
- Proxy: per-destination outbound TLS fingerprint control — `groups`, `sigalgs`, TLS 1.3 `ciphersuites` and an ordered `alpn` list on `outbound_tls`, plus `chrome`/`firefox`/`safari`/`curl` presets, so an origin's anti-bot layer sees a browser-shaped ClientHello instead of gori's OpenSSL one. `gori settings tls-fingerprint` prints the JA3/JA4 that actually goes out; presets are approximations, not byte-exact matches (#822)
- gRPC: point a project at a `protoc` descriptor set (`Project → Project settings → Proto schema`, or drop one in `~/.gori/protos/`) and captured protobuf renders as named, typed fields — the request path `/package.Service/Method` is the binding. Undeclared field numbers and wire/schema disagreements are still shown, the raw wire tree stays beside the lens on every surface, and with no descriptor set loaded nothing changes (#823)
- TUI: syntax-highlight HTTP structure and structured bodies in the History Request/Response preview (#834)
- Proxy: with `network.strip_alt_svc` off, a response advertising `Alt-Svc: h3=…` now says so on the flow instead of passing silently — the advertisement still reaches the client byte-for-byte, but a client leaving for QUIC is a reported blind spot rather than an unexplained gap in History (#835)
- TUI: the project picker marks a project an MCP client is bound to, and an open project shows a clickable `mcp:<client>` top-bar chip that lists the attached agents (#815)
- TUI: the Comparer flow picker follows the active project Scope lens, and says `no flows in scope` rather than `no flows captured yet` when the lens hides everything; turning the lens off still exposes every captured flow (#809)

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
