# Agent eval

Measures whether an agent with gori MCP attached gets capture-analysis tasks right, and at
what cost, per catalogue profile (`@minimal`, `@recon`, full, full `--read-only`), against a
`script` control with no gori at all. It exists to decide the default catalogue and how long
tool descriptions should be, and whether gori beats plain scripting at all — not to gate CI:
runs are nondeterministic and cost money. CI only format-checks and type-checks `eval/*.cr`
(`scripts/script_check.sh`), so the harness cannot rot against the Store API unnoticed.

```sh
just build
just eval-fixtures          # eval/out/fixtures/<name>.db + <name>.truth.json
just eval --n=3 --jobs=4    # all tasks × all profiles; --tasks=GLOB --profiles=LIST --model=M
# re-summarize a run, and compare it with an older one (no build, no claude calls):
crystal run eval/run.cr -- --report=eval/out/runs/<stamp> --baseline=eval/out/runs/<older>
```

Needs the `claude` CLI, logged in. Each run gets a copy of the fixture db, an empty
`GORI_HOME` and an empty cwd, and `claude` runs with `--setting-sources ""
--strict-mcp-config --tools ""`, so the only tools the agent sees are gori's. The summary
flags any run whose init listed another tool.

The `script` profile is the control. The agent gets no MCP server, only `Bash` and `Read`, and
the same fixture as `capture.har` (exported by `gori run history --format har`) in a cwd under
the system temp dir, outside the repo. A flow's id is its 1-based position in
`log.entries`; the harness refuses to start if the export skipped a flow. That `Bash` can
read the whole host, so a run whose tool input names the answer key or `eval/` is counted
apart as peeked.

Output lands in `eval/out/runs/<stamp>/`: `results.jsonl` (one row per run: pass, answer,
expected answer, tool calls, tokens, cost) and each run's raw `stream.jsonl`.

The summary has three parts: a task × profile table; a per-profile rollup (pass rate, median
input tokens and its multiple of `@minimal`, median calls, the most common first tool call);
and every failed run's answer beside the expected one. Errored runs and runs whose init
listed a tool outside its profile, or peeked, are counted apart, never as failures. Judge cost by input tokens:
`cost_usd` is noisy because parallel runs share a prompt cache. `--baseline` adds the older
run's pass rate and input-token change to each profile's row, which is how to check a
tool-description edit: a shift in first calls (say, a `ql_reference` call before every
query) shows up there before it shows up in pass rates.

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
