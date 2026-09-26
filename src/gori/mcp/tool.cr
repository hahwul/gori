module Gori
  module MCP
    # Declares a `Tools` handler as the implementation of one MCP tool:
    #
    #     @[Tool("delete_note", gated: true, agent_action: true)]
    #     private def delete_note(h) : Result
    #
    # `Tools` harvests every annotated method in its `macro finished` block (the "Tool
    # registry" section of mcp/tools.cr) into the name → handler dispatch and the flag sets
    # named below. A tool is therefore declared exactly once, next to its body, and adding
    # one touches only its own `tools/*.cr` file. The JSON Schema it advertises still lives
    # in that file's `list_*_tools`; `spec/mcp/tool_registry_spec.cr` holds the two in step.
    #
    # Positional argument: the tool name, as advertised by tools/list. A handler with one
    # parameter receives the call's argument hash; a zero-parameter handler is called bare.
    #
    # Flags, all defaulting to false:
    #
    # - `gated` — an action or write tool. Refused with TOOL_DISABLED under `gori mcp
    #   --read-only` (`Tools#gated`) before the handler runs. Project selection is the
    #   deliberate exception (`switch_project` always, `create_project` when unbound) so
    #   install-and-use works on a fresh machine; those handlers gate themselves.
    #
    # - `agent_action` — #124: a tool whose SUCCESSFUL (or failed) execution is a real
    #   mutation or outbound send worth recording in the event feed as a visible "agent
    #   action", so the human can see (via list_events, and later the notification ring)
    #   what the AI did. Deliberately EXCLUDES gated READ tools (fuzz_status/results,
    #   mine_status/results, list_jobs, get_job, preview_rule) and project-management tools
    #   (switch_project reopens @store, so a post-hoc append would land in the wrong DB):
    #   only in-project side effects. `export_project` / `import_project` are project tools that
    #   are here anyway: neither moves the binding, so the entry lands in the project the agent
    #   is working in, and an unredacted copy of an engagement written to disk — or a foreign
    #   one registered beside it — is exactly what the operator should see. The intercept write
    #   verbs act on LIVE traffic the human is holding — forwarding, dropping, or rewriting bytes mid-flight is the single
    #   most consequential thing an agent can do here, so they belong in the feed more than
    #   any store mutation does; toggle/set_filter/set_direction change what the proxy HOLDS
    #   next, which silently reshapes the human's queue, and are recorded for the same
    #   reason. `grpc_reflect` is an outbound request AND a project mutation (the descriptor
    #   cache), `grpc_forget` mutates the same row. `move_repeater` is here for the same
    #   reason `move_color_rule` is: order is what the operator navigates by, so an agent
    #   that rearranges the strip has changed something the human will notice and should be
    #   able to trace. `probe_scan` is the one call-shaped case — a READ tool whose
    #   `active: true` mode sends real requests — and is decided per call in
    #   `Tools#agent_action?`, not here.
    #
    # - `env_refresh` — R2-3: a tool that READS or WRITES the per-project `$KEY` env vars.
    #   Env vars live in a process-global (Settings.project_env_vars) loaded once at bind
    #   time (initialize / switch_project's Env.load_project), so a mid-session CLI change
    #   (`gori run project env set KEY val`) is otherwise invisible to an already-running MCP
    #   server. `Tools#call` reloads from the store before dispatching any of these. Three
    #   populations, all of which need the fresh value: active/outbound tools that EXPAND or
    #   MASK `$KEY` at call time; `list_env`, which would otherwise REPORT a stale set as
    #   fact; and `set_env_var`/`delete_env_var`, which read-modify-WRITE the whole array
    #   (Env.save_project persists it wholesale) — on a stale copy that silently DELETES
    #   every var another process added since we bound. The same refresh re-reads the
    #   session-slot list (#1216), so every tool that SENDS under a slot is here too:
    #   `probe_scan` (its `active: true` sender overlays the active slot) and `authorize_start`
    #   — which expands no `$KEY` (its backend marks every buffer verbatim, see
    #   `Authorize::Engine#send_one`) but resolves each identity's `$BIND` values from per-slot
    #   tables that only a slot reload prunes, so a slot a peer edited or re-created would
    #   otherwise go out with the discarded identity's captured credential. Deliberately
    #   EXCLUDES other read tools and the async *_status / *_results / *_stop pollers (a
    #   running job already captured its fully expanded template at build time).
    #
    # - `read_only` — the `annotations.readOnlyHint` an MCP client reads to decide whether a
    #   call needs the human's approval. DEFAULTS to `!gated`, which is right for the great
    #   majority: `--read-only` serves exactly the tools that neither mutate nor dial. The
    #   flag is for the two populations where the gate and the hint disagree, and it is
    #   spelled on those and refused as redundant anywhere else, so the exceptions stay a
    #   short readable list instead of rotting into noise:
    #
    #   - `read_only: true` on a GATED read — the `*_status` / `*_results` pollers,
    #     `list_jobs`, `get_job`, `preview_rule`. These are gated because the workbench they
    #     report on is, not because they change anything.
    #   - `read_only: false` on an UNGATED writer — the handful that gate themselves instead
    #     of being gated: `switch_project` and `create_project` (so install-and-use works on
    #     a fresh machine), `probe_scan` (whose `active: true` mode SENDS), and
    #     `operator_messages`, which can write delivery rows when actions are allowed.
    #
    #   `read_only: true` with `agent_action: true` is a contradiction the macro refuses: an
    #   agent action is by definition a mutation or an outbound send.
    #
    # - `unbound` — works with no project store open; every other tool is answered with
    #   NO_PROJECT (`Tools#no_project`) before dispatch. `diff_projects` qualifies because
    #   both sides can be NAMED, and then the diff needs no binding at all — an agent
    #   comparing two past engagements should not have to bind one of them first; with `to`
    #   omitted it still refuses, from `resolve_diff_target`, with the same NO_PROJECT
    #   sentence, because the default side IS the bound project.
    #
    # - `requires` — other MCP tools this tool's advertised description or schema tells the
    #   agent it must call as part of the same workflow. `--tools` adds these transitively;
    #   if the operator explicitly excludes one while retaining its parent, startup refuses
    #   the conflicting filter rather than widening the allowlist or advertising a broken
    #   workflow.
    # - `permission` — the operator's coarse switch this tool sits behind, one of
    #   `Settings::MCP_PERMISSION_KEYS` (Preferences › AI › MCP permissions): `send` for a
    #   tool that dials a target or an OAST server (and the pollers of the jobs those start),
    #   `intercept` for the tools that act on held traffic, `projects` for the ones that move
    #   the binding or copy a project in or out, `write` for every other in-project write. A
    #   denied group is left out of `tools/list` and refused with TOOL_DISABLED, the same two
    #   answers `--read-only` gives. Required on every `agent_action` tool; the rest of the
    #   writers that carry one are named in spec/mcp/tool_permissions_spec.cr, which also holds the
    #   three that are deliberately unswitched: the operator channel (`operator_messages`,
    #   `reply_to_operator`) and `probe_scan`, whose `active: true` mode is refused per call.
    annotation Tool
    end
  end
end
