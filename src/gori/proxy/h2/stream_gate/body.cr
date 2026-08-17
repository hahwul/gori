# The buffered entity behind a head+body intercept hold, and the DATA re-framing that puts the
# operator's bytes back on the wire (PR #6) — reopens `Gori::Proxy::H2::StreamGate` (see
# `proxy/h2/stream_gate.cr` for the class, its state and the hold this serves).
#
# These are the pure/slot-local half of the hold: deciding whether a body is bufferable at all
# (`holdable_body`, whose "known length only" rule is why a streaming upload keeps the head-only
# hold), reading the parked DATA back out (`body_of`), and turning an edited entity into DATA
# frames again (`write_rebuilt`). None of them takes `@mutex`, touches `@opens`, or goes near
# `@peer`; `write_rebuilt` is called with the lock already held, exactly as `write` is.
class Gori::Proxy::H2::StreamGate
  # The body size this gate will buffer for a hold, or nil to hold the HEAD only.
  #
  # Known length only, and the reason is `MAX_HOLD_BODY`'s: buffering means waiting, and a
  # body whose end gori cannot predict is a wait with no end. Streaming uploads, SSE, gRPC
  # streams and every chunked-equivalent response therefore keep exactly the head-only hold
  # they have today, which is also what the DATA frames keep: untouched (P6).
  private def holdable_body(block : HeadRewrite::Block) : Int32?
    return 0 if block.first.end_stream?
    len = declared_body_length(block.fields)
    return nil unless len && len <= MAX_HOLD_BODY
    len
  end

  # The one `content-length` this head declares, or nil. Two of them is RFC 9113 §8.1.1-
  # malformed and gori does not get to pick which one it believes — that message keeps its
  # head-only hold and its DATA goes out exactly as it arrived (P7).
  private def declared_body_length(fields : Array(HPACK::Field)) : Int32?
    declared = fields.select { |f| f.name == "content-length" }
    return nil unless declared.size == 1
    len = declared.first.value.to_i32?
    len && len >= 0 ? len : nil
  end

  # The buffered entity: every parked DATA payload in arrival order. Unpadded by
  # construction — `note_body_frame` gives the buffer up at the first padded frame.
  private def body_of(slot : Slot) : Bytes
    size = 0
    slot.frames.each { |(f, _)| size += f.payload.size if f.frame_type == Frame::Type::Data }
    buf = Bytes.new(size)
    at = 0
    slot.frames.each do |(f, _)|
      next unless f.frame_type == Frame::Type::Data
      f.payload.copy_to(buf + at)
      at += f.payload.size
    end
    buf
  end

  private def join(head : Bytes, body : Bytes) : Bytes
    return head if body.empty?
    buf = Bytes.new(head.size + body.size)
    head.copy_to(buf)
    body.copy_to(buf + head.size)
    buf
  end

  # Whether the edit's `content-length` was computed FOR the operator rather than declared BY
  # them — the one thing that decides whether `HeadCodec.restore_content_length` runs over
  # their bytes (R3-F2).
  #
  # Derived from the bytes, not asserted by the caller, because the caller does not reliably
  # know: `gori run intercept edit` runs `ContentLength.sync` over `--raw-file` unconditionally,
  # the MCP tool runs it unless `update_content_length:false`, and the TUI editor runs it
  # unless `^L` is off. What every one of those affordances PRODUCES is a `content-length`
  # that agrees with the body the edit carries, and a HEAD-ONLY h2 hold carries no body — so a
  # value that DISAGREES cannot have come from any of them. That is the operator declaring one,
  # which on h2 is the RFC 9113 §8.1.1 probe (does this origin/CDN/WAF/gRPC gateway enforce
  # content-length against DATA?) and on h1 is already forwarded byte-exact.
  #
  # Its stated limit: a deliberate `content-length: 0` on a head-only hold is
  # INDISTINGUISHABLE from a sync of the same empty body, so it still gets the peer's value
  # back. That case is unreachable by construction, not by choice.
  #
  # Asked ONLY of a head-only hold. When the hold covered head+body the question does not
  # arise — see `edited_with_body`.
  private def length_synced?(head : Bytes, body_size : Int32) : Bool
    declared = declared_lengths(head)
    declared.empty? || declared.all? { |v| v == body_size.to_s }
  end

  private def declares_length?(head : Bytes) : Bool
    !declared_lengths(head).empty?
  end

  private def declared_lengths(head : Bytes) : Array(String)
    values = [] of String
    String.new(head).each_line do |line|
      stripped = line.rstrip('\r')
      break if stripped.empty?
      next unless pair = HeadCodec.header_field(stripped)
      values << pair[1] if pair[0].compare("content-length", case_insensitive: true) == 0
    end
    values
  end

  # The operator's body, re-framed, in place of the DATA this gate buffered (PR #6).
  #
  # Everything else that was parked keeps its order around it — trailers stay after the body,
  # WINDOW_UPDATE and PRIORITY stay where the peer put them — and the rebuilt DATA lands at
  # the position of the FIRST buffered DATA frame, or straight after the head when there was
  # none (a bodiless message the operator gave a body to).
  private def write_rebuilt(slot : Slot, body : Bytes) : Nil
    rebuilt = data_frames(slot.stream_id, body, end_stream_on_body?(slot))
    written = slot.frames.none? { |(f, _)| f.frame_type == Frame::Type::Data }
    rebuilt.each { |f| write(f, nil) } if written
    slot.frames.each do |(f, pre)|
      if f.frame_type == Frame::Type::Data
        next if written
        written = true
        rebuilt.each { |d| write(d, nil) }
        next
      end
      write(f, pre)
    end
  end

  # Whether the rebuilt DATA carries END_STREAM: true when the peer ended the message with a
  # DATA frame (or with the head itself), false when TRAILERS end it instead — the flag stays
  # on whatever ended the message, so an edit cannot half-close a stream that still has
  # trailers to send.
  private def end_stream_on_body?(slot : Slot) : Bool
    slot.frames.each do |(f, _)|
      return true if f.frame_type == Frame::Type::Data && f.end_stream?
      return false if f.frame_type == Frame::Type::Headers && f.end_stream?
    end
    (slot.decided || slot.pending).try(&.first.end_stream?) || false
  end

  # Re-frame a body into DATA frames of at most `HeadRewrite::MAX_FRAME_PAYLOAD` — the initial
  # SETTINGS_MAX_FRAME_SIZE, which is also the floor every endpoint must advertise at or above
  # (RFC 9113 §6.5.2). Same ceiling the head re-framer splits at and for the same reason:
  # nothing in this relay reads the peer's SETTINGS, and every conformant peer accepts a frame
  # this size.
  #
  # An empty body still emits one empty DATA frame when END_STREAM has to ride on it (a §6.1
  # zero-length DATA is legal, and the alternative is a stream nobody ever half-closes).
  private def data_frames(stream_id : UInt32, body : Bytes, ends : Bool) : Array(Frame::Header)
    frames = [] of Frame::Header
    return frames if body.empty? && !ends
    at = 0
    loop do
      take = Math.min(HeadRewrite::MAX_FRAME_PAYLOAD, body.size - at)
      last = at + take >= body.size
      frames << Frame::Header.new(Frame::Type::Data.value, last && ends ? Frame::END_STREAM : 0_u8,
        stream_id, body[at, take])
      at += take
      break if last
    end
    frames
  end

  private def without_end_stream(f : Frame::Header) : Frame::Header
    return f unless f.end_stream?
    Frame::Header.new(f.type, f.flags & ~Frame::END_STREAM, f.stream_id, f.payload)
  end
end
