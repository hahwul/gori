require "./frame"

module Gori::Proxy::H2
  # The origin's offer of RFC 8441 extended CONNECT, which is how a browser opens a WebSocket
  # over HTTP/2 (#1896). Withholding it keeps a client's sockets on the HTTP/1.1 Upgrade path,
  # where per-message intercept and Match&Replace run (settings `network.strip_extended_connect`).
  #
  # A SETTINGS frame is not flow-controlled, so removing a parameter changes only this frame's
  # length: the objection that keeps gori from re-framing DATA (#492 step 5) does not reach it.
  module ConnectOffer
    PARAMETER = 0x8_u16 # SETTINGS_ENABLE_CONNECT_PROTOCOL, RFC 8441 §3

    ENTRY_SIZE = 6 # a 16-bit identifier and a 32-bit value (RFC 9113 §6.5.1)

    # The SETTINGS frame without its extended CONNECT offer, or nil when it makes none
    # (the caller then forwards the frame exactly as read).
    #
    # A malformed SETTINGS frame is not this module's to repair: the client's own error handling
    # sees exactly what the origin sent. An entry carrying 0 is the parameter's initial value and
    # changes nothing, so a frame whose only id-0x8 entries are 0 stays byte-identical. Every
    # other value is one a client may read as the offer. A frame left with no entries is still
    # returned, never dropped: the origin counts the client's SETTINGS ACKs one for one.
    def self.withhold(frame : Frame::Header) : Frame::Header?
      return nil unless frame.type == Frame::Type::Settings.value && frame.stream_id == 0 && !frame.ack?
      payload = frame.payload
      return nil unless payload.size % ENTRY_SIZE == 0
      offers = 0
      0.step(to: payload.size - 1, by: ENTRY_SIZE) { |at| offers += 1 if offer?(payload, at) }
      return nil if offers == 0
      kept = Bytes.new(payload.size - offers * ENTRY_SIZE)
      to = 0
      0.step(to: payload.size - 1, by: ENTRY_SIZE) do |at|
        next if offer?(payload, at)
        payload[at, ENTRY_SIZE].copy_to(kept + to)
        to += ENTRY_SIZE
      end
      Frame::Header.new(frame.type, frame.flags, 0_u32, kept)
    end

    private def self.offer?(payload : Bytes, at : Int32) : Bool
      IO::ByteFormat::BigEndian.decode(UInt16, payload[at, 2]) == PARAMETER &&
        IO::ByteFormat::BigEndian.decode(UInt32, payload[at + 2, 4]) != 0
    end
  end
end
