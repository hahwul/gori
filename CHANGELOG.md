# Changelog

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
