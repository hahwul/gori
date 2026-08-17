+++
title = "MCP Server"
description = "Drive gori from an AI agent or script over the Model Context Protocol."
weight = 85

[extra]
group = "Automation"
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
gori mcp --no-project              # force unbound even inside a Git workspace
```

With no explicit selector, gori discovers the nearest Git root and binds its canonical path to an isolated project. The binding prevents two repositories with the same directory name from sharing a database.

**Outside a Git workspace** (the common case when an AI client spawns MCP from a home or app directory), the server starts **unbound**: the MCP handshake and tool list succeed immediately, but traffic tools (`list_history`, `send_request`, …) return `NO_PROJECT` until the agent calls `list_projects`, `create_project` (auto-binds when unbound), or `switch_project`. Unbound mode never silently opens the active TUI or MRU project — that requires the explicit `--use-active-project` opt-in (or `--project` / `--db` / `GORI_MCP_PROJECT` / `GORI_MCP_DB`).

**If the selected project cannot be opened** — a database that is missing, corrupt, or unreadable, a project name that no longer exists — the server still completes the handshake and starts unbound rather than exiting. The reason is written to stderr, repeated in the handshake `instructions`, returned with every `NO_PROJECT` tool error, and reported as `bind_error` by `project_info`, so the agent can call `list_projects` and `switch_project` to recover without a restart.

Call `project_info` before using data. It reports `bound`, the selected project, database path, workspace root, and selection source.

## Read-Only Mode

By default the server also exposes action tools that send live requests and write issues. To expose only the read tools (safe for handing a project to an untrusted agent), start it read-only:

```bash
gori mcp --read-only
```

## Installing Into an Agent

gori can write the MCP configuration for common clients for you:

| Flag | Client | Config written |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | `claude_desktop_config.json` in the platform's app-config directory (see below) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

Every client except Claude Desktop keeps its config in the same place on macOS, Linux and Windows. Claude Desktop follows Electron's app-data directory instead: `~/Library/Application Support/Claude/` on macOS, `%APPDATA%\Claude\` on Windows, and `$XDG_CONFIG_HOME/Claude/` — defaulting to `~/.config/Claude/` — on Linux. gori reads that variable, so a Nix or home-manager session that moves it is followed too.

The exception is a **Flatpak** Claude Desktop: it reads `XDG_CONFIG_HOME` from inside its own sandbox (`~/.var/app/<app-id>/config/Claude/`), which the host shell running gori cannot see. There gori writes `~/.config/Claude/claude_desktop_config.json` and prints that path — copy it into the app's sandbox directory yourself. Every install command prints the file it wrote, so check that line against where your build actually reads.

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
gori mcp --install-claude-code --install-codex  # several clients in one run
```

Codex and Grok use TOML with an `[mcp_servers.gori]` table (not JSON). Restart the client (or re-open the session) after installing so it reloads MCP servers. Existing config files are updated in place: other servers, tables and comments are preserved, the file's permissions are kept, and the replacement is atomic so an interrupted install can never truncate it.

If a client starts MCP outside your repository directory, the server starts unbound and the agent can pick or create a project over tools. To pin a fixed engagement at install time instead, pass a selector, for example `gori mcp --project my-engagement --install-codex`.

Every flag you pass alongside `--install-*` is written into the installed command, so what the client spawns matches what you typed — selectors (`--project`, `--db`, `--no-project`, `--use-active-project`), `--read-only`, `--insecure-upstream`, and `--config`. Paths are made absolute, because the client spawns the server from a working directory you did not choose.

## Tools

**Read tools** (always available):

