# Agent eval

Measures whether an agent with gori MCP attached gets capture-analysis tasks right, and at
what cost, per catalogue profile (`@minimal`, `@recon`, full, full `--read-only`, full `deferred`), against a
`script` control with no gori at all. It exists to decide the default catalogue and how long
tool descriptions should be, and whether gori beats plain scripting at all — not to gate CI:
runs are nondeterministic and cost money. Parser specs run without agent calls; CI also
format-checks and type-checks `eval/*.cr`
(`scripts/script_check.sh`), so the harness cannot rot against the Store API unnoticed.

```sh
just build
just eval-fixtures          # eval/out/fixtures/<name>.db + <name>.truth.json
just eval --n=3 --jobs=4    # Claude Code (default), all tasks × all profiles
just eval --agent=codex --n=1 --jobs=1 --tasks=t0-request-ref --profiles=analysis,minimal,script
# --model=M selects the agent's model; --tasks=GLOB and --profiles=LIST narrow the run
# re-summarize a run, and compare it with an older one (no build or agent calls):
crystal run eval/run.cr -- --report=eval/out/runs/<stamp> --baseline=eval/out/runs/<older>
```

Select `--agent=claude` (default) or `--agent=codex`. The selected CLI must be on PATH and
logged in. Claude defaults to `sonnet`; Codex uses its built-in default unless `--model` is
set. Use an explicit model for reproducible comparisons. `--budget` is Claude-only (default
$2 per run); Codex rejects it because `codex exec` has no USD budget limit. Start with one
task and `--n=1` before a full paid run.

### Claude Code

Needs the `claude` CLI, logged in. Each run gets a copy of the fixture db, an empty
`GORI_HOME` and an empty cwd under the system temp dir (a cwd inside the repo hands the agent
the repo's `AGENTS.md` and Claude Code project memory; the summary voids such a run), and
`claude` runs with `--setting-sources ""
--strict-mcp-config --tools ""`, so the only tools the agent sees are gori's. The summary
flags any run whose init listed another tool.

`--tools ""` also drops Claude Code's `ToolSearch`, so those profiles load every gori schema
upfront. The `deferred` profile keeps `ToolSearch` and serves the full catalogue, so only the
tool names load and the agent fetches each schema before calling it: Claude Code's default.
It is the profile to judge Claude Code's input-token cost by; the others measure a client
that loads the whole catalogue. Its `calls` include the `ToolSearch` calls.

### Codex

Needs a Codex CLI supporting `exec --json --ephemeral --ignore-user-config --ignore-rules`
(tested with 0.169.0). It runs outside the repo, ignores user config and execpolicy rules,
and disables project instructions, automatic skill instructions and memory. Codex still
loads global `AGENTS.md` / `AGENTS.override.md` despite these options, so the harness refuses
to start if either exists under `CODEX_HOME`. Use a separately logged-in clean `CODEX_HOME`
in that case; do not copy rotating OAuth credentials between homes. The harness keeps
the original authentication storage so OAuth token refresh remains coordinated with other
Codex sessions. Custom provider and auth-storage settings in user config are not loaded;
use the default file-backed login or an inherited API key. Personal MCP servers and plugins
are excluded. Shell is disabled for MCP profiles; web search, image viewing, apps,
plugins, tool search and subagents are disabled. The catalogue loads upfront. Native tools
without an off switch (such as patching) can still be advertised; the read-only sandbox
restricts writes, and foreign action events void the run.

Default profiles are `analysis,minimal,recon,full,full-ro,script`. `deferred` is Claude Code's
`ToolSearch` experiment, so explicitly selecting it with Codex is rejected.
`script` uses Codex's shell with a read-only sandbox and no MCP server. Unlike Claude's
init event, Codex JSONL does not expose a tool inventory: the summary detects foreign
**called** tools rather than every advertised tool. Plan bookkeeping is ignored.

Eval prompts should not explicitly invoke personal skills (`$skill`); automatic skill
instructions are disabled, but explicit skill invocation remains a Codex capability.

### Shared tasks and reports

The `script` profile is the control. The agent gets no MCP server, shell tools (`Bash` and
`Read` for Claude, shell for Codex), and the same fixture as `capture.har` (exported by
`gori run history --format har`) in a cwd under the system temp dir, outside the repo. A flow's id is its 1-based position in
`log.entries`; the harness refuses to start if the export skipped a flow. That `Bash` can
read the whole host, so a run whose tool input names the answer key or `eval/` is counted
apart as peeked.

Output lands in `eval/out/runs/<stamp>/`: `results.jsonl` (one row per run: pass, answer,
expected answer, agent, model, tool calls, tokens, cost) and each run's raw `stream.jsonl`.

The summary groups by agent and model, then has three parts: a task × profile table; a
per-profile rollup (pass rate, median input tokens and its multiple of `@minimal`, median
calls, the most common first tool call); and every failed run's answer beside the expected one. Errored runs and runs whose init
listed a tool outside its profile, or peeked, are counted apart, never as failures. Judge cost by input tokens:
Claude's `cost_usd` is noisy because parallel runs share a prompt cache. Codex does not
report USD cost, so its `cost_usd` is null and the table shows `-`; its input-token total
already includes cached tokens. `--baseline` adds the older
run's pass rate and input-token change to each profile's row for the same agent and model,
which is how to check a tool-description edit: a shift in first calls (say, a `ql_reference`
call before every query) shows up there before it shows up in pass rates. Old reports without metadata still
work as `claude / unknown` and compare only to other legacy reports. A nonzero CLI exit,
missing completion event or fatal stream error voids the run even if it printed an answer.

## Tasks

`tasks/<id>.yml` names a fixture, a tier, a grading mode (`set`: order-free, ids or strings;
`exact`: numbers compare as numbers) and the prompt.
The expected answer is not in the task: `fixtures.cr` writes it to the fixture's answer
key while inserting the flows, keyed by task id, so it is always the id or value the store
actually holds.

| Tier | What it measures |
| --- | --- |
| T0 | reads the capture and states a fact correctly |
| T1 | does not mistake a paged, cut or empty answer for absence |
| T2 | (not yet) does not send or write what it was not asked to |

To add a task: plant its fact in a fixture builder, return the answer under the task's id,
write the yml, rerun `just eval-fixtures`.

`analysis` uses `--tools=@analysis`: five readers for a capture already bound by the harness,
without project switching or operator messages. It is available to both agent CLIs.
The profile rollup prints total input tokens and maximum calls as well as medians, so an
improved median cannot hide a costly task.

`t1-deep-body` replaces `t0-deep-body`: its answer is after the 512 KiB column read cap and
the 64 KiB full-body view. `t1-cursor-values` asks for 620 unpredictable header values in
order, beyond the 500-row page maximum; a count cannot answer it. The fixture builder
checks those size boundaries. Existing count tasks remain as count-only controls.
