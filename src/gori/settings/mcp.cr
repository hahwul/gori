require "json"

# MCP section: gori's own MCP server and how it talks back to the agents attached to it.
# See settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # OFF by default. The `claude/channel` capability that lets "Tell the agent…" push a
  # message straight into a Claude Code session's turn is a research-preview surface —
  # Claude Code has to be launched with `--dangerously-load-development-channels
  # server:gori` for it to exist at all, and a push to a session that never registered the
  # channel is dropped silently. An operator who has opted into the Claude Code flag opts
  # into this too.
  #
  # It is a LAST RESORT, not an extra layer: `Courier#deliver` tries the inbox socket and the
  # `codex queue` hand-off first and returns on the one that answers, so the push happens only
  # when no route that can confirm itself is open. That ordering is what keeps the setting from
  # making delivery worse — pushing first meant a session launched WITHOUT the flag had its
  # socket taken away by a frame nobody could tell had been dropped — and it is also why there
  # is no double delivery to weigh: no message ever takes two routes. What the push does cost
  # is a second READING: it is not in `AgentDelivery::CARRIED`, so the message stays in the
  # feed for `operator_messages` and the tool-result carry, which is the safe direction.
  DEFAULT_MCP_CHANNELS = false

  # Read ONCE per `gori mcp` process, and then once more per handshake: the server loads
  # settings at startup (`cli/mcp.cr`) and latches the answer when the client opens a session
  # (`Server#handle_initialize`). Nothing re-reads `settings.json` afterwards, so flipping this
  # in Preferences reaches an agent only when that agent's server is STARTED again — not when
  # it reconnects, and not when the client re-handshakes over the same process. The Settings
  # row says so, because an operator who toggles it and sees nothing change has no other way
  # to find out.
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