| Tool | Purpose |
|------|---------|
| `list_history` | List flows newest-first, with optional QL and pagination |
| `list_events` | Tail an append-only feed of job lifecycle and agent activity, by forward cursor. Flows stay the firehose; this never duplicates flow rows |
| `get_flow` | Full request + response for one flow |
| `get_response_body_chunk` | Page through decoded (or raw) flow/Repeater responses beyond the inline 64 KiB cap |
| `list_sitemap` / `list_sitemap_tags` | Distinct endpoints (host, method, path), and the tags placed on them |
| `list_issues` / `get_issue` | Read triaged issues |
| `probe_scan` | Rescan captured flows and Repeater tabs. Passive (zero requests) unless `active:true`, which needs write access and is scope-gated |
| `probe_issues` | The Probe tab's persisted findings, as triage state (open by default) |
| `list_probe_rules` | Every scan rule (passive, active, custom), which are enabled, and the project's scan mode |
| `list_scope` | Current scope include/exclude rules |
| `list_links` | Evidence pointers from an issue or note to a flow, Repeater session, or job |
| `compare_flows` | Line diff of two flows' request or response — with each side's status/size/time and the A→B delta; `context:N` folds the unchanged runs into `{kind:fold,hidden}` markers |
| `intercept_list` / `intercept_get` | Inspect the live intercept queue and one held item in full |
| `list_projects` | Every gori project on this host |
| `list_notes` / `get_note` | Read project notes |
| `list_rules` | List the Match & Replace rules applied to the project in apply order — global rules first, then the project's own (`scope` filters to one) |
| `list_env` | Project env tokens available to `$KEY` substitution (values redacted) |
| `list_host_overrides` | The host to IP dial map in force for this project |
| `list_session_slots` | The project's [session slots](/guide/authorize/#session-slots-one-list-two-readers) — named identities, each a header overlay plus the extract rules whose bound values belong to it — and which one is ACTIVE (header values redacted) |
| `list_oast_providers` | Configured OAST providers and which one is active |
| `list_oast_sessions` | The project's persisted OAST listening sessions — payload host, hits, last poll — the rows `oast_resume` re-arms |
| `decode` | Run an encode/decode/hash/compress chain over `input` (pure transform; no network or state) |
| `jwt_decode` / `jwt_encode` / `jwt_attacks` | Decode, re-sign, or generate attack payloads for a JWT (pure compute; available even under `--read-only`) |
| `sequence_analyze` | Grade a pasted token list for randomness / predictability (pure) |
| `oast_presets` / `oast_payload` / `oast_poll` | List OAST providers, read the active payload, and poll a running listener for callbacks |
| `discover_status` / `discover_results` | Progress and findings of a Discover run |
| `project_info` | Flow / issue counts, database, workspace binding, and selection source |
| `get_current_context` | What the user is viewing in the TUI right now |
| `get_repeater_context` | Repeater workbench state and saved sessions |
| `ql_reference` | The query-language reference |
| `ql_explain` | Diagnose a query without running it, to check a filter before spending requests on it |

**Action tools** (disabled by `--read-only`):

| Tool | Purpose |
|------|---------|
| `send_request` | Send / resend an HTTP request (active; records History by default, expands `$KEY` env tokens, and redacts sensitive response-header values unless explicitly requested). `reframe_grpc: true` recomputes a unary gRPC message's 5-byte length prefix over the body actually sent — off by default, so an edited message ships with the prefix it was captured with |
| `send_websocket` | Execute a saved WebSocket Repeater session and collect the replies |
| `create_repeater` / `update_repeater` / `delete_repeater` | Manage Repeater sessions |
| `minimize_repeater` | Shrink a Repeater request to the smallest form that still reproduces the response |
| `create_issue` / `update_issue` / `delete_issue` | Record, update, and remove issues |
| `add_link` / `remove_link` | Attach or detach an issue's / note's evidence pointer |
| `create_note` / `update_note` / `delete_note` | Manage project notes |
| `create_rule` / `update_rule` / `set_rule_enabled` / `delete_rule` | Create, edit, toggle, and delete Match & Replace rules (rewrites on in-flight request/response head or body). Each takes `scope` — `project` (default) or `global`, which applies in every project |
| `preview_rule` | Estimate how many stored flows a rule would change, before creating it |
| `import_flows` | Bulk-import a HAR / URL list / OpenAPI / Postman / Insomnia / Burp file into History |
| `delete_flow` / `clear_history` | Remove one flow, or wipe captured History |
| `set_sitemap_tag` | Pin a free-text memo onto a sitemap path |
| `create_project` / `switch_project` / `delete_project` | Create or reopen a project, point this server at another one, or delete one. Deletion is two-step: a `dry_run` first, then a confirmation token |
| `add_scope_rule` / `update_scope_rule` / `delete_scope_rule` / `set_scope_enabled` | Edit the project's include / exclude rules and toggle the scope lens |
| `set_sandbox` | Hard containment: when on, the proxy forwards only what scope allows and blocks the rest |
| `set_env_var` / `delete_env_var` | Manage the project env tokens `$KEY` substitution reads |
| `create_session_slot` / `update_session_slot` / `delete_session_slot` | Manage the session slots — the same list the Authorize tab's identities card edits, and the set `authorize_start` replays under |
| `set_active_session_slot` | Choose the identity every outbound request goes out as: its header overlay is applied to the final wire bytes and `$NAME` resolves against its binding table. Held by this server process only — never persisted, so a new connection starts as-captured |
| `add_host_override` / `update_host_override` / `delete_host_override` | Manage the host to IP dial map (changes only the connect IP, never the request) |
| `probe_promote` / `probe_dismiss` / `probe_delete` | Triage a Probe finding into Issues, dismiss it, or remove it |
| `set_probe_mode` | Set the scan mode: `off`, `passive`, `active`, or `aggressive` (authorized targets only) |
| `create_probe_rule` / `update_probe_rule` / `delete_probe_rule` / `set_probe_rule_enabled` | Manage custom match rules and arm or disarm any scan rule |
| `create_oast_provider` / `update_oast_provider` / `delete_oast_provider` / `set_oast_provider_enabled` | Manage the OAST providers `oast_start` can listen on |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Drive the fuzzer. A gRPC sweep reports `grpc_stale_prefix` when a payload changed a message's length; `fuzz_start{reframe_grpc: true}` recomputes the prefix instead of reporting it. `fuzz_results` keeps rows the matcher rejected when the run observed something about them (a re-send, a retry, a truncated response), so read each row's `matched` — or pass `matched_only: true` |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Drive the param miner |
| `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` | Collect tokens by live replay and grade them (results return the report, never the tokens) |
| `authorize_start` / `authorize_status` / `authorize_results` / `authorize_stop` | Replay captured flows under several identities and compare each response against a baseline — broken access control. Results lead with `access_control` (`BYPASS`/`enforced`/`review`/`nothing_sent`) and a flat, never-paged `bypasses` list |
| `discover_start` / `discover_stop` | Spider and brute-force endpoints (poll with `discover_status` / `discover_results`) |
| `oast_start` / `oast_stop` | Register an ad-hoc OAST payload and poll for callbacks (read the hits with `oast_poll`); `oast_stop` on a RESUMED session stops polling but keeps it resumable |
| `oast_resume` / `oast_release` | Re-arm a persisted session so payloads planted earlier keep resolving (its polls are saved into the project), or deregister one for a finished engagement — its callbacks stay |
| `list_jobs` / `get_job` / `stop_job` | Work across job kinds: list every fuzz and mine job this session started, or fetch and stop one by id |
| `intercept_forward` / `intercept_forward_edit` / `intercept_drop` | Release a held message byte-exact, release it with edited wire bytes, or drop it |
| `intercept_toggle` / `intercept_set_filter` / `intercept_set_direction` | Arm or disarm the catch, set its condition query, and choose which leg it holds |

