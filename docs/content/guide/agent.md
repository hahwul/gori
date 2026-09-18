+++
title = "Agent"
description = "Host your own Claude Code as a child process inside gori, with this project's MCP tools from its first turn."
weight = 77

[extra]
group = "Workbenches"
+++

The **Agent** tab hosts the operator's own coding agent — Claude Code first — as a child process of gori, and shows the conversation right there in the tab. gori does not talk to a model itself: the decision recorded around [#98](https://github.com/hahwul/gori/issues/98) stands, there is no built-in AI chat, and this tab does not change that. What it hosts is the agent you already run on your machine — the same `claude` you'd type at a shell — with this project's own MCP tools handed to it before its first turn, so it can read your History, Sitemap, Repeater tabs, and Issues without you pasting anything in.

## What It Is Not

- It is not a second AI feature living beside `gori mcp` — it *drives* `gori mcp`, over a config file gori writes for it, the same server an external agent would connect to.
- gori never decides anything with a model. Every mutating action the agent takes is a tool call the child process makes, and every one of those still goes through gori's own tool surface and, for outbound traffic, [Outbound](/guide/proxy/#scope) scope and sandbox.
- It is not a place to type a one-off question about the target and get an answer synthesized from nothing — the agent's context comes from your project, over MCP, exactly like any other MCP client.

## Requirements

- The `claude` binary on `PATH` — or `agent.command` set to a path, if you keep more than one build around.
- A Claude Code already logged in. gori spawns it, it does not authenticate it.

When the binary is missing, the tab body shows install guidance instead of an empty transcript, rather than failing silently.

## The Tab

Three parts, top to bottom:

- **Transcript pane.** The conversation so far. A tool call and its result fold to one line each by default — `▸ Bash(git status)` then `  ✓ 12 lines` — so a long `ls` or a fetched response body does not bury the two sentences around it. `↵`, or a click, unfolds the call under the cursor and shows the input and the output; the same key folds it back.
- **Status band.** One row: `idle · <model> · 3 turns · $0.14` between turns, `running ⟳` while the agent is working, `⚠ 2 permission requests` when tool calls are waiting on you, or `dead: <reason>` once the child is gone.
- **Input pane.** Multi-line, with the same insert/read split as Notes: `i` enters insert mode, `esc` returns to read mode, and `↵` in read mode sends (also `^S`, so you never have to leave insert mode to send).

| Key | Action |
|-----|--------|
| `i` | Insert mode |
| `esc` | Read mode |
| `↵` (read mode) / `^S` | Send (`agent.send`) |
| `^X` / `agent.interrupt` | Cancel the running turn |
| `agent.history` | Open a picker of past conversations for this project (read-only view) |
| `agent.restart` | Resume the last conversation (`--resume`) |
| `agent.new` | Start a fresh conversation |
| `agent.fold` | Toggle the tool call under the cursor |
| `agent.copy` | Copy the selection, or the whole transcript with nothing selected |

## Asking From Another Tab

`agent.ask` is a Global verb — it works from any tab, not just Agent — reachable from the command palette as **"Ask the agent"**. It opens a one-line prompt, sends what you type as a turn, and returns you to whatever you were doing: you never have to switch to the Agent tab to fire off a question. When the reply lands, it arrives as a notification you can jump to, same as any other background result.

## Permissions

When the agent wants to run a tool the CLI would itself prompt for, gori raises a card with three answers instead of letting the child decide alone:

| Key | Answer |
|-----|--------|
| `a` | Allow |
| `d` / `esc` | Deny |
| `s` | Allow for this session |

"Allow for this session" is a grant gori keeps in memory for as long as this one hosted conversation runs — it is not written to the operator's own `~/.claude/settings.json`, and the CLI's own "add a rule" suggestion is never offered. gori changes what happens in gori; it does not edit your Claude Code configuration behind your back.

If the card arrives while you are on another tab, a notification (`source: agent`) points back at the Agent tab, and the request stays queued — the CLI holds that tool call, and the whole turn behind it, until someone answers it there.

Two things worth saying plainly:

