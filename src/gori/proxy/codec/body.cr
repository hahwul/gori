require "./message"

# Byte-exact HTTP/1.1 message-body framing + streaming (P6/P7).
#
# `stream` copies the body from `src` to `dst` while teeing every wire octet to
# `tee` (the capture buffer). The captured truth is the *transfer/wire* form:
# for chunked bodies the chunk framing is preserved (decoding is a derived view,
# done later if ever). We never buffer the whole body — large/SSE bodies stream.
module Gori::Proxy::Codec
  enum BodyFraming
    None           # no message body
    Length         # Content-Length: N
    Chunked        # Transfer-Encoding: chunked
    CloseDelimited # body runs until the connection closes (responses only)
  end

  # A write-only capture sink for body bytes that stores at most `limit` octets
  # so one huge transfer can't OOM the proxy, while still counting the TRUE wire
  # size. The forwarded copy (the `dst` of `Body.stream`) is always complete and
  # byte-exact (P6/P7); only this captured copy — what lands in the DB as a BLOB
  # — is bounded. `truncated?` flips once more than `limit` bytes arrive.
  class CaptureBuffer < IO
    getter total : Int64 = 0_i64
    getter? truncated : Bool = false

    def initialize(@limit : Int32)
      @mem = IO::Memory.new
    end

    def write(slice : Bytes) : Nil
      @total += slice.size
      stored = @mem.bytesize
      if stored < @limit
        room = @limit - stored
        if slice.size <= room
          @mem.write(slice)
        else
          @mem.write(slice[0, room])
          @truncated = true
        end
      elsif !slice.empty?
        @truncated = true
      end
    end

    # Write-only: the body codec only ever tees into this.
    def read(slice : Bytes) : Int32
      raise NotImplementedError.new("CaptureBuffer is write-only")
    end

    # The captured (possibly truncated) bytes — a fresh copy safe to persist.
    def to_slice : Bytes
      @mem.to_slice.dup
    end
  end

  module Body
    BUFSIZE = 64 * 1024

    # Ceiling on a single captured request/response body. Forwarding is never
    # capped (it streams byte-exact); this only bounds what we buffer for the DB,
    # so a multi-GB download can't OOM the proxy or bloat one row. Tune as needed.
    CAPTURE_MAX = 8 * 1024 * 1024 # 8 MiB

    # RFC 7230 §3.3.3 framing for a request body.
    def self.request_framing(req : RawRequest) : {BodyFraming, Int64}
      if chunked?(req.headers.get_all("Transfer-Encoding"))
        {BodyFraming::Chunked, 0_i64}
      elsif cl = content_length(req.headers)
        {BodyFraming::Length, cl}
      else
        {BodyFraming::None, 0_i64}
      end
    end

    # RFC 7230 §3.3.3 framing for a response body, given the request method.
    def self.response_framing(resp : RawResponse, request_method : String) : {BodyFraming, Int64}
      m = request_method.upcase
      return {BodyFraming::None, 0_i64} if m == "HEAD" || m == "CONNECT"
      s = resp.status
      return {BodyFraming::None, 0_i64} if (s >= 100 && s < 200) || s == 204 || s == 304

      if chunked?(resp.headers.get_all("Transfer-Encoding"))
        {BodyFraming::Chunked, 0_i64}
      elsif cl = content_length(resp.headers)
        {BodyFraming::Length, cl}
      else
        {BodyFraming::CloseDelimited, 0_i64}
      end
    end

    # Stream the body src->dst, teeing wire bytes to `tee`. Tolerant of premature
    # EOF (captures what arrived rather than raising, per P7) but RETURNS whether
    # the body completed: false means a Content-Length/chunked body was cut short,
    # so the caller must close the connection (a half-delivered body can't be
    # followed by a keep-alive request without desyncing the peer).
    def self.stream(src : IO, dst : IO, framing : BodyFraming, length : Int64, tee : IO) : Bool
      complete =
        case framing
        in BodyFraming::None           then true
        in BodyFraming::Length         then copy_n(src, dst, tee, length)
        in BodyFraming::CloseDelimited then (copy_until_eof(src, dst, tee); true) # EOF is the framing
        in BodyFraming::Chunked        then copy_chunked(src, dst, tee)
        end
      dst.flush
      complete
    end

    # Reads a message body (by framing) into a single buffer — used by the Replay
    # engine to capture a response without forwarding it anywhere.
    def self.read(src : IO, framing : BodyFraming, length : Int64) : Bytes?
      return nil if framing.none?
      capture = IO::Memory.new
      stream(src, capture, framing, length, IO::Memory.new) # tee discarded
      capture.to_slice.dup
    end

    private def self.chunked?(transfer_encodings : Array(String)) : Bool
      transfer_encodings.any?(&.downcase.includes?("chunked"))
    end

    private def self.content_length(headers : HeaderList) : Int64?
      headers.get?("Content-Length").try(&.strip.to_i64?)
    end

    # Copies exactly `n` bytes; returns false if the source EOF'd early (a
    # truncated Content-Length body), true once all `n` were transferred.
    private def self.copy_n(src : IO, dst : IO, tee : IO, n : Int64) : Bool
      buf = Bytes.new(BUFSIZE)
      remaining = n
      while remaining > 0
        want = remaining < BUFSIZE ? remaining.to_i : BUFSIZE
        read = src.read(buf[0, want])
        break if read == 0 # premature EOF
        slice = buf[0, read]
        dst.write(slice)
        tee.write(slice)
        remaining -= read
      end
      remaining == 0
    end

    private def self.copy_until_eof(src : IO, dst : IO, tee : IO) : Nil
      buf = Bytes.new(BUFSIZE)
      while (read = src.read(buf)) > 0
        slice = buf[0, read]
        dst.write(slice)
        tee.write(slice)
      end
    end

    # Returns true once the terminating 0-length chunk is seen; false if the
    # source EOF'd mid-stream (a truncated chunked body).
    private def self.copy_chunked(src : IO, dst : IO, tee : IO) : Bool
      loop do
        size_line = read_crlf_line(src)
        return false if size_line.nil? # EOF mid-stream — truncated
        emit(dst, tee, size_line)
        size = parse_chunk_size(size_line)
        if size == 0
          # consume trailers (header lines) up to and including the blank line
          loop do
            trailer = read_crlf_line(src)
            break if trailer.nil?
            emit(dst, tee, trailer)
            break if blank_line?(trailer)
          end
          return true # terminating chunk reached
        end
        return false unless copy_n(src, dst, tee, size) # truncated mid-chunk
        if crlf = read_exact(src, 2)                    # the CRLF terminating the chunk data
          emit(dst, tee, crlf)
        end
      end
    end

    private def self.emit(dst : IO, tee : IO, bytes : Bytes) : Nil
      dst.write(bytes)
      tee.write(bytes)
    end

    # Reads up to and including the next LF. Returns nil on EOF before any byte.
    private def self.read_crlf_line(io : IO) : Bytes?
      buf = IO::Memory.new
      while byte = io.read_byte
        buf.write_byte(byte)
        break if byte == 0x0a_u8 # LF
      end
      buf.bytesize == 0 ? nil : buf.to_slice.dup
    end

    private def self.read_exact(io : IO, n : Int32) : Bytes?
      buf = Bytes.new(n)
      read = io.read_fully?(buf)
      read ? buf : nil
    end

    # Parse a chunk-size line: hex digits before any ';' chunk-extension.
    private def self.parse_chunk_size(line : Bytes) : Int64
      s = String.new(line).strip
      semi = s.index(';')
      hex = semi ? s[0...semi] : s
      hex.to_i64?(base: 16) || 0_i64
    end

    private def self.blank_line?(line : Bytes) : Bool
      line.size <= 2 # "\r\n" or "\n"
    end
  end
end
