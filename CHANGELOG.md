# Changelog

## Unreleased

- MCP: start **unbound** outside a Git workspace instead of aborting before the handshake, so `gori mcp --install-*` always connects; agents bind via `list_projects` / `create_project` (auto-binds when unbound) / `switch_project`. Traffic tools return `NO_PROJECT` until bound. Add `--no-project` to force unbound inside a workspace. Unbound never silently opens the active TUI/MRU project (still requires `--use-active-project`).

## v0.1.1

- Fix wide-character/emoji rendering and caret placement in the TUI editors with a per-grapheme width model (#281, #285, #289, #291)
- Fix proxy self-loop guards under wildcard binds, serve the CA cert page to LAN clients, and show a dialable bind address (#279, #284, #287)
- Stop background reconcile from resetting the caret in Repeater and Notes (#277, #286)
- Add Snap packaging and publish workflow (#276)
- Docs: install command picker, sidebar regrouping, AI setup guide, landing refresh (#275, #282, #283, #288, #290)

## v0.1.0

First Release
