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

**Outside a Git workspace** (the common case when an AI client spawns MCP from a home or app directory), the server starts **unbound**: the MCP handshake and tool list succeed immediately, but traffic tools (`list_history`, `send_request`, …) return `NO_PROJECT` until the agent calls `list_projects`, `create_project` (auto-binds when unbound), or `switch_project`. Unbound mode never silently opens the active TUI or MRU project; that requires the explicit `--use-active-project` opt-in (or `--project` / `--db` / `GORI_MCP_PROJECT` / `GORI_MCP_DB`).

A few tool families never need a project and work unbound: project management (`project_info`, `list_projects`, `create_project`, `switch_project`, `delete_project`, `diff_projects`), the pure-compute helpers (`decode`, `jwt_*`, `cookie_*`, `sequence_analyze`), the query-language reference (`ql_reference`, `ql_explain`), and the ad-hoc OAST listener (`oast_presets`, `oast_payload`, `oast_start`, `oast_stop`, `oast_poll`). Everything else, including the persisted `oast_resume` / `oast_release`, answers `NO_PROJECT` until one is bound.

**If the selected project cannot be opened** (a database that is missing, corrupt, or unreadable, a project name that no longer exists), the server still completes the handshake and starts unbound rather than exiting. The reason is written to stderr, repeated in the handshake `instructions`, returned with every `NO_PROJECT` tool error, and reported as `bind_error` by `project_info`, so the agent can call `list_projects` and `switch_project` to recover without a restart.

Call `project_info` before using data. It reports `bound`, the selected project, database path, workspace root, selection source, and the project `description` — the operator's note on what this engagement is for, which `create_project` stores and this is the call that reads it back.

**The project named in `instructions` is the one bound at the handshake.** That text is sent once and nothing pushes an update to it, so after a `switch_project` it still describes the binding as it was then while every later call reads and writes the new project. `project_info` is the live answer. `switch_project` — and `create_project` when it auto-binds — return the same correction in their result, alongside `previous_project`, the binding they moved off.

## Read-Only Mode

By default the server also exposes action tools that send live requests and write issues. To expose only the read tools (safe for handing a project to an untrusted agent), start it read-only:

```bash
gori mcp --read-only
```

A read-only server also keeps no writer. It never writes the project it serves and runs no background indexing, because SQLite allows a single writer, and a second gori holding that slot for nothing but its own bookkeeping is what makes it contend with the TUI capturing into the same project. The one exception is a database written by an older gori, which is migrated on open because this build cannot read it otherwise.

A default (actions-on) server still has a writer (`send_request` and `create_issue` need one), but it does not idle-index. Free-text search drains the backlog on demand; the capturing TUI is the process that keeps the index current in the background.

One consequence is worth knowing: free-text search (`body:`) reads an index that is built off the capture commit, and a read-only server cannot build it. If flows are still waiting to be indexed, such a query is refused with `FTS_BACKLOG` rather than answered from a partial index; open the project in gori, or drop `--read-only`, to drain it.

## Choosing Which Tools Are Exposed

By default `gori mcp` advertises every tool, so an agent can reach the whole workbench without a restart. The price is context: a client loads the entire catalogue into the model's context before the first question and keeps it for the session. Every start logs how many tools it serves and how large `tools/list` is. For a client with a tight context budget, start from a profile:

| Start with | Tools | `tools/list` | Tokens | For |
| --- | ---: | ---: | ---: | --- |
| `gori mcp` | 180 | ~206 KB | ~53k | Everything (the default) |
| `--read-only` | 60 | ~67 KB | ~17k | Read tools and pure compute; no live requests |
| `--tools=@recon` | 35 | ~52 KB | ~13k | Read and map the capture, replay a request, record issues and notes |
| `--tools=@recon --read-only` | 27 | ~37 KB | ~10k | `@recon` minus what `--read-only` disables |
| `--tools=@minimal` | 17 | ~25 KB | ~6k | Read History, flows and the current TUI context; talk to the operator |

Tokens are bytes ÷ 4, a rough rule for JSON; your client's tokenizer has the final word.

| Profile | Tools |
| --- | --- |
| `@minimal` | `project_info`, `list_projects`, `switch_project`, `create_project`, `ql_reference`, `ql_explain`, `list_history`, `get_flow`, `get_response_body_chunk`, `get_current_context`, `get_repeater_context`, `get_issue`, `list_sitemap`, `intercept_get`, `intercept_list`, `operator_messages`, `reply_to_operator` |
| `@recon` | `@minimal`, plus `list_scope`, `list_params`, `compare_flows`, `list_env`, `decode`, `jwt_decode`, `jwt_verify`, `probe_issues`, `probe_promote`, `probe_dismiss`, `list_issues`, `list_notes`, `get_note`, `send_request`, `create_issue`, `update_issue`, `create_note`, `update_note` |

A profile is a fixed list of names, not a glob, so a later gori that adds a `list_*` tool does not quietly grow `@recon`. Both keep `switch_project` and `create_project`, so they work on an unbound start, even on a machine with no project yet.

`--tools` takes a comma-separated list of tool names, `*` globs and `@profiles`, applied left to right; a term prefixed with `-` subtracts:

```bash
gori mcp --tools=@recon                                          # a profile
gori mcp --tools='@minimal,send_request'                         # a profile plus one tool
gori mcp --tools='@recon,-send_request'                          # a profile minus one
gori mcp --tools='-fuzz_*,-mine_*,-discover_*,-sequence_*'       # everything but the async workbench
```

