require "./frame"
require "./hpack"
require "./head_codec"
require "./assembler"
require "../head_rewriter"
require "../extractor"
require "../upstream"

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

    # `extractor` is read for ONE thing: `notice_coalesced`, which runs on request heads only.
    # The "in" direction therefore never touches it, and extraction itself happens in
    # `H2::Extract` on the response side — this seam only has to be able to ASK whether a
    # body-scoped extract rule would have wanted a stream the connection gate could not see.
    def initialize(@direction : String, @rewriter : Proxy::HeadRewriter?,
                   @assembler : Assembler, @host : String,
                   @extractor : Proxy::ResponseExtract? = nil)
      @encoder = HPACK::Encoder.new
      @engaged = false
      @warned = false
      @warned_unfaithful = false
      @warned_coalesced = false
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
    #
    # `restore_length` is PROVENANCE, not policy (#513 / R3-F2). Reverting the operator's
    # `content-length` is right when the surface computed it FOR them — the TUI intercept
    # editor's `^L` recomputes it from the editor's body, and a HEAD-ONLY h2 hold carries no
    # body, so on a dirty edit that lands as `content-length: 0` beside DATA gori still relays.
    # (`StreamGate` passes false for a hold that buffered the body: there the edit's body IS
    # what gori sends, so the operator's value is simply true about it.) It is
    # wrong when the operator DECLARED it: a content-length that disagrees with the DATA is
    # RFC 9113 §8.1.1-malformed, and whether a given origin/CDN/WAF/gRPC gateway enforces that
    # is exactly the probe they opened the editor to run. h1 forwards the identical edit
    # byte-exact and says so (`client_conn.cr`); h2 reverted it and reported success.
    def encode_edited(block : Block, head : Bytes, restore_length : Bool = true) : Block?
      # The head shown to the operator is a lossy rendering of what the peer sent, so re-parsing
      # their edit would apply it to a DIFFERENT message (#517). Refuse the edit rather than
      # send that; the caller keeps the block as it stood.
      #
      # `StreamGate` now asks `HeadCodec.h1_unfaithful_reason` at HOLD time and refuses the edit
      # at the surface that asked for it, so this is the backstop rather than the only stop.
      if reason = HeadCodec.h1_unfaithful_reason(block.fields, block.request)
        warn_unfaithful(block.stream_id, block.request, reason)
        return nil
      end
      parsed = block.request ? HeadCodec.parse_request(head, block.fields) : HeadCodec.parse_response(head, block.fields)
      if parsed.nil?
        warn_unparseable(block.stream_id, "an intercept edit")
        return nil
      end
      fields = restore_length ? HeadCodec.restore_content_length(parsed, block.fields) : parsed
      @engaged = true
      Block.new(reframe(block.first, block.prefix, @encoder.encode(fields)),
        Assembler::HeadBlock.new(pairs(fields)), fields, head, block.first, block.prefix, block.request)
    end

    # Feed one frame; yields the frames to forward, in arrival order, each with the
    # decoded projection the assembler should use for it (nil = the assembler decodes).
    # Yields nothing while a header block is still being buffered.
    def accept(frame : Frame::Header, &) : Nil
      opens = block_opener?(frame)
      continues = pending? && frame.frame_type == Frame::Type::Continuation &&
                  frame.stream_id == @block_stream

      # An intruder — any frame that is neither the start of a block nor the legal
      # continuation of the one in flight, arriving while one is buffered. RFC 9113
      # §6.2/§6.10 make that a connection error, so there is nothing here worth rewriting:
      # release what we hold VERBATIM, in arrival order, and let the peer's own error
      # handling (and the assembler's #409 guard) take it from there. Order and P7 both
      # survive, and the assembler sees exactly the frames it would have seen.
      if pending? && !continues
        # The buffered block is abandoned here WITHOUT ever reaching `finish`, so it is never
        # decoded and never scope-tested — flushing it verbatim was a live sandbox bypass in
        # three frames: HEADERS(1) with END_HEADERS cleared for an out-of-scope path, ANY
        # intruder frame (a bare PRIORITY does it), then the CONTINUATION. Measured: the origin
        # received both halves of `/blocked` and ANSWERED it, while the control without the
        # intruder got `RST_STREAM code=8` and the origin got nothing. That every route in is
        # itself a §6.10 violation is not a mitigation gori may lean on — it is the reasoning
        # `undecodable`'s own comment rejects, and the out-of-scope bytes reach the origin
        # either way. So tell the deferrer, exactly as the ceiling and HPACK-failure branches
        # do: this IS "a head with no URL to scope-test". Sandbox ON ends the connection;
        # sandbox OFF keeps the verbatim forward the paragraph above describes (P7).
        frames, stream = @buf.dup, @block_stream
        reset
        @deferrer.try(&.undecodable(stream))
        frames.each { |f| yield f, nil }
      end

      unless opens || continues
        yield frame, nil
        return
      end

      @block_stream = frame.stream_id if @buf.empty?
      @buf << frame
      @block_bytes += frame.payload.size

      # Same 1 MiB ceiling the assembler enforces: a peer that never sends END_HEADERS must
      # not grow this buffer without bound. Past it the block goes out as it arrived — but
      # the `Deferrer` hears about it FIRST, exactly as `unreadable` does. This block is
      # never decoded either, so it is the same situation the hook was written for: a head
      # with no URL to scope-test, walking past a BLOCKING gate. Without it a client could
      # reach any host the sandbox excludes by sending HEADERS with no END_HEADERS followed
      # by 64 MiB of CONTINUATION. With the sandbox off `undecodable` is a no-op and this
      # stays the verbatim forward it has always been.
      if @block_bytes > Assembler::MAX_HEADER_BLOCK
        # Drain the buffer into a local and `reset` BEFORE the deferrer is told, because
        # `undecodable` RAISES to end the connection when the sandbox is on. The raise unwinds
        # through `pump_gated`'s `ensure gate.close`, and `close` drains this same buffer
        # straight to `@dst` (`stream_gate.cr`) — so leaving the frames here forwarded the very
        # block the gate had just refused to let past, unexamined, while the WARN said the
        # opposite. Empty buffer, nothing for `close` to write.
        frames, stream = @buf.dup, @block_stream
        reset
        @deferrer.try(&.undecodable(stream))
        frames.each { |f| yield f, nil }
        return
      end
      return unless frame.end_headers?

      frames, pre = finish # resets @buf itself
      last = frames.size - 1
      frames.each_with_index { |f, i| yield f, (i == last ? pre : nil) }
    end

    # Any frames still buffered when the connection ends: a block that never got END_HEADERS,
    # so it never reached `finish` and was never decoded or scope-tested.
    #
    # `discard` is the sandbox's answer to that. Verbatim release is P7's "nothing is silently
    # swallowed", and it stays that with the sandbox OFF (`discard: false`). But a block with no
    # END_HEADERS has no URL to scope-test, so with the sandbox ON writing it to the peer was the
    # fifth site of the buffered-block leak — reachable in one frame plus a hangup
    # (`HEADERS(no END_HEADERS)` for an out-of-scope path, then close). It is dropped instead: the
    # connection is ending regardless, and the raw h2 frame log already recorded what arrived, so
    # nothing is lost that P7 needs. Not routed through `undecodable`: `close` wraps only the
    # `write` in `rescue nil`, so a raise here would escape `@mutex.synchronize` and skip the rest
    # of `close` (slot cleanup, handing held items back to the Interceptor) — leaking queue rows.
    def drain(discard : Bool = false, &) : Nil
      if discard
        ::Log.warn { "h2: dropped a #{@buf.size}-frame header block with no END_HEADERS at connection close (sandbox on — no URL to scope-test)" } unless @buf.empty?
      else
        @buf.each { |f| yield f, nil }
      end
      reset
    end

    # A HEADERS/PUSH_PROMISE that opens a buffered block. `stream_id != 0` is load-bearing:
    # `StreamGate` now routes connection-level frames through `accept` (so one inside a buffered
    # block is caught as an intruder), and a HEADERS/PUSH_PROMISE on stream 0 is a §6.2
    # connection error. Without this guard such a frame would OPEN a block, `defer?` could mint a
    # Slot keyed 0, and every later SETTINGS/PING/WINDOW_UPDATE would park behind it — the freeze
    # D1 rule 1 forbids. With it, a stream-0 frame falls to the `unless opens || continues` yield
    # and is written at once, as before.
    private def block_opener?(frame : Frame::Header) : Bool
      (frame.frame_type == Frame::Type::Headers || frame.frame_type == Frame::Type::PushPromise) &&
        frame.stream_id != 0
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
      split = split_block(first) # reads every frame in @buf (assembles the CONTINUATIONs)
      # Snapshot the frames and `reset` HERE, the moment `split_block` has finished reading
      # `@buf`, rather than at the single `defer?` site below. Everything between this point
      # and the return — `decode_head_block`, `head_text`, `notice_coalesced`, `rewrite`
      # (which runs OPERATOR REGEXES over PEER BYTES), `@encoder.encode`, and `defer?` itself —
      # can raise, and a raise unwinds to `StreamGate#close`'s `drain`, which writes whatever
      # is still in `@buf` to the peer. Leaving `@buf` full through all of that is the residual
      # window each per-site fix closed one at a time; clearing it up front closes the class.
      # `snapshot` is what a passthrough block and `unreadable` forward — never `@buf` again.
      snapshot = @buf.dup
      reset
      # Malformed padding (RFC 7540 §6.1): we cannot locate the block, so forward exactly
      # what arrived and let the assembler drop the projection, as `validate_pad` does.
      return unreadable(first, snapshot) if split.nil?
      prefix, block = split

      fields = @assembler.decode_head_block(@direction, block)
      # Malformed/hostile HPACK. Same disposition, and the nil projection is what stops the
      # assembler from running a second (differently-positioned) decode over the same bytes.
      return unreadable(first, snapshot) if fields.nil?

      request = @direction == "out"
      # `first.stream_id`, NOT `@block_stream`: `reset` above zeroed it (deliberately — it
      # closes the buffered-block leak class), so every warning below `finish` named "stream 0",
      # a stream that cannot exist. `encode_edited` was never affected because it reads
      # `block.stream_id`, which is why the intercept-path warnings said the right thing while
      # the rule-path ones did not.
      stream_id = first.stream_id
      head = head_text(fields, first, request)
      # Before the rewrite, and NOT from inside it: what this announces is a seam the relay
      # cannot reach at all, which is true whether or not a head rule is live. Running it from
      # `rewrite` put it behind `rw.active?`, so an operator whose only rule is a session-binding
      # extract descriptor — the case #536 is about — got nothing.
      notice_coalesced(fields) if request && head
      rewritten = head ? rewrite(fields, head, request, stream_id) : nil
      emit_fields = rewritten || fields
      built = if rewritten.nil? && !@engaged
                # Unchanged, and this direction has never re-encoded: byte-exact passthrough,
                # which is also what keeps the peer's HPACK table driven by the original encoder.
                # `snapshot`, not `@buf` — `@buf` was cleared above.
                Block.new(snapshot, Assembler::HeadBlock.new(pairs(fields)), fields, head, first, prefix, request)
              else
                @engaged = true
                # A rule changed the head, so the TEXT the gate would show a human is the
                # rewritten one — re-synthesized from the fields actually going out, so what the
                # operator edits is what would have been sent.
                shown = rewritten ? head_text(emit_fields, first, request) : head
                Block.new(reframe(first, prefix, @encoder.encode(emit_fields)),
                  Assembler::HeadBlock.new(pairs(emit_fields)), emit_fields, shown, first, prefix, request)
              end
      # `@buf` was already cleared at the top, so `defer?` raising here (StreamGate ends the
      # connection past MAX_REFUSED_STREAMS) leaves `close`'s drain nothing to write.
      return {[] of Frame::Header, built.pre} if @deferrer.try(&.defer?(built))
      {built.frames, built.pre}
    end

    # A block this direction could not read. The frames go out exactly as they arrived (from the
    # snapshot `finish` took before clearing `@buf`), with a nil projection so the assembler does
    # not attempt its own decode. The `Deferrer` is told first: it may refuse a connection it has
    # gone blind on, which is the only honest answer for a blocking gate — and since `@buf` is
    # already empty, that raise reaches `close`'s drain with nothing to leak.
    private def unreadable(first : Frame::Header,
                           frames : Array(Frame::Header)) : {Array(Frame::Header), Assembler::HeadBlock}
      @deferrer.try(&.undecodable(first.stream_id))
      {frames, Assembler::HeadBlock.new(nil)}
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
    private def rewrite(fields : Array(HPACK::Field), head : Bytes, request : Bool,
                        stream_id : UInt32) : Array(HPACK::Field)?
      rw = @rewriter
      return nil unless rw && rw.active?
      # The peer's own head has no faithful h1-text form, so the round trip that runs the
      # rules would hand the far side a DIFFERENT message — see `HeadCodec.h1_faithful?`.
      # `parse_*` refuses it anyway; checking here keeps the rules from running for nothing
      # and, more to the point, keeps the log from blaming a rule for the peer's bytes.
      if reason = HeadCodec.h1_unfaithful_reason(fields, request)
        note_skipped(stream_id, reason)
        return warn_unfaithful(stream_id, request, reason)
      end
      # The BARE host, because that is what a rule's host glob is written against and what
      # every other host-scoping site in this pipeline passes (`notice_coalesced` below,
      # `H2::Extract`, `StreamGate`'s three gates). `:authority` may carry a port, and
      # `Rules.host_matches?` compiles an anchored regex — so `api.example.com:8443` silently
      # matched no `*.example.com` glob, leaving a head rule that fires on h1 and on this
      # stream's own RESPONSE head (which gets the bare `@host`) inert on the request.
      authority = request ? request_host(fields) : @host
      rewritten_head = request ? rw.rewrite_request(head, authority) : rw.rewrite_response(head, @host)
      return nil if rewritten_head == head # `Rules` returns the same content when nothing matched

      parsed = request ? HeadCodec.parse_request(rewritten_head, fields) : HeadCodec.parse_response(rewritten_head, fields)
      if parsed.nil?
        warn_unparseable(stream_id, "a Match&Replace rule")
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

    # The same refusal as `warn_unfaithful`, recorded AGAINST THE FLOW instead of only in the
    # log — `Store::FlowRow#advisory`, the HTTP twin of the `[gori] …` rows a WebSocket flow
    # gets. The log line is once per direction per connection (a flood would be useless); this
    # is once per MESSAGE, because "did my rule run on THIS request?" is a per-message
    # question and the operator asking it is reading History, not tailing `gori.log`. Reached
    # only with a head rule live, which is what makes the skip a fact worth recording; with no
    # rules there is nothing that failed to fire.
    private def note_skipped(stream_id : UInt32, reason : String) : Nil
      @assembler.note_advisory(stream_id,
        "Match&Replace was NOT applied to this #{@direction == "out" ? "request" : "response"} " \
        "head: it has no HTTP/1.1 text form (#{reason}). The fields went out exactly as they " \
        "arrived, and an intercept edit to it would be refused for the same reason (#517)")
    end

    # The mirror of `warn_unparseable` for a head the PEER sent that the h1 text cannot carry
    # (#517). Not a rule's doing and not the operator's, so it gets its own line — and its own
    # flag, or whichever of the two happened first would silence the other. Always nil, so
    # `rewrite` can return it directly: nothing is rewritten and the original fields go out.
    #
    # `reason` names the offending field. "No HTTP/1.1 text form" is a class, not a cause, and
    # the operator who induced it — probe a CRLF sink, watch the origin reflect `%0d%0a` back —
    # needs to read the field name to connect the two.
    private def warn_unfaithful(stream_id : UInt32, request : Bool, reason : String) : Nil
      return if @warned_unfaithful
      @warned_unfaithful = true
      ::Log.warn do
        "h2 #{@direction}: the peer sent a #{request ? "request" : "response"} head that has no " \
        "HTTP/1.1 text form (stream #{stream_id}): #{reason}. Match&Replace and intercept edits " \
        "are not applied to it, the fields go out exactly as they arrived"
      end
    end

    # The stated cost of #526, kept spoken instead of silent.
    #
    # Every gate that can cost a connection its protocol (`tls/tunnel.cr#h2_candidate?`) is per
    # CONNECT, so it can only ask about the CONNECT host. Since #526 it asks whether a rule the
    # h2 relay cannot run matches THAT host — which is right for every stream whose `:authority`
    # is that host, and every stream on a conformant connection is (gori's leaf carries a SAN of
    # exactly the requested host, `tls/cert_builder.cr`, so a conformant client cannot coalesce
    # onto one). A hand-rolled client can still coalesce, and then a rule scoped to the coalesced
    # authority goes unapplied where the pre-#526 blanket downgrade would have caught it.
    #
    # Enforcement is right either way — a rule that cannot scope a stream must not fire on it —
    # so what is wrong is only that it is SILENT: the operator sees a request they stubbed reach
    # the origin, or `$SESSION` never bind, with nothing saying why.
    #
    # So: one line per connection, naming the authority, the connection host, and WHICH KIND of
    # rule was skipped — three kinds now share this notice and they fail differently, so a line
    # that did not name them would send the operator to the wrong rule table (#536). Costs a
    # string compare per request head on every normal connection (the authority IS the host, and
    # that returns before any lock); only a genuinely coalesced stream reaches the rule lookups,
    # This stream's request host, port stripped, falling back to the CONNECT host when the
    # block carries no `:authority`. One spelling of "which host is this stream for", so the
    # rule gate and the coalescing notice below cannot drift on it.
    private def request_host(fields : Array(HPACK::Field)) : String
      authority = HeadCodec.pseudo_of(fields, ":authority")
      return @host if authority.nil? || authority.empty?
      host, _ = Upstream.split_host_port(authority, 0)
      host.empty? ? @host : host
    end

    # and only until the line is written.
    private def notice_coalesced(fields : Array(HPACK::Field)) : Nil
      return if @warned_coalesced
      authority = HeadCodec.pseudo_of(fields, ":authority")
      return if authority.nil? || authority.empty?
      # `:authority` may carry a port; the gate asked about a bare host.
      host, _ = Upstream.split_host_port(authority, 0)
      return if host.compare(@host, case_insensitive: true) == 0
      kinds = unreachable_kinds(host)
      return if kinds.empty?
      @warned_coalesced = true
      ::Log.warn do
        "h2 #{@direction}: stream authority #{host.inspect} is not the CONNECT host " \
        "#{@host.inspect} (RFC 9113 §9.1.1 coalescing), and it is matched by rules this relay " \
        "cannot apply: #{kinds.join(", ")}. The connection was not downgraded because no such " \
        "rule matches #{@host.inspect}, so they do not fire on this stream. Reach this host on " \
        "its own connection to have them apply."
      end
    end

    # Which of the per-CONNECT gates would have wanted this stream — i.e. which host-scoped
    # seams the h2 relay cannot reach have a live rule for the coalesced authority. Exactly the
    # set `h2_candidate?` tests, asked about the authority instead of the CONNECT host, so the
    # two cannot drift apart in what they consider unreachable.
    #
    # Only ever reached on a genuinely coalesced stream and only once per connection, so each
    # predicate is free to take its lock (all three document themselves as once-per-CONNECT).
    private def unreachable_kinds(host : String) : Array(String)
      kinds = [] of String
      if rw = @rewriter
        kinds << "a Match&Replace BODY rule" if rw.rewrites_body_for_host?(host)
        kinds << "a Match&Replace SHORT-CIRCUIT rule" if rw.short_circuits_for_host?(host)
      end
      # Head-scoped extraction is deliberately absent: `H2::Extract` reads the response head on
      # this relay and scopes it on the stream's own request, so a cookie/header descriptor is
      # applied correctly on a coalesced stream and has nothing to announce.
      if @extractor.try(&.extracts_body_for_host?(host))
        kinds << "a session-binding EXTRACT rule that reads the response body"
      end
      kinds
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
