module Gori
  # A coding agent hosted INSIDE gori as a child process (#1093): the operator's own Claude
  # Code, driven over its stream-json stdio protocol, drawn in the Agent tab. gori never
  # calls a model itself — the decision from #98 stands (no built-in AI chat; AI value lives
  # at the MCP seam). What this module adds is the seat: the agent the operator already uses,
  # running here, with gori's own MCP tools handed to it at spawn.
  #
  # Layering, top to bottom: `Event` (this file) is the backend-NEUTRAL vocabulary a session
  # consumes; `Claude::Protocol` (protocol.cr) is the one place that knows Claude Code's wire
  # format; `Backend` (backend.cr) is the seam an ACP-speaking agent plugs into later without
  # touching `Session` or `Transcript`. Nothing under `Gori::Agent` may name a surface — with one
  # named exception: `McpConfig` borrows `MCP::Install`'s argv builder and binary lookup, because a
  # second spelling of `gori mcp`'s flags is how a flag gets validated in one place and dropped in
  # the other.
  module Agent
    # One thing the child said, already lifted out of its wire framing. A union of records
    # rather than a kind-enum on one struct so that `case ev in …` is exhaustive at compile
    # time: adding a variant fails every consumer that does not map it, which is the same
    # argument `Tui::OverlayKind` makes for its enum.
    module Event
      # `system/init`. Arrives on EVERY turn, not once — a consumer treats it as idempotent
      # metadata (session id, model, the capability strings that gate `interrupt`), never as
      # "a new conversation started".
      record TurnStarted, session_id : String, model : String, capabilities : Array(String)

      # A streamed slice of assistant prose. Display only — the `AssistantText` that follows
      # carries the complete block and is what gets persisted.
      record TextDelta, text : String

      # A streamed slice of extended thinking. Usually empty on the wire (the model's thinking
      # is redacted to a signature); kept as a variant so the tab can show "thinking…".
      record ThinkingDelta, text : String

      # One complete `text` content block of an assistant message.
      record AssistantText, text : String

      # One `tool_use` block: the agent decided to call `name` with `input_json` (the block's
      # input object, re-serialized compactly). `id` is what the matching `ToolResult` and any
      # `PermissionAsked` refer back to.
      record ToolUse, id : String, name : String, input_json : String

      # The `tool_result` block the CLI fed back to the model. `content` is the text form —
      # a string on the wire, or the text parts of a block array joined.
      record ToolResult, tool_use_id : String, content : String, is_error : Bool

      # A `control_request` of subtype `can_use_tool`: the CLI is holding a tool call until
      # someone answers. The answer goes back through `Backend#permission_response` with the
      # same `request_id`. `reason` is the CLI's `decision_reason` (why the rules did not
      # settle it), `tool_use_id` the block it gates.
      record PermissionAsked, request_id : String, tool : String, display : String,
        input_json : String, description : String, reason : String, tool_use_id : String

      # The `result` frame that closes a turn. `subtype` is `success` or one of the CLI's
      # `error_*` values; `text` is the final assistant text (empty on an error);
      # `denials` counts `permission_denials` so a turn that ended because the operator said
      # no is distinguishable from one that simply finished.
      record TurnDone, subtype : String, text : String, cost_usd : Float64, denials : Int32,
        session_id : String

      # A line the protocol could not place: malformed JSON, or a frame that parsed but wants
      # something we do not speak (a `control_request` of another subtype is the important
      # case — the CLI is waiting on an answer nobody will give). Surfaced rather than
      # dropped so the transcript can show "the child said something gori did not
      # understand" instead of a silent gap. `truncated` when the line was cut to fit.
      record Raw, line : String, truncated : Bool

      # The child is gone. `status` nil when it never spawned (or the wait did not land);
      # `reason` is the human line for the tab's dead band — the stderr tail if it left any,
      # else the exit code or signal.
      record Exited, status : Process::Status?, reason : String

      alias Any = TurnStarted | TextDelta | ThinkingDelta | AssistantText | ToolUse | ToolResult |
                  PermissionAsked | TurnDone | Raw | Exited
    end

    # What the operator decided about one `Event::PermissionAsked`.
    enum Decision
      Allow
      Deny
      # Allow, and stop asking for this tool for as long as THIS session lives. Kept in gori
      # (`Session#session_allow`), never written to the operator's own agent settings — the
      # `permission_suggestions` the CLI offers target `~/.claude/settings.json`, and gori
      # mutating that behind the operator's back is not a favour.
      AllowForSession
    end
  end
end
