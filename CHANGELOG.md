# Changelog

## Unreleased

### Added — Param Miner covers more body types

The Miner now injects candidate parameters into two body shapes it previously
ignored:

- **multipart/form-data** — a new `multipart` location splices candidate fields
  into an existing multipart body (reusing the request's boundary, byte-exact
  otherwise), instead of silently falling back to query-only mining. It's
  *applicable but off by default* (a captured file part would be re-sent on every
  request); enable it with `--locations multipart`, the MCP `locations` field, or
  its overlay checkbox.
- **Nested & array JSON** — JSON mining previously probed only the top-level
  object's keys. It now injects candidate keys into every object node — nested
  objects and objects inside a root array included — capped BFS shallow-first, so
  `{"data":{…}}` and `[{…},{…}]` bodies are covered. Single-object bodies mine
  exactly as before.

### Changed — upstream TLS verification moved to Settings: Network

The bottom status bar no longer carries the `upstream:verify` / `upstream:insecure`
chip. Upstream TLS certificate verification is now a live toggle in **Settings:
Network** (command palette → `settings:network` → "Verify upstream TLS"). Toggling
it re-syncs the running capture proxy, the active-probe sender, and the Repeater/
Fuzzer/Miner senders without a restart, and the choice persists globally in
`settings.json` (`network.verify_upstream`). The `--insecure-upstream` launch flag
still works: it seeds the toggle off for that session (and the editor reflects it).
`gori run` / MCP keep their own `--insecure-upstream` flag.

### Performance — behavior-preserving hot-path optimizations

A measured pass over the render / fuzz / decoder hot paths (micro-benchmarks in
`bench/`, gated on a benchmark delta + the full spec suite staying green). No
observable behavior changes — byte-exact forwarding, identical rendered glyphs,
identical query/pretty output. Highlights:

- **TUI render primitives** — `Highlight.draw` (the styled-line primitive behind
  the History detail, Repeater, Intercept, Fuzzer, and Decoder panes) and
  `Screen.display_width`/`column_width` gained the printable-ASCII fast path
  `Screen#text` already had: an ASCII line (the common HTTP head/body) is drawn
  by char at width 1 with interned cells instead of grapheme-clustering and
  allocating a `String` per glyph. `Highlight.draw` over a styled viewport drops
  ~21× (123 kB/op → 640 B/op); `display_width` on a frame's worth of labels drops
  ~115× (0 B/op). Non-ASCII (CJK/emoji/combining) keeps the exact grapheme path.
- **Tab bar** — the menu strip and the ⋯ hidden-count now come from ONE
  `Chrome.split_tabs` reconcile per frame instead of two.
- **Fuzzer** — `Template#render` pre-sizes its output buffer to the exact length,
  dropping the default-64 B realloc chain on every emitted request.
- **Pretty-print** — a JSON body is parsed ONCE (shared between the GraphQL sniff
  and the pretty-print) instead of twice per detail-view rebuild.

New benches: `highlight_draw_bench`, `display_width_bench`, `fuzz_render_bench`,
`pretty_bench`. New parity/equivalence specs lock the behavior of each change.

### Changed — MCP server hardening & new tools

A broad pass over the MCP surface based on an external assessment. Highlights:

- **Structured errors** — every tool error carries a stable `error_code`
  (`NOT_FOUND`, `INVALID_ARGUMENT`, `QUERY_SYNTAX`, `NETWORK_ERROR`,
  `BUDGET_EXHAUSTED`, `PROJECT_BUSY`, `SCOPE_BLOCKED`, `TOOL_DISABLED`, …) plus
  `retryable`, surfaced in `structuredContent` alongside the human message.
- **Secret redaction** — `get_flow` and `get_repeater_context` now `[REDACTED]`
  Authorization/Cookie/Set-Cookie/API-key header values by default
  (`include_sensitive:true` to reveal), matching `send_request`.
- **Scope enforcement (BREAKING)** — active tools (`send_request`,
  `send_websocket`, `fuzz`, `mine`) refuse a target outside — or without — a
  configured scope (`SCOPE_BLOCKED`); pass `allow_unscoped:true` to override.
- **Budget-exhausted state** — fuzz/mine distinguish `budget_exhausted` from
  `done`, with `incomplete_reason` + remaining-candidate counts.
