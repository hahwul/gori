+++
title = "Run an AI co-pilot session"
description = "Put an agent on the same project over MCP and watch every move it makes — the intelligence lives outside the tool, by design."
weight = 120

[extra]
group = "Wrap up"
+++

gori has no chat window, and that is deliberate: the intelligence lives outside the tool, reached over MCP. You bring the model and the client; gori exposes the project over a clean tool interface, so you choose what runs, your traffic isn't shipped anywhere you didn't intend, and every move the agent makes shows up in the same TUI you're already watching. This playbook connects an agent to a project you already captured and puts it to work — about ten minutes, most of it a one-time install.

> **Before you begin.** You need an existing project with captured traffic — ideally the one from the earlier playbooks — and an MCP-capable client (Claude Code, Claude Desktop, OpenAI Codex, Antigravity, Grok, and others). An agent can send real requests, so keep the project scoped to a target you are authorized to test.

## 1. Install the MCP server

`gori mcp` is a JSON-RPC server the client spawns over stdio: it sends requests on STDIN and reads results on STDOUT. Rather than hand-edit each client's config, let gori write it:

```bash
gori mcp --install-claude-code   # Claude Code
```

Other hosts install the same way: `--install-claude` (Claude Desktop), `--install-codex` (OpenAI Codex), `--install-agy` (Antigravity), `--install-grok` (Grok). Each command prints the file it wrote and the exact launch command it recorded; Codex and Grok write a TOML `[mcp_servers.gori]` table rather than JSON. Restart the client (or reopen the session) afterward so it reloads its MCP servers.

Two choices ride along into that recorded command. **Read-only vs. full access**: by default the agent also gets the action tools (`send_request`, issue writes, the intercept mutators); add `--read-only` to expose only the read tools. **Which project**: run the install from inside your engagement's Git repository and gori path-binds that workspace to its own project; from anywhere else the server starts unbound and the agent picks a project over tools. Pin one explicitly with `--project` or `--db`, and it is written into the recorded command with an absolute path:

```bash
gori mcp --project my-engagement --install-codex
```

**Checkpoint.** Your client lists gori's tools — `list_history`, `get_flow`, `send_request`, `project_info`, and the rest. If they don't appear, confirm the client restarted and that `gori` is on the `PATH` it uses.

## 2. Give the agent a task

With the tools live, prompt the agent in plain language. It maps your intent onto the same tools you drive by hand, against the same project database — not a copy:

> "List the last 20 POSTs to `/login`, resend the newest with a different password, and open an issue if the status code changes."

A capable agent turns that into a short, ordered sequence:

```text
→ list_history   method:POST path~/login   (newest 20)
→ get_flow       <the newest flow>
→ send_request   POST /login  (edited body)
→ create_issue   "Auth bypass on /login" severity:high
```

Tools run one at a time, in the order they arrive, so a slow `send_request` never overlaps the next call and the results come back in order.

**Checkpoint.** A new flow from the agent's `send_request` appears in your **History**, and any issue it filed shows up on the **Issues** tab.

## 3. Watch what it does

You don't have to trust an agent blindly, because none of its actions are silent. Every one lands in gori's **notification center** tagged as coming from an agent and rendered differently from your own, so you can glance over and see what a co-pilot changed — a request it sent, an issue it filed, a rule it wrote — while you were reading another tab.

The same holds inside the intercept loop: an agent can sit in the queue next to you, and each `intercept_forward_edit` it makes is marked as its own. One safety note for a live handoff — once an agent attaches to the intercept queue, gori arms a 30-second auto-forward for held items nobody is watching, so a client that dies mid-hold can't wedge the connection indefinitely.

**Checkpoint.** Open the notification center from the command palette (`Ctrl-P` → notifications) and the agent's actions are there, visibly tagged apart from your own.

## 4. Hand off safely

To hand the project to an agent — or a teammate — you don't fully trust with the target, install it read-only:

```bash
gori mcp --read-only --install-claude-code
```

Read-only keeps every inspection tool (`list_history`, `get_flow`, `list_sitemap`, `compare_flows`) and the pure-compute helpers (`decode`, `jwt_decode`) while disabling `send_request`, issue writes, and the intercept mutators. The agent can read and reason about the whole engagement; it cannot touch the target or change your records.

Scope is the second guardrail, and it holds even with the action tools enabled. An active tool aimed at a host outside — or without — your project scope is refused with a `SCOPE_BLOCKED` error, whether or not the sandbox is on. So even a full-access agent cannot send a stray request to a host you never scoped; it inherits the same guardrail Repeater and the Fuzzer check.

**Checkpoint.** A read-only agent can list history and analyze flows, but `send_request` comes back disabled — and with the action tools on, a request to an out-of-scope host returns `SCOPE_BLOCKED`.

## Next Steps

- [Playbooks](/playbooks/): back to the full list of workflows
- [MCP Server](/guide/mcp/): the full tool catalog, live intercept, and why gori uses an MCP seam
- [AI Setup](/getting-started/ai-setup/): the step-by-step connect-and-drive walkthrough
