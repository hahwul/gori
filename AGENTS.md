# AGENTS.md: working on gori

gori is an intercepting proxy and workbench for **authorized** security testing, written in
Crystal and shipped as one binary. It sits in the loop between a client and its target,
capturing every request and response as a *flow* you can intercept, replay, fuzz, and scan
across HTTP/1.1, HTTP/2, WebSocket, gRPC, and SSE.

Three entry points, one engine layer underneath: `gori` (TUI), `gori mcp` (stdio JSON-RPC for
agents), `gori run <sub>` (headless, for scripts).

This file is the short version, and it is the whole contract for a change that stays inside
one subsystem. [DESIGN.md](.github/DESIGN.md) is the long one, and its numbering is
load-bearing: source comments cite principles as `(P4)`, `(P6/P7)` and sections as
`DESIGN.md §4`.

- Changing behavior? Read **Invariants** below first — those three are what changes get wrong.
- Adding or moving a TUI key or space-menu row? **TUI keys** lists the rules the boot checks and
  guard specs hold you to.
- Committing? **House rules** has the commit, CHANGELOG and pre-commit checklist.
- Adding a subsystem? DESIGN.md, then back here.

## Invariants: three things not to get wrong

### 1. Malformed input is the payload (P7)

A security proxy that sanitizes its operator's bytes is broken. The captured wire bytes are
canonical; parsed columns and pretty views are derived projections.

- There is **no** stdlib `HTTP::Request` parsing anywhere on the proxy path.
  `src/gori/proxy/codec/http1.cr` is a byte-exact sans-IO codec: it flags `malformed?` and
  keeps the octets rather than rejecting. `serialize_head` is the identity function.
- **The axis is provenance, not byte values.** The same octet gets three different answers:
  - **operator bytes** (imported HAR, an MCP `raw` request, a replay) go out verbatim, never
    sanitized. See the comment at `src/gori/import/builder.cr:31-38` and
    `src/gori/repeater/url_request.cr` (`raw` / `normalize_raw`, shared by MCP `send_request`
    and `gori run send`).
  - **page-authored bytes** (a crawled `<a href>`) get percent-encoded where they merely
    break, and refused where they *frame*. See `src/gori/discover/url.cr` (`encode_unsafe`).
  - **remote-chosen bytes** (a redirect `Location`) are refused outright, not repaired. See
    `src/gori/fuzz/engine.cr` (redirect following).