- **fuzz/mine audit** — `record_history: none|matched|all` records sent
  requests as History flows (per-result `flow_id`); status includes an audit
  block (target/rate/concurrency/budget/times).
- **Project lifecycle** — `list_projects`, `create_project`, `switch_project`,
  `delete_project` (dry-run + short-lived confirmation token).
- **New tools/params** — `ql_explain`, `preview_rule`/`update_rule`,
  `list_jobs`/`get_job`/`stop_job`, `send_request(repeater_id)`, `timeout_ms`,
  `body_mode`/`max_body_bytes`, QL `strict`, sitemap transport keying +
  `collapse_transport`, `effective_request`/`ignored_fields`, typed WebSocket
  frames, JWT `alg:none` warning, deterministic `gzip-compress`.

Deferred (need store-schema migrations, a proxy-dialer change, a decoder
converter-protocol change, or whole new subsystems, so out of scope for this
MCP-surface pass): fine-grained network `error_kind` (DNS vs TLS-verify vs
refused — the dialer collapses these); decoder `warning`/`partial` step states;
HMAC/JWT signature *verification* via a key reference; WebSocket handshake flows
in general History and subprotocol/extension negotiation; issue immutable
evidence snapshots, CWE/CVSS/tags, duplicate/merge, and SARIF export; and the
larger protocol/tooling backlog (gRPC/SSE first-class capture, crawler, passive
scanner, HAR/OpenAPI import).

### Added — protocol filter in History

WebSocket, gRPC, and SSE flows are now first-class in the History tab instead of
being indistinguishable from plain HTTP:

- **PROTO column** shows `WS` / `GRPC` / `SSE` (accented) for those flows; ordinary
  requests keep showing the scheme (`HTTP` / `HTTPS`).
- **New QL field `proto:`** — `proto:ws`, `proto:grpc`, `proto:sse`, `proto:http`
  (`websocket` is an alias for `ws`). WS is the 101 upgrade handshake; gRPC/SSE are
  matched by response Content-Type. `proto:http` is everything else, including
  still-pending flows. No database column or migration — it is derived from data
  gori already stores.

### Changed — clearer `/` filter guidance

The filter bars on the History, Sitemap, and Repeater tabs now surface what you
can type from the moment they open:

- The field hint no longer vanishes when the Scope lens is on (History, Sitemap) —
  the lens is already signalled by the `⇧S` chip, so the row keeps listing the
  filter fields instead of showing a bare `(in-scope only)`.
- Opening `/` with nothing typed now shows a standing hint of the available fields
  and a reminder that bare words are a free-text search (the row used to stay blank
  until you started typing).
- History and Sitemap idle hints now include the new `proto:` field.

### Changed — four tabs renamed (BREAKING)

Four tools were renamed for clearer, more conventional names. The rename is
tool-wide: TUI, `gori run`, the MCP server, config, and the on-disk database.

| Old | New |
|-----|-----|
| Replay | **Repeater** |
| Prism | **Probe** |
| Findings | **Issues** |
| Convert | **Decoder** |

**Automatic (no action needed):**

- **Existing project databases** migrate in place on first open (schema V32–V34).
  Repeater sessions, Probe issues/suppressions, triaged Issues, entity links, and
  the saved scan mode are all preserved under the new names. No data is lost.
- **Existing `settings.json`** is read with back-compat: saved tab order/visibility,
  layout preview toggles, the Decoder (`convert`) section, and custom keybindings on
  renamed verbs are all remapped to the new names on load, and rewritten on next save.

**Breaking — update your scripts/integrations:**

- **MCP tool names.** `create_replay`/`update_replay`/`delete_replay` →
  `create_repeater`/`update_repeater`/`delete_repeater`; `get_replay_context` →
  `get_repeater_context`; `list_findings`/`get_finding`/`create_finding`/`update_finding`
  → `list_issues`/`get_issue`/`create_issue`/`update_issue`; `convert` → `decode`.
  Input fields `replay_id`/`save_as_replay`/`finding_id` → `repeater_id`/`save_as_repeater`/`issue_id`.
  Output keys `findings` → `issues`, `tui_on_replay_tab`/`tui_replay` → `…repeater…`.
- **CLI subcommands.** `gori run replay` → `gori run repeater`; `gori run prism` →
  `gori run probe`; `gori run findings` → `gori run issues`.
- **Exported files.** `findings.md`/`findings.json` → `issues.md`/`issues.json`.
