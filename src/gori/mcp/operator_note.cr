module Gori::MCP
  # How the operator's line is worded on its way to an agent's own session (#1090).
  #
  # Every live route carries the SAME sentence — a Claude Code inbox socket, a `claude/channel`
  # event, a `codex queue` hand-off — because the thing that needs saying does not change with
  # the transport: who is speaking, that gori is only the relay, and where the answer goes.
  # It lives here rather than beside one of those routes so adding the next client is a new
  # delivery module and not a second, drifting copy of the wording.
  #
  # Context (the tab, the marked flows) travels in `operator_messages`, not here — a relayed
  # line is a sentence, not a payload.
  module OperatorNote
    # Every message ends with where the answer goes. The handshake instructions say the same
    # thing once; a model answering in its own pane while the operator waits in gori was the
    # first thing the live test showed, and a sentence on the message itself is what the
    # model actually has in front of it when it decides how to answer.
    REPLY_HINT = " — answer with the gori tool reply_to_operator (summary + optional detail); the operator is in gori, not in this terminal."

    # The operator's line, framed. Kept short and honest: who is speaking, and that gori is
    # only the relay.
    def self.frame(text : String, from_tab : String?) : String
      where = from_tab ? " (from the #{from_tab} tab)" : ""
      "[gori] The operator at the gori TUI says#{where}: #{text}#{REPLY_HINT}"
    end
  end
end
