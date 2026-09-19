require "json"

# MCP section: gori's own MCP server and how it talks back to the agents attached to it.
# See settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # OFF by default. The `claude/channel` capability that lets "Tell the agent…" push a
  # message straight into a Claude Code session's turn is a research-preview surface —
  # Claude Code has to be launched with `--dangerously-load-development-channels
  # server:gori` for it to exist at all, and a push to a session that never registered the
  # channel is dropped silently. Combined with the inbox-socket delivery that already runs
  # unconditionally, turning this on by default would risk delivering the same message
  # twice. An operator who has opted into the Claude Code flag opts into this too.
  DEFAULT_MCP_CHANNELS = false

  # Read live wherever `gori mcp` decides how to deliver an operator message, so flipping
  # this in Preferences takes effect when the agent next connects: the capability is declared
  # at the handshake, and a running session keeps the answer it was given.
  class_property? mcp_channels : Bool = DEFAULT_MCP_CHANNELS

  # Tolerant mcp section: absent/non-object keeps current.
  private def self.parse_mcp(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool_h, not `|| mcp_channels?` — a plain `||` resurrects a stored `false`.
    self.mcp_channels = load_bool_h(o, "channels", mcp_channels?)
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_mcp writes.
  private def self.reset_mcp : Nil
    self.mcp_channels = DEFAULT_MCP_CHANNELS
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_mcp(j : JSON::Builder) : Nil
    unless mcp_channels? == DEFAULT_MCP_CHANNELS
      j.field "mcp" do
        j.object do
          j.field "channels", mcp_channels?
        end
      end
    end
  end
end
