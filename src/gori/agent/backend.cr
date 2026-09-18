require "./config"
require "./event"

module Gori
  module Agent
    # The seam an ACP backend arrives through (#1093).
    #
    # The Agent tab is built in two halves. `Event`, the session that owns a spawn, and the
    # transcript in `agent_sessions`/`agent_messages` are backend-NEUTRAL: they speak in turns,
    # tool calls, permission questions and costs, which is the vocabulary every coding agent
    # has. This class and `protocol.cr` are the Claude-specific half — how those concepts are
    # spelled on one particular wire (`claude -p --output-format stream-json`), and how a
    # process is asked to speak it.
    #
    # Two responsibilities, and they are separate on purpose:
    #
    # * **`argv`** — a PURE function of a config plus three ids. No spawning, no filesystem, no
    #   clock. It is the whole launch contract, so it is the thing a spec can pin exhaustively
    #   (flag order, what a nil model omits, where an operator's extra args land) without a
    #   `claude` binary on the machine. The one impure input it needs — the MCP config file —
    #   is passed IN as a path, already written.
    # * **`parse` / `user_turn` / `permission_response` / `interrupt`** — the codec, delegated
    #   to a pure module. A backend instance holds no parse state, so a session can be handed a
    #   backend and a transcript and reconstruct either from the other.
    #
    # A second backend therefore has to supply an argv and a codec and nothing else; everything
    # the operator sees is already written against `Event`. That is the test for whether
    # something belongs here: if a concept cannot be spelled for a non-Claude agent, it belongs
    # in `Event` and not on this class.
    abstract class Backend
      # The stored `agent_sessions.backend` token. Free text in the column, so this is the list
      # of what is actually written — the stance `Store::EVENT_SOURCES` documents.
      abstract def name : String

      # The full argv for one spawn; `argv[0]` is the command to exec.
      #
      # `session_uuid` is the uuid THIS spawn will claim, and `resume_uuid` the conversation it
      # continues (nil for a fresh one). Both, rather than one: Claude Code refuses a
      # `--session-id` it has already issued, so continuing a conversation means a new uuid
      # AND a resume of the old one — see the V29 comment in `store/schema.cr`.
      abstract def argv(config : Config, session_uuid : String, resume_uuid : String?,
                        mcp_config_path : String) : Array(String)

      # One line of the child's stdout as events. `[]` means "nothing this build has an event
      # for" — never an error, because an unknown frame from a newer agent must not take the
      # tab down.
      abstract def parse(line : String) : Array(Event::Any)

      # One line for the child's stdin: the operator's message.
      abstract def user_turn(text : String) : String

      # The answer to a `PermissionAsked`. `input_json` is a MODIFIED tool input when the
      # operator edited it and nil when they did not; `message` is the reason shown to the
      # agent on a denial.
      abstract def permission_response(request_id : String, allow : Bool, input_json : String?,
                                       message : String?) : String

      # Stop the turn `request_id` belongs to.
      abstract def interrupt(request_id : String) : String
    end
  end
end