- **A tool your own Claude Code settings already allow-list never produces a prompt.** gori can only gate what the CLI asks it about; a rule you've already trusted in your own settings runs without ever reaching this card.
- **So does a permission mode that never asks.** With `permissions.defaultMode` set to `auto` or `bypassPermissions` in your own Claude Code settings, the CLI decides every tool call itself and the card never appears. To have gori ask, put `--permission-mode default` in `agent.args`.
- **`agent.permission_policy = "deny"` auto-denies everything.** There is deliberately no policy value that auto-*allows* — the choice is "ask me" or "refuse it all", never "run whatever it wants."

## History and Resume

Conversations live in the project database (`agent_sessions`, `agent_messages`) — the same database as your captured traffic, so an agent conversation about this engagement travels with it. Streamed deltas are never stored; the completed message is, once it is whole.

`agent.history` opens a past conversation read-only; `esc` returns to the live one. `agent.restart` (`⇧R`) resumes the live conversation's CLI context with `--resume` after the child has exited, so the model picks back up where it left off, not just gori's transcript of it. gori's copy survives even if the CLI's own session state is later deleted — the two are related but the store row is not a cache of the CLI's file.

`agent.history_keep` (default 50) bounds how many past conversations are kept per project; past that, the oldest are pruned.

## Settings

Section `agent` in `settings.json` (Preferences → the settings picker, or edit the file directly):

| Key | Default | Meaning |
|-----|---------|---------|
| `command` | `"claude"` | The binary to spawn — a name resolved through `PATH`, or an absolute path |
| `args` | `""` | Extra argv appended after everything gori builds itself, one text field tokenized like a shell's argv (no shell — no `$`, `;`, `` ` ``, or `\|`) |
| `model` | `""` | Passed as `--model` when set; empty means the CLI's own default |
| `mcp_read_only` | `false` | Starts the agent's `gori` MCP server with `--read-only`, so it can read your project but every mutating tool is refused at the server rather than merely gated by a permission prompt |
| `system_prompt_append` | `""` | Appended after gori's own orientation preamble, never in place of it |
| `permission_policy` | `"ask"` | `"ask"` raises the permission card; `"deny"` auto-denies every tool the CLI would have prompted for |
| `history_keep` | `50` | Conversations kept per project before the oldest are pruned |

Every key and its exact behavior: [`agent` in the configuration reference](/reference/config/#agent).

`mcp_read_only` is the one worth pausing on: full actions are the default. An agent you spawn here can send requests, fuzz, mine, and file issues in this project from its first turn, exactly as if you'd typed the commands yourself over MCP — flip `mcp_read_only` on when you want it to look without touching anything.

## Miss Ring

[Miss Ring](/guide/settings/#appearance), the companion mascot, reacts to the hosted agent when Companion is turned on (off by default, like every other companion behaviour): a warn face and bubble when a permission request arrives while you're on another tab, a happy face with the first line of the reply when a turn finishes while you're on another tab, and an error face when the child dies.

## What Happens to the Child on Quit

Quitting gori, or leaving the project, closes the agent's stdin — the documented clean end of a `stream-json` session — then waits briefly, sends `SIGTERM`, waits again, and finally `SIGKILL`s it if it's still there.

That ladder reaches the `claude` process itself, but Crystal's `Process` has no `setpgid`, so anything the agent spawned on its own — a `sleep` inside a `Bash` tool call, say — is not in a process group gori can signal, and can outlive gori's own exit. The agent's own signal handling is what is supposed to clean those up; a `SIGKILL` of gori (rather than the graceful ladder above) skips that entirely and orphans the whole tree under the agent, not just the agent.

## Limitations

- **Claude Code only, in v1.** The backend seam is written to take another ACP-speaking agent later, but nothing else is wired up yet.
- **The permission-prompt wire protocol is not documented by Anthropic.** gori's side of it is read off Claude Code's own behavior and gated on the CLI advertising the capability it needs (`interrupt_receipt_v1` and friends) — a build that doesn't advertise a capability gori depends on degrades that one feature rather than failing the whole tab.

## Next Steps

- [MCP Server](/guide/mcp/): the same tool surface an external agent gets, and what `agent.mcp_read_only` restricts it to
- [Settings](/guide/settings/): Companion, and where `settings.json` lives
- [Scripting](/guide/scripting/): drive the rest of gori headless, alongside a hosted agent
