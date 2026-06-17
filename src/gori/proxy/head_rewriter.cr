module Gori::Proxy
  # The seam where the Match&Replace lens rewrites message HEAD bytes in flight.
  # Kept abstract (like FlowSink) so ClientConn stays decoupled from the rule
  # engine and testable with a stub. Bodies are never passed here — they stream
  # untouched (P6). An impl MUST return the SAME bytes when it changes nothing,
  # so the caller can tell a rewrite happened and preserve byte-fidelity (P7)
  # for unmodified flows.
  abstract class HeadRewriter
    abstract def rewrite_request(head : Bytes) : Bytes
    abstract def rewrite_response(head : Bytes) : Bytes
  end
end
