module Gori
  module Verb
    abstract class ExecContext
      # "Tell the agent…" (#1090) — hand one line of instruction to an MCP client attached to
      # this project. Global, like `open_agents` beside it, because the thing being addressed
      # is a session-wide attachment rather than anything the focused tab owns: the operator
      # is as likely to say it while reading a Repeater response as while standing in History.
      #
      # ONE intent covers the whole gesture (pick a target, type the line, post the row). The
      # pick and the prompt are two overlays, but the operator performs a single action and a
      # verb that stopped after the picker would be an intent nobody means on its own — the
      # same reason `link_attach` is one intent over a picker that can also create.
      abstract def tell_agent : Nil

      # "Answer the agent…" (#1324) — the oldest `ask_operator` question an attached agent is
      # waiting on, on its answer card. Global for tell_agent's reason: the question belongs
      # to the session, not to whichever tab the operator happens to be on.
      abstract def answer_agent_question : Nil
    end
  end
end