- The predicate has **one home**: `Codec::Http1.request_token_safe?`. Do not re-derive it next
  to a new caller; that exact shape has already recurred three times (#390, #394, #397).
- Request framing rejects any obfuscation (`obfuscated_header?`); response framing is
  deliberately narrower (`framing_ambiguous?`, and read the comment above it). Do not
  "symmetrize" them: a request's peer is the operator's own browser, a response's peer is the
  whole internet.

### 2. Three surfaces, one engine layer

The TUI is the center of gravity. `gori mcp` and `gori run` are expected to stay at near
parity with it, and every parity gap found so far has been in a surface, not an engine.

- The shared seam is **`Plan.build(options, outbound) : Plan`**, one per tool:
  `src/gori/{fuzz,miner,discover,sequencer,repeater}/plan.cr`. Option *parsing* is
  surface-specific (an `OptionParser` on the CLI, the args hash on MCP, view state in the
  TUI); everything downstream of the normalized options has exactly one implementation.
- Adding a feature means: engine + `Plan.build` path once, then a thin adapter in each of
  `src/gori/tui/`, `src/gori/cli/run/`, `src/gori/mcp/tools/`. Parity is a convention held by
  each surface calling the same engines, not by a shared dispatcher ([DESIGN.md §2](.github/DESIGN.md)).
- Unknown Rewriter labels read from settings or a project database stay raw and inert; enum
  fallback values are projections for listing, never permission to rewrite. `MatchRule#inert?`
  gates both replacement and short-circuit selection. Surfaces may list and delete such rows,
  but must not enable, edit, duplicate, move or reorder them.
- The seam is **not** the `Verb` registry. Its 318 verbs are TUI-only by decision: a verb reads
  its target from TUI selection state instead of naming it, and the missing argument schema is
  the blocker, not registry wiring (`src/gori/verb.cr`, DESIGN.md §7). Do not "fix" parity by
  wiring CLI or MCP into the registry.
- **Layering contract:** core subsystems must not know a surface exists. Enforced by
  `spec/layering_spec.cr`, which scans the same file set and fails on any hit that is not a
  comment line. The quick manual form:

  ```sh
  grep -rnE '\b(Tui|CLI|MCP)::' \
    src/gori/{store,proxy,probe,fuzz,miner,discover,sequencer,oast,authorize}/ \
    src/gori/{store,probe,fuzz,miner,discover,sequencer,oast,authorize}.cr
  ```

  Today that returns hits in `src/gori/store/models.cr`, `src/gori/probe/group.cr`,
  `src/gori/fuzz/{types,engine}.cr`, all of them comments. A comment may point at a caller;
  code may not — so the check is "every hit is a comment", not a hit count. (The count drifts
  as those comments are edited; that is fine, and is why it is not the check.)
- Every gori-originated request goes through the `Gori::Outbound` chokepoint
  (`src/gori/outbound.cr`). It is a required constructor argument on `Fuzz::Sender` and
  `Repeater::Sender`, so an ungated sender is a compile error. Layer 1 (`check`) is the only
  per-surface variance: `Outbound.agent` (MCP, strict), `Outbound.cli` (permissive when
  unconfigured), `Outbound.interactive` (TUI, no up-front gate). Layer 2 (`sweep_block` /
  `send_block`: sandbox + explicit excludes) is identical everywhere and applies even when
  Layer 1 was waived. Judge the host actually dialled via `Outbound.scope_url`, never the
  request line.

### 3. Never stall the data path (P6), and don't crash

The proxy and the Store writer are hot paths. The proxy plus the HTTP/1.1 codec add only
~25µs per request (`src/gori/store/schema.cr:573-576`); capture, not proxying, has been the
bottleneck every time.

- gori runs on Crystal's **single-threaded** cooperative fiber scheduler. **Never** build or
  benchmark with `-Dpreview_mt`: `Store`, `Fuzz::Engine`, `Miner::Engine`, and
  `Store::SafeRegexp` all depend on it.
- All writes funnel through one writer fiber fed by a buffered `Channel`, batched into one
  transaction to amortize fsync. Replies and events fire only **after** commit, and a failed
  batch must not kill the writer fiber or every blocked caller deadlocks (`Store#writer_loop`).
- Measure, don't guess. 36 harnesses live in `bench/` and are cited back from the source they
  justify. Allocation-shaped wins are real; CPU micro-optimizations usually are not.
  `bench/proxy_bench.cr` has ±40% run-to-run noise, so use `bench/capture_bench.cr` for
  allocation deltas.
- Read the comment before touching these; each one is a crash or a DoS that already happened:
  TLS `sync_close: true` (`src/gori/proxy/tls/tunnel.cr:100`, SIGSEGV under a browser's h2
  connections), cross-close on tunnel teardown (`src/gori/proxy/pump.cr:13`, fd exhaustion),
  `TeardownLatch` must stay a reference type (`src/gori/proxy/conn/client_conn.cr:65`), no
  loop-variable capture in `spawn do…end` (`src/gori/proxy/server.cr`).

## TUI keys: the space menu and its letters

Every letter the operator presses is checked at boot or by a guard spec. A new or moved verb
passes these; it does not work around them. The reasoning is in DESIGN.md §7 (the 2026-09-12
key grammar and the 2026-09-25 #1274 entries).

- **One letter, one meaning per tab (R1).** A space-menu letter may differ from the verb's
  chord, but it must never be a key the same tab answers with a different action. That covers
  the tab's scope under every OS profile × keyset, the Editor scope in an editor pane, the
  sub-tab strip's raw keys, and the Global fallback (`c` stops capture and `i` holds all
  traffic on a dropped `space`). `spec/tui/menu_letter_meaning_spec.cr` sweeps all four. Its
  `MENU_LETTER_ALLOWED` names exact verb pairs with a reason and fails when an entry stops
  violating, so a fix deletes its own line. Never add an entry just to let a new verb pass.
  So a level-1 `c` or `i` is allowed only on a tab that binds that letter itself: anywhere else a
  dropped `space` reaches Global and stops capture or holds all traffic, and the guard fails.
  The one rule-based exemption is the `vim` keyset's motions (`VIM_MOTIONS`: append, top, bottom,
  find, select line), which only move or select. Never widen it to a verb that writes or sends.
