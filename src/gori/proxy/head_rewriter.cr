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

    # Whether any rewrite is actually configured. The TLS MITM uses this to decide
    # NOT to advertise h2 (forcing the client to HTTP/1.1) when rules are live — h2's
    # HPACK-encoded heads never reach this seam, so without the downgrade a Match&
    # Replace rule would silently no-op on every h2 flow. Default false (a no-op stub).
    def active? : Bool
      false
    end
  end
end
