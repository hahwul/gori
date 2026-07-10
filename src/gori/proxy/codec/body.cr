require "./message"
require "./http1"

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

  # A write-only sink that discards everything (no buffering). Used as `Body.stream`'s
  # `tee` when the caller only needs the `dst` copy (e.g. `read_complete`), so the body
  # isn't accumulated a second time.
  class DiscardIO < IO
    def write(slice : Bytes) : Nil
    end

    def read(slice : Bytes) : Int32
      raise NotImplementedError.new("DiscardIO is write-only")
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
    # so a multi-GB download can't OOM the proxy or bloat one row. The TRUE wire
    # size is preserved in request_size/response_size regardless of this cap, so
    # lowering it only trims the stored BLOB, never the reported size. 2 MiB keeps
    # whole HTML/JS/JSON/API bodies while cutting the multi-MB media/protobuf tail
    # that dominated DB growth (a single 8 MiB Safe-Browsing blob was ~25% of one
    # capture). Tune as needed.
    CAPTURE_MAX = 2 * 1024 * 1024 # 2 MiB

    # RFC 7230 §3.3.3 framing for a request body.
    def self.request_framing(req : RawRequest) : {BodyFraming, Int64}
      # A header written as `Transfer-Encoding : chunked` (whitespace before colon) or
      # obs-folded is invisible to the exact-match framing lookups below, yet a lenient
      # backend still honours it — a CL/TE request-smuggling primitive. Reject up front,
      # like CL+TE, rather than framing on a header we can't see (RFC 7230 §3.2.4).
      raise Gori::Error.new("obfuscated request header (whitespace before colon or obs-fold)") if Http1.obfuscated_header?(req.raw_head)
      te = req.headers.get_all("Transfer-Encoding")
      if chunked?(te)
        reject_te_with_cl(req.headers)
        {BodyFraming::Chunked, 0_i64}
      elsif te_present?(te)
        # A REQUEST whose Transfer-Encoding's final coding isn't `chunked` (e.g.
        # `Transfer-Encoding: gzip`) has no reliable body length — RFC 7230 §3.3.3 rule 3.
        # A proxy MUST NOT guess: falling through to Content-Length (or a body-less frame)
        # would leave the real body on the wire to be misframed as the next pipelined
        # request — a TE desync / request-smuggling vector. Reject + close, like the
        # non-final-chunked case. (Responses differ: a non-chunked TE there legitimately
        # means close-delimited, so response_framing keeps that path.)
        raise Gori::Error.new("non-chunked Transfer-Encoding on request")
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

      te = resp.headers.get_all("Transfer-Encoding")
      if chunked?(te)
        reject_te_with_cl(resp.headers)
        {BodyFraming::Chunked, 0_i64}
      elsif te_present?(te)
        # RFC 7230 §3.3.3 rule 3: a response with a non-chunked Transfer-Encoding (e.g.
        # `identity`/`gzip`) is close-delimited — TE takes precedence over any Content-Length
        # (the CL.TE ambiguity). Framing by CL would leave the real body on the wire to
        # misframe the next response on a reused upstream (a response-desync primitive).
        {BodyFraming::CloseDelimited, 0_i64}
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
      # The body is already buffered once in `capture`; tee into a discard sink rather than
      # a second IO::Memory so a large response isn't held in memory TWICE (the old
      # `IO::Memory.new` tee doubled peak RAM on every replay/read_complete).
      complete = stream(src, capture, framing, length, DiscardIO.new)
      {capture.to_slice.dup, complete}
    end

    # RFC 7230 §3.3.1: `chunked` must be the FINAL transfer-coding. Accept it only
    # when it's the last token of the (comma-joined) Transfer-Encoding; a non-final
    # or obfuscated placement (`chunked, gzip`, a repeated `chunked`) is a framing
    # error a proxy MUST reject — a TE-desync / request-smuggling vector — so raise
    # to close the connection rather than guess. (A token like `xchunked` simply
    # isn't `chunked` and yields no body framing here.)
    # Whether any non-empty transfer-coding token is present (an empty/blank
    # Transfer-Encoding header carries none, so it isn't "present" for framing).
    private def self.te_present?(transfer_encodings : Array(String)) : Bool
      transfer_encodings.any? { |v| v.split(',').any? { |t| !t.strip.empty? } }
    end

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
      # RFC 7230 §3.3.3: Content-Length is 1*DIGIT. `to_i64?` alone would accept a leading
      # '+' (the `n < 0` guard below only rejects '-'), so `Content-Length: +5` would frame
      # a 5-byte body that a stricter peer rejects/reinterprets — a CL desync primitive.
      # Mirror parse_chunk_size's pure-digit guard and reject any non-digit token.
      nums = tokens.map do |t|
        unless t.each_char.all?(&.ascii_number?)
          raise Gori::Error.new("invalid Content-Length #{t.inspect}")
        end
        t.to_i64? || raise Gori::Error.new("invalid Content-Length #{t.inspect}")
      end
      raise Gori::Error.new("conflicting Content-Length values") if nums.uniq.size > 1
      n = nums.first
      raise Gori::Error.new("negative Content-Length #{n}") if n < 0
      n
    end

    # Copies exactly `n` bytes; returns false if the source EOF'd early (a
    # truncated Content-Length body), true once all `n` were transferred.
    # `buf` is the scratch copy buffer. The Length-framing caller lets it default to a
    # fresh 64 KiB slice (one alloc per body); copy_chunked passes ONE buffer reused
    # across every chunk (a chunked body used to allocate a fresh 64 KiB per chunk — a
    # 100 MB response in 16 KB chunks churned ~400 MB of throwaway buffers). Safe to
    # share: a body is pumped one direction on one fiber, so chunks copy sequentially.
    private def self.copy_n(src : IO, dst : IO, tee : IO, n : Int64, buf : Bytes = Bytes.new(BUFSIZE)) : Bool
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
      buf = Bytes.new(BUFSIZE) # reused across every chunk's copy_n (see copy_n)
      loop do
        size_line = read_crlf_line(src)
        # EOF before any byte → truncated mid-stream. A line that hit MAX_LINE_BYTES WITHOUT an
        # LF is also unterminated: parse_chunk_size could still read a valid-looking size from the
        # partial (all-'0' → 0 terminating chunk; '5;<oversized ext>' → 5), leaving the rest of the
        # line on the wire to desync the next message. A real chunk-size line always ends in LF.
        return false if size_line.nil?
        return false unless size_line[size_line.size - 1] == 0x0a_u8
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
            # Clean EOF after the 0-chunk → tolerate (as before). But an unterminated (LF-less,
            # cap-truncated) trailer line is a framing error: forwarding it and keeping the
            # connection alive would leak the line remainder onto the wire to misframe the next
            # message — abort and close instead.
            break if trailer.nil?
            return false unless trailer[trailer.size - 1] == 0x0a_u8
            emit(dst, tee, trailer)
            trailer_total += trailer.size
            return false if trailer_total > MAX_TRAILER_BYTES
            break if blank_line?(trailer)
          end
          return true # terminating chunk reached
        end
        return false unless copy_n(src, dst, tee, size, buf) # truncated mid-chunk
        if crlf = read_exact(src, 2)                         # the CRLF terminating the chunk data
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

    # A trailer-section blank line is JUST the terminator ("\r\n" / "\n"). Size
    # alone is wrong: a 1-char trailer with a bare-LF terminator ("X\n") is also
    # 2 bytes but NOT blank — treating it as the terminator would break the loop
    # early, leaving the real blank line on the wire to desync the next keep-alive
    # request. Check content (terminator octets only), not length.
    private def self.blank_line?(line : Bytes) : Bool
      line.all? { |b| b == 0x0d_u8 || b == 0x0a_u8 }
    end
  end
end
