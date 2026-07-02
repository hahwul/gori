require "../verb"

module Gori
  module Verbs
    def self.register_links(r : Verb::Registry) : Nil
      flow_available = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && !ctx.link_flow_id.nil?
      }
      replay_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :replay && !ctx.link_replay_id.nil?
      }
      fuzz_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :fuzzer && !ctx.link_fuzz_id.nil?
      }
      miner_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :miner && !ctx.link_miner_id.nil?
      }

      r.register Verb::Definition.new(
        "link.history.to-finding", "Link to finding", "Attach this flow to a finding",
        Verb::Scope::Body, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }

      r.register Verb::Definition.new(
        "link.history.to-note", "Link to note", "Attach this flow to a note",
        Verb::Scope::Body, available: flow_available, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-finding", "Link to finding", "Attach this flow to a finding",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }

      r.register Verb::Definition.new(
        "link.history-detail.to-note", "Link to note", "Attach this flow to a note",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.replay.to-finding", "Link to finding", "Attach this replay session to a finding",
        Verb::Scope::Replay, available: replay_linkable, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }

      r.register Verb::Definition.new(
        "link.replay.to-note", "Link to note", "Attach this replay session to a note",
        Verb::Scope::Replay, available: replay_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.fuzzer.to-finding", "Link to finding", "Attach this fuzz session to a finding",
        Verb::Scope::Fuzzer, available: fuzz_linkable, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }

      r.register Verb::Definition.new(
        "link.fuzzer.to-note", "Link to note", "Attach this fuzz session to a note",
        Verb::Scope::Fuzzer, available: fuzz_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }

      r.register Verb::Definition.new(
        "link.miner.to-finding", "Link to finding", "Attach this miner session to a finding",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'k') { |ctx| ctx.link_to_finding; nil }

      r.register Verb::Definition.new(
        "link.miner.to-note", "Link to note", "Attach this miner session to a note",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'u') { |ctx| ctx.link_to_note; nil }
    end
  end
end