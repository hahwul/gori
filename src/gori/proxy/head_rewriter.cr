module Gori::Proxy
  # The seam where the Match&Replace lens rewrites messages in flight. Kept abstract
  # (like FlowSink) so ClientConn stays decoupled from the rule engine and testable
  # with a stub. HEAD rewrites (`rewrite_request`/`rewrite_response`) run on every
  # message while its body streams untouched (P6). BODY rewrites are opt-in and cost
  # a buffer: ClientConn only calls `rewrite_request_body`/`rewrite_response_body`
  # (and only after `rewrites_*_body?` says a body rule is live), passing the ENTITY
  # body — de-chunked, decompression left to the impl to skip — and re-frames the
  # message (Content-Length synced) itself. Every rewrite MUST return the SAME bytes
  # when it changes nothing, so the caller can tell a rewrite happened and preserve
  # byte-fidelity (P7) for unmodified flows.
  abstract class HeadRewriter
    abstract def rewrite_request(head : Bytes, host : String) : Bytes
    abstract def rewrite_response(head : Bytes, host : String) : Bytes

    # Whether any rewrite is actually configured. The TLS MITM uses this to decide
    # NOT to advertise h2 (forcing the client to HTTP/1.1) when rules are live — h2's
    # HPACK-encoded heads never reach this seam, so without the downgrade a Match&
    # Replace rule would silently no-op on every h2 flow. Default false (a no-op stub).
    def active? : Bool
      false
    end

    # Whether a BODY rule is live for the request/response side. ClientConn checks
    # this before paying to buffer a body — the common (head-only / no-rule) case
    # keeps zero-buffer streaming (P6). Default false so a stub never buffers.
    def rewrites_request_body? : Bool
      false
    end

    def rewrites_response_body? : Bool
      false
    end

    # Rewrite the ENTITY body (de-chunked, not decompressed). MUST return the SAME
    # bytes when nothing matched so ClientConn can passthrough byte-exact (P7); a
    # compressed body simply won't match a literal pattern and returns unchanged.
    # `host` lets a rule scope itself to matching hosts (empty glob = all).
    def rewrite_request_body(entity : Bytes, host : String) : Bytes
      entity
    end

    def rewrite_response_body(entity : Bytes, host : String) : Bytes
      entity
    end
  end
end
