require "../verb"

module Gori
  module Verbs
    # Repeater's/Fuzzer's own "Link to issue/note" (link.repeater.*/link.fuzzer.*) are
    # registered in register_miner (history.cr) instead of here — Round 5 moved them
    # there so their Repeater/Fuzzer COMMON menu position lands AFTER Fuzz/Mine (see
    # the comment at their new registration site for why). History's/HistoryDetail's/
    # Miner's own link verbs are unaffected and stay below.
    def self.register_links(r : Verb::Registry) : Nil
      flow_available = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && !ctx.link_flow_id.nil?
      }
      miner_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :miner && !ctx.link_miner_id.nil?
      }

      r.register Verb::Definition.new(
        "link.history.to-issue", "Link to issue", "Attach this flow to an issue",
        Verb::Scope::Body, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.history.to-note", "Link to note", "Attach this flow to a note",
        Verb::Scope::Body, available: flow_available, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-issue", "Link to issue", "Attach this flow to an issue",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-note", "Link to note", "Attach this flow to a note",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.miner.to-issue", "Link to issue", "Attach this miner session to an issue",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'k') { |ctx| ctx.link_to_issue; nil }

      r.register Verb::Definition.new(
        "link.miner.to-note", "Link to note", "Attach this miner session to a note",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }
    end
  end
end
