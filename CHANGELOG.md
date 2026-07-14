# Changelog

## Unreleased

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
