require "../rules"
require "./plan"
require "./flow_request"

module Gori
  module Repeater
    # OPT-IN Match&Replace parity for a direct send. Direct sends are byte-exact (P7) by default
    # — a repeater/fuzz caller wants exactly what it typed — and `apply_rules` asks for
    # live-proxy parity instead: the project's enabled REQUEST-side rules run over the built
    # bytes and Content-Length is re-synced. Response-side rules are intentionally NOT applied.
    #
    # MCP `send_request{apply_rules}` had this alone until `gori run send`/`repeater` grew
    # `--apply-rules` (#1384); one implementation, so the two surfaces rewrite the same request
    # the same way.
    module RequestRules
      # The (possibly rewritten) plan, and whether a rule actually changed the bytes. `rules`
      # must come from a store that is still OPEN: a rule that fails (a hook, a refused binding)
      # writes an event row through it.
      def self.apply(plan : Plan, rules : Rules) : {Plan, Bool}
        # Match&Replace parity operates on h1 head TEXT; a field-native plan has none (its
        # `bytes` is only the synthetic scope line), so applying rules would rewrite that line
        # and never the fields on the wire. A field list is byte-exact by construction — the
        # reason apply_rules is opt-in at all — so it is simply not offered here.
        return {plan, false} if plan.h2_fields
        return {plan, false} unless rules.active?
        # `add_if_missing: false` — this runs AFTER `Plan.build`, so it is past the point where
        # `auto_content_length` was honoured, and the plan shapes that reach here with that flag
        # deliberately OFF (a captured flow and a raw/verbatim request) are the ones this must
        # not re-frame. A capture that carried no Content-Length is evidence — an h2/gRPC
        # streamed POST is stored exactly that way — and inventing framing for it here would
        # undo the very thing those call sites turned the flag off for. Rules may still CHANGE
        # the body, so an EXISTING Content-Length is still re-synced; only the ADD is withheld.
        rewritten = FlowRequest.resync_content_length(
          rules.transform_message(String.new(plan.bytes), Store::RuleTarget::Request, plan.host).to_slice,
          add_if_missing: false)
        return {plan, false} if rewritten == plan.bytes
        {plan.with_requests([rewritten]), true}
      end
    end
  end
end
