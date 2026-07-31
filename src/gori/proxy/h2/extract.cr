require "./frame"
require "./head_codec"
require "./assembler"
require "../extractor"
require "../upstream"

module Gori::Proxy::H2
  # Session-binding extraction on the h2 relay (#501 slice 2).
  #
  # ## What runs here, and what deliberately does not
  #
  # HEAD-scoped descriptors only — a cookie or a header off the response head. A BODY-scoped
  # descriptor (regex / position / jsonpath) needs the response entity, and on this relay DATA
  # frames stream past untouched: body rewriting on h2 is #492 step 5 and does not exist. So a
  # body-scoped extract rule earns the SAME h2→h1 downgrade a Match&Replace body rule earns
  # (`tls/tunnel.cr#h2_candidate?`), host-scoped per #526/#531 so it costs only the hosts its
  # own glob can match. By the time a stream reaches this file, a body-scoped rule for this
  # host has therefore already moved the connection to `ClientConn`, and what is left here
  # cannot need a body.
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
  # one nil test and a response with no rule live costs one atomic read on top of that.
  #
  # One instance per direction per connection; only the "in" direction ever constructs one.
  class Extract
    def initialize(@extractor : Proxy::ResponseExtract, @assembler : Assembler,
                   @host : String, @port : Int32)
      @warned_unscopable = false
    end

    # Offer a delivered response head to the extract rules. `pre` is the projection the caller
    # already decoded; nil for every frame that is not the end of a header block.
    def observe(frame : Frame::Header, pre : Assembler::HeadBlock?) : Nil
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
      host, _ = Upstream.split_host_port(ref.authority, @port)
      # No entity: DATA is untouched on this relay, and a body-scoped rule for this host would
      # have downgraded the connection before it got here (see the class comment). Passing nil
      # rather than an empty slice is what makes the observer say "there was no body" instead
      # of "the selector found nothing".
      @extractor.observe_response(HeadCodec.synth_response(fields), nil,
        method: ref.method, host: host, target: ref.target, scheme: ref.scheme,
        status: status, flow_id: @assembler.flow_id_of(frame.stream_id))
    rescue ex
      # An extract rule must never be able to break a relayed connection.
      ::Log.warn { "extract rules skipped for an h2 response: #{ex.message}" }
    end

    private def warn_unscopable(stream_id : UInt32) : Nil
      return if @warned_unscopable
      @warned_unscopable = true
      ::Log.warn do
        "h2 in: stream #{stream_id} is not tracked (over #{Assembler::MAX_LIVE_STREAMS} live " \
        "streams), so its response has no request target to scope a session-binding extract " \
        "rule against — nothing was extracted from it"
      end
    end
  end
end
