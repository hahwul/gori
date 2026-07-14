# Changelog

## Unreleased

### Added — protocol filter in History

WebSocket, gRPC, and SSE flows are now first-class in the History tab instead of
being indistinguishable from plain HTTP:

- **PROTO column** shows `WS` / `GRPC` / `SSE` (accented) for those flows; ordinary
  requests keep showing the scheme (`HTTP` / `HTTPS`).
- **New QL field `proto:`** — `proto:ws`, `proto:grpc`, `proto:sse`, `proto:http`
  (`websocket` is an alias for `ws`). WS is the 101 upgrade handshake; gRPC/SSE are
  matched by response Content-Type. `proto:http` is everything else, including
  still-pending flows. No database column or migration — it is derived from data
  gori already stores.

### Changed — clearer `/` filter guidance

The filter bars on the History, Sitemap, and Repeater tabs now surface what you
can type from the moment they open:

- The field hint no longer vanishes when the Scope lens is on (History, Sitemap) —
  the lens is already signalled by the `⇧S` chip, so the row keeps listing the
  filter fields instead of showing a bare `(in-scope only)`.
- Opening `/` with nothing typed now shows a standing hint of the available fields
  and a reminder that bare words are a free-text search (the row used to stay blank
  until you started typing).
- History and Sitemap idle hints now include the new `proto:` field.

### Changed — four tabs renamed (BREAKING)

Four tools were renamed for clearer, more conventional names. The rename is
tool-wide: TUI, `gori run`, the MCP server, config, and the on-disk database.

| Old | New |
|-----|-----|
| Replay | **Repeater** |
| Prism | **Probe** |
| Findings | **Issues** |
| Convert | **Decoder** |

**Automatic (no action needed):**

- **Existing project databases** migrate in place on first open (schema V32–V34).
  Repeater sessions, Probe issues/suppressions, triaged Issues, entity links, and
  the saved scan mode are all preserved under the new names. No data is lost.
- **Existing `settings.json`** is read with back-compat: saved tab order/visibility,
  layout preview toggles, the Decoder (`convert`) section, and custom keybindings on
  renamed verbs are all remapped to the new names on load, and rewritten on next save.

**Breaking — update your scripts/integrations:**

- **MCP tool names.** `create_replay`/`update_replay`/`delete_replay` →
  `create_repeater`/`update_repeater`/`delete_repeater`; `get_replay_context` →
  `get_repeater_context`; `list_findings`/`get_finding`/`create_finding`/`update_finding`
  → `list_issues`/`get_issue`/`create_issue`/`update_issue`; `convert` → `decode`.
  Input fields `replay_id`/`save_as_replay`/`finding_id` → `repeater_id`/`save_as_repeater`/`issue_id`.
  Output keys `findings` → `issues`, `tui_on_replay_tab`/`tui_replay` → `…repeater…`.
- **CLI subcommands.** `gori run replay` → `gori run repeater`; `gori run prism` →
  `gori run probe`; `gori run findings` → `gori run issues`.
- **Exported files.** `findings.md`/`findings.json` → `issues.md`/`issues.json`.
