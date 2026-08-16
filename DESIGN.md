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
`MCP::` in code. Enforced by `spec/layering_spec.cr`; the same set is checkable by hand:

```sh
grep -rnE '\b(Tui|CLI|MCP)::' \
  src/gori/{store,proxy,probe,fuzz,miner,discover,sequencer,oast,authorize}/ \
  src/gori/{store,probe,fuzz,miner,discover,sequencer,oast,authorize}.cr
```

(There is no `src/gori/proxy.cr`; the proxy is directory-only.) A comment may point at a
caller; code may not — so the assertion is that **every hit is a comment line**, not that
there are N of them. The count is not the check precisely because it moves whenever one of
those comments is reworded: this paragraph claimed "exactly one hit" for long enough that
the true figure reached twelve across four files, which is the failure mode the spec exists
to remove.

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

### 2026-07-26: the verb registry is a TUI concern, and `ExecContext` is a catalogue

Refines: [P1](#p1). Issue #357.

Two comments described a system that does not exist. `src/gori/verb.cr` promised that one
`Verb::Definition` drives "a keybinding AND a command-palette entry (and later an MCP tool +
CLI subcommand)", and `src/gori/verb/context.cr` called `ExecContext` "thin … deliberately
(P0)". Neither the later nor the thin was true: `grep -rn 'Verb::Registry\|Verb::Definition'
src/gori/cli src/gori/mcp` returns nothing, and the interface declares 266 abstract methods.
Both read as descriptions of the present, which cost reviewers time. The comments are now
corrected; the structure is deliberately unchanged.

Measured on `main` at `57f1812`:

- `ExecContext` requires **266** abstract methods: 42 in `verb/context.cr` and 224 more spread
  across the twenty per-tool files in `verb/context/`, which exist only to hold declarations.
- `Tui::Runner` (with its `runner/*.cr` mixins) defines **534** methods and implements all
  266, none missing. It is the only production implementor; `spec/support/fake_context.cr` is
  a recording double.
- Only the 42 root ones are app chrome and cross-tool actions. The other 224 are tool intents
  grouped by tool (repeater 28, issues 23, probe 22, history 17, fuzzer 17, jwt 13 …) —
  surface-neutral in name.

Collapsing `ExecContext` into direct `Runner` calls was considered and rejected. It would
delete the 266 declarations and the indirection, not the 266 implementations, which the
palette and keymap still have to invoke — a large mechanical edit for no behavioural gain. It
would also destroy the two things the interface does buy: one enumerable catalogue of every
action a verb can trigger, and a one-way dependency, since `verb/` names no `Tui::` in code
([§2.1](#s2-1)). Keeping a 266-method abstraction is not a [P0](#p0) minimalism claim, and it
should stop being written up as one.

Wiring CLI and MCP into the registry was also rejected, for a reason worth recording because
it is not obvious from the method names. Those 224 tool intents are surface-neutral in name
and TUI-coupled in semantics: `repeater_send` means "send the ACTIVE sub-tab",
`probe_rule_toggle` means "toggle the HIGHLIGHTED row". A CLI or MCP caller has no selection,
only an id. Making them callable from another surface therefore requires an argument schema
so an intent can name its target — the field `Verb::Definition` records as absent. That
schema is the prerequisite, not a follow-up to the wiring, and it is a project of its own
across ~224 intents.

So P1's reach stays where [P1](#p1) already describes it: one execution path inside the TUI,
parity elsewhere by calling the same engines. Read P1's closing sentence — "that gap is real,
known, and under decision in issue #357" — as settled by this entry: the gap is deliberate, and
what would close it is the argument schema, not registry wiring. If CLI/MCP parity work resumes
at the rate it ran before, revisit, but open the argument-schema issue first.

### 2026-07-26: Discover's seed waives Layer 1, never Layer 2

Refines: [P4](#p4). Issue #364, surfaced by the review of #354.

`Discover::Engine#seed_frontier` put the seed, `<origin>/robots.txt`, `<origin>/sitemap.xml` and
the origin-root soft-404 calibration straight onto the frontier with no `bounded_url` call.
Every URL the crawl derived afterwards was gated normally, which is why it read as a deliberate
seed exemption rather than a hole, but only the *path-confinement* half had ever been reasoned
about (well-known paths live at the origin, so a run confined to `/app/` has to step outside its
subtree to find them). The scope gate rode along with it by accident.

The exposure was not uniform across the four, and the difference is what settles the decision. A
Layer-1 `in_scope` verdict already implies a clean Layer 2, because `Scope#sandbox_blocks?` and
`Outbound#evaluate` both route through `allowlisted_unlocked?` — so for the **seed** the gap only
ever opened where Layer 1 was waived, which is the TUI and any `--allow-unscoped` run. The three
**derived** requests were exposed on every surface, since they are anchored on `Url.origin` and a
path-scoped include rule never covers them.

The two-layer split in [§3](#s3) already answers this, and the answer is asymmetric on purpose:

- **Layer 1 stays waived for all four.** The seed is what a human typed, which is the same
  argument `Outbound.interactive` makes for the TUI, and every surface has already made that
  decision before the engine runs (`Outbound.agent` refuses an out-of-scope seed, `.cli` refuses
  one on a configured project, `.interactive` waives by name; the CLI and MCP enforce the verdict
  right after `Plan.build`, before a single send). `robots.txt` and `sitemap.xml` inherit it:
  they are derived from a seed the operator was already authorised to hit and live at that same
  origin by construction. Re-asking the include question here would only re-ask what the surface
  just answered, and on a path-scoped include rule it would break the calibration on every run
  that has one.
- **Layer 2 now applies to all four.** Sandbox's documented promise in [§3](#s3), that a request
  to a host which is not allowlisted is blocked outright, carries no "unless the operator typed
  it" clause, and `Outbound.interactive`'s own contract already says Layer 2 still hard-stops the
  send. "The operator chose this target" was never an argument about Sandbox. Explicit EXCLUDE
  rules come with it (`sweep_block` semantics, not `send_block`): discover is the most automated
  sweep gori has, and its every other URL is judged by the same predicate.

Three specifics worth recording:

- **A blocked seed fails the run, loudly.** The verdict is taken in `Engine#initialize` and
  `Engine#start` emits it as the run's sole terminal `ErrorEvent` (`Engine::SEED_BLOCKED`); it is
  not a skipped enqueue. A blocked seed blocks everything derived from it, so the alternative is
  a run that finishes with zero findings and no reason, which an operator reads as "there is
  nothing there" rather than "gori sent nothing" ([P4](#p4)). A blocked `robots.txt`/`sitemap.xml`
  is skipped silently instead: the crawl is still meaningful without it.
- **A gated calibration still routes its two dependants.** `@seed_calibration_dir` is set whether
  or not the Calibrate task survives the gate. Without it a robots/sitemap outcome falls back to
  `record_page`, whose raw-status trust reports both as findings on a 200-everything server,
  which is the exact false positive the calibration exists to prevent. With it and no baseline
  they go uncounted: no baseline, no claim.
- **The gate is the engine's injected `ScopePolicy`, not an `Outbound`.** `StoreScope#allowed?`
  is already the negation of `sandbox_blocks? || excluded?`, which is `sweep_block`'s predicate,
  and the engine stays Store-free, which is the whole reason that seam exists.

What this does **not** close, deliberately, because each is a separate decision: brute-force and
calibration probes are still authorised by their *directory* rather than per URL, so a `string`
or `regex` EXCLUDE that matches a child but not its parent does not stop them; and
`Plan.resolve_policy` still hands an unconfigured scope an `OpenScope`, so Layer 2 is absent
entirely on a project with Sandbox on and no rules. Both are closed by the two entries below.

### 2026-07-26: a directory verdict does not authorise the URLs under it

Refines: [§3](#s3). Issue #391, the remaining half of the #364 review.

`enqueue_probes` was the only `@frontier <<` site with no gate: it built `Url.parse("#{bl.dir}#{cand}")`
and pushed a Probe straight onto the frontier, and `process_calibrate` sent `"#{dir}#{bogus_name}"`
`calibrate_probes + extensions.size` times the same way. With the defaults that is **~278 real
requests per calibrated directory on one `allowed?` answer about the directory**.

The reason a directory verdict cannot stand in for its children is that only some rule kinds are
monotone under a path append. `host` rules and `string` INCLUDEs are; `string` and `regex`
EXCLUDEs are not, and neither are the `regex` INCLUDEs Sandbox reads as its allowlist — any
`$`-anchored or length-bounded pattern matches a directory and refuses everything beneath it. So
an EXCLUDE on `logout` / `signout` / `shutdown`, the canonical "do not touch destructive
endpoints" rule, was silently ignored by the brute-forcer even though `logout` ships on line 41
of the built-in wordlist, alongside `admin`, `actuator/env`, `.git/config` and `.env`.

The path confine was escapable by the same append: `Url.parse` collapses dot-segments, so a
wordlist entry of `../admin` under an `/app/`-confined run re-parsed to `/admin`, and
`@confine_path` lived only inside `bounded_url`, which probes never reached.

The fix splits by layer rather than by call site, because the two layers have different contracts:

- **Layer 2 moves to `send_with_retries`,** the single funnel all three send sites pass through.
  Calibration probes are built by a *worker* at send time from a random bogus name, so no
  enqueue-time gate can see them at all; this is the only line that can judge them. Brute-force
  candidates are additionally gated in `enqueue_probes`, which keeps a refused one out of the
  frontier and out of `per_dir_cap` instead of spending both on a send that will be refused.
  A refusal returns a benign `Engine::SCOPE_REFUSED` Result in the shape `CappedBackend` already
  uses for the request cap, and is **not** counted as an error: it is a decision the operator
  asked for, not a failure of the run.
- **The path confine moves to `enqueue_probes` only,** via the `confined?` predicate now shared
  with `bounded_url`. It deliberately does *not* go on the send chokepoint: the origin-root
  calibration and the two well-known paths waive the confine on purpose (previous entry), and
  gating there would refuse them on every path-scoped run.
- **Layer 1 (`containment` / `boundary?`) is deliberately NOT re-asked per probe.** It was
  answered for the directory, which is what the crawl actually reached, and [§3](#s3) makes
  Layer 1 the layer whose strictness legitimately varies per surface. Re-asking it would also
  mean a narrow anchored include silently disables brute-force under a directory that include
  itself admitted. Layer 2 is the layer that is identical everywhere, and it is the one that now
  bites every send.

### 2026-07-26: a rule-less scope is not an absent one

Refines: [§3](#s3). Issue #392.

`Plan.resolve_policy` returned `OpenScope` for `scope.nil? || verdict.unscoped?`, and
`unscoped?` is true exactly when `Scope#configured?` is false — that is, whenever the project's
scope has no *rules*. `OpenScope#allowed?` is unconditionally true, so Layer 2 was absent for the
entire run.

Sandbox is enabled independently of rules (`Scope#enable_sandbox` takes none into account), and
with no include rules `sandbox_blocks?` blocks everything, which [§3](#s3) states is deliberate.
So on a project with Sandbox on and no rules the proxy blocked every request and every other
automated sweep refused — `Outbound#sweep_block` skips only on a **nil** scope, never on a
rule-less one — while `gori run discover` and the TUI Discover tab crawled and brute-forced
completely unrestricted. Discover was the sole fail-**open** tool, in the one configuration §3
singles out as fail-closed.

The fix separates the two questions the old condition conflated. `scope.nil?` — genuinely no
project — keeps `OpenScope`, because there is nothing to consult. A rule-less scope now gets
`StoreScope` like any other. This changes containment not at all: `StoreScope#configured?`
delegates to `Scope#configured?`, still false, so scope-aware containment keeps falling back to
same-origin and `boundary?` is never consulted. The only difference is that `allowed?` starts
consulting Sandbox and EXCLUDE, and on an ordinary rule-less project with Sandbox off both are
false — so those runs are byte-for-byte unaffected.

### 2026-07-26: a request line refuses what frames it and encodes what merely breaks it

Refines: [P7](#p7). Issue #394, the remaining half of the #390 review.

`Headers.safe_url?` rejected CR and LF only, but `Sender#build_get` writes
`GET #{target} HTTP/1.1\r\n` and **space is that line's field separator**. `Extract::ATTR`'s
`"([^"]*)"` captures a space, `Url.resolve` strips only the ends, and `URI.parse` keeps it
verbatim in `path` and `query` — so an ordinary `<a href="/my file.pdf">`, which is common in
handwritten HTML, put `GET /my file.pdf HTTP/1.1` on a real socket. No attacker required. A
lenient origin reads target `/my` and version `file.pdf`, so gori requests a resource it did
not record; a strict one 400s, and that 400 diverges from the soft-404 baseline, which
`Calibrate.hit?` scores at +0.50 — a false-POSITIVE source in the brute-forcer, not a cosmetic
defect. The malformed line then persisted into the stored flow head via `Discover::Persist`
(`Import::Builder::CONTROL_CHAR` is `[\x00-\x1f\x7f]`, which does not cover 0x20), so a
byte-exact Repeater re-send reproduced it.

The rule is not restated here. It is `Proxy::Codec::Http1.request_token_safe?` — no octet
`<= 0x20` or `0x7F` reaches a request line raw — which the #397 fix made the one home for
exactly this class, after gori hit it in three subsystems in a week. Discover adds only the
part that is its own: a **repair** for the half of the class that has one.

The remedy splits by what the octet does to the wire, not by which issue found it:

- **CR and LF frame.** They do not corrupt one request line, they end it and begin a second
  message (#390). No author writes one into an href. They are **refused** — dropped at every
  enqueue by `Headers.safe_url?`, refused at the wire by `Sender#fetch` — which keeps #390's
  disposition intact. Encoding them instead would convert a splice attempt into a real request
  for a URL nobody authored, and put `%0D%0A` rows in the operator's Sitemap.
- **SP, TAB, DEL and the remaining C0 separate fields.** They break one line and cannot start a
  second. A space in an href is a real resource a browser fetches, so refusing it would silently
  shrink a crawl's coverage — the failure mode this project treats as worse than an error
  ([P4](#p4)). They are **percent-encoded**, which is lossless and is what every browser does.

This is deliberately the opposite call from #397, which **refuses** an unsafe redirect
`Location` on the same octet class, and the difference is provenance rather than inconsistency.
A page's own `<a href>` is text that page authored and that a browser would encode before
fetching, so encoding reproduces what the link meant. A redirect `Location` is named by whatever
host answered; encoding it would invent a URL the origin never named while gori recorded it as
sent. Same class, same one predicate, different answer because the input is a different kind of
thing.

Encoded at **parse** (`Url.parse`), not in `build_get`, because a URL must have exactly one
spelling: `visit_key`, `template_key`, the Layer-2 gate question, the `Finding`, and the Sitemap
row `Persist` writes all come off the same `Parts`. Encoding only at the wire would leave the
raw octet in all five, so the scope would judge a different URL than the one sent — the exact
two-spellings bug `Url.gate_url` and the seed's `Url.normalize` were introduced to kill. It also
makes discover ask the gate the already-encoded form every other Layer-2 consumer sees, since
those targets arrive off the wire from a real client. The encoding is idempotent (`%` is not in
the class), which `#{bl.dir}#{cand}` and every re-crawled link rely on.

The **host** is refused rather than repaired, by `Url.parse` returning nil: percent-encoding is
defined for a path, not for a reg-name, and `Import::Builder::HOST_INVALID` already records that
a real host never carries one of these octets. That refusal turned out to close the question
#397 left open. #397 could not demonstrate a live path to the unguarded
`CONNECT #{authority} HTTP/1.1` in `proxy/upstream.cr`; there is one, and it runs through here.
A crawled `<a href="http://ac me.acme.test/x">` passes `Headers.safe_url?` (a space is not
CR/LF) and `same_or_subdomain?` containment, and with an upstream proxy configured its host
reaches `Upstream.dial_via_proxy` verbatim. Refusing at parse makes it unreachable, and refusing
at parse is the only place that covers BOTH synthesized request lines — the GET and the CONNECT —
since the CONNECT is built far below any Discover gate. `sender_spec` pins it on the socket.

`Sender#fetch` now refuses the whole class rather than CR/LF. That costs no coverage — the
repairable half never reaches it, having been encoded upstream — and it means the wire seam can
state the invariant it is there to state: a Discover run never puts a malformed or doubled
request line on a connection.

One instance of the same root cause is knowingly left open, because it is outside this
subsystem: `Import::Builder::CONTROL_CHAR` (`import/builder.cr`) still stops at `\x1f`, so a
raw space in a request target imported from a HAR or `--urls` file is stored and replayed
byte-exact. `HOST_INVALID` covers space, but only for the host.

### 2026-07-26: a path-confined run brute-forces its own subtree, and a run that sends nothing says so

Refines: [P4](#p4). Issue #395, adjacent to #393.

`seed_frontier` took the brute-force base from `Url.dir_of(seed)` — everything up to the last
`/` — while `@confine_path` was derived from the seed's full path. For a **file-shaped seed**
(a path with no trailing slash) the two disagreed: on `http://t/api`, `dir_of` is the origin
root `http://t/`, whose path is neither `/api` nor under `/api/`, so `enqueue_dir` went through
`bounded_url`, the confine refused it, and the seed's own subtree was never probed. With
`spider: false, bruteforce: true` — `gori run discover --target https://acme.test/api
--no-spider`, an ordinary invocation — that was the entire run: `sent=0 findings=[]`, a clean
`DoneEvent`, no reason given.

The issue offered two fixes, and the answer is a third that the confine's own documented meaning
already implies. Widening `@confine_path` from `/api` to `/` would spray the built-in wordlist —
`admin`, `logout`, `.git/config`, `.env` — at the origin root of a run the operator explicitly
scoped to `/api`, which is what the confine exists to prevent. Reporting "brute-force has
nothing to do" answers a question nobody asked: a seed path deeper than `/` means *the subtree
rooted here* (`confined?`), so **the brute-force base is that subtree's root as a directory**,
not the seed's containing directory. `/api` and `/api/` therefore both calibrate `http://t/api/`,
`/a/b` calibrates `http://t/a/b/`, and a seed at `/` is unchanged (no confine, so `dir_of`).

Two consequences are worth stating plainly rather than leaving a reader to discover them:

- The base appends a slash the operator did not type. `/api` and `/api/` are distinct resources
  on an origin that cares, and the probes now go under the latter. That is the only reading
  under which a file-shaped seed has a subtree at all, and it is what `build_discover_seed`
  already does when a run is seeded from Sitemap or History.
- A file-shaped seed with the spider on now calibrates **twice**, at `/api/` and at the origin
  root, where it previously calibrated once. The root calibration is the one #393 added to gate
  `robots.txt`/`sitemap.xml`; it used to be reached because `enqueue_dir` had FAILED and left
  `@dirs` empty. Both are needed once the subtree is really probed. The rows of the issue's
  matrix that already brute-forced something — `http://t/` and `http://t/api/` — are unchanged
  in both request count and destination.

`Url.parse` also now collapses a trailing bare `.`, the one dot-segment shape it let through
(`/a/.` trips none of `..`, `./`, `//`). That was harmless while nothing read the seed's path
back, but this entry's derivation does: a seed of `/api/.` produced the confine `/api/.`, which
nothing can satisfy, and the run went straight back to brute-forcing nothing.

Separately, as the general backstop: **a run that puts no request on the wire now ends in a
terminal `ErrorEvent`** (`Engine::NOTHING_TO_SEND`) rather than a `DoneEvent` with zero
findings. The condition is the send counter, deliberately, and not "seeding enqueued nothing" —
an empty frontier is only the shape this issue found. A frontier whose every task is refused
later by the per-URL Layer-2 gate ends in exactly the same silence, and `SCOPE_REFUSED` is a
benign error, so even the error count stays 0. That state became ordinary the moment the gate
started re-reading the scope mid-run (entry below). A run the operator STOPPED is exempt:
stopping before the first send is a decision, not a failure to have anything to do.

### 2026-07-26: Discover's Layer-2 gate reloads on the same schedule as every other sweep

Refines: [P5](#p5). Issue #396, surfaced by the review of #391.

The entry above for #354 records one reload semantic for the active-traffic scope gate: the
scope is re-read from its store before each Layer-2 check, throttled to
`Outbound::RELOAD_INTERVAL`, "uniform for every LONG-RUNNING job … on all three surfaces".
Discover was not honouring it. Its Layer 2 goes through the injected `ScopePolicy`
(`StoreScope#allowed?`) and not through `Outbound#sweep_block`, so `Outbound#refresh` was never
reached: `cli/run/discover.cr` and `mcp/tools/discover.cr` both use the `Outbound` for
`Plan.build` plus the up-front Layer-1 guard and then hand the engine a policy that never calls
back into it. The result was that `gori run project scope add exclude string logout` in a second
terminal stopped an in-flight fuzz, mine or sequence within a second, while an in-flight
discover — potentially thousands of probes — kept going against a start-time snapshot. Only the
TUI was exempt, and by accident: it shares its live `Scope` object, which its own `data_version`
poll reloads.

`StoreScope#allowed?` now performs the same throttled reload, reusing
`Outbound::RELOAD_INTERVAL` rather than naming a second interval — same clock-before-reload
ordering so concurrent worker fibers cannot stampede the store, same swallowed failure so the
last-known rules stay in force rather than the run breaking or failing open. Threading the
`Outbound` into the engine was rejected for the reason the `ScopePolicy` seam exists at all: the
engine is deliberately Store-free ([§2.1](#s2-1)).

**`configured?` is snapshotted at construction, and that is the load-bearing half of this
entry.** It answers "is there a scope to bound the crawl", which is what switches
`Containment::ScopeAware` between the same-origin fallback and `boundary?` — a Layer-1 question.
Delegating it live would let the reload rewrite the containment mode mid-run, and the direction
it rewrites in is catastrophic: on a project with no rules, an operator adding the single
canonical `exclude string logout` flips `configured?` false to true, and `matches_url?` requires
at least one INCLUDE (`Scope#allowlisted_unlocked?` — an excludes-only scope is deliberately not
an allowed range), so `boundary?` becomes false for every URL. The operator asked to skip one
path and the whole crawl would stop, silently, which is the [P4](#p4) failure the entry above
exists to remove. [§3](#s3) and the #354 entry already draw the line this respects: Layer 1's
strictness is settled per surface before the first byte, Layer 2 is the layer that is identical
everywhere and applied continuously. #396 asked for the second, not the first.

`boundary?` itself needs no reload of its own: its only caller (`bounded_url`) asks it
immediately after `allowed?`, so it already reads whatever that call refreshed.

### 2026-07-26: import is deliberately permissive — the host is a URL, the target is a payload

Refines: [P7](#p7). Issue #400.

Import (`src/gori/import/builder.cr`) feeds the replay path, so it obeys [P7](#p7): it stores and
replays operator-supplied malformed input byte-exact rather than sanitising it. A HAR, OpenAPI
spec or `--urls` file is a file the operator deliberately handed gori, describing traffic they
want to reproduce — a CRLF-bearing request line, a raw space in a target, a duplicate `Host` are
the smuggling *payloads* an operator tests with, not corruption to be repaired. Reproducing a
broken request is the point of the tool. This closes the inverse of how #400 was first filed:
the defect was never that a byte slipped *through* the denylist and replayed; it was that a
denylist rejected the operator's payload at all.

The split that makes this safe to state is **host versus target**:

- A control byte or space in the **path or query** is a URL describing a malformed request →
  store it, replay it byte-exact. `URI.parse` copies a literal control byte verbatim into
  `path`/`query`, and `request_head` writes the target onto the request line as-is, so the
  operator's forged message reaches the wire unchanged.
- A control byte or space in the **host** is not a URL at all — a parse failure, not a payload.
  `URI.parse` copies a reg-name authority verbatim, so `not a url at all` becomes a stored
  "host" of literal spaces. `Builder::HOST_INVALID` (`/[\x00-\x20\x7f]/`) rejects it in
  `endpoint`, and the parser's per-entry rescue skips just that entry. This is the ONE reject
  import keeps, and it is a shape check on a URL, not a judgement on a request.

One `CONTROL_CHAR` regex used to match anywhere in the URL and so did both jobs, rejecting the
payload case along with the parse-failure case; removing it and leaning on the pre-existing
`HOST_INVALID` restores the distinction. The send layer already encodes the same principle:
`Codec::Http1.request_token_safe?` (#399) documents itself as applying only where gori
*synthesizes* a request line from bytes a remote chose, never to operator-replay bytes.
`spec/repeater/import_replay_wire_spec.cr` pins that on the socket — an imported CRLF target
replays byte-exact through `Repeater::Plan`, and the guard's own verdict on those same bytes is
`false`, proving it does not gate the replay path.

Two adjacent guards are NOT relaxed by this decision and stay as they were: `HEADER_INJECT`
(CR/LF/NUL in a header name/value) and `reject_inject!` (the same in method / HTTP version /
reason phrase). Those forge a message boundary the same way a CRLF target does, and whether
import should also carry an operator's header-boundary payload is a separate question #400 did
not settle — left rejected pending its own call rather than widened by implication.

### 2026-07-30: an imported request's Host header is the operator's, and carries its port

Refines: [P7](#p7). PR #488 (the port) and its follow-up (the passthrough).

The entry above names "a duplicate `Host`" as one of the payloads import must preserve, but
`Builder.request_head` was doing the opposite: it skipped every incoming `Host` line and
synthesized one from `uri.host`. Two defects fell out of that, found by replaying imported
flows at a raw-echo origin and reading the bytes it received.

- `uri.host` never carries a port, so the synthesized line dropped it. RFC 7230 §5.4 requires
  the port whenever it is not the scheme default, so a HAR recording `Host: 127.0.0.1:8099`
  was stored — and replayed — as `Host: 127.0.0.1`. Name/port-based routing at the origin saw
  a different request than the one imported, and two imports differing only in port became
  indistinguishable by Host. Only the stored `host`/`port` columns were right, so the raw bytes
  and the JSON projection disagreed.
- Synthesizing at all discarded the operator's own bytes. A recorded `Host: evil.example`, or
  the duplicate `Host` this log already called a payload, was silently replaced — so the
  Host-header attack the operator imported could not reproduce.

Resolved as two halves of one rule: **a recorded Host goes out verbatim — order kept,
duplicates kept — and a Host is synthesized only when the source described none.** The
synthesized form now carries `host:port` unless the port is the scheme default
(`Builder.host_header`, reusing `Discover::Url.default_port?`). Sources that describe no
headers (`--urls`, OpenAPI) are the synthesize case; HAR/Postman/Insomnia are the passthrough
case. `Import::Raw` (Burp) never enters Builder and is unaffected.

Safe because gori already permits a Host that disagrees with the dialled host, deliberately:
the scope gate judges `Outbound.scope_url` — the host actually dialled — never the request
line or this header, which is what makes Host-header testing possible at all
([§3](#s3)). The two guards the entry above kept are untouched: `HEADER_INJECT` still rejects
CR/LF/NUL in any header, and `request_head` now applies the same check to the `host` it is
handed, since that field reaches the start of the head and could forge a boundary there.

### 2026-08-09: a crawler that will not read JavaScript cannot find a modern app

Refines: [P4](#p4).

Discover's two techniques both derive their targets from links, and both stopped at the same
wall. `Engine#extract_links` chose its parser from the response: robots.txt by role, a
`<loc>`-bearing body as a sitemap, an html-like content type as HTML — and **everything else as
`EMPTY_LINKS`**. The spider follows `<script src>` like any other link, so a run spent a real
request on the bundle, decoded it, fingerprinted it, and then discarded every route in it. On
anything SPA-shaped that is the whole application: an API route reachable only from JS is by
construction unlinked, so it was invisible to the spider *and* absent from any wordlist. The
same silence covered every JSON response.

Three changes, all inside the engine's existing gates:

- **`Extract.from_text`** takes the `else` branch. It looks for two shapes — an absolute
  http(s) URL, and a root-relative path *opening a quoted string* — because those are spelled
  identically in JS, JSON, YAML and plain text. The quote is the whole false-positive filter: a
  regex literal (`/foo/g`), a MIME type (`application/json`) and a date all fail it. It runs
  over inline `<script>` in HTML too, and `Engine#text_like?` keeps it off binary bodies, which
  a crawl following `<img src>` and `<link href>` meets constantly and which would each cost a
  full `String#scrub` to feed a regex no image can match.
- **`Engine::WELL_KNOWN`** replaces the hard-coded robots.txt/sitemap.xml pair with the
  registry: `sitemap_index.xml` (the Yoast spelling, and the majority of what `sitemap.xml`
  misses) and the `.well-known/` set, of which OIDC Discovery / RFC 8414 / RFC 9728 are the
  highest-yield documents gori fetches at all — one 200 names authorize, token, userinfo, jwks,
  revocation, introspection and registration as absolute URLs. `.well-known` and
  `.well-known/security.txt` *were* in the wordlist already, which is not the same thing: that
  probes them once per calibrated **directory**, never at the origin on a path-confined run,
  and reads nothing they say.
- **`Source::WellKnown`** carries them, and `Engine#well_known?` is the one predicate deciding
  both the routing and the confidence anchor. The 2026-07-26 entry above reasoned about
  "the seed and its two derived well-known paths"; nothing in that reasoning was about the
  number two. All of these are origin-anchored guesses at a fixed path, so all of them waive
  Layer 1 and the path confine, none of them waives Layer 2, and all of them are graded against
  the origin's soft-404 baseline rather than `record_page`'s raw-status trust — a wildcard-200
  origin answers 200 to `/.well-known/openid-configuration` exactly as readily as to
  `/robots.txt`.

Widening what one response yields makes the **orchestrator** the thing to watch, since
`consider_link` runs there and so does `enqueue_probes`, and that fiber is also the only one
dispatching jobs. Both were paid for in the same change: `Extract` de-duplicates within a body
and caps it at `MAX_LINKS`, and `Url.probe` derives a brute-force candidate by concatenation —
one string serving as both the frontier entry and the `seen` key, which are the same string for
any query-less URL. It is an optimization and never a second opinion: it declines every
candidate `Url.parse` would have rewritten, split or refused, and the caller falls back.
`bench/discover_extract_bench.cr` measures the directory loop at 546µs/805kB before and
233µs/251kB after, and `url_spec` pins `probe == parse` across the whole built-in list.

### 2026-08-09: a soft-404 baseline is a snapshot, and origins change their mind

Refines: [P4](#p4).

`Calibrate` recognises the four shapes of "not found" it was built for, and measuring it
against an origin serving all four confirms that: a custom-designed error page on a real 404,
a 200-everything soft-404, one that quotes the requested path back, and a 302-everything login
funnel each yielded the planted endpoint and nothing else. Two things it does *not* recognise
turned up in the same measurement, and they pull in opposite directions.

**A stale baseline reports the whole wordlist.** A `DirBaseline` is measured once, before a
directory's ~315 probes, and never revisited. When the origin's rate limiter tripped on the
8th request, every remaining probe diverged from that snapshot in status *and* length *and*
content — 0.50 + 0.25 + 0.35, clamped — so the run ended `320 found`, of which **310 were the
limiter, every one at confidence 1.0**. This is the ordinary case on a real engagement, not an
exotic one, and it is the worst failure the tool has: not a missed endpoint but a confident
lie, repeated 310 times.

A status guard (`429`/`503` are not evidence of existence) was considered and rejected as the
whole answer: the new uniform response is as often a 200 block page or a 403 as it is a 429,
so the shape to detect is *uniformity*, not a status class. `DirState` now carries the run of
consecutive cleared-and-alike outcomes, and `DRIFT_RUN` of them means the baseline no longer
describes the origin — re-measure the directory, and swap the new baseline into the `DirState`
every queued probe already holds a reference to. Three details are load-bearing:

- **The first member of a run is emitted; the rest are held.** At the moment it arrives, one
  diverging response is indistinguishable from a real finding, so it is reported. The second
  and later are held until the run either breaks (released — an ordinary directory pays only
  the latency of one more outcome) or reaches `DRIFT_RUN` (dropped). That bound is why
  `DRIFT_RUN` can be generous: raising it spends a few more requests, it does not leak more
  false positives, so 12 sits far above a real cluster of same-shell routes.
- **`drifted` is not enough; the baseline needs a GENERATION.** The flag covers the window
  between declaring drift and the re-measurement landing — and is cleared by the very swap
  that strands the probes still in flight, which were scored against the discarded snapshot.
  Caught in testing as a second false positive surviving the guard. A probe now reads the
  baseline and the generation together and carries the pair back; a mismatch means the verdict
  is evidence about nothing.
- **Re-calibration is capped** (`MAX_RECALIBRATIONS`). A limiter that relents and trips again
  would otherwise re-measure forever. Past the cap the directory stops producing findings and
  says so in `RunStats#drift_suppressed`, which all three surfaces now render.

**And the same measurement found the opposite error.** `WildcardOk` required
`fp_novel && length_div`, and the length band is proportional — `max(16, max // 20)`, 5% of the
page. A real page sharing the error page's template, which is what a CMS or SPA soft-404 always
is, lands inside that 5%: a 524-byte `/soft/admin` against a 545-byte soft-404 sat inside
`[518, 572]` and was never reported, however different its content.

Relaxing it to `fp_novel` alone produced **15,013 findings in one directory** against the
path-echoing origin — because there, content divergence *is* the echo. So the conjunction is
now conditional on a measured property rather than assumed, and the measurement is a byte
search, not an inference: each calibration probe looks for its OWN name in its OWN body. It
has to be direct, and the reason is the good kind of subtle. `Fingerprint.dynamic?` skips
all-hex runs of 12 or more so that ids and hashes cannot move a hash, and `bogus_name` is
exactly 16 hex characters — the reflected name is invisible to the very hash the reflection
would show up in. Inferring the echo from an out-of-cluster fingerprint fails too, and fails in
the direction that matters: one extra token in an 80-token page moves a simhash by fewer bits
than `simhash_distance`, while `swagger/v1/swagger.json` contributes four and clears it, so the
inferred test is *less* sensitive than the thing it predicts. The byte search costs no extra
request, and `DirBaseline#label` reports `wildcard-200 (echoes path)` so an operator can see
which of the two they got.

Net, on the five-variant origin: 320 findings with 310 false positives became 12 with 1 — the
single unavoidable one — while `/soft/admin`, which no configuration could previously surface,
is now found.

### 2026-08-16: a race is a count on the plan, not a fifth attack Mode

Refines: [P0](#p0). PR #705.

The Fuzzer's Race (last-byte-sync) mode arrived as `Config#race_count : Int32?`
(`src/gori/fuzz/types.cr`) rather than as a member of `Fuzz::Mode`, which still holds exactly
`Sniper`, `BatteringRam`, `Pitchfork`, `ClusterBomb`.

`Mode` answers one question: how do payload lists combine into the sequence of requests a run
sends. All four members are read by `Generator`, and every one of them produces a stream of
*different* requests. A race produces N copies of the *same* request and bypasses
`Mode`/`Generator` entirely (`Fuzz::Engine#run_race`). Modelling it as a fifth member would
have put a value into an enum that the enum's only consumer cannot consume, and forced an
inert arm into the exhaustive `case` in all three surfaces — structure added to describe a
thing that does not have that shape.

The cost of the choice is that "race" is not spelled the way the other attack shapes are, and
a surface must know to read a second field. That is the right trade while `race_count` is the
only such knob; a second orthogonal send-shape would be the concrete second caller P0 asks
for, and the two should then be generalized together rather than one of them retrofitted into
`Mode`.

### 2026-08-16: a refused send is not an enforcement result

Refines: [P4](#p4). Issues #707, #710.

Extends the 2026-07-26 decision that a run which sends nothing says so, to the case where the
answer is not merely empty but *actively misleading*.

The Authorize tool replays one captured request under several identities and reports whether
access control held. Its verdicts therefore carry a claim about the target. When gori's own
Sandbox or an EXCLUDE rule refuses every send, the run has learned nothing about the target
at all — but the shape of the result is indistinguishable from the shape of a run where the
server rejected every non-baseline identity. Reporting that as `enforced` would state the
strongest possible finding on the strength of traffic that never left the process.

So `Authorize` reports `nothing_sent`, never `enforced`, when every send was blocked, and
says in the same breath that this is not evidence access control works
(`src/gori/mcp/tools/authorize.cr`, `src/gori/cli/run/authorize.cr`). The same reasoning
makes an all-skipped selection raise `PlanError::NothingToSend` carrying the per-flow skip
list rather than returning an empty plan: "we declined to test these four requests, here is
why" and "we tested them and found nothing" are opposite findings and must not share a
rendering.

Authorize also shipped in #707 as a TUI-only tool, against the convention in [§2](#s2) that
every tool reaches all three surfaces over a shared `Plan.build` seam. #710 added
`src/gori/authorize/plan.cr`, `gori run authorize` and the MCP `authorize_*` family. Recorded
here because the gap was not noticed until a structure review looked for it: a new tool's
parity is part of shipping it, not a follow-up, and the seam is the thing that makes the two
non-TUI surfaces cheap enough for that to be true.

---

*Keep this document honest against the code. When you change a subsystem it describes, update
the matching section; when you cite a principle inline, use the labels above.*
