require "./frame"
require "./assembler"
require "./head_rewrite"
require "./stream_gate"
require "./extract"
require "../head_rewriter"
require "../extractor"
require "../sink"
require "../../interceptor"

module Gori::Proxy::H2
  # A transparent HTTP/2 relay. Once ALPN negotiated "h2" on BOTH the client and
  # upstream legs, gori forwards the client preface and every subsequent frame in
  # both directions byte-faithfully (P7), capturing each raw frame to the sink.
  #
  # Forwarding happens BEFORE capture so a slow writer never delays the peer (same
  # discipline as the WebSocket relay). The ONE exception is a header block when a
  # `rewriter` is wired in: a rewritten head does not exist to forward until END_HEADERS
  # has arrived and the rules have run. See `HeadRewrite` for why that costs nothing here
  # and why DATA deliberately keeps the forward-first path (#492 step 2).
  #
  # With neither a `rewriter` nor an `interceptor` this is exactly the byte-faithful relay it
  # has always been — no head pipeline, and no locking on the frame path.
  #
  # An `interceptor` adds a `StreamGate` per direction, which holds streams INDIVIDUALLY: the
  # pump never blocks on a human, so a held stream does not freeze the connection (#492 step 3).
  class Relay
    def self.run(client : IO, upstream : IO, host : String, port : Int32, sink : FlowSink,
                 rewriter : Proxy::HeadRewriter? = nil, interceptor : Gori::Interceptor? = nil,
                 extractor : Proxy::ResponseExtract? = nil) : Nil
      new(client, upstream, host, port, sink, rewriter, interceptor, extractor).run
    end

    def initialize(@client : IO, @upstream : IO, @host : String, @port : Int32, @sink : FlowSink,
                   @rewriter : Proxy::HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @extractor : Proxy::ResponseExtract? = nil)
    end

    def run : Nil
      conn_id = @sink.on_h2_open(@host, @port, "h2")
      assembler = Assembler.new(@sink, @host, @port, now_us, conn_id)
      begin
        # The client preface (RFC 7540 §3.5) precedes any frame; forward verbatim.
        @upstream.write(Frame.read_preface(@client))
        @upstream.flush

        out_gate, in_gate = gates(conn_id, assembler)
        done = Channel(Nil).new(2)
        spawn { pump(@client, @upstream, conn_id, "out", assembler, out_gate); done.send(nil) }
        spawn { pump(@upstream, @client, conn_id, "in", assembler, in_gate); done.send(nil) }
        2.times { done.receive }
      rescue
        # handshake/preface failure: nothing decodable to relay
      ensure
        # Flush any stream still open at connection close (never got END_STREAM on
        # both halves) so it doesn't sit Pending forever. Runs after BOTH pumps have closed
        # their gates, so a stream held at teardown has already been projected.
        assembler.finalize_all("h2 connection closed")
      end
    end

    # The two gates, PAIRED — a drop has to reset the opposite leg, and each gate reaches the
    # other only through `peer`. {nil, nil} when intercept is off, so a relay without it keeps
    # exactly the frame path (and the zero locking) it has today.
    private def gates(conn_id : Int64, assembler : Assembler) : {StreamGate?, StreamGate?}
      ic = @interceptor
      return {nil, nil} unless ic
      out_gate = StreamGate.new("out", @upstream, conn_id, @sink, assembler, @host, @port, ic,
        HeadRewrite.new("out", @rewriter, assembler, @host))
      in_gate = StreamGate.new("in", @client, conn_id, @sink, assembler, @host, @port, ic,
        HeadRewrite.new("in", @rewriter, assembler, @host), extract_for(assembler))
      out_gate.peer = in_gate
      in_gate.peer = out_gate
      {out_gate, in_gate}
    end

    private def pump(src : IO, dst : IO, conn_id : Int64, direction : String,
                     assembler : Assembler, gate : StreamGate?) : Nil
      if gate
        pump_gated(src, gate)
      else
        pump_plain(src, dst, conn_id, direction, assembler)
      end
    ensure
      dst.close rescue nil # propagate close so the opposite pump unblocks
    end

    private def pump_gated(src : IO, gate : StreamGate) : Nil
      loop do
        frame = Frame.read(src)
        break if frame.nil? # clean EOF at a frame boundary
        gate.accept(frame)
      end
    rescue
      # peer reset / parse error ends this direction
    ensure
      # Releases the rewriter's partial block, hands every still-held item back to the
      # Interceptor, and projects what was held.
      gate.close rescue nil
    end

    # The response-side extract observer, or nil when no extract rule could ever fire. Built per
    # connection because it carries a once-per-connection warning latch.
    private def extract_for(assembler : Assembler) : Extract?
      ex = @extractor
      ex ? Extract.new(ex, assembler, @host, @port) : nil
    end

    private def pump_plain(src : IO, dst : IO, conn_id : Int64, direction : String,
                           assembler : Assembler) : Nil
      rw = @rewriter
      heads = rw ? HeadRewrite.new(direction, rw, assembler, @host) : nil
      extract = direction == "in" ? extract_for(assembler) : nil
      begin
        loop do
          frame = Frame.read(src)
          break if frame.nil? # clean EOF at a frame boundary
          if heads
            heads.accept(frame) { |f, pre| emit(dst, conn_id, direction, assembler, f, pre, extract) }
          else
            emit(dst, conn_id, direction, assembler, frame, nil, extract)
          end
        end
      rescue
        # peer reset / parse error ends this direction
      ensure
        # A header block still buffered at teardown never got END_HEADERS — release it
        # rather than swallowing frames the peer did send (P7). The write can itself fail
        # (this path is usually reached BECAUSE the peer went away), which is fine: the
        # capture and the projection are what still matter here.
        if h = heads
          h.drain { |f, pre| emit(dst, conn_id, direction, assembler, f, pre, extract) rescue nil }
        end
      end
    end

    # Forward one frame, then capture it, then project it. Order is deliberate for every
    # frame the rewrite path does not hold back: a slow writer must never delay the peer
    # (P6). `pre` is the already-decoded projection for a header block the rewrite path
    # owns — the assembler must not decode such a block a second time.
    private def emit(dst : IO, conn_id : Int64, direction : String, assembler : Assembler,
                     frame : Frame::Header, pre : Assembler::HeadBlock?, extract : Extract? = nil) : Nil
      dst.write(frame.wire_bytes) # original wire bytes when untouched — no re-serialize/copy
      dst.flush
      @sink.on_h2_frame(conn_id, direction, frame.type, frame.flags, frame.stream_id, frame.payload)
      assembler.feed(direction, frame, pre)
      # Session-binding extraction (#501 slice 2), after the frame is on the wire.
      extract.try(&.observe(frame, pre))
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
