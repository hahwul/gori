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

  # One coarse on/off switch over a group of `gori mcp` tools. Reading the capture is not a
  # group: it is what an attached agent is FOR, and a server with nothing to read is not a
  # narrower server but a broken one.
  record McpPermission, key : String, title : String, summary : String

  # The groups, in the order Preferences draws them. `key` is what `settings.json` stores and
  # what a tool's `@[Tool(permission:)]` names (the registry macro refuses any other value),
  # so it is never renamed: a stored `false` under an old key would quietly turn back on.
  MCP_PERMISSIONS = [
    McpPermission.new("send", "Send traffic",
      "replay, race, fuzz, mine, discover, authorize, sequence, retest and OAST — every tool that dials a target"),
    McpPermission.new("intercept", "Intercept control",
      "forward, drop, edit and re-filter held traffic, and switch intercept on or off"),
    McpPermission.new("write", "Edit project data",
      "issues, notes, repeaters, rules, scope, env, session slots and the other project records"),
    McpPermission.new("projects", "Manage projects",
      "create, switch, delete, import and export projects"),
  ]

  # The same keys as a literal, for the `@[Tool]` registry macro, which can read a constant
  # only when its value IS a literal. spec/settings/mcp_spec.cr holds the two in step.
  MCP_PERMISSION_KEYS = %w[send intercept write projects]

  # Every group is allowed by default, which is what `gori mcp` did before the switches
  # existed. Stored as the DENIED keys, because that is the only thing the file records: a
  # default install writes no `mcp_permissions` section at all. A key this gori does not know
  # (a newer gori's group) is kept and written back, never dropped — it grants nothing here.
  #
  # Its OWN top-level section, not a key inside `mcp`: the save merge reconciles whole
  # sections (`merge_with_disk`), so sharing one with `channels` let a window that only
  # toggled Channel delivery write its stale copy of the denials back over another window's.
  #
  # Read at `gori mcp` start like `mcp_channels` (through `mcp_enforced_denials`), so a change
  # reaches an agent whose server is started after it; the Preferences rows say so.
  class_property mcp_denied_permissions : Set(String) = Set(String).new

  # The group `key` names, or nil for a key this gori does not know.
  def self.mcp_permission(key : String) : McpPermission?
    MCP_PERMISSIONS.find(&.key.==(key))
  end

  # The groups among `keys`, in Preferences order; a key this gori does not know is skipped.
  def self.mcp_permission_groups(keys : Enumerable(String)) : Array(McpPermission)
    MCP_PERMISSIONS.select { |p| keys.includes?(p.key) }
  end

  def self.mcp_permitted?(key : String) : Bool
    !mcp_denied_permissions.includes?(key)
  end

  def self.set_mcp_permitted(key : String, allowed : Bool) : Nil
    denied = mcp_denied_permissions.dup
    allowed ? denied.delete(key) : denied.add(key)
    self.mcp_denied_permissions = denied
  end

  # The denials `gori mcp` enforces. A security switch must not fail OPEN: when the last `load`
  # left sections at their defaults (`load_degraded?` — a section above this one raised, the
  # file is not JSON, or it could not be read) the in-memory set says "all allowed" about a
  # file nobody finished reading. The section is then read on its own from the raw file, and
  # when even that is impossible every group is denied, with the reason on stderr.
  def self.mcp_enforced_denials : {Set(String), String?}
    return {mcp_denied_permissions.dup, nil} unless load_degraded?
    root = begin
      JSON.parse(File.read(path))
    rescue
      nil
    end
    if root && (h = root.as_h?)
      return {mcp_denials_from(h["mcp_permissions"]?) || Set(String).new, nil}
    end
    {MCP_PERMISSION_KEYS.to_set, "#{path} could not be read, so every MCP permission group is off until it is fixed"}
  end

  private def self.mcp_denials_from(node : JSON::Any?) : Set(String)?
    node.try(&.as_h?).try &.compact_map { |k, v| k if v.as_bool? == false }.to_set
  end

  # Tolerant mcp section: absent/non-object keeps current.
  private def self.parse_mcp(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool_h, not `|| mcp_channels?` — a plain `||` resurrects a stored `false`.
    self.mcp_channels = load_bool_h(o, "channels", mcp_channels?)
  end

  # An object replaces the whole set: the file records only denials, so a key it no longer
  # names is one somebody turned back on. Absent or non-object keeps the current set.
  private def self.parse_mcp_permissions(node : JSON::Any?) : Nil
    if denied = mcp_denials_from(node)
      self.mcp_denied_permissions = denied
    end
  end

  # Factory reset for these sections (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_mcp / serialize_mcp_permissions write.
  private def self.reset_mcp : Nil
    self.mcp_channels = DEFAULT_MCP_CHANNELS
  end

  private def self.reset_mcp_permissions : Nil
    self.mcp_denied_permissions = Set(String).new
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

  private def self.serialize_mcp_permissions(j : JSON::Builder) : Nil
    return if mcp_denied_permissions.empty?
    j.field "mcp_permissions" do
      j.object { mcp_denied_permissions.to_a.sort!.each { |k| j.field k, false } }
    end
  end
end
