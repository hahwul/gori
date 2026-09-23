module Gori::Proxy
  # The seam where session-binding extract rules OBSERVE a proxied response (#501 slice 2).
  #
  # Kept abstract (like `FlowRewriter`'s `HeadRewriter` and `FlowSink`) so the proxy stays
  # decoupled from `Gori::Bindings` and testable with a stub. It is deliberately NOT part of
  # `HeadRewriter`: a rewrite produces bytes and an extraction produces none, and folding the
  # two together would put a read-only observer behind the gates that exist to protect the
  # write path.
  #
  # ## Where it is called, and why there
  #
  # **On the bytes that were DELIVERED to the client** — after the response-head rewrite, after
  # the response-body rewrite, and after any intercept decision. The justification is P4: if the
  # operator edited that response, the edit is the truth, and if they dropped it, the client
  # never had it. Binding off bytes the browser never received would make `$SESSION` disagree
  # with the browser's actual session, which is the one disagreement this feature exists to
  # remove. Reversal cost is low (a call-site move inside one function), so it is recorded here
  # rather than made configurable.
  #
  # ## The gates, and what each one is for
  #
  # `extracts?` is a LOCK-FREE atomic read, checked before anything is allocated: a proxy with
  # no extract rule pays one integer compare per response and nothing else (P6).
  #
  # `extracts_body?` is the host-blind summary. A head-scoped descriptor (cookie / header) reads
  # the parsed head, which every response already has; a body-scoped one (regex / position /
  # jsonpath) needs the entity, which means buffering a response that would otherwise stream.
  #
  # `extracts_body_for_host?` is the same question asked ABOUT ONE HOST. ClientConn uses it for
  # each response on a multi-host HTTP/1 connection; the h2 downgrade gate uses it for the
  # CONNECT host. A body-scoped extraction needs the entity in hand, so it earns the same
  # downgrade to HTTP/1.1 only for hosts its glob can actually match. Downgrading a host no rule
  # matches is the regression #531 fixed.
  module ResponseExtract
    # Is ANY enabled extract rule live? Read per response, so it must not lock.
    def extracts? : Bool
      false
    end

    # Is any enabled extract rule live whose descriptor needs the response ENTITY?
    # Read per response (`ClientConn` deciding whether to buffer), so it must not lock.
    def extracts_body? : Bool
      false
    end

    # `extracts_body?` narrowed to one host. HTTP/1 forward-proxy connections can carry multiple
    # hosts, so ClientConn asks this before buffering each response. The h2 downgrade gate asks
    # it once for its CONNECT host.
    def extracts_body_for_host?(host : String) : Bool
      extracts_body?
    end

    # Offer one DELIVERED response to the extract rules.
    #
    # `head` and `body` are the bytes as FORWARDED, and they must be framed consistently with
    # each other — the implementation runs them through `Codec::ContentDecode`, so a body
    # already de-chunked alongside a head still declaring `Transfer-Encoding: chunked` would
    # be de-chunked a second time into garbage. Handing over the pair the client received is
    # what makes that automatic rather than a rule to remember.
    #
    # `body` is nil when this response was not buffered — a streaming (SSE / close-delimited /
    # 101) or oversized body, or the h2 relay, where DATA is never held. A body-scoped rule
    # that matches such a response records a miss naming THAT reason, rather than reporting
    # that its selector found nothing.
    #
    # `method` / `target` come from the REQUEST that was actually sent, because that is what the
    # rule's condition (`InterceptFilter`) scopes on — a response carries neither.
    #
    # Must never raise into the proxy path and must never block: an extract rule cannot be
    # allowed to fail a response the client is waiting on.
    def observe_response(head : Bytes, body : Bytes?, *,
                         method : String, host : String, target : String,
                         scheme : String, status : Int32, flow_id : Int64? = nil) : Nil
    end
  end
end
