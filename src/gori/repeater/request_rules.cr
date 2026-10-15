require "../rules"
require "../import/curl"
require "../proxy/codec/body"
require "../proxy/codec/content_decode"
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
      # The (possibly rewritten) plan, and whether a rule actually changed the bytes. A changed
      # plan carries the rules that changed it and the bytes they replaced (`Plan#rewrite`), for
      # the History row. `rules` must come from a store that is still OPEN: a rule that fails (a
      # hook, a refused binding) writes an event row through it.
      def self.apply(plan : Plan, rules : Rules) : {Plan, Bool}
        # Match&Replace parity operates on h1 head TEXT; a field-native plan has none (its
        # `bytes` is only the synthetic scope line), so applying rules would rewrite that line
        # and never the fields on the wire. A field list is byte-exact by construction — the
        # reason apply_rules is opt-in at all — so it is simply not offered here.
        return {plan, false} if plan.h2_fields
        return {plan, false} unless rules.active?
        head, body = Env.split_head_body(plan.bytes)
        hits = [] of Store::RuleRef
        new_head = rules.rewrite_request(head, plan.host, hits)
        rules.settle_hits(hits, 0, head, new_head) { |h| h } # as the proxy names them
        new_body = body.try { |b| rewrite_body(rules, head, new_head, b, plan.host, hits) }
        # Re-frame ONLY when a rule changed the body's length, never as a blanket resync: the
        # plan shapes that reach here were built with `auto_content_length` deliberately OFF (a
        # captured flow, a raw/verbatim request), so a `Content-Length: 99` over a 2-byte body
        # is the operator's desync probe, and a rule that matched nothing must not "fix" it and
        # report a change. Nor is a missing length ADDED (`_if_body_changed` passes
        # `add_if_missing: false`): a capture without one — an h2/gRPC streamed POST — is evidence.
        rewritten = FlowRequest.resync_content_length_if_body_changed(plan.bytes,
          new_body ? new_head + new_body : new_head)
        return {plan, false} if rewritten == plan.bytes
        sent = plan.with_requests([rewritten])
        sent.rewrite = Store::Rewrite.new(hits, head, new_body == body ? nil : body)
        {sent, true}
      end

      # The body as the proxy's body rule sees it (`ClientConn#apply_body_rewrite`): a
      # compressed one is not rewritten, a chunked one is rewritten as its entity. The rewritten
      # entity goes back out chunked, so the operator's own framing header stays true. A head the
      # proxy could not frame (an obfuscated or CL+TE request) would never have reached a rule
      # there, and its body is left as written; so is a chunked body a re-chunk would not
      # reproduce byte for byte (extensions, trailers, bytes past the 0-chunk) (P7).
      private def self.rewrite_body(rules : Rules, head : Bytes, new_head : Bytes, body : Bytes,
                                    host : String, hits : Array(Store::RuleRef)) : Bytes
        return body if Proxy::Codec::ContentDecode.content_encoded?(new_head)
        chunked = Proxy::Codec::Body.request_framing(Proxy::Codec::Http1.parse_request_head(head))[0].chunked?
        return body if chunked && !Proxy::Codec::ContentDecode.plain_chunked?(body)
        entity = chunked ? Proxy::Codec::ContentDecode.dechunk(body) : body
        mark = hits.size
        edited = rules.rewrite_request_body(entity, host, hits)
        rules.settle_hits(hits, mark, entity, edited) { |b| b }
        return body if edited == entity
        chunked ? Import::Curl.chunk(edited) : edited
      rescue Gori::Error
        body
      end
    end
  end
end
