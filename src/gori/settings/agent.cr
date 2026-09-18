require "json"

# AGENT section: the hosted coding-agent tab (#1093) — what `claude` gets launched with and
# how much rope its permission prompts get. See settings.cr for the module-level overview and
# the load/save/serialize orchestration, and src/gori/agent/ for what these actually drive
# (`Agent::Config.from_settings` turns these seven properties into one spawn).
module Gori::Settings
  # argv[0]. "claude" resolves through $PATH, which is the common case (the operator already
  # has Claude Code installed); an absolute path is for an operator who keeps several builds
  # around and wants gori pinned to one of them.
  DEFAULT_AGENT_COMMAND = "claude"
  # Extra argv, appended LAST after everything the backend builds — so a flag this build has
  # never heard of still reaches the child. Stored as one text field (`--foo "bar baz"`) and
  # split at spawn time by `ProcessHook.argv?`/`Agent::Config.parse_args`, never here: this
  # file only reads and writes strings, the same shape as `editor`'s `command`.
  DEFAULT_AGENT_ARGS = ""
  # "" defers to the CLI's own default model rather than gori naming one — the same reason
  # `mcp_read_only` below names a server property instead of a model gori has opinions about.
  DEFAULT_AGENT_MODEL = ""
  # Whether the agent's OWN `gori` MCP server is started `--read-only`. A property of the
  # SERVER, not of the agent's permission prompts (`permission_policy` below): a read-only
  # server refuses every mutating tool at the source, before a prompt is even possible. Off by
  # default because a project-only agent that cannot touch the network of the project it is
  # meant to test — sending requests, running fuzz/authorize — is a smaller tool than gori
  # already ships in the TUI, and the operator is the one deciding what they hand it.
  DEFAULT_AGENT_MCP_READ_ONLY = false
  # Appended to the agent's system prompt verbatim — house rules ("always run tests before
  # committing"), scope reminders, whatever the operator wants every turn to carry. Empty
  # means the CLI's own prompt, unmodified.
  DEFAULT_AGENT_SYSTEM_PROMPT_APPEND = ""
  # "ask" | "deny" — deliberately NO "allow". The operator's own `claude` settings can already
  # auto-allow tools silently (their `~/.claude/settings.json`, a project's `.claude/`); a
  # second auto-allow layer INSIDE gori, on top of that, would make a tool run gori never
  # showed a prompt for and gori would own that decision. "deny" is the safe default an
  # operator opts OUT of turn by turn; "ask" is the default that opts them IN.
  DEFAULT_AGENT_PERMISSION_POLICY = "ask"
  # How many turns of transcript the tab keeps once the live session is gone (the Agent tab's
  # History, #1093's `agent.history`). 50 is generous for "what did we just do" without the
  # unbounded growth a proxy's own capture already has to guard against (P6) — clamped 1..1000
  # so a hand-edited settings.json cannot ask for an unbounded log or a useless zero.
  DEFAULT_AGENT_HISTORY_KEEP = 50

  # All read live at spawn (`Agent::Config.from_settings`), so a save takes effect on the next
  # session rather than the live one — the same contract `editor_command` has.
  class_property agent_command : String = DEFAULT_AGENT_COMMAND
  class_property agent_args : String = DEFAULT_AGENT_ARGS
  class_property agent_model : String = DEFAULT_AGENT_MODEL
  class_property? agent_mcp_read_only : Bool = DEFAULT_AGENT_MCP_READ_ONLY
  class_property agent_system_prompt_append : String = DEFAULT_AGENT_SYSTEM_PROMPT_APPEND
  class_property agent_permission_policy : String = DEFAULT_AGENT_PERMISSION_POLICY
  class_property agent_history_keep : Int32 = DEFAULT_AGENT_HISTORY_KEEP

  AGENT_PERMISSION_POLICIES = {"ask", "deny"}

  # Allowed permission policies; anything else — including a stored "allow" from a build that
  # never should have written one — falls back to the default.
  def self.normalize_agent_permission_policy(s : String) : String
    AGENT_PERMISSION_POLICIES.includes?(s) ? s : DEFAULT_AGENT_PERMISSION_POLICY
  end

  def self.normalize_agent_history_keep(n : Int32) : Int32
    n.clamp(1, 1000)
  end

  # Tolerant agent section: absent/non-object keeps current.
  private def self.parse_agent(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    o["command"]?.try(&.as_s?).try { |v| self.agent_command = v }
    o["args"]?.try(&.as_s?).try { |v| self.agent_args = v }
    o["model"]?.try(&.as_s?).try { |v| self.agent_model = v }
    # load_bool_h, not `|| agent_mcp_read_only?` — a plain `||` resurrects a stored `false`.
    self.agent_mcp_read_only = load_bool_h(o, "mcp_read_only", agent_mcp_read_only?)
    o["system_prompt_append"]?.try(&.as_s?).try { |v| self.agent_system_prompt_append = v }
    o["permission_policy"]?.try(&.as_s?)
      .try { |v| self.agent_permission_policy = normalize_agent_permission_policy(v) }
    o["history_keep"]?.try(&.as_i?)
      .try { |v| self.agent_history_keep = normalize_agent_history_keep(v) }
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_agent writes. The source-grep guard only checks that this method
  # EXISTS and is dispatched (see display.cr's block) — keeping the two field lists in step is
  # a hand job, so add to both in the same edit.
  private def self.reset_agent : Nil
    self.agent_command = DEFAULT_AGENT_COMMAND
    self.agent_args = DEFAULT_AGENT_ARGS
    self.agent_model = DEFAULT_AGENT_MODEL
    self.agent_mcp_read_only = DEFAULT_AGENT_MCP_READ_ONLY
    self.agent_system_prompt_append = DEFAULT_AGENT_SYSTEM_PROMPT_APPEND
    self.agent_permission_policy = DEFAULT_AGENT_PERMISSION_POLICY
    self.agent_history_keep = DEFAULT_AGENT_HISTORY_KEEP
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_agent(j : JSON::Builder) : Nil
    unless agent_command == DEFAULT_AGENT_COMMAND &&
           agent_args == DEFAULT_AGENT_ARGS &&
           agent_model == DEFAULT_AGENT_MODEL &&
           agent_mcp_read_only? == DEFAULT_AGENT_MCP_READ_ONLY &&
           agent_system_prompt_append == DEFAULT_AGENT_SYSTEM_PROMPT_APPEND &&
           agent_permission_policy == DEFAULT_AGENT_PERMISSION_POLICY &&
           agent_history_keep == DEFAULT_AGENT_HISTORY_KEEP
      j.field "agent" do
        j.object do
          j.field "command", agent_command
          j.field "args", agent_args
          j.field "model", agent_model
          j.field "mcp_read_only", agent_mcp_read_only?
          j.field "system_prompt_append", agent_system_prompt_append
          j.field "permission_policy", agent_permission_policy
          j.field "history_keep", agent_history_keep
        end
      end
    end
  end
end
