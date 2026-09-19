module Gori::MCP
  # How the operator's line is worded on its way to an agent's own session (#1090).
  #
  # Every live route carries the SAME sentence — a Claude Code inbox socket, a `claude/channel`
  # event, a `codex queue` hand-off — because the thing that needs saying does not change with
  # the transport: who is speaking, that gori is only the relay, and where the answer goes.
  # It lives here rather than beside one of those routes so adding the next client is a new
  # delivery module and not a second, drifting copy of the wording.
  #
  # A relayed line is a sentence, not a payload: the flows themselves stay in the store, and
  # the agent fetches them. What the sentence must carry is everything the row holds that the
  # agent cannot get back once a carrying route retires it — which is why the marked ids and
  # the message id are in it, and the bodies are not.
  module OperatorNote
    # Every message ends with where the answer goes. The handshake instructions say the same
    # thing once; a model answering in its own pane while the operator waits in gori was the
    # first thing the live test showed, and a sentence on the message itself is what the
    # model actually has in front of it when it decides how to answer.
    REPLY_HINT = " — answer with the gori tool reply_to_operator (summary + optional detail); the operator is in gori, not in this terminal."

    # The operator's line, framed. Kept short and honest: who is speaking, and that gori is
    # only the relay.
    #
    # The marked flows and the message id ride along because a route that carries the message
    # RETIRES it: once the socket write or the `codex queue` hand-off lands, `operator_messages`
    # stops answering with that row, and everything the row held that is not in this sentence
    # becomes unreachable. The text alone was enough while the poll layer was still holding the
    # same message for the same session; it is not enough for a session whose only copy is this
    # one. Ids, not a payload — the flows themselves are still fetched with `get_flow` /
    # `list_history{ids}`.
    def self.frame(text : String, from_tab : String?,
                   flow_ids : Array(Int64) = [] of Int64, id : Int64? = nil) : String
      where = from_tab ? " (from the #{from_tab} tab)" : ""
      marked = flow_ids.empty? ? "" : " [flows the operator had marked: #{flow_ids.join(", ")}]"
      "[gori] The operator at the gori TUI says#{where}: #{text}#{marked}#{reply_hint(id)}"
    end

    # `REPLY_HINT`, naming the message to answer when the carrier knows which one it is. The
    # constant stays the id-less form: the channel push carries `message_id` in its own `meta`,
    # so it has no sentence to spend on one.
    def self.reply_hint(id : Int64? = nil) : String
      return REPLY_HINT unless id
      " — answer with the gori tool reply_to_operator (summary + optional detail, " \
      "in_reply_to #{id}); the operator is in gori, not in this terminal."
    end
  end
end
