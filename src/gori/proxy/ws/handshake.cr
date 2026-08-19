require "../codec/message"

module Gori::Proxy::WS
  # The one header gori removes from a WebSocket handshake it relays (#518).
  #
  # `WS::Relay` stores frame payloads verbatim and never decodes an extension, so a
  # socket that negotiated `permessage-deflate` was captured as a deflate stream
  # presented as the message: History, the detail view, `gori run history show`,
  # MCP `get_flow`, the decoder and export all read those bytes as the payload.
  # Removing the client's OFFER is what stops the negotiation, because extension
  # negotiation is offer-driven (RFC 6455 §9.1): a conformant origin can only accept
  # from what it was offered, so with nothing offered neither peer compresses and the
  # captured frames are the messages.
  #
  # This is gori's first hop-by-hop removal on the WS path and it is DELIBERATE. It
  # cannot be made lazy the way #512's h2 re-encode was: extension negotiation happens
  # once, in the 101 handshake, with no renegotiation, so by the time a capture
  # consumer exists the window has closed. The cost is stated plainly: a
  # deflate-capable app loses compression through gori, and gori changes bytes on the
  # wire while merely observing. The trade is that the status quo was not "byte-exact
  # and correct", it was byte-exact on the wire and WRONG in the store; an operator who
  # needs a compressed socket untouched has TLS passthrough, which leaves the host
  # alone entirely.
  #
  # The WHOLE field goes, not just the `permessage-deflate` parameter. `Relay` is
  # extension-blind by construction (it reads the RFC 6455 frame header and stores the
  # payload), and ANY negotiated extension may transform that payload or give the RSV
  # bits a meaning, so every one of them breaks capture the same way. Removing the field
  # entire is also what `Repeater::WsEngine.build_handshake` already does.
  #
  # BOTH halves of the negotiation go, and they go together. Removing only the client's
  # offer used to be the policy, on the argument that stripping an accept the origin
  # believes in would leave it compressing into a client that saw no acceptance and must
  # then fail the connection on the first RSV1 frame (RFC 6455 §5.2). That argument is
  # sound — for a handshake gori did NOT strip. It is exactly backwards for one gori did:
  # an origin cannot "believe in" an acceptance of something it was never offered, so the
  # accept is answering a header that no longer exists, and relaying it is what manufactures
  # a desync rather than what avoids one. The client took the 101 at its word, turned
  # permessage-deflate on and sent RSV1 frames into an origin that had negotiated nothing —
  # the §5.2 connection failure the old comment was trying to prevent, aimed at the other
  # peer. History read the same way round: an origin sending an unsolicited accept.
  #
  # `carries_extensions?` on the head gori ACTUALLY SENT is the condition that tells the two
  # cases apart, and `ClientConn#settle_ws_extensions` is where it is asked. An acceptance on
  # a handshake gori left alone (an operator who put
  # the offer back with a Match&Replace rule, or an origin violating §4.1) is still relayed
  # untouched: there the two peers do agree, and gori's store is the only thing that suffers.
  module Handshake
    # The field-name gori removes, lower-cased for the byte compare.
    EXTENSIONS_NAME = "sec-websocket-extensions"

    # True when this head is a WebSocket upgrade that offers an extension: the only
    # shape `strip_extensions` should touch. A `Sec-WebSocket-Extensions` on a request
    # that is NOT upgrading is inert (the field is defined only for the handshake, RFC
    # 6455 §11.3.2), so it is left byte-exact (P7) rather than rewritten for nothing.
    #
    # `Upgrade` is a comma-separated protocol list (RFC 7230 §6.7), so match the TOKEN
    # rather than the whole field-value: `Upgrade: websocket, h2c` is still a WebSocket
    # handshake. Both lookups are allocation-free on the miss, which is every non-WS
    # request on the hot path (the `EXTENSIONS_NAME` test stays first for that reason).
    def self.offers_extensions?(headers : Codec::HeaderList) : Bool
      return false unless headers.has?(EXTENSIONS_NAME)
      upgrades_to_websocket?(headers)
    end

    # Does this head's `Upgrade` field name WebSocket? The one home for that question.
    #
    # `ClientConn` used to compare the whole field-value to `"websocket"`, so an origin
    # answering the RFC 7230 §6.7 list form (`Upgrade: websocket, h2c`) fell out of the
    # WebSocket branch entirely and was relayed as an opaque byte tunnel — no frames
    # captured, no `part: ws` rule, no `proto:ws` hold — on a socket gori can decode.
    # Two predicates for one field-value is what let that disagreement exist.
    def self.upgrades_to_websocket?(headers : Codec::HeaderList) : Bool
      upgrade = headers.get?("Upgrade")
      return false unless upgrade
      upgrade.split(',').any? { |token| token.strip.compare("websocket", case_insensitive: true) == 0 }
    end

    # True when this raw head still carries a `Sec-WebSocket-Extensions` line.
    #
    # Asked of the head gori ACTUALLY SENT, because that is the only thing that answers "did
    # the origin receive an offer?". The parsed client request cannot: `strip_ws_extension_offer`
    # runs BEFORE Match&Replace precisely so a rule can put the header back, and the request
    # projection the response path carries is still the client's own.
    def self.carries_extensions?(head : Bytes) : Bool
      pos = 0
      start_line = true
      while pos < head.size
        lf = head.index(0x0a_u8, pos)
        stop = lf ? lf + 1 : head.size
        return true if !start_line && extensions_line?(head[pos, stop - pos])
        start_line = false
        pos = stop
      end
      false
    end

    # `head` with every `Sec-WebSocket-Extensions` line removed and every other byte
    # copied verbatim (P7), including the start-line and the terminating CRLFCRLF.
    # Header VALUE bytes are never round-tripped through String, so a non-UTF-8
    # cookie/auth token on the handshake survives byte-exact (mirroring
    # `Repeater::WsEngine.build_handshake`, which strips the same header from its own
    # handshake and is the precedent this follows).
    #
    # Direction-agnostic: it copies the start-line through untouched and only ever drops a
    # header line, so the same method removes the client's OFFER from a request head and the
    # origin's ACCEPT from the 101 that answers it.
    #
    # Lines are split on the terminator only and the field-name is matched EXACTLY,
    # the same view `Codec::Http1.parse_headers` takes. An obs-folded or
    # `name<SP>:`-obfuscated variant that this scan would miss cannot reach an origin
    # regardless: `Codec::Body.request_framing` rejects the whole request
    # (`Http1.obfuscated_header?`) before it is forwarded.
    def self.strip_extensions(head : Bytes) : Bytes
      io = IO::Memory.new(head.size)
      pos = 0
      start_line = true
      while pos < head.size
        lf = head.index(0x0a_u8, pos)
        stop = lf ? lf + 1 : head.size # the line INCLUDING its terminator
        line = head[pos, stop - pos]
        io.write(line) if start_line || !extensions_line?(line)
        start_line = false
        pos = stop
      end
      io.to_slice
    end

    # True when the header line's field-name is exactly `Sec-WebSocket-Extensions`
    # (ASCII case-insensitive). A colon-less line (the blank line that ends the head,
    # or a garbage line) never matches.
    private def self.extensions_line?(line : Bytes) : Bool
      colon = line.index(0x3a_u8) # ':'
      return false unless colon
      return false unless colon == EXTENSIONS_NAME.bytesize
      name = EXTENSIONS_NAME.to_slice
      colon.times do |i|
        b = line.unsafe_fetch(i)
        b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8 # ASCII 'A'..'Z' → lower
        return false unless b == name.unsafe_fetch(i)
      end
      true
    end
  end
end
