+++
title = "MCP Server"
description = "Drive gori from an AI agent or script over the Model Context Protocol."
+++

gori ships a built-in **MCP (Model Context Protocol) server**. Instead of embedding a chat window in the TUI, gori exposes its project over a clean tool interface so any MCP-capable agent (Claude, Codex, Grok, and others) can read your traffic and drive the tools.

<figure class="agent-session" aria-label="Example agent session: an agent finds an IDOR over MCP and logs an issue">
  <div class="agent-session-bar">
    <span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
    <span class="agent-session-title">agent · gori over MCP</span>
  </div>
  <div class="agent-session-body">
    <p class="as-user"><span class="as-who">you</span>Find an IDOR on the users API and log it.</p>
    <p class="as-call"><span class="as-arrow">→</span> <code>list_history</code> <span class="as-args">path~/v1/users status:200</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-args">14 flows, customer and admin tokens</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>send_request</code> <span class="as-args">GET /v1/users/2 · customer token</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-warn">200</span> <span class="as-args">{"id":2,"email":"other-tenant@example.com"}, not the caller's row</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>create_issue</code> <span class="as-args">"IDOR on /v1/users/{id}" severity:high</span></p>
    <p class="as-done"><span class="as-check">✓</span> Issue logged; the request is saved as a Repeater session for repro.</p>
  </div>
</figure>

```bash
gori mcp
```

The server speaks JSON-RPC 2.0 over stdio: STDOUT carries the protocol, STDERR carries logs. Tool results include both backward-compatible text and MCP `structuredContent` when the payload is JSON.

## Choosing a Project

```bash
cd /path/to/my-repository && gori mcp # path-binds this Git workspace to its own gori project
gori mcp --project my-engagement   # serve a named project's database
gori mcp --db /path/to/project.db  # serve a specific database file
gori mcp --use-active-project      # explicitly serve the active TUI/MRU project
```

With no explicit selector, gori discovers the nearest Git root and binds its canonical path to an isolated project. The binding prevents two repositories with the same directory name from sharing a database. If the process is outside a Git workspace, gori fails closed instead of silently serving an unrelated active project; pass `--project`, `--db`, `GORI_MCP_PROJECT`, `GORI_MCP_DB`, or the explicit `--use-active-project` opt-in.

Call `project_info` before using data. It reports the selected project, database path, workspace root, and selection source.

## Read-Only Mode

By default the server also exposes action tools that send live requests and write issues. To expose only the read tools (safe for handing a project to an untrusted agent), start it read-only:

```bash
gori mcp --read-only
```

## Installing Into an Agent

gori can write the MCP configuration for common clients for you:

| Flag | Client | Config written |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
```

Codex and Grok use TOML with an `[mcp_servers.gori]` table (not JSON). Restart the client (or re-open the session) after installing so it reloads MCP servers.

If a client starts MCP outside your repository directory, pin the installation to a project, for example `gori mcp --project my-engagement --install-codex`.

## Tools

**Read tools** (always available):

| Tool | Purpose |
|------|---------|
| `list_history` | List flows newest-first, with optional QL and pagination |
| `get_flow` | Full request + response for one flow |
| `get_response_body_chunk` | Page through decoded (or raw) flow/Repeater responses beyond the inline 64 KiB cap |
| `list_sitemap` | Distinct endpoints (host, method, path) |
| `list_issues` / `get_issue` | Read triaged issues |
| `list_scope` | Current scope include/exclude rules |
| `list_notes` / `get_note` | Read project notes |
| `list_rules` | List the project's Match & Replace rules in apply order |
| `decode` | Run an encode/decode/hash/compress chain over `input` (pure transform; no network or state) |
| `jwt_decode` / `jwt_encode` / `jwt_attacks` | Decode, re-sign, or generate attack payloads for a JWT (pure compute; available even under `--read-only`) |
| `sequence_analyze` | Grade a pasted token list for randomness / predictability (pure) |
| `oast_presets` / `oast_payload` / `oast_poll` | List OAST providers, read the active payload, and poll a running listener for callbacks |
| `discover_status` / `discover_results` | Progress and findings of a Discover run |
| `project_info` | Flow / issue counts, database, workspace binding, and selection source |
| `get_current_context` | What the user is viewing in the TUI right now |
| `get_repeater_context` | Repeater workbench state and saved sessions |
| `ql_reference` | The query-language reference |

**Action tools** (disabled by `--read-only`):

| Tool | Purpose |
|------|---------|
| `send_request` | Send / resend an HTTP request (active; records History by default, expands `$KEY` env tokens, and redacts sensitive response-header values unless explicitly requested) |
| `create_repeater` / `update_repeater` / `delete_repeater` | Manage Repeater sessions |
| `create_issue` / `update_issue` | Record and update issues |
| `create_note` / `update_note` / `delete_note` | Manage project notes |
| `create_rule` / `set_rule_enabled` / `delete_rule` | Create, toggle, and delete Match & Replace rules (literal rewrites on in-flight request/response head or body) |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Drive the fuzzer |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Drive the param miner |
| `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` | Collect tokens by live replay and grade them (results return the report, never the tokens) |
| `discover_start` / `discover_stop` | Spider and brute-force endpoints (poll with `discover_status` / `discover_results`) |
| `oast_start` / `oast_stop` | Register an OAST payload and poll for callbacks (read the hits with `oast_poll`) |

> Action tools are capped for safety: fuzz, mine, sequence, and discover jobs are limited in total requests, concurrency, and stored results. A rule created via `create_rule` is picked up by `gori run` and newly opened TUIs; an already-running TUI applies it only after its rules reload.

## Why an MCP Seam

gori deliberately has no in-tool AI chat. The intelligence lives outside the tool, reachable through MCP. That means you choose the model, your traffic isn't shipped anywhere you didn't intend, and the same interface serves scripts and agents alike. `gori run` covers the non-interactive path; MCP covers the interactive-agent path.

## Next Steps

- [CLI Reference](/reference/cli/): full `gori mcp` flags
- [Query Language](/reference/query-language/): the syntax agents use to filter
