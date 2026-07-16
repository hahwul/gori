require "compress/gzip"
require "compress/deflate"
require "compress/zlib"
require "./brotli"
require "./zstd"

module Gori::Proxy::Codec
  # Decodes a captured body for DISPLAY: de-chunks the h1 wire form (the stored
  # bytes preserve chunk framing) and inflates the Content-Encoding (gzip/deflate/
  # br/zstd) so compressed responses stop rendering as garbage. This is a DERIVED
  # view only — the stored/forwarded/resent bytes stay byte-faithful (P7). All
  # decoding is tolerant (truncated capture-capped bodies yield partial output, never
  # raise) and output is capped to guard against decompression bombs.
  module ContentDecode
    MAX_OUT = 32 * 1024 * 1024 # decompression-bomb ceiling for the decoded view

    # Returns {decoded | nil, note | nil}. nil decoded => the caller should show the
    # raw body unchanged (no transfer/content coding, or nothing to do). A note
    # describes what was applied ("decoded: gzip") or why it couldn't be ("compressed:
    # br — decode unsupported").
    #
    # `max_out` caps the decoded output (bomb ceiling by default). A caller that only
    # scans a prefix (Probe scans the first 64 KiB) can pass a small cap so a large
    # compressed body stops inflating early instead of expanding megabytes only to be
    # truncated — the single-Content-Encoding case (virtually all traffic) yields exactly
    # that prefix; a rare multi-coding body yields a valid, decode-tolerant prefix.
    def self.decode(head : Bytes?, body : Bytes?, max_out : Int32 = MAX_OUT) : {Bytes?, String?}
      return {nil, nil} if body.nil? || body.empty? || head.nil?
      te_values, ce_values = encoding_headers(head)
      te_chunked = transfer_encoding_chunked?(te_values)
      encodings = ce_values
        .flat_map(&.split(','))
        .map(&.strip.downcase)
        .reject { |e| e.empty? || e == "identity" }
      return {nil, nil} if !te_chunked && encodings.empty?

      entity = te_chunked ? dechunk(body) : body
      notes = [] of String
      notes << "de-chunked" if te_chunked
      # Content-Encoding lists are applied in order; decode from the outermost
      # (last-listed) inward.
      encodings.reverse_each do |enc|
        decoded, note = inflate(entity, enc, max_out)
        notes << note if note
        return {entity, notes.join(" · ")} if decoded.nil? # unsupported/failed — stop
        entity = decoded
      end
      {entity, notes.empty? ? nil : notes.join(" · ")}
    end

    # `chunked` frames the body only when it's the FINAL transfer-coding (RFC 7230
    # §3.3.1) — mirror the strict wire codec (Body.chunked?) rather than a loose
    # substring scan, which would wrongly de-chunk a body whose TE merely contains
    # the word (e.g. a non-final coding, or a token like "xchunked").
    private def self.transfer_encoding_chunked?(values : Array(String)) : Bool
      values.flat_map(&.split(',')).map(&.strip.downcase).reject(&.empty?).last? == "chunked"
    end

    # {decoded | nil, note | nil}. nil => stop (unsupported or hard error).
    private def self.inflate(data : Bytes, enc : String, max_out : Int32) : {Bytes?, String?}
      case enc
      when "gzip", "x-gzip" then {gunzip(data, max_out), "decoded: gzip"}
      when "deflate"        then {inflate_deflate(data, max_out), "decoded: deflate"}
      when "br"
        return {nil, "compressed: br — decoder not built in"} unless Brotli::AVAILABLE
        {Brotli.decode(data, max_out), "decoded: br"}
      when "zstd"
        return {nil, "compressed: zstd — decoder not built in"} unless Zstd::AVAILABLE
        {Zstd.decode(data, max_out), "decoded: zstd"}
      else
        {nil, "compressed: #{enc} — decode unsupported"}
      end
    rescue ex
      {nil, "decode error (#{enc}): #{ex.message}"}
    end

    private def self.gunzip(data : Bytes, max_out : Int32) : Bytes
      read_all(Compress::Gzip::Reader.new(IO::Memory.new(data)), max_out)
    end

    # HTTP "deflate" is ambiguous: usually zlib-wrapped (RFC 1950), sometimes raw
    # (RFC 1951). Try zlib first; if it produced nothing, retry as raw deflate.
    private def self.inflate_deflate(data : Bytes, max_out : Int32) : Bytes
      zlib = begin
        read_all(Compress::Zlib::Reader.new(IO::Memory.new(data)), max_out)
      rescue
        Bytes.empty
      end
      return zlib unless zlib.empty?
      read_all(Compress::Deflate::Reader.new(IO::Memory.new(data)), max_out)
    end

    # Drain a decompressing reader into a buffer, tolerant of a truncated/corrupt
    # stream (returns what decoded so far) and capped at `max_out` (a prefix-only caller
    # passes a small cap so inflation stops early instead of expanding the whole body).
    private def self.read_all(reader : IO, max_out : Int32 = MAX_OUT) : Bytes
      out = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      begin
        while (n = reader.read(buf)) > 0
          out.write(buf[0, n])
          break if out.bytesize >= max_out
        end
      rescue
        # truncated/corrupt stream — return the partial we managed to decode
      end
      out.to_slice
    end

    # Recover the entity body from a stored h1 chunked wire form
    # ("<hex>[;ext]\r\n<data>\r\n...0\r\n"). Tolerant: stops at the terminating
    # 0-chunk, EOF, or a malformed size line, returning bytes recovered so far.
    # Public so the Match&Replace body path can rewrite the entity, not the wire form.
    def self.dechunk(body : Bytes) : Bytes
      out = IO::Memory.new
      pos = 0
      while pos < body.size
        eol = index_of(body, 0x0a_u8, pos)
        break unless eol
        line = String.new(body[pos, eol - pos]).strip
        pos = eol + 1
        semi = line.index(';')
        hex = (semi ? line[0...semi] : line).strip
        size = hex.each_char.all?(&.to_i?(16)) ? hex.to_i?(base: 16) : nil # pure hex only (reject +/garbage)
        break if size.nil? || size <= 0                                    # 0 = terminating chunk; nil/negative = malformed
        avail = {size, body.size - pos}.min
        out.write(body[pos, avail])
        break if avail < size # truncated mid-chunk
        pos += size
        # Skip the chunk-data terminator byte-accurately: an OPTIONAL CR then the LF.
        # A blind 2-byte skip eats the first byte of the next chunk-size line when the
        # wire form uses a bare LF (non-conformant but seen), misaligning every later
        # chunk in this display/scan projection.
        pos += 1 if pos < body.size && body[pos] == 0x0d_u8 # CR (optional)
        pos += 1 if pos < body.size && body[pos] == 0x0a_u8 # LF
      end
      out.to_slice
    end

    private def self.index_of(body : Bytes, byte : UInt8, from : Int32) : Int32?
      i = from
      while i < body.size
        return i if body[i] == byte
        i += 1
      end
      nil
    end

    # Collect the transfer-encoding AND content-encoding header values in ONE pass over the
    # head — previously two separate `String.new(head).each_line` walks (two full head-String
    # copies + iterations), even in the dominant no-encoding case that returns {nil, nil}.
    # Same case-insensitive name match, same value extraction (strip after the colon), same
    # blank-line head terminator, same wire-order append: the returned lists are byte-identical
    # to two `header_values` calls. The first line (request/status line) has no colon-name that
    # matches, so it's skipped; we stop at the blank line that ends the head.
    private def self.encoding_headers(head : Bytes) : {Array(String), Array(String)}
      te = [] of String
      ce = [] of String
      String.new(head).each_line do |raw|
        line = raw.chomp
        break if line.empty?
        idx = line.index(':')
        next unless idx
        name = line[0...idx].strip.downcase
        if name == "transfer-encoding"
          te << line[(idx + 1)..].strip
        elsif name == "content-encoding"
          ce << line[(idx + 1)..].strip
        end
      end
      {te, ce}
    end
  end
end
