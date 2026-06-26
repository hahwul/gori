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

    # Bounds on chunked framing lines so a hostile peer can't make us buffer/forward
    # unboundedly after the terminating 0-chunk: a single size/trailer line is capped
    # at MAX_LINE_BYTES, and the whole trailer section at MAX_TRAILER_BYTES. Both are
    # vastly larger than any legitimate chunk-size or trailer header; overflow is a
    # framing error (→ close), consistent with the malformed-chunk-size handling.
    MAX_LINE_BYTES    = 64 * 1024
    MAX_TRAILER_BYTES = 256 * 1024

    # Ceiling on a single captured request/response body. Forwarding is never
    # capped (it streams byte-exact); this only bounds what we buffer for the DB,
    # so a multi-GB download can't OOM the proxy or bloat one row. Tune as needed.
    CAPTURE_MAX = 8 * 1024 * 1024 # 8 MiB

    # RFC 7230 §3.3.3 framing for a request body.
    def self.request_framing(req : RawRequest) : {BodyFraming, Int64}
      if chunked?(req.headers.get_all("Transfer-Encoding"))
        reject_te_with_cl(req.headers)
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
        reject_te_with_cl(resp.headers)
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
      read_complete(src, framing, length)[0]
    end

    # As `read`, but also returns whether the body completed (false = a
    # Content-Length/chunked body the origin cut short). Lets the Replay engine
    # flag a half-delivered response instead of presenting it as whole.
    def self.read_complete(src : IO, framing : BodyFraming, length : Int64) : {Bytes?, Bool}
      return {nil, true} if framing.none?
      capture = IO::Memory.new
      complete = stream(src, capture, framing, length, IO::Memory.new) # tee discarded
      {capture.to_slice.dup, complete}
    end

    # RFC 7230 §3.3.1: `chunked` must be the FINAL transfer-coding. Accept it only
    # when it's the last token of the (comma-joined) Transfer-Encoding; a non-final
    # or obfuscated placement (`chunked, gzip`, a repeated `chunked`) is a framing
    # error a proxy MUST reject — a TE-desync / request-smuggling vector — so raise
    # to close the connection rather than guess. (A token like `xchunked` simply
    # isn't `chunked` and yields no body framing here.)
    private def self.chunked?(transfer_encodings : Array(String)) : Bool
      tokens = transfer_encodings.flat_map(&.split(',')).map(&.strip.downcase).reject(&.empty?)
      return false if tokens.empty?
      final_chunked = tokens.last == "chunked"
      earlier = final_chunked ? tokens[0...-1] : tokens
      raise Gori::Error.new("chunked transfer-coding is not final") if earlier.includes?("chunked")
      final_chunked
    end

    # RFC 7230 §3.3.3: a message with BOTH Transfer-Encoding and Content-Length is
    # a framing ambiguity (the classic CL.TE / TE.CL smuggling primitive). gori
    # never strips a header (P7), so reject and close instead of choosing one.
    private def self.reject_te_with_cl(headers : HeaderList) : Nil
      return if headers.get_all("Content-Length").empty?
      raise Gori::Error.new("Transfer-Encoding and Content-Length both present")
    end

    private def self.content_length(headers : HeaderList) : Int64?
      values = headers.get_all("Content-Length")
      return nil if values.empty?
      # A header line may itself be a comma list ("5, 5"); split + parse each token.
      # RFC 7230 §3.3.3: any non-numeric token, a negative value, or two DIFFERENT
      # values is a framing error a proxy MUST reject (a request-smuggling vector) —
      # raise so the connection is closed rather than guessing a length. Repeated
      # identical values collapse to one. No header at all → nil (no body / close-
      # delimited, as before).
      tokens = values.flat_map(&.split(',')).map(&.strip).reject(&.empty?)
      return nil if tokens.empty?
      nums = tokens.map { |t| t.to_i64? || raise Gori::Error.new("invalid Content-Length #{t.inspect}") }
      raise Gori::Error.new("conflicting Content-Length values") if nums.uniq.size > 1
      n = nums.first
      raise Gori::Error.new("negative Content-Length #{n}") if n < 0
      n
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
        # A malformed / out-of-range chunk size is NOT a terminating chunk: bailing
        # out (false → caller closes) avoids reading a fabricated 0 as the end of
        # the body and leaving the rest on the wire for the next keep-alive message
        # to misframe (request-smuggling / response-desync).
        return false if size.nil?
        if size == 0
          # consume trailers (header lines) up to and including the blank line,
          # bounded so a peer that never sends the blank line (or streams endless
          # trailer lines) can't pin/forward unboundedly — abort (→ close) on overrun.
          trailer_total = 0_i64
          loop do
            trailer = read_crlf_line(src)
            break if trailer.nil? # clean EOF after the 0-chunk — tolerate (as before)
            emit(dst, tee, trailer)
            trailer_total += trailer.size
            return false if trailer_total > MAX_TRAILER_BYTES
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
    # Stops buffering at `max_size` even without an LF, so a pathological line with
    # no terminator can't grow memory unbounded; the partial (LF-less) line then
    # fails the caller's framing check (bad chunk-size / never-blank trailer → close).
    private def self.read_crlf_line(io : IO, max_size : Int32 = MAX_LINE_BYTES) : Bytes?
      buf = IO::Memory.new
      while byte = io.read_byte
        buf.write_byte(byte)
        break if byte == 0x0a_u8 # LF
        break if buf.bytesize >= max_size
      end
      buf.bytesize == 0 ? nil : buf.to_slice.dup
    end

    private def self.read_exact(io : IO, n : Int32) : Bytes?
      buf = Bytes.new(n)
      read = io.read_fully?(buf)
      read ? buf : nil
    end

    # Parse a chunk-size line: hex digits before any ';' chunk-extension. Returns
    # nil for a malformed, signed, or out-of-range size so the caller can abort
    # (a fabricated 0 would be read as the terminating chunk and desync the body).
    private def self.parse_chunk_size(line : Bytes) : Int64?
      s = String.new(line).strip
      semi = s.index(';')
      hex = (semi ? s[0...semi] : s).strip
      # Pure hex only: to_i64?(base:16) would otherwise accept a leading '+' (and the
      # >= 0 guard only catches '-'), a weak smuggling primitive vs a stricter peer.
      return nil if hex.empty? || !hex.each_char.all?(&.to_i?(16))
      n = hex.to_i64?(base: 16)
      n && n >= 0 ? n : nil
    end

    private def self.blank_line?(line : Bytes) : Bool
      line.size <= 2 # "\r\n" or "\n"
    end
  end
end
