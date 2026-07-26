require "./mcp/serialize"
require "./mcp/request_builder"
require "./mcp/project_resolver"
require "./mcp/tools"
require "./mcp/server"
require "./mcp/install"

module Gori
  # The `gori mcp` server: exposes captured data + the repeater engines to an AI
  # client over the Model Context Protocol (JSON-RPC 2.0 on stdio). It talks
  # straight to Store + Repeater rather than the TUI verb registry, because a verb
  # names no target — it acts on whatever a live `ExecContext` has selected, which
  # a headless client cannot express (DESIGN.md §7, 2026-07-26; issue #357). That
  # separation is settled, not pending. See `MCP::Server` (transport), `MCP::Tools`
  # (the tool surface), `MCP::Serialize` (struct→JSON), and `MCP::RequestBuilder`
  # (send_request bytes).
  module MCP
  end
end