> Action tools are capped for safety: fuzz, mine, sequence, discover, and authorize jobs are limited in total requests, concurrency, and stored results. An authorize run's cap counts `flows × identities`, and a selection over it is refused up front rather than truncated into a run that would report "enforced" for flows it never sent. A rule created via `create_rule` is picked up by `gori run` and newly opened TUIs; an already-running TUI applies it only after its rules reload.

## Live Intercept

An agent can sit in the intercept loop next to you rather than reading History after the fact. The TUI session holding the capture lock mirrors held messages out to the agent and drains the commands it sends back, so `intercept_list` → `intercept_get` → `intercept_forward_edit` is the same loop you drive by hand.

The mutating half (`intercept_forward`, `intercept_forward_edit`, `intercept_drop`, `intercept_toggle`, `intercept_set_filter`, `intercept_set_direction`) is disabled by `--read-only`, and every one of them refuses when no live capture session is holding the lock. There is nothing to forward without a proxy actually holding traffic.

Agent actions are visible, not silent. Each one lands in the notification center tagged as coming from an agent, rendered differently from your own actions, so you can see what a co-pilot did to traffic while you were reading another tab.

One safety rule is worth knowing before you leave an agent running. A held message normally waits forever for a human decision, which is what you want when you are the only one at the keyboard. Once an agent attaches to the intercept queue in that session, gori arms a 30 second auto-forward for items nobody is watching, so a client that dies mid-hold cannot wedge the connection indefinitely. A session with no agent attached never auto-forwards.

## One Call at a Time

Tools run one at a time, in the order they arrive — a fuzz or a slow `send_request` does not overlap with the next call, and responses come back in order. Two messages are answered immediately regardless: `ping`, so a client's liveness probe never stalls behind a long call and declares the server dead, and `notifications/cancelled`, which suppresses the response to a request you stopped waiting for. Cancelling does not abort work already in flight — an in-progress request finishes, its answer is simply not sent.

## Why an MCP Seam

gori deliberately has no in-tool AI chat. The intelligence lives outside the tool, reachable through MCP. That means you choose the model, your traffic isn't shipped anywhere you didn't intend, and the same interface serves scripts and agents alike. [`gori run`](/guide/scripting/) covers the non-interactive path; MCP covers the interactive-agent path.

## Next Steps

- [AI Setup](/getting-started/ai-setup/): a step-by-step walkthrough to connect an agent and drive its first request
- [Scripting](/guide/scripting/): the other automation path — `gori run` for pipelines and CI
- [CLI Reference](/reference/cli/): full `gori mcp` flags
- [Query Language](/reference/query-language/): the syntax agents use to filter