- **A recurring intent takes its letter from the lexicon.** Declare `intent:`
  (`src/gori/verb/lexicon.cr`), never a `mnemonic:` beside it (`validate_intents!` raises).
  The same intent has the same letter on every tab, and a verb whose id names an intent
  (`*.filter`, `*.export`, `*.copy`, the strip ids, …) must declare it
  (`spec/verb/lexicon_spec.cr`). Only a one-off action spells a local `mnemonic:`.
- **Reserved letters.** Menu `X` / `⇧X` is wipe and nothing else. On a tab with a sub-tab
  strip, the strip's nine (`n w d e t f / T N`) are never a COMMON verb's letter: COMMON shares
  the strip-focused card, where the SUB-TABS bucket is drawn expanded. In a pane view the bucket
  is one row, `T` **Sub-tabs…** (`Registry::SUBTABS_FOLD`), so a pane verb may use the other
  eight but never `T`; `pinned:` keeps a strip verb at level 1 in the panes too (Paste cURL).
  Reassign a freed pane letter in its own change.
- **No menu letter is `h`/`j`/`k`/`l`**, at either level: not a row's letter (a chord-derived one
  included), a pinned member's, a family key or a level-2 letter. Inside the menu those four
  always move the selection; the Runner's fallback stays. `Registry#validate_intents!` and
  `Verb::Family#validate!` raise at boot (`Family::NAV_LETTERS`).
- **A variation of one intent joins a family instead of taking a letter.** Every cross-tool
  send is a member of `Send flow to…` (`>`), every view toggle of `Display…` (`Z`) and every
  Repeater/Fuzzer transport toggle of `Protocol…` (`P`), all in `src/gori/verbs/families.cr`.
  - Members are keyed by `intent:`. Their second-level letters come only from the family table
    (`Verb::Family`, `TOOL_LETTERS` for sends) and are the same on every tab.
  - A toggle family is `sticky:`: its card comes back after a member runs and draws each row's
    `ExecContext#menu_state` (●/○ or a value). A new toggle member needs its arm in the tab's
    `TabController#menu_state` (`spec/tui/toggle_family_state_spec.cr` checks). A member that
    opens something instead of flipping it closes the card through `SpaceMenu.resume_sticky?`
    (an overlay, or a pane that takes the keys: `TabController#pane_captures_keys?`). A
    member is never a write-back to the request.
  - `pinned: true` keeps a loop action one keypress away as well.
  - A family row is static: it is drawn whenever the view registers a member. It is never gated
    on `available?` and never collapsed into its lone member.
- **A bare key that belongs to one pane declares `chord_sections:`.** Do not hide that gate in
  `available:`, because the R1 guard reads the declaration. Never pane-gate a letter that Global
  binds: outside the pane, the press falls through to Global.
- **The space menu is for the frequent; the palette takes the long tail.** A row that only
  repeats a direct chord for an editing or navigation convenience, or a once-a-session
  configuration action, is placed `menu: :palette` (`Verb::Placement`): no row at either level,
  found by `Ctrl-P`'s typed search from its tab, chords unchanged. It spells no `mnemonic:`, is
  never a family member, pinned or hidden (`validate_intents!` raises), and the letter rules
  ignore it. Name it in UI text with `{space:verb.id}` like any row: `Hotkeys.route` prints its
  chord, or `^P → <title>` when it has none. Move a row by that criterion, never by a row count.
- **Never spell a menu letter in UI text.** Help rows, hints and toasts use `{space:verb.id}` or
  `Hotkeys.menu_path` (which prints `space → > f` for a member; `Hotkeys.route` also covers a
  palette-only verb). A chip, a border badge or a tight hint uses `Hotkeys.menu_chip` (`␣Pr`).
  `spec/verb/hint_token_expands_spec.cr` fails on a literal `space → X` or `␣X`.
- **`Space` and `Ctrl-P` share one context.** `ActionContext.capture` + `Registry#for_view` is
  the only answer to "what can I do here", and the palette's typed search finds the focused
  tab's actions through it. Do not compute that a second way.
- A key change runs the boot validators (`validate_chords!`, `validate_menu_keys!`,
  `validate_intents!`). Run `spec/verbs/registry_reach_spec.cr` and the guard specs above
  before the full suite.

## Commands

`just --list` shows everything. The ones that matter:

