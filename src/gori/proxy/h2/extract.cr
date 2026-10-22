require "./frame"
require "./head_codec"
require "./assembler"
require "../extractor"
require "../upstream"
require "../../sse"

module Gori::Proxy::H2
  # Session-binding extraction on the h2 relay (#501 slice 2).
  #
  # ## Head and body
  #
  # A HEAD-scoped descriptor (a cookie or a header) reads the response head and runs the moment
  # that head is delivered — unless a body-scoped rule matches the host too, in which case both
  # run together at the end, as on h1's buffering path. A BODY-scoped one (regex / position / jsonpath) needs the entity, so
  # for a host such a rule matches the delivered DATA is copied aside as it goes out, and the
  # rules run once at END_STREAM over head and body together — what h1's buffering path offers
  # them (#1635). The copy never holds anything back: frames reach the client exactly as they
  # would with no rule live, so extraction costs the host neither its protocol nor its latency.
  #
  # A body gori cannot read whole is offered as no body at all, as h1 offers a streaming one:
  # an event stream, a tunnel, a padded DATA frame (padding is `Assembler#data_block`'s to
  # strip), or one that runs past `MAX_BODY` — a ceiling shared by every response this
  # connection is copying (P6).
  #
  # ## Where it is called
  #
  # From the two places that WRITE a frame to the far leg — `StreamGate#write` (intercept on)
  # and `Relay#emit` (intercept off) — right after the frame has gone out. That is the same
  # "delivered, not arrived" rule the h1 path follows, and it falls out of the structure here
  # rather than being asserted: a head the sandbox suppressed or the operator dropped is fed to
  # the assembler by `project`, never by `write`, so it never reaches this observer.
  #
  # `pre` is non-nil on exactly the LAST frame of a decoded header block, so a DATA frame costs
  # one nil test plus an empty-Hash test, and a response with no rule live costs one atomic read
  # on top of that.
  #
  # One instance per direction per connection; only the "in" direction ever constructs one.
  class Extract
    # h1's buffering ceiling for the same rule (`ClientConn::MAX_REWRITE_BODY`), here across
    # every body this connection is copying at once.
    MAX_BODY = Proxy::ClientConn::MAX_REWRITE_BODY

    # A delivered response head waiting for its body.
    private record Pending, head : Bytes, ref : Assembler::RequestRef, status : Int32,
      body : IO::Memory

    def initialize(@extractor : Proxy::ResponseExtract, @assembler : Assembler,
                   @host : String, @port : Int32)
      @warned_unscopable = false
      @pending = {} of UInt32 => Pending
      @buffered = 0
    end

    # Offer a delivered frame to the extract rules. `pre` is the projection the caller already
    # decoded; nil for every frame that is not the end of a header block.
    def observe(frame : Frame::Header, pre : Assembler::HeadBlock?) : Nil
      return collect(frame) if !@pending.empty? && @pending.has_key?(frame.stream_id)
      return unless pre
      return unless @extractor.extracts? # lock-free: nothing configured, nothing decoded
      fields = pre.fields
      return unless fields
      status = HeadCodec.pseudo(fields, ":status").try(&.to_i?)
      return unless status
      # Interim 1xx never carries the final head; h1 skips these before its own gates
      # (`client_conn.cr#skip_interim_responses`), so this is parity rather than a new rule.
      return if status < 200
      # An extract rule's condition scopes on the REQUEST's method and target, and an h2
      # response head carries neither — the assembler's live stream map is the source, exactly
      # as the intercept response gate uses it (`StreamGate#hold_response`).
      ref = @assembler.request_ref(frame.stream_id)
      if ref.nil?
        # Past `Assembler::MAX_LIVE_STREAMS` this connection stopped tracking new streams, so
        # there is no request target to test the rule's condition against. Inventing one is how
        # an extraction escapes its declared scope, so: do not extract, and say so once.
        warn_unscopable(frame.stream_id)
        return
      end
      head = HeadCodec.synth_response(fields)
      if copies_body?(frame, ref, fields)
        forget_gone
        @pending[frame.stream_id] = Pending.new(head, ref, status, IO::Memory.new)
        return
      end
      # Passing nil rather than an empty slice is what makes the observer say "there was no
      # body" instead of "the selector found nothing".
      offer(frame.stream_id, head, ref, status, nil)
    rescue ex
      # An extract rule must never be able to break a relayed connection.
      ::Log.warn { "extract rules skipped for an h2 response: #{ex.message}" }
    end

    # Whether a body-scoped rule wants this response's body, and it is one that ends.
    private def copies_body?(frame : Frame::Header, ref : Assembler::RequestRef,
                             fields : Array({String, String})) : Bool
      return false if frame.end_stream? || ref.method == "CONNECT"
      host, _ = Upstream.split_host_port(ref.authority, @port)
      @extractor.extracts_body_for_host?(host) &&
        !Sse.sse?(HeadCodec.pseudo(fields, "content-type"))
    end

    # One delivered frame of a response whose body is being copied.
    private def collect(frame : Frame::Header) : Nil
      pending = @pending[frame.stream_id]
      case frame.frame_type
      when Frame::Type::Data
        if frame.padded? || @buffered + frame.payload.size > MAX_BODY
          return finish(frame.stream_id, nil)
        end
        pending.body.write(frame.payload)
        @buffered += frame.payload.size
        finish(frame.stream_id, pending.body.to_slice) if frame.end_stream?
      when Frame::Type::Headers
        # Trailers end the message when they carry END_STREAM (RFC 9113 §8.1).
        finish(frame.stream_id, pending.body.to_slice) if frame.end_stream?
      when Frame::Type::RstStream
        # Cut short: offered with what was delivered, as h1 offers a truncated body.
        finish(frame.stream_id, pending.body.to_slice)
      end
    rescue ex
      ::Log.warn { "extract rules skipped for an h2 response: #{ex.message}" }
    end

    private def finish(stream_id : UInt32, body : Bytes?) : Nil
      pending = drop(stream_id) || return
      offer(stream_id, pending.head, pending.ref, pending.status, body)
    end

    private def drop(stream_id : UInt32) : Pending?
      pending = @pending.delete(stream_id)
      @buffered -= pending.body.size if pending
      pending
    end

    # A response the CLIENT reset is never seen here (its RST_STREAM goes the other way), so its
    # copy is let go once the assembler has forgotten the stream.
    private def forget_gone : Nil
      @pending.keys.each { |id| drop(id) if @assembler.request_ref(id).nil? }
    end

    private def offer(stream_id : UInt32, head : Bytes, ref : Assembler::RequestRef, status : Int32,
                      body : Bytes?) : Nil
      host, port = Upstream.split_host_port(ref.authority, @port)
      @extractor.observe_response(head, body,
        method: ref.method, host: host, target: ref.target, scheme: ref.scheme,
        status: status, flow_id: @assembler.flow_id_of(stream_id), port: port)
    end

    private def warn_unscopable(stream_id : UInt32) : Nil
      return if @warned_unscopable
      @warned_unscopable = true
      ::Log.warn do
        # Its `stream_gate.cr` twin named the live-stream ceiling unconditionally and fired on
        # single-stream connections, where the real cause was an undecodable request head. Same
        # wording here, for the same reason: do not send the operator to a limit they are not near.
        "h2 in: stream #{stream_id} has no projected request, so its response has no request " \
        "target to scope a session-binding extract rule against — nothing was extracted from " \
        "it. Either the request head could not be decoded, or the connection is past " \
        "#{Assembler::MAX_LIVE_STREAMS} live streams"
      end
    end
  end
end
