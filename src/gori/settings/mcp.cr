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
      "issues, notes, repeaters, rules, env, session slots, saved wordlists and the other records"),
    # Its own group, not part of `write`: scope and the sandbox are the fence around what an
    # agent may reach, so an operator who lets it take notes need not let it move the fence.
    McpPermission.new("scope", "Change scope & sandbox",
      "add, edit and delete scope rules, and switch the scope lens and the sandbox on or off"),
    McpPermission.new("projects", "Manage projects",
      "create, switch, delete, import and export projects"),
    # An ADDITIONAL gate, ANDed with the tool's own group, not a group a tool sits in: the
    # tools that can run a command (`create_rule`, `mine_start`, `fuzz_start`, …) also do work
    # that runs nothing, so this refuses the ARGUMENT that would (`Tools#exec_refusal`), never
    # the tool. Denying `write` or `send` still refuses those tools first, so an install that
    # shipped before this group existed loses nothing it had denied and needs no migration.
    McpPermission.new("exec", "Run local commands",
      "Rewriter pipe rules, Probe exec rules, Miner hooks and Fuzzer exec: chain steps — anything that runs a program on this machine"),
  ]

  # The same keys as a literal, for the `@[Tool]` registry macro, which can read a constant
  # only when its value IS a literal. spec/settings/mcp_spec.cr holds the two in step.
  MCP_PERMISSION_KEYS = %w[send intercept write scope projects exec]

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

  # The groups in the third state, `ask` (#1585): served, but each call waits on the operator's
  # approval in the TUI (`Tools#approval_gate`). Stored beside the denials as `"<key>": "ask"`,
  # which an older gori reads as off — any non-boolean is a denial there — so a downgrade fails
  # closed and needs no migration. Never also in `mcp_denied_permissions`.
  class_property mcp_asked_permissions : Set(String) = Set(String).new

  # The three states a group's Preferences row cycles through, in that order.
  MCP_PERMISSION_STATES = %w[on ask off]

  # The group `key` names, or nil for a key this gori does not know.
  def self.mcp_permission(key : String) : McpPermission?
    MCP_PERMISSIONS.find(&.key.==(key))
  end

  # The groups among `keys`, in Preferences order; a key this gori does not know is skipped.
  def self.mcp_permission_groups(keys : Enumerable(String)) : Array(McpPermission)
    MCP_PERMISSIONS.select { |p| keys.includes?(p.key) }
  end

  # "on", "ask" or "off".
  def self.mcp_permission_state(key : String) : String
    return "off" if mcp_denied_permissions.includes?(key)
    mcp_asked_permissions.includes?(key) ? "ask" : "on"
  end

  def self.set_mcp_permission_state(key : String, state : String) : Nil
    denied = mcp_denied_permissions.dup
    asked = mcp_asked_permissions.dup
    state == "off" ? denied.add(key) : denied.delete(key)
    state == "ask" ? asked.add(key) : asked.delete(key)
    self.mcp_denied_permissions = denied
    self.mcp_asked_permissions = asked
  end

  # The denials and asks `gori mcp` enforces. A security switch must not fail OPEN: when the
  # last `load` left sections at their defaults (`load_degraded?` — a section above this one
  # raised, the file is not JSON, or it could not be read) the in-memory sets say "all allowed"
  # about a file nobody finished reading. The section is then read on its own from the raw
  # file, and when even that is impossible every group is denied, with the reason on stderr.
  def self.mcp_enforced_denials : {Set(String), Set(String), String?}
    return {mcp_denied_permissions.dup, mcp_asked_permissions.dup, nil} unless load_degraded?
    root = begin
      JSON.parse(File.read(path))
    rescue
      nil
    end
    if root && (h = root.as_h?)
      node = h["mcp_permissions"]?
      asked = mcp_asks_from(node)
      return {(mcp_denials_from(node) || Set(String).new) - asked, asked, nil}
    end
    {MCP_PERMISSION_KEYS.to_set, Set(String).new, "#{path} could not be read, so every MCP permission group is off until it is fixed"}
  end

  # The rule an older gori applies to the whole section, `"ask"` included, so it stays the
  # first pass here and the asks are taken back out of it (`mcp_asks_from`).
  private def self.mcp_denials_from(node : JSON::Any?) : Set(String)?
    return nil unless h = node.try(&.as_h?)
    # Only a real `true` allows a known group: `"send": "false"`, `0` or `null` is a switch
    # somebody meant to turn off, and reading it as on would fail open.
    denied = h.compact_map do |k, v|
      k if v.as_bool? == false || (v.as_bool?.nil? && MCP_PERMISSION_KEYS.includes?(k))
    end.to_set
    # `scope` was split out of `write` after both had shipped on main, and a `write: false`
    # written before the split meant "no scope edits" too. Reading it as "scope allowed" would
    # turn a security switch back on across an upgrade, so an ABSENT `scope` beside a denied
    # `write` is denied; `serialize_mcp_permissions` writes `scope: true` for the one
    # combination that has to say otherwise.
    denied.add("scope") if denied.includes?("write") && !h.has_key?("scope")
    denied
  end

  # The keys stored as exactly `"ask"`. An unknown key is kept, like an unknown denial, so a
  # newer gori's group round-trips; it asks for nothing here.
  private def self.mcp_asks_from(node : JSON::Any?) : Set(String)
    return Set(String).new unless h = node.try(&.as_h?)
    h.compact_map { |k, v| k if v.as_s? == "ask" }.to_set
  end

  # Tolerant mcp section: absent/non-object keeps current.
  private def self.parse_mcp(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool, not `|| mcp_channels?` — a plain `||` resurrects a stored `false`.
    self.mcp_channels = load_bool(o, "channels", mcp_channels?)
  end

  # An object replaces the whole set: the file records only denials, so a key it no longer
  # names is one somebody turned back on. Absent or non-object keeps the current set.
  private def self.parse_mcp_permissions(node : JSON::Any?) : Nil
    if denied = mcp_denials_from(node)
      asked = mcp_asks_from(node)
      self.mcp_denied_permissions = denied - asked
      self.mcp_asked_permissions = asked
    end
  end

  # Factory reset for these sections (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_mcp / serialize_mcp_permissions write.
  private def self.reset_mcp_permissions : Nil
    self.mcp_denied_permissions = Set(String).new
    self.mcp_asked_permissions = Set(String).new
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  defaulted_section mcp, "mcp",
    {"channels", mcp_channels?, DEFAULT_MCP_CHANNELS}

  private def self.serialize_mcp_permissions(j : JSON::Builder) : Nil
    return if mcp_denied_permissions.empty? && mcp_asked_permissions.empty?
    j.field "mcp_permissions" do
      j.object do
        mcp_denied_permissions.to_a.sort!.each { |k| j.field k, false }
        mcp_asked_permissions.to_a.sort!.each { |k| j.field k, "ask" }
        # See `mcp_denials_from`: without it, `write` off (or `ask`, which an older reader takes
        # for off) and `scope` on reads back with `scope` off.
        j.field "scope", true if mcp_permission_state("write") != "on" && mcp_permission_state("scope") == "on"
      end
    end
  end
end
