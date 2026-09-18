require "../process_hook"

module Gori
  module Agent
    # Everything one agent spawn needs to know, decided by the caller rather than read from a
    # global.
    #
    # NO `Settings` dependency, deliberately. The settings that will populate these arrive in a
    # later slice of #1093, and the moment this record reaches for them it stops being a value
    # a spec (or a headless caller, or a second concurrent session on a different project) can
    # construct. The Store/Session layer that owns a tab is where a setting gets read and turned
    # into one of these — the same split `Plan.build` has, where option PARSING is
    # surface-specific and everything downstream of the normalized options has one implementation.
    #
    # `db_path` is not optional and comes first because it is what makes this spawn belong to a
    # project: it is the database the agent's own `gori` MCP server is pointed at
    # (`McpConfig.write`), so an agent launched with the wrong one answers questions about
    # somebody else's traffic.
    record Config,
      db_path : String,
      # argv[0]. A name resolved through `$PATH`, or an absolute path for an operator who keeps
      # several builds around.
      command : String = "claude",
      # Extra argv appended AFTER everything the backend builds, so an operator can pass a flag
      # this build has never heard of. Last wins for most CLI parsers, which is the point.
      args : Array(String) = [] of String,
      model : String? = nil,
      # Whether the agent's `gori` MCP server is started `--read-only`. A property of the
      # SERVER, not of the agent's own permission prompts: a read-only server refuses every
      # mutating tool at the source, where a permission policy only decides what gets asked.
      mcp_read_only : Bool = false,
      system_prompt_append : String? = nil,
      # Reserved for the permission seam (`ask` | … ) that PR2 wires to the prompt overlay.
      # A string rather than an enum because the vocabulary is not settled yet and a
      # `PlanError::Reason`-shaped exhaustive `case` across three surfaces is the trap AGENTS.md
      # names; it becomes an enum when the set stops moving.
      permission_policy : String = "ask",
      # The child's working directory. nil = inherit gori's, which is what an operator running
      # `gori` in a repo means by "here".
      cwd : String? = nil do
      # Tokenize the settings-string form of `args` — `--foo "bar baz"` as one text field —
      # into argv.
      #
      # `ProcessHook.parse_argv` is the tokenizer, and reused rather than rewritten because it
      # is the one place that has been argued through: it is NOT a shell (`$FOO`, `;`, `|` and
      # `` ` `` are ordinary characters handed to `execvp` as data), which is the security
      # property, and its double-quote escape rules have already been wrong once (#842).
      #
      # Through `ProcessHook.argv?`, which is `parse_argv` with the error branch already
      # folded to nil — the "run path" form the hooks use, for callers that have already been
      # validated at the write surface and only need the happy answer.
      #
      # An unparseable spec answers `[] of String` rather than raising or half-tokenizing.
      # `parse_argv` returns the PROBLEM as a String, and every write surface in gori validates
      # with it before persisting, so the settings editor is where an operator learns their
      # quote never closed. By the time a spawn is reading a stored value the useful answer is
      # "no extra args", not a crash in the middle of starting an agent. An EMPTY spec takes
      # the same branch ("no command"), and lands on the same right answer.
      def self.parse_args(spec : String) : Array(String)
        ProcessHook.argv?(spec) || [] of String
      end
    end
  end
end
