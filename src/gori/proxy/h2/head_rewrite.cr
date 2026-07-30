require "./frame"
require "./hpack"
require "./head_codec"
require "./assembler"
require "../head_rewriter"

module Gori::Proxy::H2
  # One direction's head-rewrite pipeline: buffer a header block, decode it, run the
  # Match&Replace rules over its h1-equivalent text, re-encode, re-frame (#492 step 2).
  #
  # ## Why the forward happens after the rewrite here, and only here
  #
  # `Relay#pump` forwards every frame BEFORE capturing it so a slow writer never delays the
  # peer (P6). Rewriting inverts that for header blocks: nothing can be written until
  # END_HEADERS, the decode, the rules and the re-encode have all happened. That inversion
  # costs nothing, for two reasons that hold only for header blocks:
  #
  #   1. RFC 9113 §6.2/§6.10 — a HEADERS without END_HEADERS may be followed ONLY by
  #      CONTINUATION frames for the same stream. Nothing else is queued behind the buffer,
  #      so there is no head-of-line blocking to create.
  #   2. An h2 receiver cannot act on a partial header block; END_HEADERS is when it could
  #      have started anyway. Holding fragments until then delays the peer by zero.
  #
  # DATA keeps the forward-first path untouched — the body rewrite (#492 step 5) is where
  # that trade actually gets made.
  #
  # ## The one-way latch, and why "re-encode only the heads a rule changed" is unsound
  #
  # HPACK is stateful and per-direction (RFC 7541 §2.2). When the original encoder emits a
  # literal WITH incremental indexing (§6.2.1) it inserts that entry into its own table and
  # the peer's decoder inserts it too — the two stay equal because both act on the same
  # representation. `HPACK::Encoder` with `indexing: false` emits literals WITHOUT indexing,
  # so re-encoding a block drops those inserts on the peer's side while the original
  # encoder's table has already grown. Its next block indexes entry 62 and the peer resolves
  # a different header, silently, or one out of range and the connection dies.
  #
  # That breaks on the FIRST re-encoded head, with indexing off, without this encoder ever
  # emitting a dynamic index. So mixing is not a compression trade, it is a correctness bug,
  # and the invariant is:
  #
  #   once a direction re-encodes one header block, it re-encodes EVERY subsequent header
  #   block in that direction for the rest of the connection — trailers and PUSH_PROMISE
  #   included — and never goes back.
  #
  # The latch engages lazily, on the first head a rule actually changes, so a connection no
  # rule touches stays byte-exact and pays no compression loss. It is one-way for the mirror
  # of the reason above: while we re-encode, the original encoder keeps inserting on its own
  # table and we keep dropping those inserts, so returning to passthrough would forward
  # indices the peer never received.
  #
  # Dynamic-table insertion stays OFF (`Encoder`'s default). Turning it on needs more than
  # this latch — a direction that engaged mid-connection has an empty encoder table where
  # the peer's decoder holds entries from before the switch — and is not part of this step.
  class HeadRewrite
    # Split a re-encoded block at SETTINGS_MAX_FRAME_SIZE's initial value, which is also
    # the floor every endpoint must advertise at or above (RFC 9113 §6.5.2). Every
    # conformant peer accepts a frame this size, so the relay never has to read the peer's
    # SETTINGS to re-frame a head — and nothing in the relay parses SETTINGS today
    # (`Assembler#feed` returns at `stream_id == 0`).
    MAX_FRAME_PAYLOAD = 16384

    def initialize(@direction : String, @rewriter : Proxy::HeadRewriter,
                   @assembler : Assembler, @host : String)
      @encoder = HPACK::Encoder.new
      @engaged = false
      @warned = false
      @buf = [] of Frame::Header
      @block_bytes = 0
      @block_stream = 0_u32
    end

    # Whether this direction has begun re-encoding (see the class comment).
    def engaged? : Bool
      @engaged
    end

    # Feed one frame; yields the frames to forward, in arrival order, each with the
    # decoded projection the assembler should use for it (nil = the assembler decodes).
    # Yields nothing while a header block is still being buffered.
    def accept(frame : Frame::Header, &) : Nil
      opens = frame.frame_type == Frame::Type::Headers || frame.frame_type == Frame::Type::PushPromise
      continues = pending? && frame.frame_type == Frame::Type::Continuation &&
                  frame.stream_id == @block_stream

      # An intruder — any frame that is neither the start of a block nor the legal
      # continuation of the one in flight, arriving while one is buffered. RFC 9113
      # §6.2/§6.10 make that a connection error, so there is nothing here worth rewriting:
      # release what we hold VERBATIM, in arrival order, and let the peer's own error
      # handling (and the assembler's #409 guard) take it from there. Order and P7 both
      # survive, and the assembler sees exactly the frames it would have seen.
      if pending? && !continues
        @buf.each { |f| yield f, nil }
        reset
      end

      unless opens || continues
        yield frame, nil
        return
      end

      @block_stream = frame.stream_id if @buf.empty?
      @buf << frame
      @block_bytes += frame.payload.size

      # Same 1 MiB ceiling the assembler enforces: a peer that never sends END_HEADERS must
      # not grow this buffer without bound. Past it the block goes out as it arrived.
      if @block_bytes > Assembler::MAX_HEADER_BLOCK
        @buf.each { |f| yield f, nil }
        reset
        return
      end
      return unless frame.end_headers?

      frames, pre = finish
      last = frames.size - 1
      frames.each_with_index { |f, i| yield f, (i == last ? pre : nil) }
      reset
    end

    # Any frames still buffered when the connection ends: a block that never got
    # END_HEADERS. Release them verbatim so nothing is silently swallowed (P7).
    def drain(&) : Nil
      @buf.each { |f| yield f, nil }
      reset
    end

    private def pending? : Bool
      !@buf.empty?
    end

    private def reset : Nil
      @buf.clear
      @block_bytes = 0
      @block_stream = 0_u32
    end

    # One complete header block: decode it (advancing the SHARED per-direction decoder
    # exactly once), rewrite it, and choose between forwarding the frames as they arrived
    # and emitting re-encoded ones. Returns the frames to write plus the projection the
    # assembler must use — never letting the assembler decode the block a second time.
    private def finish : {Array(Frame::Header), Assembler::HeadBlock}
      first = @buf.first
      split = split_block(first)
      # Malformed padding (RFC 7540 §6.1): we cannot locate the block, so forward exactly
      # what arrived and let the assembler drop the projection, as `validate_pad` does.
      return {@buf.dup, Assembler::HeadBlock.new(nil)} if split.nil?
      prefix, block = split

      fields = @assembler.decode_head_block(@direction, block)
      # Malformed/hostile HPACK. Same disposition, and the nil projection is what stops the
      # assembler from running a second (differently-positioned) decode over the same bytes.
      return {@buf.dup, Assembler::HeadBlock.new(nil)} if fields.nil?

      rewritten = rewrite(fields, first)
      if rewritten.nil? && !@engaged
        # Unchanged, and this direction has never re-encoded: byte-exact passthrough, which
        # is also what keeps the peer's HPACK table driven by the original encoder.
        return {@buf.dup, Assembler::HeadBlock.new(pairs(fields))}
      end
      emit_fields = rewritten || fields
      @engaged = true
      {reframe(first, prefix, @encoder.encode(emit_fields)), Assembler::HeadBlock.new(pairs(emit_fields))}
    end

    # Run the Match&Replace rules over this block's h1-equivalent head. nil = unchanged
    # (which is also what a block the rules do not apply to returns).
    private def rewrite(fields : Array(HPACK::Field), first : Frame::Header) : Array(HPACK::Field)?
      return nil unless @rewriter.active?
      # PUSH_PROMISE carries a request the SERVER invented, not one the client sent; a
      # TRAILER block has no start line, and the header ops treat line 0 as one and skip it
      # (`rules.cr:246`, `rules.cr:264`), so running them over trailers would mangle the
      # first trailer rather than help. Both are re-encoded once engaged, never rule-applied
      # — which also keeps h1 and h2 equivalent, since h1 rules never see trailers either.
      return nil if first.frame_type == Frame::Type::PushPromise
      request = @direction == "out"
      return nil unless message_head?(fields, request)

      tuples = pairs(fields)
      if request
        # Scope the rule on the stream's own `:authority` rather than the CONNECT host, so a
        # host-scoped rule is right even on a coalesced connection. Responses have no
        # authority to read, so those fall back to the connection's host.
        authority = HeadCodec.pseudo(tuples, ":authority") || @host
        head = HeadCodec.synth_request(tuples, authority)
        rewritten_head = @rewriter.rewrite_request(head, authority)
      else
        head = HeadCodec.synth_response(tuples)
        rewritten_head = @rewriter.rewrite_response(head, @host)
      end
      return nil if rewritten_head == head # `Rules` returns the same content when nothing matched

      parsed = request ? HeadCodec.parse_request(rewritten_head, fields) : HeadCodec.parse_response(rewritten_head, fields)
      if parsed.nil?
        warn_unparseable(first.stream_id)
        return nil
      end
      restored = HeadCodec.restore_content_length(parsed, fields)
      # The head TEXT changed but no field did — a rule that rewrote the `HTTP/2` version
      # token, or a reason phrase, or the casing of a field name, all of which the h2 wire
      # format has no room for. Stay byte-exact and leave the latch alone rather than
      # re-encoding for a change that cannot reach the wire.
      restored == fields ? nil : restored
    end

    # A message head carries `:method` (request) / `:status` (response). Trailers carry
    # neither, and this test — unlike "the first block on the stream" — still rewrites the
    # final response head when an interim 1xx preceded it.
    private def message_head?(fields : Array(HPACK::Field), request : Bool) : Bool
      want = request ? ":method" : ":status"
      fields.any? { |f| f.name == want }
    end

    # A rewritten head that is no longer a head reaches this only from a destructive
    # `Replace` rule — the header ops keep it well-formed by construction. The original
    # block is forwarded unchanged, which must not be silent: say so once per direction per
    # connection, naming the stream.
    private def warn_unparseable(stream_id : UInt32) : Nil
      return if @warned
      @warned = true
      ::Log.warn do
        "h2 #{@direction}: a Match&Replace rule produced a head that is no longer parseable " \
        "(stream #{stream_id}) — forwarded the original head unchanged"
      end
    end

    private def pairs(fields : Array(HPACK::Field)) : Array({String, String})
      fields.map(&.to_tuple)
    end

    # {prefix to carry over, the block's bytes across all buffered frames}. PADDED padding
    # is dropped (it carries no information and a re-encoded head is a different length
    # anyway); the PRIORITY prefix and PUSH_PROMISE's promised-stream-id are preserved
    # verbatim. nil when the padding is malformed — the caller then forwards untouched.
    private def split_block(first : Frame::Header) : {Bytes, Bytes}?
      payload = first.payload
      offset = 0
      pad = 0
      if first.padded?
        return nil if payload.empty?
        pad = payload[0].to_i
        offset = 1
      end
      prefix_len = if first.frame_type == Frame::Type::PushPromise
                     4 # R + promised stream id
                   elsif first.priority?
                     5 # exclusive + dependency (4) + weight (1)
                   else
                     0
                   end
      return nil if payload.size < offset + prefix_len
      prefix = prefix_len > 0 ? payload[offset, prefix_len] : Bytes.empty
      offset += prefix_len
      return nil if pad > payload.size - offset
      stop = payload.size - pad
      head = stop > offset ? payload[offset...stop] : Bytes.empty

      io = IO::Memory.new(head.size + 64)
      io.write(head)
      @buf.each_with_index { |f, i| io.write(f.payload) if i > 0 }
      {prefix, io.to_slice}
    end

    # HEADERS/PUSH_PROMISE + CONTINUATION for a re-encoded block, split at
    # MAX_FRAME_PAYLOAD. END_STREAM and the PRIORITY prefix are preserved; PADDED is
    # cleared (the padding is gone); END_HEADERS lands on the last frame only.
    private def reframe(first : Frame::Header, prefix : Bytes, block : Bytes) : Array(Frame::Header)
      frames = [] of Frame::Header
      head_len = {block.size, MAX_FRAME_PAYLOAD - prefix.size}.min
      payload = Bytes.new(prefix.size + head_len)
      prefix.copy_to(payload) unless prefix.empty?
      block[0, head_len].copy_to(payload + prefix.size) if head_len > 0
      flags = first.flags & ~(Frame::PADDED | Frame::END_HEADERS)
      flags |= Frame::END_HEADERS if head_len >= block.size
      frames << Frame::Header.new(first.type, flags, first.stream_id, payload)

      pos = head_len
      while pos < block.size
        take = {block.size - pos, MAX_FRAME_PAYLOAD}.min
        pos += take
        frames << Frame::Header.new(Frame::Type::Continuation.value,
          pos >= block.size ? Frame::END_HEADERS : 0_u8,
          first.stream_id, block[pos - take, take])
      end
      frames
    end
  end
end
