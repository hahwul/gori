require "./frame"
require "./assembler"
require "../sink"

module Gori::Proxy::H2
  # A transparent HTTP/2 relay. Once ALPN negotiated "h2" on BOTH the client and
  # upstream legs, gori forwards the client preface and every subsequent frame in
  # both directions byte-faithfully (P7), capturing each raw frame to the sink.
  #
  # This slice does NOT decode HPACK or assemble streams — it proves end-to-end
  # h2 passthrough plus the raw frame log. Higher layers (HPACK, stream→flow)
  # read that log. Forwarding happens BEFORE capture so a slow writer never
  # delays the peer (same discipline as the WebSocket relay).
  class Relay
    def self.run(client : IO, upstream : IO, host : String, port : Int32, sink : FlowSink) : Nil
      new(client, upstream, host, port, sink).run
    end

    def initialize(@client : IO, @upstream : IO, @host : String, @port : Int32, @sink : FlowSink)
    end

    def run : Nil
      conn_id = @sink.on_h2_open(@host, @port, "h2")
      assembler = Assembler.new(@sink, @host, @port, now_us, conn_id)
      begin
        # The client preface (RFC 7540 §3.5) precedes any frame; forward verbatim.
        @upstream.write(Frame.read_preface(@client))
        @upstream.flush

        done = Channel(Nil).new(2)
        spawn { pump(@client, @upstream, conn_id, "out", assembler); done.send(nil) }
        spawn { pump(@upstream, @client, conn_id, "in", assembler); done.send(nil) }
        2.times { done.receive }
      rescue
        # handshake/preface failure: nothing decodable to relay
      ensure
        # Flush any stream still open at connection close (never got END_STREAM on
        # both halves) so it doesn't sit Pending forever.
        assembler.finalize_all("h2 connection closed")
      end
    end

    private def pump(src : IO, dst : IO, conn_id : Int64, direction : String, assembler : Assembler) : Nil
      loop do
        frame = Frame.read(src)
        break if frame.nil?         # clean EOF at a frame boundary
        dst.write(frame.wire_bytes) # original wire bytes — no re-serialize/copy
        dst.flush
        @sink.on_h2_frame(conn_id, direction, frame.type, frame.flags, frame.stream_id, frame.payload)
        assembler.feed(direction, frame)
      end
    rescue
      # peer reset / parse error ends this direction
    ensure
      dst.close rescue nil # propagate close so the opposite pump unblocks
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
