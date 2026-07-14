require "./mcp/serialize"
require "./mcp/request_builder"
require "./mcp/tools"
require "./mcp/server"
require "./mcp/install"

module Gori
  # The `gori mcp` server: exposes captured data + the replay engines to an AI
  # client over the Model Context Protocol (JSON-RPC 2.0 on stdio). It talks
  # straight to Store + Replay rather than the TUI verb registry, because verbs
  # drive a live ExecContext (UI state) and have nothing to offer a headless
  # client. See `MCP::Server` (transport), `MCP::Tools` (the tool surface),
  # `MCP::Serialize` (struct→JSON), and `MCP::RequestBuilder` (send_request bytes).
  module MCP
  end
end
