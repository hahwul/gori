# CLAUDE.md — working in the gori codebase

gori (고리, Korean for *ring / link / loop*) is a keyboard-first TUI web proxy for
authorized penetration testing: it sits between a client and its target, capturing
every request/response as a *flow* you can intercept, replay, fuzz, and scan across
HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE. Every capability is exposed on three
surfaces: the TUI, the `gori run` CLI, and the `gori mcp` MCP server.

It is written in **Crystal** and runs on the single-threaded fiber scheduler
(**never build with `-Dpreview_mt`** — Store, Fuzz::Engine, Miner::Engine and
Store::SafeRegexp document plain ivars/unguarded counters that are only safe under
cooperative scheduling).

## Build / test / lint

Use `just` (see `justfile`):

| Command | What |
|---|---|
| `just build` (`shards build`) | build `bin/gori` |
| `just dev` | build + run the TUI |
| `just test` (`crystal spec`) | full suite (~148 files, sequential, one binary) |
| `just test-<area>` | one `spec/` subdir, e.g. `just test-tui`, `just test-store` |
| `just test-file path=spec/foo_spec.cr` | a single file (also: `crystal spec spec/foo_spec.cr`) |
| `just check` | `crystal tool format --check` + ameba |
| `just fix` | auto-format + ameba `--fix` |

**Never run `crystal tool format` across the whole tree.** The pinned Crystal version
drifts from the one the tree was last formatted with, so a blanket format reformats
~40 unrelated files. Format only files you changed (`crystal tool format <files>`) and
otherwise match the surrounding style by hand. ameba config lives in `.ameba.yml`
(cyclomatic complexity cap is 12).

## Module map (`src/gori/`)

| Path | Responsibility |
|---|---|
| `proxy/` | MITM proxy: `codec/` (HTTP/1 + body), `h2/` (HTTP/2, HPACK, gRPC), `tls/` (CA, tunnel), `conn/`, `server.cr` |
| `store.cr` + `store/` | SQLite persistence. Single-writer-fiber + `Channel`; reads via WAL pool. `store/{models,schema,compact,safe_regexp}.cr` are class-reopening partials |
| `repeater/` | replay engines (`engine`, `h2_engine`, `ws_engine`, `diff`) shared by all three surfaces |
| `fuzz/` `miner/` `sequencer/` `discover/` `oast/` `probe/` | pure engines for each tool tab (Intruder-style fuzzing, param mining, token randomness, spider/brute, out-of-band, passive+active scan) |
| `scope.cr` `rules.cr` `host_overrides.cr` `interceptor.cr` | mutex-guarded domain wrappers over a Store slice; read on the proxy hot path, written from the TUI |
| `ql.cr` | the History query language (see DESIGN.md §4) |
| `verb.cr` + `verb/` + `verbs/` | the TUI action/command system (keybinding + palette + space-menu, one code path) |
| `mcp.cr` + `mcp/` | MCP server; `mcp/tools.cr` is the tool surface |
| `cli.cr` + `cli/` | CLI entry + `cli/run.cr` (the `gori run` headless suite) |
| `tui/` | terminal UI (see below) |
| `settings.cr` + `settings/` | persisted config (module-level, no mutex — TUI-fiber only) |
| `decoder.cr` `jwt.cr` `saml.cr` `graphql.cr` `pretty.cr` `sse.cr` `proto.cr` | payload decode / pretty-print helpers |

### The TUI seams (`src/gori/tui/`)

The shell (`runner.cr`) owns the event loop, tab bar, and modal overlays. Everything
tab-specific lives behind two clean seams — **respect them; do not reach around them**:

- **`TabController`** (`tab_controller.cr`) — one per top-level tab, built once in
  `Runner#initialize`. Reaches the shell **only** through the **`Host`** module
  (defined in `runner.cr`); it never touches another controller or `Runner` directly.
  Override `tab` / `command_scope` / `render_body` + optional hooks. A tab's rendering
  and ephemeral edit state live in a plain `*_view.cr` class the controller drives.
- **`Overlay`** (`tui/overlay.cr`, *arriving in the overlay-refactor PRs*) — the same
  idea for modal popups, reached through `OverlayHost`. Until then, overlays are still
  hand-wired in `runner.cr`'s dispatch ladders.

## Design principles (P0–P8)

