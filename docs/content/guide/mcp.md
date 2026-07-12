+++
title = "MCP Server"
description = "Drive gori from an AI agent or script over the Model Context Protocol."
+++

gori ships a built-in **MCP (Model Context Protocol) server**. Instead of embedding a chat window in the TUI, gori exposes its project over a clean tool interface so any MCP-capable agent — Claude, Codex, Grok, and others — can read your traffic and drive the tools.

<figure class="agent-session" aria-label="Example agent session: an agent finds an IDOR over MCP and logs a finding">
  <div class="agent-session-bar">
    <span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
    <span class="agent-session-title">agent · gori over MCP</span>
  </div>
  <div class="agent-session-body">
    <p class="as-user"><span class="as-who">you</span>Find an IDOR on the users API and log it.</p>
    <p class="as-call"><span class="as-arrow">→</span> <code>list_history</code> <span class="as-args">path~/v1/users status:200</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-args">14 flows — customer and admin tokens</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>send_request</code> <span class="as-args">GET /v1/users/2 · customer token</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-warn">200</span> <span class="as-args">{"id":2,"email":"other-tenant@example.com"} — not the caller's row</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>create_finding</code> <span class="as-args">"IDOR on /v1/users/{id}" severity:high</span></p>
    <p class="as-done"><span class="as-check">✓</span> Finding logged; the request is saved as a Replay session for repro.</p>
  </div>
</figure>

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
| `list_notes` / `get_note` | Read project notes |
| `list_rules` | List the project's Match & Replace rules in apply order |
| `convert` | Run an encode/decode/hash/compress chain over `input` (pure transform; no network or state) |
| `project_info` | Flow / finding counts and which database is served |
| `get_current_context` | What the user is viewing in the TUI right now |
| `get_replay_context` | Replay workbench state and saved sessions |
| `ql_reference` | The query-language reference |

**Action tools** (disabled by `--read-only`):

| Tool | Purpose |
|------|---------|
| `send_request` | Send / replay an HTTP request (active; expands `$KEY` env tokens) |
| `create_replay` / `update_replay` / `delete_replay` | Manage Replay sessions |
| `create_finding` / `update_finding` | Record and update findings |
| `create_note` / `update_note` / `delete_note` | Manage project notes |
| `create_rule` / `set_rule_enabled` / `delete_rule` | Create, toggle, and delete Match & Replace rules (literal rewrites on in-flight request/response head or body) |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Drive the fuzzer |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Drive the param miner |

> Action tools are capped for safety: fuzz and mine jobs are limited in total requests, concurrency, and stored results. A rule created via `create_rule` is picked up by `gori run` and newly opened TUIs; an already-running TUI applies it only after its rules reload.

## Why a Seam, Not a Chatbox

gori deliberately has no in-tool AI chat. Keeping the intelligence *outside* the tool — reachable through MCP — means you choose the model, your traffic isn't shipped anywhere you didn't intend, and the same interface serves scripts and agents alike. `gori run` covers the non-interactive path; MCP covers the interactive-agent path.

## Next Steps

- [CLI Reference](/reference/cli/) — full `gori mcp` flags
- [Query Language](/reference/query-language/) — the syntax agents use to filter
