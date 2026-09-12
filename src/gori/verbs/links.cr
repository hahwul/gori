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

      # ONE verb, and it keeps the bytes (#1038). There used to be a "Link & freeze…" sibling
      # on `Z`; it asked the operator to understand that a link is a mutable pointer — that
      # retention and the next send can hollow it out — at the moment of FILING, when the
      # answer was almost always "keep the bytes". So ↵ on an issue links AND freezes the
      # ref's current exchange in one transaction whenever there is one, and says so when
      # there is not. A note still takes the pointer alone: a note owns no evidence.
      r.register Verb::Definition.new(
        "link.history.attach", "Link…",
        "Attach the selected/marked flows to an issue (freezing their exchanges as evidence) or a note — or create one",
        Verb::Scope::Body, available: flow_targets, mnemonic: 'k') { |ctx| ctx.link_attach; nil }

      r.register Verb::Definition.new(
        "link.history-detail.attach", "Link…",
        "Attach this flow to an issue (freezing its exchange as evidence) or a note — or create one",
        Verb::Scope::HistoryDetail, available: flow_available, mnemonic: 'k') { |ctx| ctx.link_attach; nil }

      # No freeze half here, and none possible: a mining session is a template plus a run,
      # not one exchange (`Evidence.freezable?`), so the picker's hint says "link".
      r.register Verb::Definition.new(
        "link.miner.attach", "Link…", "Attach this miner session to an issue or note — or create one",
        Verb::Scope::Miner, available: miner_linkable, mnemonic: 'k') { |ctx| ctx.link_attach; nil }
    end
  end
end
