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
    #   only in-project side effects. The intercept write verbs act on LIVE traffic the
    #   human is holding — forwarding, dropping, or rewriting bytes mid-flight is the single
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
    #   every var another process added since we bound. Deliberately EXCLUDES other read
    #   tools and the async *_status / *_results / *_stop pollers (a running job already
    #   captured its fully expanded template at build time) — and `authorize_start`, which
    #   is the one active *_start that never expands a `$KEY` at all: an authorize run sends
    #   the CAPTURED bytes under an operator-authored header overlay, so its backend marks
    #   every buffer verbatim (`Fuzz::Backend.all_verbatim`, see `Authorize::Engine#send_one`).
    #   A refresh there would re-read the store for a value nothing on that path reads.
    #
    # - `unbound` — works with no project store open; every other tool is answered with
    #   NO_PROJECT (`Tools#no_project`) before dispatch. `diff_projects` qualifies because
    #   both sides can be NAMED, and then the diff needs no binding at all — an agent
    #   comparing two past engagements should not have to bind one of them first; with `to`
    #   omitted it still refuses, from `resolve_diff_target`, with the same NO_PROJECT
    #   sentence, because the default side IS the bound project.
    annotation Tool
    end
  end
end
