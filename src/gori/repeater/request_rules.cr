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
        # Re-frame ONLY when a rule changed the body's length, never as a blanket resync: the
        # plan shapes that reach here were built with `auto_content_length` deliberately OFF (a
        # captured flow, a raw/verbatim request), so a `Content-Length: 99` over a 2-byte body
        # is the operator's desync probe, and a rule that matched nothing must not "fix" it and
        # report a change. Nor is a missing length ADDED (`_if_body_changed` passes
        # `add_if_missing: false`): a capture without one — an h2/gRPC streamed POST — is evidence.
        rewritten = FlowRequest.resync_content_length_if_body_changed(plan.bytes,
          rules.transform_message(String.new(plan.bytes), Store::RuleTarget::Request, plan.host).to_slice)
        return {plan, false} if rewritten == plan.bytes
        {plan.with_requests([rewritten]), true}
      end
    end
  end
end
