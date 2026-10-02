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
  end
end
