+++
title = "AI Setup"
description = "Connect an AI agent to gori over MCP: install the server into your client, pin the project, and drive your first request."
weight = 30
+++

gori has three entry points over one project and one engine: `gori` (the TUI, for you), `gori run` (the headless CLI, for scripts), and `gori mcp` (the [MCP server](/guide/mcp/), for AI agents). This page is the AI path. It gets an agent connected to a gori project and running its first request.

There is no chat window inside the TUI. You bring your own model and client; gori exposes the project over a clean tool interface, and the agent reads your traffic and drives the same tools you do. For the full tool catalog and deeper topics (live intercept, the design rationale), see the [MCP Server guide](/guide/mcp/).

> **Before you begin.** [Install gori](/getting-started/installation/) and have an MCP-capable client ready (Claude Code, Claude Desktop, OpenAI Codex, Antigravity, Grok, and others).

## 1. Install the server into your client

`gori mcp` speaks JSON-RPC 2.0 over stdio: an AI client spawns it, sends requests on STDIN, and reads results on STDOUT (STDERR carries logs). Rather than hand-editing each client's config, let gori write it for you:

```bash
gori mcp --install-claude-code   # Claude Code
gori mcp --install-claude        # Claude Desktop
gori mcp --install-codex         # OpenAI Codex
gori mcp --install-agy           # Antigravity CLI
gori mcp --install-grok          # Grok
```

| Flag | Client | Config written |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

Each command prints the file it wrote and the exact launch command it recorded. Codex and Grok use a TOML `[mcp_servers.gori]` table, not JSON. Restart the client (or reopen the session) afterward so it reloads its MCP servers.

Wiring it up by hand instead? The server is just the `gori mcp` command over stdio. Point any MCP client at that command with no extra arguments.

**Checkpoint.** Your client lists gori's tools (`list_history`, `send_request`, `project_info`, and the rest). If they do not appear, confirm the client was restarted and that `gori` is on the `PATH` the client uses.

## 2. Bind a project (or let the agent pick one)

Each gori project is its own database. After install, `gori mcp` always connects:

| How the client starts MCP | What happens |
|---------------------------|--------------|
| Inside a Git repository | Path-binds that workspace to its own gori project |
| Outside a Git repository (common for Desktop / global agents) | Starts **unbound** — handshake succeeds; the agent calls `list_projects` / `create_project` / `switch_project` before traffic tools |
| Installed with `--project` / `--db` | Serves that project from the first tool call |

Have the agent call `project_info` first. When `bound` is false, it should list or create a project (create auto-binds when unbound), then switch if needed. When bound, confirm the name, database path, and selection source before mutating data.

To pin a fixed engagement at install time:

```bash
gori mcp --project my-engagement --install-codex     # a named project's database
gori mcp --db /path/to/project.db --install-claude-code   # a specific database file
```

The full selection rules live in [Choosing a Project](/guide/mcp/#choosing-a-project).

## 3. Hand off safely with read-only

By default the server also exposes action tools that send live requests and write issues. To give an agent (or a teammate you do not fully trust with the target) only the read tools, install it read-only:

```bash
gori mcp --read-only --install-claude-code
```

Read-only keeps `list_history`, `get_flow`, `list_sitemap`, and the other inspection tools while disabling `send_request`, issue writes, and the intercept mutators. Pure-compute helpers like `decode` and `jwt_decode` stay available because they never touch the network or your data.

## 4. Drive your first request

With the tools live, prompt the agent in plain language. It maps your intent onto the read and action tools:

> "List the last 20 POSTs to `/login`, resend the newest one with a different password, and open an issue if the status code changes."

A capable agent turns that into a short tool sequence:

```text
→ list_history   method:POST path~/login   (newest 20)
→ get_flow       <the newest flow>
→ send_request   POST /login  (edited body)
→ create_issue   "Auth bypass on /login" severity:high
```

Agent actions are not silent. Each one lands in gori's notification center tagged as agent-driven and rendered differently from your own actions, so you can see what a co-pilot did to a project while you were reading another tab.

## Next Steps

- [MCP Server](/guide/mcp/): the full tool catalog, live intercept, and why gori uses an MCP seam
- [CLI Reference](/reference/cli/): every `gori mcp` flag
- [Query Language](/reference/query-language/): the filter syntax agents use with `list_history`
