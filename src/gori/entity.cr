require "./proxy/codec/content_decode"

module Gori
  # The ENTITY behind a stored message body — the bytes the peer actually meant — as opposed
  # to the MESSAGE body, which is what went on the wire: chunk framing intact, still
  # gzip/br/deflate/zstd compressed. gori stores the wire form and nothing else (P7), so every
  # DISPLAY-time decoder that reads a body has to ask for the entity first.
  #
  # The decode panes did not, and each failed in its own way on the same flow:
  #
  #   * a gzip'd GraphQL POST — what any client sending a large query does — produced no
  #     GraphQL pane at all, byte-identical to "this is not GraphQL", while the `p` toggle
  #     two keystrokes away pretty-printed it (`Pretty` is handed an already-decoded body);
  #   * a chunked form POST did not merely vanish from the PARAMS pane, it produced GARBAGE:
  #     the chunk-size line fused onto the first key, so `a=1&b=22` was listed as a field
  #     literally named `9\r\na`;
  #   * and the JWT pane scans the RESPONSE body, which in real traffic is compressed almost
  #     always — so token discovery, the reason that pane exists, was off for the majority of
  #     responses.
  #
  # `ContentDecode` has always been able to do this and has a zero-allocation gate (the head
  # must contain the ASCII `-encoding`), so the overwhelmingly common uncompressed, unchunked
  # body costs one byte scan and is returned unchanged.
  module Entity
    extend self

    # {entity bytes, whether anything was decoded}. The bool is not a diagnostic: a decoder
    # whose output can be RE-ENCODED into the request (GraphQL's editable pane, SAML's param
    # splice) must know that what it is showing is a PROJECTION of bytes the envelope still
    # holds in wire form — writing a plain-JSON edit back under a head that still declares
    # `Content-Encoding: gzip` produces a request the origin cannot read and the operator
    # never wrote.
    #
    # The bool is decided by comparing the BYTES, not by "did the decoder run". A declared
    # coding that will not inflate (a truncated capture, an unsupported one) makes
    # `ContentDecode` hand back the still-encoded entity, and calling that a projection would
    # take the editable pane away from a request whose body was never transformed at all.
    # Failure is therefore indistinguishable from "nothing to do", which is exactly right:
    # the pane reads the same bytes it always did, and nothing claims a faithful round-trip
    # over bytes gori could not decode.
    def of(head : Bytes?, body : Bytes?, max_out : Int32 = Proxy::Codec::ContentDecode::MAX_OUT) : {Bytes?, Bool}
      return {body, false} if body.nil? || body.empty?
      decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, max_out)
      return {body, false} if decoded.nil? || decoded == body
      {decoded, true}
    end

    # `of`, keeping only the bytes — for the panes that are pure display and re-encode nothing.
    def bytes(head : Bytes?, body : Bytes?, max_out : Int32 = Proxy::Codec::ContentDecode::MAX_OUT) : Bytes?
      of(head, body, max_out)[0]
    end
  end
end
