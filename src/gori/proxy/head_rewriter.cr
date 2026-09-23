module Gori::Proxy
  # The seam where the Match&Replace lens rewrites messages in flight. Kept abstract
  # (like FlowSink) so ClientConn stays decoupled from the rule engine and testable
  # with a stub. HEAD rewrites (`rewrite_request`/`rewrite_response`) run on every
  # message while its body streams untouched (P6). BODY rewrites are opt-in and cost
  # a buffer: ClientConn only calls `rewrite_request_body`/`rewrite_response_body`
  # (and only after the host-scoped directional predicate says a rule can apply), passing
  # the ENTITY body — de-chunked, decompression left to the impl to skip — and re-frames the
  # message (Content-Length synced) itself. Every rewrite MUST return the SAME bytes
  # when it changes nothing, so the caller can tell a rewrite happened and preserve
  # byte-fidelity (P7) for unmodified flows.
  abstract class HeadRewriter
    # A response the rule engine authored for a request that will NOT be sent (#511).
    #
    # `head` is the status line plus header lines, each CRLF-terminated, WITHOUT the
    # terminating blank line and WITHOUT `Content-Length`/`Transfer-Encoding`: framing is
    # ClientConn's job, because only ClientConn knows the request method (a HEAD or a 204
    # takes no body) and it is the one keeping the connection in sync. A rule that names
    # either header has it dropped here rather than trusted — a stub whose declared length
    # disagrees with the bytes gori sends desyncs the next request on a keep-alive
    # connection, which is a far worse failure than a corrected header.
    #
    # `error` is non-nil only when gori generated this response ITSELF because the rule
    # could not be honoured (an unparseable stub, an unreadable `body_file`). The engine
    # answers anyway rather than falling through to the origin: the operator declared this
    # request contained, and dialing out because a stub file went missing would send a
    # payload they believed was never leaving the machine. The message is recorded on the
    # flow so the failure is visible instead of silent.
    # `status` is carried separately so the framing decision does not have to re-parse the
    # head it is about to frame.
    record Stub, head : Bytes, body : Bytes, status : Int32, rule_id : Int64, error : String? = nil

    abstract def rewrite_request(head : Bytes, host : String) : Bytes
    abstract def rewrite_response(head : Bytes, host : String) : Bytes

    # Does a short-circuit rule answer this request? Non-nil means ClientConn must write the
    # stub and NEVER dial. Called once per request head, after the head rewrite (so the
    # match sees the same bytes that would have gone out) and after the sandbox gate (so a
    # rule can never act on a host the operator's sandbox excludes). Default nil (a no-op
    # stub never short-circuits).
    def short_circuit(head : Bytes, host : String) : Stub?
      nil
    end

    # Whether any short-circuit rule is live. Separate from `active?` so a caller can ask
    # about THIS seam alone — the h2 relay cannot reach `short_circuit`, so a host with a
    # live stub rule needs the HTTP/1.1 path the way a body rule does (`tls/tunnel.cr`).
    def short_circuits? : Bool
      false
    end

    # The same questions, narrowed to one host. The h2 downgrade gate asks whether either
    # direction has a body rule for the CONNECT host. HTTP/1's forward-proxy path asks the
    # directional predicates below for each request because one client connection can carry
    # requests for different hosts.
    #
    # An UNSCOPED rule (empty glob) matches every host, so it still answers true everywhere
    # — the pre-#526 behaviour for the rule set most operators have, unchanged.
    #
    # Called at the h2 CONNECT gate, not per frame.
    # Default false, matching the host-blind pair — a no-op stub rewrites nothing anywhere.
    def rewrites_body_for_host?(host : String) : Bool
      false
    end

    def short_circuits_for_host?(host : String) : Bool
      false
    end

    # Whether any rewrite is actually configured. The h2 relay checks this before paying
    # to synthesize a head to run rules against (`H2::HeadRewrite`), and the TUI reads it
    # for the Rewriter tab. It used to also be the TLS MITM's reason to force HTTP/1.1;
    # since #492 step 2 h2 HEADS reach this seam, so that gate narrowed to body rules only
    # (`tls/tunnel.cr`) — head rules no longer cost the connection its protocol.
    # Default false (a no-op stub).
    def active? : Bool
      false
    end

    # Whether a BODY rule is live for the request/response side, regardless of host.
    # Kept for callers that need the overall rule-set state; ClientConn uses the host-scoped
    # directional predicates below before paying to buffer a body (P6). Default false so a
    # stub never buffers.
    def rewrites_request_body? : Bool
      false
    end

    def rewrites_response_body? : Bool
      false
    end

    # Whether a request-body rule can apply to this host. Implementations with no host-scoped
    # rules keep the old direction-only answer; `Rules` narrows it to the rule target and host.
    def rewrites_request_body_for_host?(host : String) : Bool
      rewrites_request_body?
    end

    def rewrites_response_body_for_host?(host : String) : Bool
      rewrites_response_body?
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

    # --- WebSocket messages (#500 step 1) ------------------------------------
    #
    # A WS message is neither a head nor an entity body, so it gets its own pair of
    # seams rather than borrowing the body one — see `Store::RulePart::Ws`.
    #
    # These two predicates are HOST-SCOPED and asked ONCE per socket, right after the
    # 101, because their answer decides whether `WS::Relay` runs its byte-exact pump
    # (today's code, untouched) or the buffering one. A direction with no live rule for
    # this host therefore keeps frame boundaries, mask keys and fragmentation exactly as
    # the peer sent them (P7) and pays nothing per message. An implementation may take a
    # lock here; it must not on `rewrite_ws_*`, which runs per MESSAGE.
    def rewrites_ws_out_for_host?(host : String) : Bool
      false
    end

    def rewrites_ws_in_for_host?(host : String) : Bool
      false
    end

    # Rewrite one reassembled WS message payload. "out" is client→server (a `Request`
    # rule), "in" is server→client (a `Response` rule). MUST return bytes equal to the
    # input when nothing matched, so the relay can forward the peer's original frame
    # verbatim instead of re-framing it.
    def rewrite_ws_out(payload : Bytes, host : String) : Bytes
      payload
    end

    def rewrite_ws_in(payload : Bytes, host : String) : Bytes
      payload
    end
  end
end
