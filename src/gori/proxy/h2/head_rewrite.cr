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

    # One complete header block, rules already applied, on its way out. `frames`/`pre` are
    # what the relay forwards when nothing holds it back.
    #
    # The rest exists for the intercept gate (#492 step 3), which needs more than the frames:
    # `head` is the h1 text a human edits, `fields` is what an edit is re-parsed against, and
    # `first`/`prefix` are what re-framing the result needs. `head` is nil for a block that is
    # not a message head — trailers, PUSH_PROMISE, or a block that could not be decoded — and
    # those are exactly the blocks that are never rule-applied and never held.
    record Block,
      frames : Array(Frame::Header),
      pre : Assembler::HeadBlock,
      fields : Array(HPACK::Field),
      head : Bytes?,
      first : Frame::Header,
      prefix : Bytes,
      request : Bool do
      def stream_id : UInt32
        first.stream_id
      end
    end

    # Consulted with every complete header block before it is forwarded. `defer?` returning
    # true means the callee has taken ownership of the block's frames — `HeadRewrite` then
    # yields nothing for it and the callee is responsible for writing them later. Only the
    # intercept gate implements this; with no deferrer wired in the pipeline is step 2's.
    module Deferrer
      abstract def defer?(block : Block) : Bool

      # Called instead of `defer?` for a block this direction could not read at all —
      # malformed padding (RFC 9113 §6.1) or a HPACK decoding failure (§4.3). Both are
      # CONNECTION errors by spec, so the peer's own error handling ends the connection
      # anyway; the frames are forwarded verbatim either way (P7 — the raw log is the truth).
      #
      # The hook exists because #492 step 4 put a BLOCKING gate on this pipeline, and a head
      # that cannot be decoded is a head whose URL cannot be scope-tested. Without it the
      # sandbox would fail OPEN on exactly the input most likely to be hostile.
      abstract def undecodable(stream_id : UInt32) : Nil
    end

    # Set by `StreamGate` when intercept is wired in. Deliberately a property rather than a
    # constructor argument: the gate needs a live `HeadRewrite` to construct itself around.
    property deferrer : Deferrer?

    def initialize(@direction : String, @rewriter : Proxy::HeadRewriter?,
                   @assembler : Assembler, @host : String)
      @encoder = HPACK::Encoder.new
      @engaged = false
      @warned = false
      @warned_unfaithful = false
      @buf = [] of Frame::Header
      @block_bytes = 0
      @block_stream = 0_u32
    end

    # Whether this direction has begun re-encoding (see the class comment).
    def engaged? : Bool
      @engaged
    end

    # Re-encode a block whose delivery is being DEFERRED, and latch the direction (#492 step 3,
    # D1 rule 5). Deferring means later blocks in this direction reach the peer AHEAD of this
    # one, and HPACK's context is one sequential per-direction state (RFC 7541 §2.2): a
    # passthrough block delivered out of order resolves its dynamic indices against a table
    # missing this block's insertions — the wrong header, silently, or out of range and the
    # connection dies. It is the same §6.2.1 asymmetry the class comment describes, reached by
    # reordering instead of by rewriting, and it breaks with zero rules enabled.
    #
    # A re-encoded block reads no dynamic index and inserts nothing, so its position in the
    # sequence stops mattering. That is what makes holding ONE stream without freezing the
    # others legal at all — so this is a correctness precondition of the hold, not a tidy-up.
    # A block produced while already engaged came out of `finish` re-encoded, so it is returned
    # untouched.
    def engage(block : Block) : Block
      return block if @engaged
      latch
      block.copy_with(frames: reframe(block.first, block.prefix, @encoder.encode(block.fields)))
    end

    # `engage` for a block that will never be written AT ALL — #492 step 4's sandbox refusal
    # SUPPRESSES a header block rather than deferring it. Same §6.2.1 asymmetry as the class
    # comment describes, reached a third way: dropping a block leaves the far decoder short of
    # its insertions while the original encoder's table has already grown, so every later
    # passthrough block in this direction resolves its dynamic indices against the wrong table.
    # There is nothing to re-encode here, so this is `engage` minus the block.
    def latch : Nil
      @engaged = true
    end

    # Re-encode a held head the operator EDITED (#492 step 3, D3). Same decoder (the block was
    # decoded on arrival), same encoder, same latch, same `HeadCodec` round trip a rule takes —
    # intercept is a stage inside this pipeline, not a second pipeline beside it. nil when the
    # edited bytes are no longer a head: the caller then forwards the block as it stood, which
    # is what an unparseable RULE result already does.
    def encode_edited(block : Block, head : Bytes) : Block?
      # The head shown to the operator is a lossy rendering of what the peer sent, so re-parsing
      # their edit would apply it to a DIFFERENT message (#517). Refuse the edit rather than
      # send that; the caller keeps the block as it stood.
      unless HeadCodec.h1_faithful?(block.fields, block.request)
        warn_unfaithful(block.stream_id, block.request)
        return nil
      end
      parsed = block.request ? HeadCodec.parse_request(head, block.fields) : HeadCodec.parse_response(head, block.fields)
      if parsed.nil?
        warn_unparseable(block.stream_id, "an intercept edit")
        return nil
      end
      fields = HeadCodec.restore_content_length(parsed, block.fields)
      @engaged = true
      Block.new(reframe(block.first, block.prefix, @encoder.encode(fields)),
        Assembler::HeadBlock.new(pairs(fields)), fields, head, block.first, block.prefix, block.request)
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
    #
    # An empty frame array means a `Deferrer` took the block: the gate owns those frames now
    # and will write them when the operator decides.
    private def finish : {Array(Frame::Header), Assembler::HeadBlock}
      first = @buf.first
      split = split_block(first)
      # Malformed padding (RFC 7540 §6.1): we cannot locate the block, so forward exactly
      # what arrived and let the assembler drop the projection, as `validate_pad` does.
      return unreadable(first) if split.nil?
      prefix, block = split

      fields = @assembler.decode_head_block(@direction, block)
      # Malformed/hostile HPACK. Same disposition, and the nil projection is what stops the
      # assembler from running a second (differently-positioned) decode over the same bytes.
      return unreadable(first) if fields.nil?

      request = @direction == "out"
      head = head_text(fields, first, request)
      rewritten = head ? rewrite(fields, head, request) : nil
      emit_fields = rewritten || fields
      built = if rewritten.nil? && !@engaged
                # Unchanged, and this direction has never re-encoded: byte-exact passthrough,
                # which is also what keeps the peer's HPACK table driven by the original encoder.
                Block.new(@buf.dup, Assembler::HeadBlock.new(pairs(fields)), fields, head, first, prefix, request)
              else
                @engaged = true
                # A rule changed the head, so the TEXT the gate would show a human is the
                # rewritten one — re-synthesized from the fields actually going out, so what the
                # operator edits is what would have been sent.
                shown = rewritten ? head_text(emit_fields, first, request) : head
                Block.new(reframe(first, prefix, @encoder.encode(emit_fields)),
                  Assembler::HeadBlock.new(pairs(emit_fields)), emit_fields, shown, first, prefix, request)
              end
      return {[] of Frame::Header, built.pre} if @deferrer.try(&.defer?(built))
      {built.frames, built.pre}
    end

    # A block this direction could not read. The frames go out exactly as they arrived, with a
    # nil projection so the assembler does not attempt its own decode — that part is unchanged.
    # What is new is telling the `Deferrer` first: it may refuse a connection it has gone blind
    # on, which is the only honest answer for a blocking gate. See `Deferrer#undecodable`.
    private def unreadable(first : Frame::Header) : {Array(Frame::Header), Assembler::HeadBlock}
      @deferrer.try(&.undecodable(first.stream_id))
      {@buf.dup, Assembler::HeadBlock.new(nil)}
    end

    # This block's h1-equivalent head text, or nil when the block is not a message head.
    #
    # PUSH_PROMISE carries a request the SERVER invented, not one the client sent; a TRAILER
    # block has no start line, and the header ops treat line 0 as one and skip it
    # (`rules.cr:246`, `rules.cr:264`), so running them over trailers would mangle the first
    # trailer rather than help. Both are re-encoded once engaged, never rule-applied and never
    # held — which also keeps h1 and h2 equivalent, since h1 sees neither.
    private def head_text(fields : Array(HPACK::Field), first : Frame::Header, request : Bool) : Bytes?
      return nil if first.frame_type == Frame::Type::PushPromise
      return nil unless message_head?(fields, request)
      tuples = pairs(fields)
      # Scope on the stream's own `:authority` rather than the CONNECT host, so a host-scoped
      # rule (and a host-scoped intercept) is right even on a coalesced connection. Responses
      # have no authority to read, so those fall back to the connection's host.
      request ? HeadCodec.synth_request(tuples, HeadCodec.pseudo(tuples, ":authority") || @host) : HeadCodec.synth_response(tuples)
    end

    # Run the Match&Replace rules over this block's h1-equivalent head. nil = unchanged
    # (which is also what a block the rules do not apply to returns).
    private def rewrite(fields : Array(HPACK::Field), head : Bytes, request : Bool) : Array(HPACK::Field)?
      rw = @rewriter
      return nil unless rw && rw.active?
      # The peer's own head has no faithful h1-text form, so the round trip that runs the
      # rules would hand the far side a DIFFERENT message — see `HeadCodec.h1_faithful?`.
      # `parse_*` refuses it anyway; checking here keeps the rules from running for nothing
      # and, more to the point, keeps the log from blaming a rule for the peer's bytes.
      return warn_unfaithful(@block_stream, request) unless HeadCodec.h1_faithful?(fields, request)
      authority = request ? (HeadCodec.pseudo_of(fields, ":authority") || @host) : @host
      rewritten_head = request ? rw.rewrite_request(head, authority) : rw.rewrite_response(head, @host)
      return nil if rewritten_head == head # `Rules` returns the same content when nothing matched

      parsed = request ? HeadCodec.parse_request(rewritten_head, fields) : HeadCodec.parse_response(rewritten_head, fields)
      if parsed.nil?
        warn_unparseable(@block_stream, "a Match&Replace rule")
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

    # A rewritten head that is no longer a head reaches this from a destructive `Replace` rule
    # (the header ops keep it well-formed by construction) or from a human editing a held head
    # into something that no longer parses. Either way the block is forwarded as it stood,
    # which must not be silent: say so once per direction per connection, naming the stream.
    private def warn_unparseable(stream_id : UInt32, source : String) : Nil
      return if @warned
      @warned = true
      ::Log.warn do
        "h2 #{@direction}: #{source} produced a head that is no longer parseable " \
        "(stream #{stream_id}) — forwarded the original head unchanged"
      end
    end

    # The mirror of `warn_unparseable` for a head the PEER sent that the h1 text cannot carry
    # (#517). Not a rule's doing and not the operator's, so it gets its own line — and its own
    # flag, or whichever of the two happened first would silence the other. Always nil, so
    # `rewrite` can return it directly: nothing is rewritten and the original fields go out.
    private def warn_unfaithful(stream_id : UInt32, request : Bool) : Nil
      return if @warned_unfaithful
      @warned_unfaithful = true
      ::Log.warn do
        "h2 #{@direction}: the peer sent a #{request ? "request" : "response"} head that has no " \
        "HTTP/1.1 text form (stream #{stream_id}) — Match&Replace and intercept edits are " \
        "not applied to it, the fields go out exactly as they arrived"
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
