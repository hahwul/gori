# Agent eval

Measures whether an agent with gori MCP attached gets capture-analysis tasks right, and at
what cost, per catalogue profile (`@minimal`, `@recon`, full, full `--read-only`). It exists
to decide the default catalogue and how long tool descriptions should be — not to gate CI:
runs are nondeterministic and cost money.

```sh
just build
just eval-fixtures          # eval/out/fixtures/<name>.db + <name>.truth.json
just eval --n=3 --jobs=4    # all tasks × all profiles; --tasks=GLOB --profiles=LIST --model=M
```

Needs the `claude` CLI, logged in. Each run gets a copy of the fixture db, an empty
`GORI_HOME` and an empty cwd, and `claude` runs with `--setting-sources ""
--strict-mcp-config --tools ""`, so the only tools the agent sees are gori's. The summary
flags any run whose init listed another tool.

Output lands in `eval/out/runs/<stamp>/`: `results.jsonl` (one row per run: pass, answer,
tool calls, tokens, cost) and each run's raw `stream.jsonl`.

## Tasks

`tasks/<id>.yml` names a fixture, a tier, a grading mode (`set` or `exact`) and the prompt.
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
