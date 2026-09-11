require "../verb"

module Gori
  module Verbs
    # ONE "Link…" verb per scope, not the `to-issue` / `to-note` pair it replaces: the
    # owner kind is now a row in the picker (LinkPicker), so choosing it is no longer a
    # choice of VERB made before you can see what exists — and each list's "+ New …" row
    # stopped being hidden behind that guess. `k` carries over from the old to-issue half
    # (the more-used of the two); `u` is freed.
    #
    # Repeater's/Fuzzer's own link verb (link.repeater.*/link.fuzzer.*) is registered in
    # register_miner (history.cr) instead of here — Round 5 moved the pair there so its
    # Repeater/Fuzzer COMMON menu position lands AFTER Fuzz/Mine (see the comment at that
    # registration site for why). History's/HistoryDetail's/Miner's own link verbs are
    # unaffected and stay below.
    def self.register_links(r : Verb::Registry) : Nil
      flow_available = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && !ctx.link_flow_id.nil?
      }
      # The History LIST pair is batch-capable (#442): pick the issue/note once, attach every
      # marked flow. The HistoryDetail pair keeps flow_available — the detail is pinned to a
      # single flow, so marks deliberately don't apply there.
      #
      # Still gates on link_flow_id (an id that resolves), so the invariant flow_available
      # protects — never offer to attach evidence that doesn't exist — survives; marks are an
      # ALTERNATIVE way to satisfy it, for the case where every mark has scrolled out from
      # under the cursor. The handler additionally skips ids the store can't resolve, so a
      # stale mark can't file an orphan link row either way.
      flow_targets = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :history && (!ctx.link_flow_id.nil? || ctx.marked_flow_count > 0)
      }
      miner_linkable = ->(ctx : Verb::ExecContext) {
        ctx.current_tab == :miner && !ctx.link_miner_id.nil?
      }

      r.register Verb::Definition.new(
        "link.history.attach", "Link…", "Attach the selected/marked flows to an issue or note — or create one",
        Verb::Scope::Body, available: flow_targets, mnemonic: 'k') { |ctx| ctx.link_attach; nil }

      r.register Verb::Definition.new(
        "link.history-detail.attach", "Link…", "Attach this flow to an issue or note — or create one",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_attach; nil }

      r.register Verb::Definition.new(
        "link.miner.attach", "Link…", "Attach this miner session to an issue or note — or create one",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'k') { |ctx| ctx.link_attach; nil }

      # "Link & freeze…" (#1038) — the same picker in its freeze mode: the pick links the
      # flow to an issue AND copies its current request/response into immutable evidence,
      # in one transaction. A SIBLING verb rather than a key inside the picker, so the menu
      # says what ↵ will do before the card opens. `Z` — freeZe — is free in all three
      # scopes that offer it; `F` is not (HistoryDetail's copy, Repeater's gRPC reframe).
      # Not offered from the Miner: a mining session has no single exchange to freeze.
      r.register Verb::Definition.new(
        "link.history.freeze", "Link & freeze…", "Attach the selected/marked flows to an issue and freeze their exchanges as evidence",
        Verb::Scope::Body, available: flow_targets, mnemonic: 'Z') { |ctx| ctx.link_attach_freeze; nil }

      r.register Verb::Definition.new(
        "link.history-detail.freeze", "Link & freeze…", "Attach this flow to an issue and freeze its exchange as evidence",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'Z') { |ctx| ctx.link_attach_freeze; nil }
    end
  end
end
