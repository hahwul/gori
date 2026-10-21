require "socket"

# A real h2 client and a real h2 origin on either side of `H2::Relay` over 127.0.0.1 (#1628),
# shared by the specs of the relay's rule path (`body_rule_spec`, `stub_spec`). Both peers keep
# flow control honestly: each tracks its receive windows and records a FLOW_CONTROL_ERROR the
# moment one goes negative, and each sends only what its send windows allow.
module H2FlowRig
  alias Frame = Gori::Proxy::H2::Frame
  alias HPACK = Gori::Proxy::H2::HPACK

  class Sink < Gori::Proxy::FlowSink
    getter requests = [] of Gori::Store::CapturedRequest
    getter responses = [] of Gori::Store::CapturedResponse
    @id = 0_i64

    def on_request(req : Gori::Store::CapturedRequest) : Int64
      @requests << req
      @id += 1
    end

    def on_response(resp : Gori::Store::CapturedResponse) : Nil
      @responses << resp
    end

    def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                      shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
    end
  end

  # One h2 endpoint that keeps both of its windows the way RFC 9113 §6.9 says a peer must.
  class Peer
    getter errors = [] of String
    getter heads = {} of UInt32 => Array({String, String})
    getter trailers = {} of UInt32 => Array({String, String})
    getter bodies = Hash(UInt32, IO::Memory).new { |h, k| h[k] = IO::Memory.new }
    getter data_frames = Hash(UInt32, Array(Int32)).new { |h, k| h[k] = [] of Int32 }
    getter done = [] of UInt32
    # RST_STREAMs and GOAWAYs received — expected in some examples, so kept apart from `errors`.
    getter resets = [] of UInt32
    getter goaways = 0
    property on_complete : Proc(UInt32, Nil)? = nil
    # Called (on its own fiber) when a stream's first head arrives.
    property on_open : Proc(UInt32, Nil)? = nil
    # Stream credit is held back until this much is owed, the way curl/nghttp2 and Firefox ack a
    # wide per-stream window: late. 0 = every frame.
    property stream_ack = 0_i64
    # While set, connection credit is held back until `release_conn`: a reader that stopped.
    property? hold_conn = false
    @held_conn = 0

    # Both connection windows, readable once the exchange is at rest: the sender's view of the
    # receiver's window has to equal the receiver's own, or credit was stranded or invented.
    getter send_conn = 65_535_i64
    getter recv_conn = 65_535_i64

    # `lag` delays every WINDOW_UPDATE this peer sends, the way a slow reader does. Credit then
    # trails the data, which is when a sender trusting a window it was not given overruns it.
    def initialize(@io : IO, @server : Bool, @recv_initial : Int64 = 65_535_i64, @lag : Time::Span? = nil)
      @mutex = Mutex.new
      @enc = HPACK::Encoder.new
      @dec = HPACK::Decoder.new
      @send_initial = 65_535_i64
      @send_streams = {} of UInt32 => Int64
      @recv_streams = {} of UInt32 => Int64
      @block = IO::Memory.new
      @block_stream = 0_u32
      @block_end = false
      @closing = false
      @unacked = Hash(UInt32, Int64).new(0_i64)
    end

    # Widen one stream's receive window by `n` up front.
    def bump(stream : UInt32, n : Int32) : Nil
      @recv_streams[stream] = recv_window(stream) + n
      window_update(stream, n)
    end

    # Announce a new SETTINGS_INITIAL_WINDOW_SIZE; every open stream's window moves with it.
    def change_initial(value : Int64) : Nil
      delta = value - @recv_initial
      @recv_initial = value
      @recv_streams.each_key { |k| @recv_streams[k] += delta }
      payload = Bytes.new(6)
      IO::ByteFormat::BigEndian.encode(0x4_u16, payload[0, 2])
      IO::ByteFormat::BigEndian.encode(value.to_u32, payload[2, 4])
      frame(Frame::Type::Settings, 0_u8, 0_u32, payload)
    end

    def send_rst(stream : UInt32) : Nil
      frame(Frame::Type::RstStream, 0_u8, stream, Bytes[0, 0, 0, 8])
    end

    def send_goaway(last : UInt32) : Nil
      payload = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(last, payload[0, 4])
      frame(Frame::Type::Goaway, 0_u8, 0_u32, payload)
    end

    private def recv_window(stream : UInt32) : Int64
      @recv_streams[stream]? || @recv_initial
    end

    def start : Nil
      @io.write(Frame::PREFACE) unless @server
      payload = Bytes.empty
      if @recv_initial != 65_535
        payload = Bytes.new(6)
        IO::ByteFormat::BigEndian.encode(0x4_u16, payload[0, 2])
        IO::ByteFormat::BigEndian.encode(@recv_initial.to_u32, payload[2, 4])
      end
      frame(Frame::Type::Settings, 0_u8, 0_u32, payload)
      spawn { read_loop }
    end

    def close : Nil
      @closing = true
      @io.close rescue nil
    end

    # One DATA frame as given, padding and all — outside the window bookkeeping, so keep it small.
    def send_raw_data(stream : UInt32, payload : Bytes, flags : UInt8) : Nil
      @mutex.synchronize do
        @send_conn -= payload.size
        @send_streams[stream] = send_window(stream) - payload.size
      end
      frame(Frame::Type::Data, flags, stream, payload)
    end

    def send_head(stream : UInt32, fields : Array({String, String}), end_stream : Bool) : Nil
      @mutex.synchronize do
        block = @enc.encode(fields)
        flags = Frame::END_HEADERS | (end_stream ? Frame::END_STREAM : 0_u8)
        @io.write(Frame::Header.new(Frame::Type::Headers.value, flags, stream, block).to_bytes)
        @io.flush
      end
    end

    # Only as fast as the windows allow, in frames of at most 16 KiB.
    def send_body(stream : UInt32, body : Bytes, end_stream : Bool) : Nil
      at = 0
      loop do
        left = body.size - at
        if left == 0
          frame(Frame::Type::Data, Frame::END_STREAM, stream, Bytes.empty) if end_stream
          return
        end
        avail = wait_window(stream) || return
        take = {left, 16_384, avail}.min
        last = at + take == body.size
        @mutex.synchronize do
          @send_conn -= take
          @send_streams[stream] = send_window(stream) - take
        end
        frame(Frame::Type::Data, last && end_stream ? Frame::END_STREAM : 0_u8, stream, body[at, take])
        at += take
        return if last
      end
    end

    def send(stream : UInt32, fields : Array({String, String}), body : Bytes,
             trailer : Array({String, String})? = nil) : Nil
      send_head(stream, fields, body.empty? && trailer.nil?)
      send_body(stream, body, trailer.nil?) unless body.empty?
      send_head(stream, trailer, true) if trailer
    end

    def wait_done(stream : UInt32, timeout = 10.seconds) : Bool
      deadline = Time.instant + timeout
      until @done.includes?(stream)
        return false if Time.instant > deadline || !@errors.empty?
        sleep 2.milliseconds
      end
      true
    end

    def body_of(stream : UInt32) : String
      String.new(bodies[stream].to_slice)
    end

    def send_window(stream : UInt32) : Int64
      @send_streams[stream]? || @send_initial
    end

    def release_conn : Nil
      @hold_conn = false
      @recv_conn += @held_conn
      window_update(0_u32, @held_conn) if @held_conn > 0
      @held_conn = 0
    end

    private def wait_window(stream : UInt32) : Int32?
      deadline = Time.instant + 10.seconds
      loop do
        avail = Math.min(@send_conn, send_window(stream))
        return avail.to_i32 if avail > 0
        if Time.instant > deadline
          @errors << "stalled waiting for window on stream #{stream}"
          return nil
        end
        sleep 1.millisecond
      end
    end

    private def frame(type : Frame::Type, flags : UInt8, stream : UInt32, payload : Bytes) : Nil
      @mutex.synchronize do
        @io.write(Frame::Header.new(type.value, flags, stream, payload).to_bytes)
        @io.flush
      end
    end

    private def window_update(stream : UInt32, n : Int32) : Nil
      payload = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(n.to_u32, payload)
      frame(Frame::Type::WindowUpdate, 0_u8, stream, payload)
    end

    private def read_loop : Nil
      Frame.read_preface(@io) if @server
      while f = Frame.read(@io)
        handle(f)
      end
    rescue ex
      @errors << "read: #{ex.message}" unless @closing
    end

    private def handle(f : Frame::Header) : Nil
      case f.frame_type
      when Frame::Type::Settings     then on_settings(f)
      when Frame::Type::WindowUpdate then on_window_update(f)
      when Frame::Type::Headers, Frame::Type::Continuation
        on_headers(f)
      when Frame::Type::Data      then on_data(f)
      when Frame::Type::RstStream then @resets << f.stream_id
      when Frame::Type::Goaway    then @goaways += 1
      end
    end

    private def on_settings(f : Frame::Header) : Nil
      return if f.ack?
      at = 0
      while at + 6 <= f.payload.size
        if IO::ByteFormat::BigEndian.decode(UInt16, f.payload[at, 2]) == 0x4
          value = IO::ByteFormat::BigEndian.decode(UInt32, f.payload[at + 2, 4]).to_i64
          delta = value - @send_initial
          @send_initial = value
          @send_streams.each_key { |k| @send_streams[k] += delta }
        end
        at += 6
      end
      frame(Frame::Type::Settings, Frame::ACK, 0_u32, Bytes.empty)
    end

    private def on_window_update(f : Frame::Header) : Nil
      n = (IO::ByteFormat::BigEndian.decode(UInt32, f.payload) & 0x7fff_ffff_u32).to_i64
      @errors << "zero WINDOW_UPDATE on stream #{f.stream_id}" if n == 0
      if f.stream_id == 0
        @send_conn += n
      else
        @send_streams[f.stream_id] = send_window(f.stream_id) + n
      end
    end

    private def on_headers(f : Frame::Header) : Nil
      if f.frame_type == Frame::Type::Headers
        @block.clear
        @block_stream = f.stream_id
        @block_end = f.end_stream?
      end
      @block.write(f.payload)
      return unless f.end_headers?
      fields = @dec.decode(@block.to_slice.dup)
      if heads.has_key?(@block_stream)
        trailers[@block_stream] = fields
      else
        heads[@block_stream] = fields
        stream = @block_stream
        @on_open.try { |cb| spawn { cb.call(stream) } }
      end
      complete(@block_stream) if @block_end
    end

    private def on_data(f : Frame::Header) : Nil
      n = f.payload.size
      @recv_conn -= n
      left = recv_window(f.stream_id) - n
      @recv_streams[f.stream_id] = left
      @errors << "FLOW_CONTROL_ERROR (connection, #{@recv_conn})" if @recv_conn < 0
      @errors << "FLOW_CONTROL_ERROR (stream #{f.stream_id}, #{left})" if left < 0
      bodies[f.stream_id].write(f.payload)
      data_frames[f.stream_id] << n
      credit(f.stream_id, n, f.end_stream?) if n > 0
      complete(f.stream_id) if f.end_stream?
    end

    # Consumed at once, so credited — conn and, while it is open, stream — at once or after `lag`.
    private def credit(stream : UInt32, n : Int32, ended : Bool) : Nil
      if lag = @lag
        spawn do
          sleep lag
          grant(stream, n, ended) rescue nil
        end
      else
        grant(stream, n, ended)
      end
    end

    private def grant(stream : UInt32, n : Int32, ended : Bool) : Nil
      if @hold_conn
        @held_conn += n
      else
        @recv_conn += n
        window_update(0_u32, n)
      end
      return if ended
      @unacked[stream] += n
      return if @unacked[stream] < @stream_ack
      owed = @unacked.delete(stream).not_nil!.to_i32
      @recv_streams[stream] = recv_window(stream) + owed
      window_update(stream, owed)
    end

    private def complete(stream : UInt32) : Nil
      @done << stream
      if cb = @on_complete
        spawn { cb.call(stream) }
      end
    end
  end

  # What the origin answers a finished request with: {head, body, trailers}.
  # nil = the answer block sent (or withheld) the response itself.
  alias Answer = {Array({String, String}), Bytes, Array({String, String})?}?

  class Rig
    getter sink = Sink.new
    getter client : Peer
    getter! origin : Peer
    @servers : Array(TCPServer)

    def initialize(rules : Gori::Rules, ic : Gori::Interceptor, host : String = "127.0.0.1",
                   origin_window : Int64 = 65_535_i64, lag : Time::Span? = nil,
                   client_window : Int64 = 65_535_i64, opened : Proc(UInt32, Peer, Nil)? = nil,
                   &answer : UInt32, Peer -> Answer)
      origin_srv = TCPServer.new("127.0.0.1", 0)
      front = TCPServer.new("127.0.0.1", 0)
      @servers = [origin_srv, front]
      origin_port = origin_srv.local_address.port
      sink = @sink
      spawn do
        next unless conn = origin_srv.accept?
        conn.read_timeout = 15.seconds
        peer = Peer.new(conn, true, origin_window, lag)
        peer.on_complete = ->(stream : UInt32) do
          if reply = answer.call(stream, peer)
            head, body, trailer = reply
            peer.send(stream, head, body, trailer)
          end
          nil
        end
        opened.try { |cb| peer.on_open = ->(stream : UInt32) { cb.call(stream, peer) } }
        @origin = peer
        peer.start
      end
      spawn do
        next unless conn = front.accept?
        upstream = TCPSocket.new("127.0.0.1", origin_port)
        Gori::Proxy::H2::Relay.run(conn, upstream, host, origin_port, sink, rewriter: rules, interceptor: ic)
      end
      socket = TCPSocket.new("127.0.0.1", front.local_address.port)
      socket.read_timeout = 15.seconds
      @client = Peer.new(socket, false, client_window)
      @client.start
    end

    def wait_origin : Peer
      20.times { break if @origin; sleep 10.milliseconds }
      origin
    end

    def close : Nil
      @client.close
      @origin.try(&.close)
      @servers.each { |s| s.close rescue nil }
    end
  end
end