Cited inline throughout the source as `(P4 — ...)`. Defined once in **DESIGN.md §1**.
Short form:

- **P0** — minimal. Don't build speculative abstraction or hierarchy; add structure
  only when a concrete need forces it.
- **P1** — one execution path. A keybinding, a palette entry, and a space-menu item
  all fire the *same* `Verb::Definition#call`; there is no parallel dispatch.
- **P3** — no premature generalization of the data model (e.g. every distinct URL
  segment is its own sitemap node; no path templating).
- **P4** — the human decides. Intercept holds an in-flight message indefinitely for a
  human decision; scope gates are explicit, never inferred.
- **P5** — state changes are mediated through a narrow facade (`Host` / `OverlayHost`
  / `Verb::ExecContext`), never by touching raw TUI/proxy/store state.
- **P6** — never stall the data path. Batch/stream on the proxy and writer hot paths
  (amortize fsync, immediate socket writes).
- **P7** — the raw wire bytes are the truth. Parsed/pretty views are derived and are
  never round-tripped back onto the wire lossily.
- **P8** — pull, not push. No ranking or queueing; History/analysis is query-driven
  (QL), fetched lazily per on-screen row.

(There is no P2 — inline `CSP2` references are an unrelated version string.)

## How to add a feature

> The steps marked **[shared]** edit a central file that other in-flight features also
> touch. The de-collision PRs are converting these to per-feature self-registration;
> this section is updated as each lands. When two of you add features at once, expect
> the [shared] edits to conflict and keep them to a pure tail-append.

**A new tab** (pure engine → TUI → CLI → MCP):

1. Pure engine + persistence: a `src/gori/<feature>.cr` (or `<feature>/`) module and,
   if it stores data, a new migration appended to `store/schema.cr`'s `MIGRATIONS`
   **[shared, and strictly ordered — coordinate the version number]** plus a
   `store/<feature>.cr` concern partial.
2. TUI: `tui/controllers/<feature>_controller.cr` (+ a `*_view.cr`), registered in
   `Runner#initialize` **[shared]**; `chrome.cr` `TABS`/`DEFAULT_HIDDEN` **[shared]**;
   a `Verb::Scope` member appended at the **tail** of the enum in `verb.cr` **[shared]**
   (append-only — never reorder; exhaustive `case`s depend on it); `verbs/<feature>.cr`
   with a `register_<feature>` added to the chain in `verbs/history.cr` **[shared]**;
   the tab-jump hash in `verbs/core.cr` **[shared]**.
3. CLI (if scriptable): a `cmd_<feature>` in `cli/run.cr` + its `dispatch_subcommand`
   case + the `SUBCOMMANDS` help array **[shared]**.
4. MCP (if agent-facing): schema in `list(j)`, a `read_tool`/`action_tool` case, and
   `AGENT_ACTION_TOOLS` if it mutates — all in `mcp/tools.cr` **[shared]**.
5. `require` the new files (`src/gori.cr`, `app.cr`) **[shared]**.
6. Specs mirroring the source under `spec/`.

**A new overlay** (modal popup): today, add its ivar and thread it through every
`case @overlay` ladder in `runner.cr` (`modal_overlay?`, `apply_preedit`,
`handle_overlay_click`, `wheel_overlay`, `focus_label`, `key_hints`, the `handle_key`
chain, the render ladder) **[shared, ~8 sites — keep them identical]**. After the
overlay-refactor PRs this becomes: one `tui/overlays/<feature>_overlay.cr` subclassing
`Overlay`, opened via `open_overlay(...)`, no `runner.cr` edit.

## Tests

- The suite compiles into one binary and runs sequentially; specs self-isolate with
  tempfile DBs (`File.tempname`).
- **`spec/spec_helper.cr` points `ENV["GORI_HOME"]` at a per-run temp dir** and cleans
  it up after the suite. **Never read or write the real `~/.gori` from a spec, and
  don't hand-roll a per-`it` `ENV["GORI_HOME"]` save/restore** — that older convention
  (still present in ~7 specs, harmless now) is why two parallel `crystal spec` runs
  could otherwise stomp a real home directory.
- Prefer `just test-<area>` while iterating; run full `just test` before finishing.

See **DESIGN.md** for the architecture and the numbered design sections referenced in
source comments, and **CONTRIBUTING.md** for the contribution flow.