| Task | Command |
| --- | --- |
| Build (debug, → `bin/gori`) | `just build` (`shards build`) |
| Full suite | `just test` (`crystal spec --no-debug`; a crashing example's backtrace then lacks file:line — rerun that file with `just test-file`) |
| Specs mirroring your change | `just test-changed` (`scripts/spec_for_changes.sh`, against `origin/main`; `just test-changed HEAD` for uncommitted edits only) — the 3–9 s pre-flight before the ~35 s suite compile |
| One file or dir | `just test-file spec/store_spec.cr` |
| One area | `just test-tui`, `test-store`, `test-proxy`, `test-verb`, `test-repeater`, `test-discover`, `test-miner`, `test-oast`, `test-sequencer`, `test-import`, `test-mcp`, `test-settings` |
| Format + lint check | `just check` (`crystal tool format --check src spec bench scripts`, then ameba) |
| Lint diff gate | `just lint-gate` (`scripts/ameba_gate.sh`, fails when a changed file gained ameba findings) |
| Format + autofix | `just fix` |
| Type-check `bench/` | `just benchmark-check` (`scripts/bench_check.sh`) |
| Proxy benchmark | `just benchmark` |
| Seed a demo project | `just seed-demo` (`scripts/seed_demo.cr`) |
| Version consistency | `just vc` |
| nix/shards.nix drift | `just nix-shards-check` (`scripts/nix_shards_check.cr`) |

What CI gates, and what it does not:

- **Gated:** `shards build`, `crystal spec`, `crystal tool format --check src spec bench scripts`,
  `scripts/bench_check.sh`, and `scripts/nix_shards_check.cr` (nix/shards.nix against shard.lock).
  Format, bench and the shards gate are real gates — `just test` touches none of them, so a green
  suite is not a green CI.
- **Gated as a diff, on pull requests:** ameba. The full run is not a gate — it carries a
  large pre-existing backlog, mostly `Metrics/CyclomaticComplexity` in the TUI (the
  reasoning is in `.ameba.yml` and above the `lint-gate` job in `ci.yml`) — but
  `scripts/ameba_gate.sh` fails when any file you changed has MORE findings than it had on
  `main`, and a new file starts from zero. `just lint-gate` runs it locally; judge the full
  `just check` output on the files *you* touched.
- CI tests your branch, **not the merge result** — the `merge_group` trigger is inert until a
  merge queue is enabled. Re-run the build and the suite after every rebase.
- ameba runs as the source file in `lib/ameba/bin/ameba.cr`, not a `bin/ameba` binary.
- Two checkouts compiling at once share `~/.cache/crystal`. In a second worktree, set
  `CRYSTAL_CACHE_DIR` to something local before building.

## Repo map

`src/main.cr` → `src/gori.cr` → `src/gori/`. Specs under `spec/` mirror the source tree:
`spec/<dir>/<name>_spec.cr` covers `src/gori/<dir>/<name>.cr`. The root of `spec/` holds two
kinds of file and nothing else — the spec for a top-level source file (`spec/scope_spec.cr` ↔
`src/gori/scope.cr`), and a cross-cutting **seam** spec that asserts a property of several
subsystems at once and so mirrors no single file (`layering_spec.cr`, `send_seam_provenance_spec.cr`).

| Path | What |
| --- | --- |
| `proxy/` | the MITM proxy: codec, conn, h2, tls, ws (directory-only, there is no `proxy.cr`); `h2/stream_gate/` is a class-reopen slice pair |
| `store.cr` + `store/` | SQLite persistence, migrations, reads |
| `tui/` | terminal UI: views, `controllers/`, and the class-reopen slices in `runner/`, `repeater_view/` + `intercept_view/` |
| `verb.cr` + `verb/` + `verbs/` | the TUI command system (definitions, keymap, `ExecContext`) |
| `cli/` | the `gori run` suite |
| `mcp/` | the MCP server and its tools |
| `scope.cr`, `outbound.cr` | scope model and the active-traffic chokepoint |
| `ql.cr`, `filter_ast.cr` | the query language behind every filter |
| one dir per tool | `repeater/`, `fuzz/`, `miner/`, `discover/`, `sequencer/`, `probe/`, `oast/`, `decoder/`, `import/`, `jwt/` |

## House rules

### Commit messages

```
type(scope): what changed, imperative (#123)
```

- One subject line, under ~72 characters, ending with the issue or PR number.
- `type` is `feat`, `fix`, `refactor`, `docs`, `style` or `chore`. `scope` is the subsystem
  (`proxy`, `store`, `tui`, `cli`, `mcp`, …), comma-joined only when a change really spans two.
- A body is optional, and a few lines when there is one: what changed, plus the *why* the diff
  cannot show. The investigation that produced the change belongs in the PR body; a decision
  that refines a principle belongs in DESIGN.md §7. `git log` has multi-page bodies — those are
  history, not a template.
- One theme per commit. A drive-by format or rename of unrelated files goes in its own commit.
- **No AI attribution anywhere** — commit, PR body or issue. End after the content and any real
  human `Co-authored-by:` trailer.

### CHANGELOG

`CHANGELOG.md` is the source for release notes, so an entry has to be liftable exactly as written.

- One line under `## Unreleased` for anything a user would notice. A refactor, a spec or an
  internal cleanup gets none.
- **One line per theme**, plain prose, one or two sentences, issue/PR numbers in parentheses at
  the end. If it has to be read twice, it is too long (#709).
- Join the existing theme line instead of adding another bullet about the same area.
- Fixing something still under `## Unreleased` means **editing the line already there**, not
  appending "…and then fixed it". The section says what will ship, not what happened.
- The reasoning that justifies a change is not a changelog entry. PR body, or DESIGN.md §7.

### Branches and PRs

- Branch off `main` as `hahwul/<topic>` — `fix-729-expect-continue`, `feat-733-ws-over-h2`,
  `audit-miner-defects`, `docs-…`. `main` takes merges, not direct commits.
- Keep a change scoped and behavior-preserving unless it is explicitly a behavior change; call
  out any intentional behavior change in the PR description.
- The PR body is where the long form goes: what you measured, what you ruled out, why this
  shape. That is the one place length pays for itself.

### Before you commit

- `just test-changed` while iterating, then `just check`, `just test` and `just benchmark-check` green. If you touched `scripts/`, also
  type-check it — nothing else compiles most of it (`crystal build --no-codegen scripts/seed_demo.cr`;
  `scripts/nix_shards_check.cr` is the exception, since `just check` and CI now run it).
- **Format only the files you changed** (`crystal tool format <files>`). A whole-tree format
  rewrites 100+ unrelated files due to Crystal version drift.
- Add or update specs mirroring the source you touched. `spec/spec_helper.cr` points
  `GORI_HOME` at a tempdir before requiring gori; engine specs that are not exercising the
  scope gate use the `ungated_outbound` helper rather than inventing a decision. A
  store-backed example uses its `with_store` (and MCP examples `tools_for`) rather than
  pasting a copy — a file that genuinely needs a different shape keeps a file-private one,
  which shadows the shared helper inside that file only.
- A user-visible change gets its CHANGELOG line, in the shape above.
- If your change makes a `DESIGN.md` section wrong, fix that section in the same PR, and
  append to the §7 decision log instead of quietly widening a principle to fit.
- Changing `shard.lock` means regenerating `nix/shards.nix` (`just nix-shards`) in the same commit. CI enforces it (`just nix-shards-check`); skipping it is otherwise silent, since the flake keeps building the old revisions.

## Traps

- Running a whole-tree `crystal tool format` and burying your diff.
- Building or benchmarking with `-Dpreview_mt`.
- Re-deriving a request-line safety check next to a new caller instead of calling
  `request_token_safe?`.
- "Sanitizing" bytes the operator handed gori to replay. That is the payload.
- Making the response framing rule as strict as the request rule.
- Wiring the verb registry into CLI or MCP to close a parity gap.
- Adding a `PlanError::Reason` member: three surfaces `case` it exhaustively.
- Crystal has no `override`, so a subclass silently shadows a base-class contract method.
  Audit overlay and controller subclasses for accidental shadowing.
- Shipping a green `just test` without `just check` and `just benchmark-check`: CI gates both.
- Picking a free-looking menu letter by hand, or copying one from an issue's "free letters" list
  (those go stale within days). Use the lexicon or a family, and let the boot checks and the R1
  guard decide.

## Where to read next

[DESIGN.md](.github/DESIGN.md) §1 (principles P0–P8) → §2 (architecture) → §2.1 (layering) → §3
(scope) → §7 (decision log, append-only, dated).
[CONTRIBUTING.md](.github/CONTRIBUTING.md) for setup and PR rules. [README.md](README.md) for the
product surface.
