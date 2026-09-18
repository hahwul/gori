require "./backend"
require "./protocol"

module Gori
  module Agent
    # Claude Code over stdio, in `stream-json` both ways (#1093).
    class ClaudeBackend < Backend
      # What every spawn is told about where it is. Fixed text rather than a setting, because
      # it is not a preference: an agent that does not know the `gori` MCP server exists will
      # answer questions about the operator's traffic out of thin air, and one that does not
      # call `get_current_context` first will answer about the wrong flow. It is prepended to
      # whatever the operator appends (`Config#system_prompt_append`), never replaced by it —
      # an operator adding a house style must not be able to silently remove the orientation.
      PREAMBLE = "You are attached to gori, an HTTP proxy for security testing; its tools " \
                 "are on the `gori` MCP server. Call get_current_context first to see what " \
                 "the operator is looking at."

      def name : String
        "claude"
      end

      # The launch contract. Pure — see `Backend`.
      #
      # The fixed flags, and why each one is not optional:
      #
      # * `-p` with `--input-format`/`--output-format stream-json` is the only mode that is a
      #   conversation rather than a one-shot: gori writes turns onto stdin for as long as the
      #   tab is open, and reads frames back.
      # * `--verbose` is what makes the stream carry the intermediate frames at all. Without it
      #   the run reports only its result, and a transcript of tool calls cannot be built from
      #   an answer.
      # * `--include-partial-messages` is what makes the pane stream instead of blinking a
      #   finished paragraph into place.
      # * `--permission-prompt-tool stdio` routes a tool's permission question back through
      #   this same stream, which is what lets the operator answer it in gori. Without it the
      #   child decides alone, and a proxy that runs an agent against live targets without an
      #   operator in the loop is not a thing to ship.
      # * `--session-id` claims the uuid gori has already written to `agent_sessions`, so the
      #   row and the process agree from the first frame rather than after the child announces
      #   one. `--resume` is added only when continuing.
      # * `--mcp-config` is the project binding (`McpConfig.write`).
      #
      # `config.args` is appended LAST so an operator's flag wins over a default of the same
      # name, which is how the CLI parsers this feeds resolve a repeat.
      def argv(config : Config, session_uuid : String, resume_uuid : String?,
               mcp_config_path : String) : Array(String)
        out_argv = [
          config.command,
          "-p",
          "--input-format", "stream-json",
          "--output-format", "stream-json",
          "--verbose",
          "--include-partial-messages",
          "--permission-prompt-tool", "stdio",
          "--session-id", session_uuid,
          "--mcp-config", mcp_config_path,
        ]
        out_argv << "--resume" << resume_uuid if resume_uuid
        # `presence` rather than a bare nil check: a settings field an operator cleared holds
        # `""`, and `--model ""` is not "no model", it is a model named the empty string — the
        # kind of argument a CLI either refuses outright or resolves to something surprising.
        if m = config.model.try(&.presence)
          out_argv << "--model" << m
        end
        out_argv << "--append-system-prompt" << system_prompt(config)
        out_argv.concat(config.args)
        out_argv
      end

      # PREAMBLE, plus the operator's addition when there is one. Joined with a blank line so
      # two paragraphs do not run together into one sentence; blank-safe, so a config that
      # never set it (or set it to whitespace) sends the preamble alone rather than a preamble
      # with a ragged tail.
      private def system_prompt(config : Config) : String
        extra = config.system_prompt_append.try(&.strip).presence
        extra ? "#{PREAMBLE}\n\n#{extra}" : PREAMBLE
      end

      # The codec, in `protocol.cr` and pure. Kept off this class so the launch contract above
      # and the wire format can be specced apart — and so a session can parse a recorded
      # transcript without constructing a backend at all.
      def parse(line : String) : Array(Event::Any)
        Claude::Protocol.parse(line)
      end

      def user_turn(text : String) : String
        Claude::Protocol.user_turn(text)
      end

      def permission_response(request_id : String, allow : Bool, input_json : String?,
                              message : String?) : String
        Claude::Protocol.permission_response(request_id, allow, input_json, message)
      end

      def interrupt(request_id : String) : String
        Claude::Protocol.interrupt(request_id)
      end
    end
  end
end
