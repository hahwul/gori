# DESIGN.md: gori architecture and principles

gori's source comments cite this file two ways: by principle (`(P4)`, `(P6/P7)`) and by
section (`DESIGN.md §4`). Both are load-bearing shorthand: roughly 120 principle citations
across 49 files, so the numbering here is stable. Sections keep their numbers and
principles keep their labels even when the prose around them is rewritten.

Anchor convention: every section carries an explicit `<a id="sN">` and every principle an
`<a id="pN">`, so `DESIGN.md#s4` and `DESIGN.md#p7` keep resolving no matter how a heading
is later reworded.

This document describes what the code does today, reconstructed from the code and its
comments. Where a principle and the code disagree, one of the two is a bug: record which
in [§7](#s7) rather than quietly widening the principle to fit.

<a id="s1"></a>

## §1 Principles (P0 to P8)

Each principle is one rule plus where to go read it in the tree.

<a id="p0"></a>

### P0: Minimal

Do not build a hierarchy or an abstraction speculatively; add structure when a concrete
second caller forces it, not before.

`src/gori.cr` defines a single `Gori::Error` base and subtypes only when a `rescue` has to
discriminate. `src/gori/tui/screen.cr` keeps `Screen` to the primitives gori's own chrome
needs, "minimal, grow-as-needed widgets" ([§5](#s5)).

<a id="p1"></a>

### P1: One execution path

A feature is declared once and gets no private dispatch path.

A `Verb::Definition` (`src/gori/verb.cr`) is the one source of truth for a keybinding, a
command-palette entry, and a space-menu entry; all three run the same `#call`. Bindings are
declared only in `src/gori/verb/keymap.cr`, and `src/gori/tui/palette.cr` and
`src/gori/tui/space_menu.cr` both go through the registry rather than re-implementing the
action.

Reach: P1 holds inside the TUI. The `gori run` CLI and the `gori mcp` server do not read the
verb registry; they reach feature parity by calling the same engines ([§2](#s2)), which is a
convention rather than a shared code path. That gap is real, known, and under decision in
issue #357.

<a id="p2"></a>

### P2: not assigned

There is no P2. The label has never been used in the tree, and `CSP2` in
`src/gori/probe/passive/security_headers.cr` is a Content-Security-Policy version, not a
principle. It is left vacant rather than closed up; see [Numbering](#numbering).

<a id="p3"></a>

### P3: No premature generalization of data

Model what the traffic actually contains. Collapsing it into templates is an explicit,
reversible view choice, never a parse-time assumption.

`src/gori/sitemap.cr` gives every distinct URL segment its own node, and only then folds
numeric runs and opaque ids into `{uuid}` / `{hex}` / `{date}` group nodes, above an explicit
threshold, keeping the real children underneath. Folding happens when the tree is built;
the stored rows keep the URL exactly as captured.

<a id="p4"></a>

### P4: The human decides

Holding, editing, dropping, rewriting, and active probing are operator decisions, made
explicitly and auditably, never inferred or auto-applied behind the operator's back.

`src/gori/interceptor.cr` and `src/gori/tui/runner.cr` hold an in-flight message
*indefinitely* for a forward / edit / drop decision; the only timeout is an opt-in guard for
an attached agent, and with no agent ever attached the hold stays indefinite.
`src/gori/rules.cr` (match&replace) is human-configured and persisted per project. Scope,
sandbox, and the active-scan gates are all explicit ([§3](#s3)).

<a id="p5"></a>

### P5: Mediated state

Mutable state is reached only through a narrow facade; nothing reaches across into another
component's raw state.

Verbs get `Verb::ExecContext` (`src/gori/verb/context.cr`) and never touch TUI, proxy, or
store state directly. Tab controllers get `Host` (`src/gori/tui/tab_controller.cr`) and never
call another controller or `Runner`. The Store writer fiber fires replies and events only
*after* commit, so nothing observes uncommitted rows (`src/gori/store.cr`). Project state is
isolated per project DB (`src/gori/project.cr`).

<a id="p6"></a>

### P6: Never stall the data path

The proxy and the Store writer are hot paths; persistence and analysis happen off the
critical path.

`src/gori/store.cr` batches a burst of writes into one transaction to amortize fsync.
`src/gori/proxy/server.cr` and `src/gori/proxy/upstream.cr` set `sync = true` so writes go out
immediately. `src/gori/proxy/head_rewriter.cr` rewrites the head while the body streams
untouched, and body rewrites are opt-in precisely because they cost the zero-buffer path
(`src/gori/proxy/codec/body.cr` streams with `max_bytes` at `Int64::MAX` when forwarding).

<a id="p7"></a>

### P7: Raw bytes are the truth

The captured wire bytes are canonical. Pretty views, decodes, and highlights are derived and
display-only, and a message the codec cannot fully parse still yields its octets.

`src/gori/proxy/codec/http1.cr` never rejects malformed input on capture or replay, only on
the live MITM path where forwarding it would be ambiguous. `src/gori/pretty.cr` never mutates
the input slice. `src/gori/store/models.cr` stores head and body as byte-exact wire octets,
with the parsed columns as a queryable projection. The h2 raw frame log and the WS raw frames
stay the truth even when the assembled view is incomplete.

<a id="p8"></a>

### P8: Pull, not push

There is no queue, inbox, or ranking. You *find* things with a query, and per-row signals are
computed only when a row is on screen.

`src/gori/tui/history_view.cr` is a flat append-only log with a QL bar (`/`) as the only
navigation. `src/gori/store/reads.cr` fetches a flow's passive-signal tags lazily, per
on-screen row. `src/gori/ql.cr` is the analysis surface ([§4](#s4)).

<a id="numbering"></a>

### Numbering

The set is deliberately not contiguous. P2 stays vacant.

Renumbering was considered and rejected: the labels carry roughly 120 citations across 49
source files, so closing the hole would invalidate every citation for a cosmetic gain, and
any comment missed in that commit would silently start asserting a different principle. A
future principle should take P9 rather than fill P2.

P0, P1, P4, P5, P6, P7, and P8 are cited inline in `src/`. P3 is cited once, in
`src/gori/sitemap.cr`.

<a id="s2"></a>

## §2 Architecture and data flow

```
client ──▶ Proxy (proxy/) ──▶ target
             │  scope + sandbox gate, intercept (P4), match&replace, host overrides
             ▼
          Store (store.cr)          single writer fiber + Channel (P6)
             │  flows / ws messages / h2 frames / sse events / issues / notes / sessions
             ▼
   ┌─────────┴───────────┬─────────────────────┐
  TUI (tui/)          CLI (cli/run.cr)      MCP (mcp/tools.cr)
  verbs + tabs        `gori run ...`        agent tools
```

Three surfaces, one engine layer. The TUI, the `gori run` CLI, and the `gori mcp` server all
build on the same lower-level engines (`Repeater::*`, `Fuzz`, `Miner`, `Sequencer`,
`Discover`, `Probe`, `QL`, `Store`). They do **not** share a dispatcher. Surface parity
("every action is also a CLI subcommand and an MCP tool") is a convention, held by each
surface calling the shared engines rather than by one code path. Keeping the surfaces thin
over fat shared engines is what makes that convention cheap to hold, and every parity gap
found so far has been in the surface layer, not the engines.

Concurrency: gori runs on Crystal's cooperative fiber scheduler, never `-Dpreview_mt`.
`Store` funnels all writes through one fiber fed by a buffered `Channel`; reads use the WAL
connection pool directly. `Scope`, `Rules`, `HostOverrides`, and `Interceptor` each guard an
in-memory snapshot with a `Mutex`, and `Rules` and `Interceptor` additionally keep a lock-free
`Atomic` counter so the common no-op case on the proxy hot path takes no lock at all.
Cross-*process* coordination (a second `gori mcp` process driving intercept decisions, or
capture ownership of a project) goes through the flock-based `CaptureLock` and Store bridge
tables, not shared memory.

<a id="s2-1"></a>

### §2.1 Layering contract

Core subsystems do not know that a surface exists. `store/`, `proxy/`, `probe/`, `fuzz/`,
`miner/`, `discover/`, `sequencer/`, and `oast/` must not reference `Tui::`, `CLI::`, or
`MCP::` in code. Checkable:

```sh
grep -rnE '\b(Tui|CLI|MCP)::' \
  src/gori/{store,proxy,probe,fuzz,miner,discover,sequencer,oast}/ \
  src/gori/{store,probe,fuzz,miner,discover,sequencer,oast}.cr
```

(There is no `src/gori/proxy.cr`; the proxy is directory-only.) Today that returns exactly
one hit: a comment in `src/gori/probe/group.cr` naming the CLI formatter that delegates to
it. A comment may point at a caller; code may not.

Dependencies run one way. Surfaces depend on engines, engines depend on `Store` and the
codecs, and nothing depends on a surface. `src/gori/sitemap.cr` and `src/gori/notes.cr` are
the pattern to copy: the data model and the pure algorithms live in a surface-free module,
and `Tui::SitemapView` and `gori run sitemap` are thin layers over it, which is why the CLI
report and the interactive tab cannot drift apart.

One caveat worth naming: the CLI reaches into `MCP::Serialize` for JSON output
(`src/gori/cli/run/intercept.cr`, `src/gori/cli/run/history.cr`). That is surface to surface,
not core to surface, so it does not breach the rule above, but the shared JSON shape should
move to a neutral module the day a third caller needs it (P0: when the second caller forces
it, and it now has).

<a id="s3"></a>

## §3 Scope

Cited from `src/gori/scope.cr`.

Scope is an ordered include/exclude rule set evaluated over `scheme://host/target`. A rule has
a kind (include or exclude) and a match type: `host` (exact, subdomain, or `*` glob,
case-insensitive), `string` (case-insensitive substring), or `regex` (case-sensitive).

It has three distinct jobs, and conflating them is the usual source of bugs:

1. **Display lens.** Everything is captured regardless. When scope is enabled, History and
   Sitemap show only in-scope flows, and mark in-scope versus out-of-scope inline.
2. **Intercept gate.** Out-of-scope flows are not held for a decision.
3. **Sandbox: a hard containment gate.** When on, a request to a host that is not allowlisted
   is blocked outright and still recorded, so the operator sees the blocked attempt (P4/P7).
   A scope with no include rules blocks everything rather than allowing everything: the gate
   fails closed, on purpose, and `Probe::Active` shares that same decision.

Rules live in the Store and are mirrored into an in-memory `Scope` snapshot read on the proxy
hot path; SQL-side and in-memory evaluation are deliberately kept in parity so a query and the
live gate can never disagree.

Active traffic (repeater, fuzz, mine, sequence, discover, active probe) is gated on the same
rule set, through one chokepoint: `Gori::Outbound` (`src/gori/outbound.cr`). The active senders
`Fuzz::Sender` and `Repeater::Sender` take it as a **constructor argument**, so an ungated
sender does not compile (P5). It carries two layers:

- **Layer 1**, up front and once: the include/allowlist decision. Its strictness is the only
  thing that legitimately varies per surface, and the variants are named rather than
  re-derived at each call site: `Outbound.agent` (MCP, refusing anything not included,
  including an unconfigured project), `Outbound.cli` (`gori run`, where an unconfigured
  project stays permissive), `Outbound.interactive` (TUI, no up-front gate because the
  operator typed the target).
- **Layer 2**, per send: Sandbox mode always, plus explicit EXCLUDE rules for an automated
  sweep. Identical on every surface, and applied even when Layer 1 was waived.

Both layers judge the URL anchored on the host actually being **dialled**, not the one in the
request line (`Outbound.scope_url`). A raw request may deliberately carry an absolute-form
request line pointing somewhere else, which is a legitimate Host-header, cache-poisoning, or
SSRF test and still goes out verbatim (P7); scoping on that spoofed host would let an anchored
include rule authorise a send to a different origin.

Waiving Layer 1 is only reachable through `--allow-unscoped` / `allow_unscoped:true`, or a
genuinely absent project. Either way the result is a named `Unscoped(reason)` that shows up in
the audit line, never a nil that silently skips the gate.

<a id="s4"></a>

## §4 Query language (QL)

Cited from `src/gori/ql.cr`.

QL is a Lucene/KQL-style boolean filter over captured flows: bare terms for free text,
`field:value` predicates, `~`-prefixed regex, and `AND` / `OR` / `NOT` / grouping.

- `:` fields: `host` `path` `method` `scheme` `proto` `status` `size` `reqsize` `respsize`
  `dur` `header` `body`
- `~` regex on: `host` `path` `url` `header` `body`
- comparison ops (`<=` `>=` `<` `>` `=`) apply to `status`, `size`, `reqsize`, `respsize`,
  `dur`

It compiles to a SQL `WHERE` fragment plus bound params. Values are always parameterised,
never interpolated, so the projection columns stay injection-safe. Regex terms are evaluated
by the `Gori::SafeRegexp` function that `Store` installs into the connection
(`SafeRegexp.install`, `src/gori/store.cr`), so an invalid pattern or a byte-unsafe body
fails closed rather than crashing the scan.

QL is the only way you navigate History, because there is no queue and no ranking (P8). One
grammar backs all of it: the History `/` filter bar, `gori run history`, the MCP
`list_history` and `ql_*` tools, and the other filter surfaces built on `filter_ast.cr`.

<a id="s5"></a>

## §5 Rendering and chrome

Cited from `src/gori/tui/screen.cr`.

The TUI builds gori's chrome (tab bar, panes, overlays) and its views, nothing more: P0
applied to widgets, "minimal, grow-as-needed widgets" rather than a general toolkit. `Screen`
is an immediate-mode drawing surface with bounds-checked writes; the backend keeps its own
front/back cell grid and, on flush, forwards only the cells that changed since the previous
frame. Measured cost lives in `set_cell`, not in highlighting, which is why `Screen` interns
single-cell strings.

Rendering is a pure function of state. Views hold ephemeral display and edit state and expose
`render(screen, rect, focused)`; controllers interpret input and own persistence through
`Host` (P5). Overlays are modal cards centred over the body. Theming is a `Palette` record,
with built-in and user themes switched at runtime.

Width is measured, never assumed: `Screen.draw_width` reports the cells a string will
occupy, and views that draw per grapheme cluster sum the width per cluster so a wide
character is never half-drawn.

<a id="s6"></a>

## §6 Data model

The Store's domain types live in `src/gori/store/models.cr`; the schema and its ordered
migrations in `src/gori/store/schema.cr`.

- **Flow**: one captured request/response exchange, plus WS messages, h2 frames, and SSE
  events for streaming protocols. Raw request and response bytes are stored verbatim (P7);
  the FTS text is derived for search. Targets are stored ABSOLUTE-form, which is the wire
  truth.
- **Sitemap node**: one node per distinct URL segment (P3), with operator path tags.
- **Issue**: the final output, a human-confirmed finding, triaged, optionally linked to the
  flow, note, or session that evidences it.
- **Note**: the running scratchpad and report.
- **Sessions**: persisted Repeater / Fuzzer / Miner / Sequencer / OAST workbench state.

Directories are `0700` (`Paths::DIR_MODE`) and the DB, plus its `-wal` and `-shm`
sidecars, are `0600` (`Store.harden_permissions`).

<a id="s7"></a>

## §7 Decision log

Design decisions that refine a principle, newest last. Append here instead of editing a
principle's wording, so that the label a source comment cites keeps meaning what it meant when
the comment was written.

Format: one `### YYYY-MM-DD: title` block per decision, naming the principle it refines and
the issue or PR that settled it. Adding an entry must not require restructuring anything
above it.

### 2026-07-25: this document restored

Refines: none. Issue #353.

`DESIGN.md` was removed in `ae7674a` and never rewritten, leaving the P0 to P8 labels cited in
47 files with no definition anywhere. Restored from `ae7674a^` and re-verified against the
tree, with the numbering kept as it was ([Numbering](#numbering)) and the layering contract in
[§2.1](#s2-1) written as a runnable check rather than a claim.

### 2026-07-25: one reload semantic for the active-traffic scope gate

Refines: [P5](#p5). Issue #354.

The scope gate on active traffic was enforced at roughly twenty call sites across three
surfaces, and the three disagreed on when a running job re-read the rules. MCP re-read them on
a throttled interval; `gori run` snapshotted at start-up and closed the store, so it could not
re-read at all; the TUI re-read only as a side effect of its own `data_version` poll. The
practical result was that a mid-run EXCLUDE or Sandbox toggle stopped an MCP sweep, was
invisible to a CLI sweep, and stopped a TUI sweep by accident rather than by design.

`Gori::Outbound` now owns the reload: before each Layer-2 check it re-reads the scope from its
store, throttled to `Outbound::RELOAD_INTERVAL` (1s). A per-send DB read is too heavy at high
concurrency, and the clock is advanced *before* the blocking reload so concurrent worker fibers
cannot stampede the store. A failed reload is swallowed and the last-known rules stay in force,
degrading to the old snapshot behaviour rather than to allow-everything.

What that buys is uniform for every LONG-RUNNING job (fuzz, mine, sequence, minimize, active
probe) on all three surfaces, which is where the divergence actually mattered. A one-shot
Repeater send builds a fresh decision per send, so the throttle window never elapses within it
and no reload fires; it reads whatever rules its scope already holds, which for the TUI is the
live session scope the `data_version` poll keeps current.

MCP's semantic won because it is the only one that honours a policy change the operator makes
*while* a sweep is running, which is exactly when they most need it to stop. Adopting it on the
CLI meant the read connection now lives as long as the run (`Outbound#close` releases it)
rather than being closed immediately after the snapshot.

The gate is Store-mediated rather than pushed: nothing notifies a running job of a rule change,
the job pulls the current rules on its own schedule ([P8](#p8)). One consequence is worth
stating, because it is a deliberate tradeoff and not an oversight: a rule written at T is
honoured somewhere in `[T, T + RELOAD_INTERVAL]`, not at T, and sends inside that window use
the previous decision. Making it exact would need a per-send read on the hot path, which
[P6](#p6) rules out.

### 2026-07-25: run assembly belongs to the tool, option parsing to the surface

Refines: [P1](#p1). Issue #356 (fuzz, the reference implementation).

Every multi-surface tool re-implemented its "assemble a run" pipeline once per surface. For the
fuzzer, *template parse → auto-mark → payload sets → matcher → config → generator → sender →
engine* existed three times over (TUI `build_engine`, `gori run fuzz`, MCP `build_fuzz_job`),
and the copies had drifted on things a user can see: the TUI never applied the project's
hostname overrides to a fuzz send, and both `gori run fuzz` and MCP ran `Env.expand` over a
seeding flow's target *twice*, so a var whose value itself contained a `$TOKEN` resolved on
those two surfaces and not in the TUI.

`Fuzz::PlanOptions` (a plain struct) plus `Fuzz::Plan.build(options, outbound)` splits the two
jobs that were tangled: parsing an input format is surface-specific and stays put — an
`OptionParser` on the CLI, the args hash on MCP, view state in the TUI — while everything
downstream of the normalized options has exactly one implementation, and `Fuzz::Engine.new` has
exactly one call site. The same split is intended for `Miner`, `Sequencer`, `Discover` and
`Repeater`.

Three specifics worth recording, because they are choices rather than mechanics:

- **The `Outbound` is an argument, never built by the builder.** Layer-1 strictness differs per
  surface on purpose (`Outbound.agent` / `.cli` / `.interactive`, see the entry above).
  Constructing one inside `Plan.build` would collapse that distinction into whichever policy
  was hard-coded, which is exactly the kind of quiet unification this refactor must not do.
- **`Env.expand` runs once, on the raw template and on the resolved target.** Twice is not a
  no-op: expansion is a single pass, so a second pass resolves tokens that the first pass
  *produced*. Once is the behaviour a user can reason about.
- **The scope gate reads the template's BASELINE rendering, not its raw first line.** The TUI's
  template arrives already marked, so the raw line would have fed `/find?term=§VAL§` into the
  Layer-1 check there while feeding `/find?term=VAL` from the CLI and MCP — and a `§` in a path
  position defeats an anchored include rule. Rendering each position's own default back out is
  marker-free on all three.

A surface still owns its own error wording: `Fuzz::PlanError` carries a machine-readable
`reason`, and each surface renders the sentence naming its own flags (`--auto` / `auto:true` /
`^A params`). Sharing the assembly must not flatten three different vocabularies into one.

---

*Keep this document honest against the code. When you change a subsystem it describes, update
the matching section; when you cite a principle inline, use the labels above.*
