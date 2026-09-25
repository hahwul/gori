require "../verb"

module Gori
  module Verbs
    # The space menu's verb families (#1274 WP9, `Verb::Family`). A verb joins one by naming a
    # member intent; the letter table here is the only place its level-2 letter is spelled.
    #
    # "Send flow to…" (`>`) holds the cross-tool sends of the selected flow(s). Send to
    # Repeater is `pinned:` on every tab that has it, so it keeps its level-1 letter (`r`, or
    # `R` where `r` runs the tab) and `space > r` also reaches it everywhere. Active scan and
    # Mock stay direct rows: one scans and one creates a rule, neither hands the flow on.
    SEND_FLOW = Verb::Family.new(:send_flow, "Send flow to…", '>', :send, [
      {:to_repeater, Verb::TOOL_LETTERS[:repeater]},
      {:to_fuzzer, Verb::TOOL_LETTERS[:fuzzer]},
      {:to_comparer, Verb::TOOL_LETTERS[:comparer]},
      {:to_miner, Verb::TOOL_LETTERS[:miner]},
      {:to_sequencer, Verb::TOOL_LETTERS[:sequencer]},
      {:to_authorize, Verb::TOOL_LETTERS[:authorize]},
      {:to_discover, Verb::TOOL_LETTERS[:discover]},
      {:to_browser, Verb::TOOL_LETTERS[:browser]},
    ])

    def self.register_families(r : Verb::Registry) : Nil
      r.register_family(SEND_FLOW)
    end
  end
end