Because the tools are named in prefix families (`list_*`, `intercept_*`, `fuzz_*`, `oast_*`), a glob selects a group. A spec that starts with a subtraction begins from every tool, so it keeps working when a later gori adds one.

Tools that document a required follow-up—such as async job status/results/stop or flow paging—bring those companions into the catalogue automatically, transitively. If a later subtraction excludes a required companion while keeping its parent, startup refuses the conflicting filter; add the companion again after the subtraction or remove the parent. Conditional live-intercept readers honor explicit exclusions: if `intercept_get` is hidden but `intercept_list` is served, `get_current_context` points to its preview and metadata while noting that full detail is unavailable. If both are hidden, it says the held item cannot be read through this server instead of restoring either reader.

A narrow spec can also leave the server with no way to *pick* a project. If it starts unbound — outside a Git workspace, with `--no-project`, or because the configured database would not open — and the spec keeps neither `switch_project` nor `create_project`, nothing the agent calls can bind one. `list_projects` does not count: it lists projects and binds none of them. gori warns at startup, and the `NO_PROJECT` errors say the same thing instead of naming tools that are not there. Keep `switch_project` in the spec, or pass `--project`/`--db`.

A pattern or profile that matches nothing aborts at startup with a suggestion (`--tools: "list_hisotry" matches no tool — did you mean list_history?`) rather than quietly serving a smaller set — a server missing a tool looks exactly like a gori that never had the feature. Tools left out are absent from `tools/list` **and** refused if called anyway, naming the flag that hid them. `--tools` composes with `--read-only`, and like every other flag it is written into the command when you pass it alongside `--install-*`.

## Seeing an Agent From the TUI

While an MCP server is bound to a project, gori shows it. In the project picker the project's row carries an `mcp` mark (`mcp×2` for more than one), and once the project is open a clickable `mcp:<client>` chip appears on the top bar. Click it, or run `app.agents` from the command palette, to open a card listing every attached agent: its name, version, pid, when it connected, and whether it is read-only. The name comes from the client's own `clientInfo` handshake; a server started with `--read-only` shows as read-only there. A row disappears on its own the moment its process exits, so the chip and card always reflect what is attached right now.

## Installing Into an Agent

gori can write the MCP configuration for common clients for you:

| Flag | Client | Config written |
| ------ | -------- | ---------------- |
| `--install-claude` | Claude Desktop | `claude_desktop_config.json` in the platform's app-config directory (see below) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |
| `--install-hermes` | Hermes | `~/.hermes/config.yaml` (`mcp_servers.gori`), or `$HERMES_HOME` |
| `--install-pi` | Pi | `~/.pi/agent/mcp.json` (`mcpServers.gori`), or `$PI_CODING_AGENT_DIR` |

Pi requires an MCP adapter such as [pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter). Install it with `pi install npm:pi-mcp-adapter`, then restart Pi. `--install-pi` writes the MCP server configuration.

Every client except Claude Desktop and Hermes keeps its config in the same place on macOS, Linux and Windows. Hermes reads `$HERMES_HOME` when it is set, and otherwise `~/.hermes` (`%LOCALAPPDATA%\hermes` on Windows). Claude Desktop follows Electron's app-data directory instead: `~/Library/Application Support/Claude/` on macOS, `%APPDATA%\Claude\` on Windows, and `$XDG_CONFIG_HOME/Claude/` (defaulting to `~/.config/Claude/`) on Linux. gori reads that variable, so a Nix or home-manager session that moves it is followed too.

