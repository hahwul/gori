# DESIGN.md — gori architecture & principles

This document is the target of the `DESIGN.md §N` references scattered through the
source comments. It was reconstructed from those comments and the code; treat any
wording you find thin as an invitation to tighten it against the implementation, not
as settled scripture.

## §1 Principles (P0–P8)

gori's code cites these inline as `(P4 — the human decides)` etc.

- **P0 — Minimal.** Don't build a hierarchy or abstraction speculatively. A single
  base `Gori::Error`; subtype only when a `rescue` must discriminate. Add structure
  when a concrete second caller forces it, not before.
- **P1 — One execution path.** A `Verb::Definition` is the single source of truth: the
  same `#call` runs whether fired by a keybinding, the command palette, or the space
  menu. No feature gets a private dispatch path.
- **P3 — No premature generalization of data.** Model what is actually there. The
  sitemap makes every distinct URL segment its own node rather than inventing path
  templates; folding is an explicit, reversible view choice.
- **P4 — The human decides.** Intercept holds an in-flight message *indefinitely* for a
  human forward/edit/drop decision. Scope, match&replace, and active-scan gates are
  explicit and auditable, never inferred or auto-applied behind the operator's back.
- **P5 — Mediated state.** Mutable state is reached only through a narrow facade —
  `Verb::ExecContext` for verbs, `Host` for tab controllers, `OverlayHost` for
  overlays. A controller never touches another controller, `Runner`, or raw
  proxy/store state directly.
- **P6 — Never stall the data path.** The proxy and the Store writer are hot paths:
  batch bursts into one transaction to amortize fsync, keep socket writes immediate,
  stream bodies untouched. Persistence and analysis happen off the critical path.
- **P7 — Raw bytes are the truth.** The captured wire bytes are canonical. Pretty
  views, decodes, and highlights are derived and display-only; they are never written
  back onto the wire lossily. A message the codec can't fully parse still yields its
  octets.
- **P8 — Pull, not push.** There is no queue, inbox, or ranking. History is a flat log;
  you *find* things with a query (QL), and per-row signals are fetched lazily when a
  row is on screen.

(There is no P2; `CSP2` in `probe/` is a Content-Security-Policy version, not a
principle.)

## §2 Architecture & data flow

```
client ──▶ Proxy (proxy/) ──▶ target
             │  intercept (P4), scope, match&replace, host-overrides
             ▼
          Store (store.cr)         single-writer fiber + Channel (P6)
             │  flows / ws msgs / h2 frames / findings / notes / sessions
             ▼
   ┌─────────┴───────────┬────────────────────┐
  TUI (tui/)          CLI (cli/run.cr)     MCP (mcp/tools.cr)
   verbs + tabs        gori run …           agent tools
```

Three surfaces, one engine layer. The TUI, the `gori run` CLI, and the `gori mcp`
server all build on the same lower-level engines (`Repeater::*`, `Fuzz`, `Miner`,
`Sequencer`, `Discover`, `Probe`, `QL`, `Store`); they do **not** share a dispatcher.
Surface parity ("every action is also a CLI subcommand and an MCP tool") is a
convention, achieved by each surface calling the shared engines — not by one code path.
Keeping the surfaces thin over fat shared engines is what makes that convention cheap
to hold.

Concurrency: gori runs on Crystal's cooperative fiber scheduler (no `-Dpreview_mt`).
`Store` funnels all writes through one fiber fed by a buffered `Channel`; reads use the
WAL connection pool directly. `Scope` / `Rules` / `HostOverrides` / `Interceptor` each
guard an in-memory snapshot with a `Mutex` and keep a lock-free fast path (`Atomic`
counters) for the common no-op case on the proxy hot path. Cross-*process*
coordination (a second `gori mcp` process driving intercept decisions, or capture
ownership of a project) goes through flock-based `CaptureLock` and Store bridge tables,
not shared memory.

## §3 Scope

The Scope lens is an ordered include/exclude rule set (host / string / regex) that
decides which flows are "in scope". It gates capture, intercept, and active probing so
the operator only ever acts on authorized targets (P4). Rules live in the Store and are
mirrored into an in-memory `Scope` snapshot (`scope.cr`) read on the proxy hot path;
SQL-side and in-memory evaluation are kept in parity. The sitemap and History surface
in-scope vs out-of-scope inline.

## §4 Query language (QL)

QL (`ql.cr`) is a Lucene/KQL-style boolean filter over captured flows: bare terms,
`field:value` predicates (`host:`, `status:`, `method:`, `size:`, `dur:`, `header:`,
`proto:` …), `~`-prefixed regex, and `AND`/`OR`/`NOT`/grouping. It compiles to a
byte-safe SQL predicate (regex via a `SafeRegexp` override so invalid patterns fail
closed, not injection-open). QL is the only way you navigate History — there is no
queue or ranking (P8). It backs the History `/` filter bar, `gori run history`, and the
MCP `list_history`/`ql_*` tools identically.

## §5 Rendering & chrome

The TUI builds gori's chrome (tab bar, panes, overlays) and its views, nothing more
(P0 — minimal). Rendering is a pure function of state onto a double-buffered `Screen`
that diffs against the previous frame and emits only changed cells (the cost was
`set_cell`, not highlighting). Views hold ephemeral display/edit state and expose
`render(screen, rect, focused)`; controllers interpret input and own persistence
through `Host` (P5). Overlays are modal cards centered over the body. Theming is a
`Palette` record with built-in and user themes, switched at runtime.

## §6 Data model (summary)

The Store's domain types live in `store/models.cr`; the schema and its ordered
migrations in `store/schema.cr`.

- **Flow** — one captured request/response exchange (plus WS messages / h2 frames /
  SSE events for streaming protocols). Raw request/response bytes are stored verbatim
  (P7); FTS text is derived for search.
- **Sitemap node** — one node per distinct URL segment (P3), with operator path tags.
- **Issue** — the final output: a human-confirmed finding, triaged, optionally linked
  to the flow/note/session that evidences it.
- **Note** — the running scratchpad / report.
- **Sessions** — persisted Repeater / Fuzzer / Miner / Sequencer / OAST workbench state.

---

*Keep this document honest against the code. When you change a subsystem it describes,
update the matching section; when you cite a principle inline, use the numbers above.*
