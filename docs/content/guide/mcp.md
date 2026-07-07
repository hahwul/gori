+++
title = "MCP Server"
description = "Drive gori from an AI agent or script over the Model Context Protocol."
+++

gori ships a built-in **MCP (Model Context Protocol) server**. Instead of embedding a chat window in the TUI, gori exposes its project over a clean tool interface so any MCP-capable agent — Claude, Codex, Grok, and others — can read your traffic and drive the tools.

```bash
gori mcp
```

The server speaks JSON-RPC 2.0 over stdio: STDOUT carries the protocol, STDERR carries logs. With no `--db` or `--project` it serves the most-recently-active project.

## Choosing a Project

```bash
gori mcp --project my-engagement   # serve a named project's database
gori mcp --db /path/to/project.db  # serve a specific database file
```

## Read-Only Mode

By default the server also exposes action tools that send live requests and write findings. To expose only the read tools — safe for handing a project to an untrusted agent — start it read-only:

```bash
gori mcp --read-only
```

## Installing Into an Agent

gori can write the MCP configuration for common clients for you:

| Flag | Client |
|------|--------|
| `--install-claude` | Claude Desktop |
| `--install-claude-code` | Claude Code |
| `--install-codex` | Codex |
| `--install-agy` | Antigravity |
| `--install-grok` | Grok |

```bash
gori mcp --install-claude-code
```

## Tools

**Read tools** (always available):

| Tool | Purpose |
|------|---------|
| `list_history` | List flows newest-first, with optional QL and pagination |
| `get_flow` | Full request + response for one flow |
| `list_sitemap` | Distinct endpoints (host, method, path) |
| `list_findings` / `get_finding` | Read triaged findings |
| `list_scope` | Current scope include/exclude rules |
| `project_info` | Flow / finding counts and which database is served |
| `get_current_context` | What the user is viewing in the TUI right now |
| `get_replay_context` | Replay workbench state and saved sessions |
| `ql_reference` | The query-language reference |

**Action tools** (disabled by `--read-only`):

| Tool | Purpose |
|------|---------|
| `send_request` | Send / replay an HTTP request (active) |
| `create_replay` / `update_replay` / `delete_replay` | Manage Replay sessions |
| `create_finding` / `update_finding` | Record and update findings |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Drive the fuzzer |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Drive the param miner |

> Action tools are capped for safety: fuzz and mine jobs are limited in total requests, concurrency, and stored results.

## Why a Seam, Not a Chatbox

gori deliberately has no in-tool AI chat. Keeping the intelligence *outside* the tool — reachable through MCP — means you choose the model, your traffic isn't shipped anywhere you didn't intend, and the same interface serves scripts and agents alike. `gori run` covers the non-interactive path; MCP covers the interactive-agent path.

## Next Steps

- [CLI Reference](/reference/cli/) — full `gori mcp` flags
- [Query Language](/reference/query-language/) — the syntax agents use to filter