The exception is a **Flatpak** Claude Desktop: it reads `XDG_CONFIG_HOME` from inside its own sandbox (`~/.var/app/<app-id>/config/Claude/`), which the host shell running gori cannot see. There gori writes `~/.config/Claude/claude_desktop_config.json` and prints that path; copy it into the app's sandbox directory yourself. Every install command prints the file it wrote, so check that line against where your build actually reads.

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
gori mcp --install-hermes
gori mcp --install-pi
gori mcp --install-claude-code --install-codex  # several clients in one run
```

Codex and Grok use TOML with an `[mcp_servers.gori]` table, and Hermes YAML with an `mcp_servers:` entry, rather than JSON. Restart the client (or re-open the session) after installing so it reloads MCP servers. Existing config files are updated in place: other servers, tables and comments are preserved, the file's permissions are kept, and the replacement is atomic so an interrupted install can never truncate it. gori edits these files as text rather than re-emitting them from a parse tree, so the documentation you keep around your own settings survives the install; a config it cannot splice safely is reported and left alone rather than rewritten.

If a client starts MCP outside your repository directory, the server starts unbound and the agent can pick or create a project over tools. To pin a fixed engagement at install time instead, pass a selector, for example `gori mcp --project my-engagement --install-codex`.

Every flag you pass alongside `--install-*` is written into the installed command, so what the client spawns matches what you typed: selectors (`--project`, `--db`, `--no-project`, `--use-active-project`), `--read-only`, `--tools`, `--insecure-upstream`, and `--config`. Paths are made absolute, because the client spawns the server from a working directory you did not choose.

## Tools

**Read tools** (always available):

| Tool | Purpose |
| ------ | --------- |
| `list_history` | List flows newest-first, with optional QL and pagination. Every row carries `source` (`proxy` for traffic a client sent, `repeater` for a `send_request` (including your own, which records by default), `discover`, `import`, …), so a flow gori made is never read back as evidence about the target. Filter with `src:`. Pass `columns` (the same `[LABEL=][req\|res:]kind:selector` specs `gori run ls --column` takes) to carry an extracted value per row (a header, a JSON field, a regex capture) under a `columns` object: what QL can *filter* on, [shown](/guide/proxy/#columns). Opt-in, since it costs a read per row. Pass `ids` to fetch an EXACT set in one call — the rows `get_current_context` reports as `selection.ids` — returned in the order asked for; `limit` and the two cursors do not apply, an id with no row comes back in `missing_ids`, and anything `query` excluded comes back in `filtered_out_ids`, so a short answer always says which kind of short it is |
| `list_events` | Tail an append-only feed of job lifecycle and agent activity, by forward cursor. Flows stay the firehose; this never duplicates flow rows. Every event carries `actor`, the surface that acted (`tui` / `cli` / `mcp`), so an agent can tell its own writes from the operator's, and config changes are recorded whoever makes them. The human reads the same feed on the **Project → Activity** pane |
| `operator_messages` | What the operator typed for you in the gori TUI ("Tell the agent…"), addressed to this session or to all attached agents, forward-cursored; gori delivers these live when it can (a peer note in Claude Code, a `codex queue` hand-off in Codex, a channel event) and rides any that are still pending back on your next tool result; this is the fallback every agent has — call it at the start of a turn. Marks what it returns as delivered so the operator's ring can say "picked up" |
| `reply_to_operator` | Answer the operator in gori: `summary` is one line for the notification ring and Miss Ring's bubble, `detail` the long form the ring opens on ↵, `level` its colour, `in_reply_to` the operator message it answers. This is how a reply reaches someone who is in gori, not in your terminal |
| `list_views` | The project's History [views](/guide/proxy/#views): named QL queries `list_history{view}` applies as a lens, ANDed over `query` rather than replacing it. Seven built-ins (`All`, `History`, `History + Repeater` (the default), `WebSocket`, `gRPC`, `SSE`, `Errors`), then the global library, then the project's own; `active` marks the one the TUI is showing, which does **not** apply to `list_history`, which filters only by the `view` you pass it |
| `get_flow` | Full request + response for one flow. Bodies come back sanitized, with a `body_redaction` object, where a [redaction profile](/reference/cli/#run-redact) is on by default; `include_sensitive:true` turns that off along with the header redaction |
| `get_response_body_chunk` | Page through decoded (or raw) flow/Repeater responses beyond the inline 64 KiB cap |
| `list_sitemap` / `list_sitemap_tags` | Distinct endpoints (host, method, path), and the tags placed on them |
| `list_params` | Per-endpoint parameter inventory: every input name by location, with counts, sample values (credentials redacted) and whether a value is reflected in the response |
| `list_issues` / `get_issue` | Read triaged issues |
| `probe_scan` | Rescan captured flows and Repeater tabs. Passive (zero requests) unless `active:true`, which needs write access and is scope-gated |
| `probe_issues` | The Probe tab's persisted findings, as triage state (open by default) |
| `list_probe_rules` | Every scan rule (passive, active, custom), which are enabled, and the project's scan mode |
| `list_scope` | Current scope include/exclude rules |
| `list_links` | Evidence pointers from an issue or note to a flow, Repeater session, or job |
| `list_evidence` / `get_evidence` | Frozen evidence — immutable copies of an exchange with provenance, linked issues and SHA-256s (one issue's with `issue_id`, the whole project archive including orphans without it) — and one copy's bytes (heads redacted unless `include_sensitive`, bodies capped like `get_flow`) |
| `list_retest_steps` / `list_retest_runs` / `get_retest_run` | An Issue's **retest**: the ordered Repeater sends that reproduce the finding, each resolved against the project so the reply already says what it will SEND and which steps change state (a step whose Repeater session was deleted reports `ref_deleted: true` and is never run, even if a new session later takes its id); the bounded run history (newest first); and one run's result table, each row keeping the History flow id of its own send |
| `get_issue` (retest field) | An issue that HAS a retest carries a `retest` object beside `links` and `evidence` — the step count and the last run's verdict — so reading a finding already tells you whether a reproducible check exists and what it last said. Omitted entirely on an issue without one |
| `compare_flows` | Line diff of two flows' request or response, with each side's status/size/time and the A→B delta; `context:N` folds the unchanged runs into `{kind:fold,hidden}` markers |
| `diff_projects` | Retest diff: two PROJECTS at endpoint scale: what is new, gone, or answering differently since the last engagement. Endpoints are keyed by the Sitemap's folded template, and `removed` (never requested in the newer capture) is a separate verdict from `gone` (asked, got 404/410) |
| `intercept_list` / `intercept_get` | Inspect the live intercept queue and one held item in full |
| `list_projects` | Find a gori project on this host: **one page** of them, most-recently-active first. `query` keeps the projects whose display name, directory slug, short id or bound workspace path contains it; `limit`/`offset` page (default 50, max 500). The project this server is serving is named beside the page (`current_project`), so a narrowed listing still answers "which one am I on?", and `total_projects` sits beside `total` so an empty match never reads as an empty host |
| `list_notes` / `get_note` | Read project notes |
| `list_rule_presets` | The response-modification [presets](/guide/proxy/#rewriter-presets): named starting points that install ordinary Match & Replace rules (unhide hidden fields, enable disabled controls, remove `maxlength`, strip client-side validation, drop CSP / security headers, disable SRI). Each row names the rules it would install |
| `list_extract_rules` | The project's **extract** rules, the read half of a [session binding](/guide/proxy/#session-bindings): each observes a response and binds one `$BIND.NAME` in memory for a Match & Replace rule to inject |
| `list_color_rules` / `list_custom_colors` | The [Colormarker](/guide/proxy/#colouring-rows-colormarker-tab) rules in precedence order, and the global custom colours a rule's `color` can name. Display only; a colour rule never modifies traffic |
| `preview_color_rule` | How many recent flows a colour condition would MATCH, and how many it would actually PAINT once the rules resolving ahead of it are counted. Takes `scope`, because a global candidate resolves before every project rule |
| `grpc_schema` | What `.proto` schema this project renders captured gRPC through, and where each piece came from: a descriptor-set file or a reflection fetch. Sends nothing |
| `list_rules` | List the Match & Replace rules applied to the project in apply order: global rules first, then the project's own (`scope` filters to one) |
| `list_env` | Project env tokens and built-in generators available to substitution, as `{syntax, prefix, example, vars, generators}` (env values redacted). The three scalars are how to WRITE a reference: `syntax` is this install's grammar (`namespaced` → `$ENV.KEY`, `$BIND.NAME`, and `$GEN.UUID`; `bare` → the legacy `$KEY` with no generators), `prefix` is the sigil, and `example` is the first two applied, so a non-default sigil needs no assembling. Each `vars` row is keyed by the bare name and also carries `length` and, when the value already begins with one, `scheme`; each `generators` row carries the complete token and output format |
| `list_host_overrides` | The host to IP dial map in force for this project |
| `list_session_slots` | The project's [session slots](/guide/authorize/#session-slots-one-list-two-readers) (named identities, each a header overlay plus the extract rules whose bound values belong to it) and which one is ACTIVE (header values redacted) |
| `list_oast_providers` | Configured OAST providers and which one is active |
| `list_oast_sessions` | The project's persisted OAST listening sessions (payload host, hits, last poll), the rows `oast_resume` re-arms |
| `decode` | Run an encode/decode/hash/compress chain over `input` (pure transform; no network or state) |
| `jwt_decode` / `jwt_verify` / `jwt_encode` / `jwt_attacks` | Decode (a JWS or the protected header of an encrypted JWE), verify a signature against a key you hold, re-sign with HMAC or a PEM key, or generate attack payloads for a JWT (pure compute; available even under `--read-only`) |
| `cookie_decode` / `cookie_verify` / `cookie_crack` / `cookie_forge` | The [Cookie workbench](/guide/cookie/) as pure offline compute: parse a Flask / Rack / Django signed session cookie, check it against a candidate secret, brute-force the secret over a wordlist, and re-sign an edited payload. No network, so all four survive `--read-only` |
| `sequence_analyze` | Grade a pasted token list for randomness / predictability (pure) |
| `oast_presets` / `oast_payload` / `oast_poll` | List OAST providers, read the active payload, and poll a running listener for callbacks |
| `project_info` | Flow / issue counts, capture window, the project `description`, database, workspace binding, and selection source |
| `get_current_context` | What the operator is viewing in the TUI **and what they have selected**. `selection.ids` is the rows they marked on History / Issues / Sitemap / Intercept — or the cursor row when nothing is marked, or the flow an open detail pins — with `target_source` naming which, so an agent never re-derives the rule. Sitemap selects `{host, path}` pairs, not flow ids, and says so with `kind`. `truncated` is the only signal that the array was capped — not `marked_count`, which describes the mark set and is reported even when an open drill-in overrides it. `marks_elsewhere` names tabs holding marks this selection does not carry (a `tab` plus a count, and a `kind` only where those marks have one), and `tui.live` reports whether a gori TUI window is attached at all — evidence, not proof. Feed a History selection straight to `list_history{ids}` |
| `get_repeater_context` | Repeater workbench state and saved sessions. Every session reports **both** ids (`db_id`, which every repeater tool takes, and `tui_index`, the 1-based number the TUI paints on its sub-tab chip (`6:POST /api`)), so an agent and the operator name the same tab. `filter` takes the same sub-tab language the TUI's `/` does (`tag:` `name:` `host:` `method:` `status:`, `-` negates, bare words search), ANDed with `query`. `include_content` adds the request head and, per credential header, an `env_headers` shape (`Authorization: Bearer $ENV.AUTH`) that names the wiring without the secret; `include_response_body` inlines the stored last response body |
| `list_fuzz_runs` / `get_fuzz_run` | List and inspect permanent Fuzzer result sets. Metrics use a scalar-only projection, including `result_index`, so retained BLOBs are not loaded. `include_content:true` returns at most 25 rows from SQLite-capped prefixes: `max_head_bytes` (default 16 KiB, max 64 KiB) bounds heads and `max_body_bytes` (default 2 KiB, max 64 KiB) bounds decoded bodies/raw samples. Full source sizes plus head/source/decode truncation flags say what was omitted; `include_sensitive:true` opts into exact capped prefixes, never uncapped bytes. Run metadata labels pre-current snapshots as `legacy:true` |
| `ql_reference` | The query-language reference |
| `ql_explain` | Diagnose a query without running it, to check a filter before spending requests on it |

**Action tools** (disabled by `--read-only`). Every one that opens a socket (`send_request`, `send_websocket`, `fuzz_*`, `mine_*`, `authorize_*`, `sequence_*`, `discover_*`, `grpc_reflect`, `minimize_repeater`, and `probe_scan` with `active:true`) is scope-gated: a target outside, or without, a configured scope is refused with `SCOPE_BLOCKED` unless the call passes `allow_unscoped:true`, the explicit waiver, and the sandbox and explicit excludes apply even then.

| Tool | Purpose |
| ------ | --------- |
| `send_request` | Send / resend an HTTP request (active; records History by default, expands `$ENV.KEY` env tokens and `$BIND.NAME` bindings, and redacts sensitive response-header values unless explicitly requested). `reframe_grpc: true` recomputes a unary gRPC message's 5-byte length prefix over the body actually sent. Off by default, so an edited message ships with the prefix it was captured with |
| `send_websocket` | Execute a saved WebSocket Repeater session and collect the replies |
| `create_repeater` / `update_repeater` / `delete_repeater` | Manage one Repeater session. Every reply carries `tui_index` beside `id`; a delete names the tab it destroyed (`was_tui_index`) and renumbers the rest |
| `create_repeaters` | Seed a tab from each of several captured flows, the second hop of an OpenAPI import (see below). Checks every flow exists before creating the first session |
| `delete_repeaters` / `update_repeaters` | Bulk close, and bulk re-label (tags and name affixes only; `update_repeater` is the one that writes request bytes). Both take explicit ids, never a filter: narrow with `get_repeater_context{filter}` first, so the set you read is the set acted on. Delete needs `confirm:true`, and an unknown id refuses the whole call |
| `move_repeater` | Rearrange the sub-tab strip: `to_index` for an absolute tab number, `direction` for a one-step nudge. An open TUI picks the new order up on its own |
| `minimize_repeater` | Shrink a Repeater request to the smallest form that still reproduces the response |
| `create_issue` / `update_issue` / `delete_issue` | Record, update, and remove issues |
| `add_link` / `remove_link` | Attach or detach an issue's / note's evidence pointer |
| `freeze_evidence` / `link_evidence` / `unlink_evidence` / `delete_evidence` | Copy a flow's or a Repeater tab's *current* exchange into immutable evidence on an issue (the next send and retention cannot touch it; `link:true` by default files the live link in the same transaction), change its Issue memberships without changing the snapshot, or delete one copy. Freeze when a response proves a finding, and again after the retest. A tab whose request was edited after its stored response arrived is refused — those two are not one exchange, so send it again or pass `allow_drift:true` to keep the mismatched pair anyway |
| `add_retest_step` / `update_retest_step` / `move_retest_step` / `remove_retest_step` | Build the retest: a Repeater session, a role (`setup` / `baseline` / `variant` / `control` / `cleanup`) and at most one assertion (`status:2xx`, `json:data.role=admin`, `json-absent:…`, `body:same` / `body:diff`). The session is not copied — a step sends whatever the tab holds when the run happens |
| `run_retest` | Run it, through the project's scope and Sandbox gates, and answer `pass` / `fail` / `inconclusive` / `blocked` plus a row per step (`isError` on anything but `pass`). A batch containing a state-changing method is REFUSED with the exact request count until `confirm:true`; after gori refuses a send the rest is skipped, cleanup included, unless `allow_cleanup:true`. Each send is recorded in History as `src:retest` |
| `clear_retest_steps` / `delete_retest_run` | Drop every step of an Issue's retest (the run history is kept — re-planning a check does not un-run it), or delete one run summary and its result rows. The steps and the History flows each send recorded both stay: `delete_retest_run` drops the report, not the evidence, for a run that should not be on the record at all |
| `create_note` / `update_note` / `delete_note` | Manage project notes |
| `create_rule` / `update_rule` / `set_rule_enabled` / `delete_rule` | Create, edit, toggle, and delete Match & Replace rules (rewrites on in-flight request/response head or body). Each takes `scope`: `project` (default) or `global`, which applies in every project |
| `create_rule_from_preset` | Install a preset (see `list_rule_presets`) as ordinary Match & Replace rules, the same result as calling `create_rule` once per rule, so they stay visible, editable and disable-able afterwards. Returns the ids created |
| `create_extract_rule` / `update_extract_rule` / `set_extract_rule_enabled` / `delete_extract_rule` | Manage the extract rules that bind `$BIND.NAME` from a response. Renaming drops the old name's bound value rather than re-labelling it, and disabling **un-declares** the name, so a rule injecting it goes back to refusing rather than sending a stale value |
| `create_color_rule` / `update_color_rule` / `set_color_rule_enabled` / `move_color_rule` / `delete_color_rule` | Manage Colormarker rules. `move_color_rule` is a semantic edit, not cosmetic: the first enabled match paints the row. Each takes `scope`: `project` (default) or `global` |
| `create_custom_color` / `update_custom_color` / `delete_custom_color` | Define the global custom colours the picker offers on top of the six built-ins. Deleting one leaves a rule that still names it inert; its rows fall back to a visible default rather than the deletion cascading into rules |
| `grpc_reflect` / `grpc_forget` | Ask a target's `grpc.reflection.v1` service (falling back to `v1alpha`) for its descriptors and cache them in the project, or drop a cached target. `grpc_reflect` is an outbound send and is scope-gated like any other |
| `create_view` / `update_view` / `delete_view` | Create, edit, re-home and delete saved History [views](/guide/proxy/#views). Each takes `scope`: `project` (default) or `global`. The query is validated on the way in: one whose every term would be dropped is refused, because it would narrow nothing while every surface showed a chip claiming it does |
| `preview_rule` | Estimate how many stored flows a rule would change, before creating it |
| `import_flows` | Bulk-import a HAR / URL list / OpenAPI / Postman / Insomnia / Burp / WSDL file into History |
| `delete_flow` / `clear_history` | Remove one flow, or wipe captured History |
| `set_sitemap_tag` | Pin a free-text memo onto a sitemap path |
| `create_project` / `switch_project` / `delete_project` | Create or reopen a project, point this server at another one, or delete one. Deletion is two-step: a `dry_run` first, then a confirmation token |
| `add_scope_rule` / `update_scope_rule` / `delete_scope_rule` / `set_scope_enabled` | Edit the project's include / exclude rules and toggle the scope lens |
| `set_sandbox` | Hard containment: when on, the proxy forwards only what scope allows and blocks the rest |
| `set_env_var` / `delete_env_var` | Manage the project env tokens substitution reads. The key is stored bare: reference it as `$ENV.KEY`, or as `$KEY` under the `bare` opt-out — `list_env`'s `syntax` / `example` says which one this install speaks |
| `create_session_slot` / `update_session_slot` / `delete_session_slot` | Manage the session slots, the same list the Authorize tab's identities card edits, and the set `authorize_start` replays under |
| `set_active_session_slot` | Choose the identity every outbound request goes out as: its header overlay is applied to the final wire bytes and `$BIND.NAME` resolves against its binding table. Held by this server process only, never persisted, so a new connection starts as-captured |
| `add_host_override` / `update_host_override` / `delete_host_override` | Manage the host to IP dial map (changes only the connect IP, never the request) |
| `probe_promote` / `probe_dismiss` / `probe_delete` | Triage a Probe finding into Issues, dismiss it, or remove it |
| `set_probe_mode` | Set the scan mode: `off`, `passive`, `active`, or `aggressive` (authorized targets only) |
| `create_probe_rule` / `update_probe_rule` / `delete_probe_rule` / `set_probe_rule_enabled` | Manage custom match rules and arm or disarm any scan rule |
| `create_oast_provider` / `update_oast_provider` / `delete_oast_provider` / `set_oast_provider_enabled` | Manage the OAST providers `oast_start` can listen on |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Drive the fuzzer. `save_results:true` permanently stores **every** row through a byte-bounded asynchronous writer and returns a database `run_id`; storage backpressure marks the save failed without stopping outbound traffic. This is independent of the bounded/selective live-job cache and `record_history`. `fuzz_start{fields: ["role"]}` sweeps a **schema-known gRPC field** of a unary request: each payload goes through the field's declaration on its way to bytes, every other byte of the message is copied from the capture, and the length prefix follows. A gRPC sweep of BYTE positions reports `grpc_stale_prefix` when a payload changed a message's length; `fuzz_start{reframe_grpc: true}` recomputes the prefix instead of reporting it. `fuzz_results` keeps rows the matcher rejected when the run observed something about them (the request was re-sent or retried, the response came back truncated, the send errored, or a `¦chain` step could not run so the payload went out untransformed), so read each row's `matched`, or pass `matched_only: true` |
| `delete_fuzz_run` | Delete a permanent fuzz run and its results; refuses a known live writer. `force_stale:true` removes a `running`/`saving` row left by a crashed process, and must never be used while another gori is saving |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Drive the param miner |
| `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` | Collect tokens by live replay and grade them (results return the report, never the tokens) |
| `authorize_start` / `authorize_status` / `authorize_results` / `authorize_stop` | Replay captured flows under several identities and compare each response against a baseline (broken access control). Results lead with `access_control` (`BYPASS`/`enforced`/`review`/`error`/`nothing_sent`) and a flat, never-paged `bypasses` list |
| `discover_start` / `discover_status` / `discover_results` / `discover_stop` | Spider and brute-force endpoints, poll progress, and read findings. All four are action tools, so a read-only server has no Discover surface |
| `oast_start` / `oast_stop` | Register an ad-hoc OAST payload and poll for callbacks (read the hits with `oast_poll`); `oast_stop` on a RESUMED session stops polling but keeps it resumable |
| `oast_resume` / `oast_release` | Re-arm a persisted session so payloads planted earlier keep resolving (its polls are saved into the project), or deregister one for a finished engagement; its callbacks stay |
| `list_jobs` / `get_job` / `stop_job` | Work across job kinds: list every fuzz, mine, discover, sequence, and authorize job this session started, or fetch and stop one by id |
| `intercept_forward` / `intercept_forward_edit` / `intercept_drop` | Release a held message byte-exact, release it with edited wire bytes, or drop it |
| `intercept_toggle` / `intercept_set_filter` / `intercept_set_direction` | Arm or disarm the catch, set its condition query, and choose which leg it holds |

> Action tools are capped for safety: fuzz, mine, sequence, discover, and authorize jobs are limited in total requests, concurrency, and stored results. An authorize run's cap counts `flows × identities`, and a selection over it is refused up front rather than truncated into a run that would report "enforced" for flows it never sent. A rule created via `create_rule` is picked up by `gori run` and newly opened TUIs; an already-running TUI applies it only after its rules reload.

## From a Spec to Repeater Tabs

`import_flows` reads OpenAPI/Swagger (JSON or YAML) and joins `servers[0].url` with each operation path, so the base-path assembly is already done. Getting from a spec to a strip of tabs is three calls:

```
import_flows{kind: "oas", path: "openapi.yaml"}
list_history{query: "src:import"}          → the flow ids
create_repeaters{flow_ids: [...], name_prefix: "oas: ", tags: "spec"}
```

`create_repeaters` checks every flow exists before it creates the first session, seeds each one through the same path a single `create_repeater{flow_id}` uses, and appends them in the order given. Rearrange afterwards with `move_repeater`, and prune with `delete_repeaters`.

## Live Intercept

An agent can sit in the intercept loop next to you rather than reading History after the fact. The TUI session holding the capture lock mirrors held messages out to the agent and drains the commands it sends back, so `intercept_list` → `intercept_get` → `intercept_forward_edit` is the same loop you drive by hand.

The mutating half (`intercept_forward`, `intercept_forward_edit`, `intercept_drop`, `intercept_toggle`, `intercept_set_filter`, `intercept_set_direction`) is disabled by `--read-only`, and every one of them refuses when no live capture session is holding the lock. There is nothing to forward without a proxy actually holding traffic.

Agent actions are visible, not silent. Each one lands in the notification center tagged as coming from an agent, rendered differently from your own actions, so you can see what a co-pilot did to traffic while you were reading another tab.

It reads the other way too. A row `intercept_list` returns with `operator_editing: true` is one you have unsaved changes typed into right now, so an agent can leave that message to you instead of forwarding, editing or dropping it and discarding your work.

One safety rule is worth knowing before you leave an agent running. A held message normally waits forever for a human decision, which is what you want when you are the only one at the keyboard. Once an agent attaches to the intercept queue in that session, gori arms a 30 second auto-forward for items nobody is watching, so a client that dies mid-hold cannot wedge the connection indefinitely. A session with no agent attached never auto-forwards.

## Messages from gori {#messages-from-gori}

Live Intercept lets an agent watch you work; the palette verb **"Tell the agent…"** (`app.tell-agent`) is the other direction — a one-line message you send from any gori tab to an attached agent's own session. Pick one of the MCP clients attached to the project (the same list the `mcp:` chip and the "Attached agents" card show), or all of them, type the line, and gori delivers it. From the "Attached agents" card itself, `t` messages the highlighted agent directly. When you send it from the History list with rows marked, those flows ride along as context so the agent can act on exactly what you had selected.

Delivery tries five layers, in the order of what gori can confirm — a route that reports back before one that cannot, and the first that answers ends the chain, so no message is ever carried twice:

1. **Inbox socket** — when the target is Claude Code, `gori mcp` writes the message to that session's inbox socket (`/tmp/cc-socks/<pid>.sock`, found by walking up from the client's own process). This is GA — no flag, no opt-in. The message arrives framed as a note from another session, prefixed `[gori] The operator at the gori TUI says:`; an idle session starts a turn on it, a busy one reads it between tool calls. Claude Code's own `crossSessionInbound` setting decides whether to accept it, hold it for later, or refuse it outright — gori writes the socket either way and cannot see which of the three happened. A socket file that is there but refuses the connection is a leftover from a session that has already exited — `/tmp/cc-socks/<pid>.sock` outlives the process that bound it, and pids are reused — so gori falls through to the next layer instead of stopping on a door nobody is behind.
2. **Codex queue** — when the target is Codex, `gori mcp` hands the line to that session's own thread with `codex queue --thread <id> --message …`, and the session runs a turn on it: immediately when it is idle, after the current turn when it is busy. Codex tells an MCP server nothing about itself, so gori reads the thread out of the writer lock the Codex process holds open (`<CODEX_HOME>/thread-writer-locks/<thread>.lock`), which names the thread and the `CODEX_HOME` to queue into — a session started with its own `CODEX_HOME` is still reached. GA, no flag. A thread that has not run a turn yet has no rollout and `codex queue` refuses it; that reason lands on the delivery row and the message stays readable through layers 4 and 5.
3. **Channel** — when `mcp.channels` is on in Settings *and neither door above answered*, `gori mcp` declares the `claude/channel` capability and pushes the message as a channel event. Claude Code shows it as `← gori: …` and starts a turn on it once the session is idle, so the model reads it as an instruction rather than a passive note. This needs Claude Code launched with `claude --dangerously-load-development-channels server:gori`, a research-preview flag with a one-time confirm dialog on the client side, and the curated `--channels` allowlist that flag ships with is Anthropic's, not gori's. It is **off by default**, and it is the LAST route tried rather than the first. A push to a session that never registered the channel is dropped silently and gori cannot tell, so going first meant the setting took the inbox socket — the one route that actually wakes that session — away from any Claude Code started without the flag. No message ever takes two routes: the first layer that answers ends the chain. What the push does cost is a second *reading* — it is not a confirmed carry, so the message stays pending for layers 4 and 5. Observed in a live test: Opus 5's safeguards flag channel-injected messages whatever they say and stop the session on a model-switch dialog; the socket route below does not trip them. Leave channels off unless you are testing them.
4. **Tool result** — whatever the client, any message the layers above did not carry rides back on the next gori tool the agent calls, whatever that tool was: the result carries a second content block with the operator's line beside the tool's own answer. GA, no flag, and nothing for the model to remember — which is the point. The other three layers are each one vendor's door (the inbox socket is Claude Code's, `codex queue` is Codex's, the channel is a preview of Claude Code's); grok, Pi, Hermes, Antigravity and Claude Desktop have none, so for them this is what turns "the message is in the feed" into "the message is in front of the model". It cannot wake an idle agent — nothing here can — but the moment that agent asks gori anything, the line is in the answer. Like the socket, it is a confirmed carry: the client asked for that result and was given it, so the message is retired from layer 5. A `--read-only` server has no writer fiber to record the delivery, so it sends the line and leaves the row readable.
5. **Poll** — always available, and the backstop under every layer above: the message is a row in the project's event feed, and the MCP tool `operator_messages` returns what is pending for the calling session. The handshake `instructions` tell the model to check it at the start of a turn, so an agent that reads its own instructions picks the message up on its next call even with no socket, no queue and no channel. What it cannot do is interrupt: an agent sitting idle at its own prompt sees the message when its next turn starts, not before.

Each delivery attempt writes an `agent_delivery` row, and you see the outcome without switching tabs: the TUI's notification ring shows `→ claude-code got it (socket)`, `→ codex-mcp-client got it (queued in codex)`, `→ grok-shell-gori got it (on its next tool result)`, `left for antigravity to pick up (operator_messages)` (and `→ antigravity picked it up` once it reads the message), or the reason a delivery failed, and Companion (Miss Ring) reacts to the same notice if she's on. The Activity pane lists every one of these under a new `operator` source, so the message and its delivery outcome stay on the record alongside everything else that happened to the project — see [Activity](/guide/proxy/#project-tab).

The way back is `reply_to_operator`. The handshake instructions tell the agent to use it for anything you must see without switching to its terminal: the one-line `summary` lands in the ring (and on Miss Ring), tagged with the client's name, and `detail` opens from the ring with `↵` — a finding, a diff, a list of endpoints. It is a row in the same feed, so it works for every agent, Claude or not, and it stays on the project's record under the `agent` source.

A few limits worth knowing before you rely on this:

- **Nothing is replayed.** A message is delivered to the agents attached *at the moment you send it*. An agent that attaches afterward does not receive it retroactively — `operator_messages` only ever answers with what is still pending for that session, and a delivery already made is not made twice.
- **It is a request, not consent.** Whichever layer carries it, a peer-framed message asks the model to do something; it does not authorize anything on its own, and the agent may decline exactly as it would any other instruction it disagrees with.
- **Channel delivery is a research preview.** It depends on an unreleased Claude Code flag and Anthropic's own curated allowlist, both of which can change out from under `mcp.channels` — the inbox socket and the poll tool exist so the feature still works the day that flag does not.

## Protocol Revisions

gori speaks both eras of MCP from one process, and each request decides which one answers it.

- **`2026-07-28`** — the stateless revision. A request carries its protocol version, the client's capabilities and (optionally) the client's name in `_meta`; there is no handshake to open and none to miss. Results come back with `resultType`, the server's identity under `_meta["io.modelcontextprotocol/serverInfo"]`, and — on `tools/list` — the `ttlMs` / `cacheScope` hints a client caches by. `server/discover` answers the supported versions, the capabilities and the instructions in a single call, and may be the first thing you send.
- **`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`** — the handshake revisions. `initialize` opens a session exactly as it always has, and is answered with the revision you asked for. Anything else — a version gori does not know, *and* a stateless one — is answered with the newest handshake revision: a session opened by `initialize` cannot switch to per-request semantics, so naming one back would be a promise gori could not keep.

A version gori does not speak is refused with `-32022` and the list of versions it does, so a client retries instead of guessing. The tool surface is identical either way: the era decides the envelope, never what a tool does.

Two things follow from the stateless revision that are worth knowing before you write a client. `subscriptions/listen` is answered, but with an empty filter and an immediate graceful close — gori pushes nothing, so the honest subscription is the empty one, and you should rely on the `ttlMs` you were given instead. And the `claude/channel` research preview is declared only to the handshake era: a stateless server may write responses, notifications belonging to a request in flight, and notifications on an acknowledged subscription, and a channel push is none of those. Operator messages still reach every client, by the socket, the Codex queue, the next tool result, and `operator_messages` — none of which touches the protocol stream.

An unknown tool name comes back as a JSON-RPC `-32602`, not as a tool result with `isError`. That is where the spec puts it: the call never reached a tool, so there is nothing for the model to retry differently. A tool that *ran* and failed still answers `isError: true` with a structured error, which is the one your agent should be handed back.

## Tool Hints

Every tool in `tools/list` carries `annotations.readOnlyHint`, so a client can tell the tools that only read this project's capture from the ones that write to it or send traffic at a target — the difference between a call worth running unattended and one worth asking about. It is derived from the same declaration [`--read-only`](#read-only-mode) enforces, so the hint and the gate cannot disagree, and a read-only tool also carries `openWorldHint: false`: it answers from the project store and never dials.

## One Call at a Time

Tools run one at a time, in the order they arrive; a fuzz or a slow `send_request` does not overlap with the next call, and responses come back in order. Two messages are answered immediately regardless: `ping`, so a client's liveness probe never stalls behind a long call and declares the server dead, and `notifications/cancelled`, which suppresses the response to a request you stopped waiting for. Cancelling does not abort work already in flight: an in-progress request finishes, its answer is simply not sent.

## Why an MCP Seam

gori deliberately has no in-tool AI chat. The intelligence lives outside the tool, reachable through MCP. That means you choose the model, your traffic isn't shipped anywhere you didn't intend, and the same interface serves scripts and agents alike. [`gori run`](/guide/scripting/) covers the non-interactive path; MCP covers the interactive-agent path.

## Next Steps

- [AI Setup](/getting-started/ai-setup/): a step-by-step walkthrough to connect an agent and drive its first request
- [Scripting](/guide/scripting/): the other automation path, `gori run` for pipelines and CI
- [CLI Reference](/reference/cli/): full `gori mcp` flags
- [Query Language](/reference/query-language/): the syntax agents use to filter
