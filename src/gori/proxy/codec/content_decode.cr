require "compress/gzip"
require "compress/deflate"
require "compress/zlib"
require "./brotli"
require "./zstd"
require "./http1" # Http1.obfuscated_header? — see content_encoded?
require "../../ascii_bytes"

module Gori::Proxy::Codec
  # Decodes a captured body for DISPLAY: de-chunks the h1 wire form (the stored
  # bytes preserve chunk framing) and inflates every compression layer the head declares
  # — Content-Encoding AND any non-chunked Transfer-Encoding (gzip/deflate/br/zstd) — so
  # compressed responses stop rendering as garbage. This is a DERIVED
  # view only — the stored/forwarded/resent bytes stay byte-faithful (P7). All
  # decoding is tolerant (truncated capture-capped bodies yield partial output, never
  # raise) and output is capped to guard against decompression bombs.
  module ContentDecode
    MAX_OUT = 32 * 1024 * 1024 # decompression-bomb ceiling for the decoded view

    # The two header NAMES whose presence is the necessary condition for `decode` to do any
    # work. The byte-level gate scans the head for either (case-insensitively) to skip the
    # head String on the dominant no-encoding response. Full names (not just "-encoding") so
    # the ubiquitous `Vary: Accept-Encoding` doesn't false-positive the gate open. Lowercase;
    # the scan folds the head.
    CE_NEEDLE = "content-encoding".to_slice
    TE_NEEDLE = "transfer-encoding".to_slice

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
      decoded, note, _ = decode_full(head, body, max_out)
      {decoded, note}
    end

    # `decode`, plus whether every coding it applied reached a clean end-of-stream.
    #
    # `false` means a decompressor stopped early — a body cut mid-stream (a truncated
    # capture, an origin that hung up, a decompression bomb hitting `max_out`) or a corrupt
    # one. That is the whole POINT of probing an encoded body, and it used to be invisible:
    # `read_all` swallowed the exception and returned the partial, so `inflate` still handed
    # back the SUCCESS note `decoded: gzip` and every surface reported a complete decode of a
    # stream that never finished. The decoded BYTES are unchanged either way — this only adds
    # the report — so nothing on the live proxy path forwards differently.
    #
    # Kept as a second entry point rather than a wider `decode` return so the many callers
    # that only want {bytes, note} stay untouched.
    def self.decode_full(head : Bytes?, body : Bytes?, max_out : Int32 = MAX_OUT) : {Bytes?, String?, Bool}
      return {nil, nil, true} if body.nil? || body.empty? || head.nil?
      # Zero-alloc gate before the head String: `encoding_headers` only ever populates its
      # lists from a `content-encoding` / `transfer-encoding` header, and BOTH names contain
      # the ASCII substring "-encoding". If the head bytes don't contain it (the dominant
      # uncompressed, unchunked response), the full parse below would return {nil, nil}
      # anyway — so skip building `String.new(head)` + its per-line substrings entirely.
      # A rare false positive (a header VALUE literally containing "content-encoding", e.g.
      # `Vary: Content-Encoding`) simply falls through to the correct parse; only a true
      # absence is short-circuited. Byte-identical result either way.
      return {nil, nil, true} unless head_has_encoding?(head)
      te_values, ce_values = encoding_headers(head)
      te_chunked = transfer_encoding_chunked?(te_values)
      # ONE decode chain for both header families, ordered outermost-LAST so the shared
      # `reverse_each` below undoes it outermost-in. Transfer-Encoding sits OUTSIDE
      # Content-Encoding: RFC 9110 §8.4.1 makes a content coding a property of the
      # REPRESENTATION (part of what the sender has to encode before it can send anything),
      # while RFC 9112 §6.1 defines the transfer codings as "applied to the content in order
      # to form the message body" — the last transformation before the wire, so the first to
      # undo. `Transfer-Encoding: gzip` used to be consulted for `chunked` alone: the gzip
      # layer was never inflated and no note said why, which is worse than an unknown
      # Content-Encoding (labelled honestly by `inflate`).
      encodings = content_layers(ce_values) + transfer_layers(te_values, te_chunked)
      return {nil, nil, true} if !te_chunked && encodings.empty?

      # A chunked wire form that never reached its terminating 0-chunk is cut, exactly like a
      # compressed stream that never ended — same fact, same report. `chunked` is the FINAL
      # transfer coding (the outermost layer), so undoing it first keeps the chain in order.
      entity, complete, notes = te_chunked ? dechunk_step(body) : {body, true, [] of String}
      # Both header families list their codings in the order they were APPLIED; decode from
      # the outermost (last-listed) inward.
      encodings.reverse_each do |enc|
        decoded, note, clean = inflate(entity, enc, max_out)
        complete = false unless clean
        notes << note if note
        return {entity, notes.join(" · "), complete} if decoded.nil? # unsupported/failed — stop
        entity = decoded
      end
      {entity, notes.empty? ? nil : notes.join(" · "), complete}
    end

    # The de-chunk step as {entity, reached the 0-chunk, the note for it}.
    private def self.dechunk_step(body : Bytes) : {Bytes, Bool, Array(String)}
      complete = chunked_complete?(body)
      {dechunk(body), complete, [complete ? "de-chunked" : "de-chunked (stream truncated)"]}
    end

    # Did a chunked wire body reach its terminating 0-chunk? False for a stream cut
    # mid-chunk, ended at EOF, or carrying a malformed size line — the same tolerant walk
    # `dechunk` does, asked for its verdict rather than its bytes.
    def self.chunked_complete?(body : Bytes) : Bool
      !scan_chunks(body) { }.nil?
    end

    # Zero-alloc necessary-condition gate: does the head carry a content/transfer-encoding
    # header at all? (Byte scan for either full name, case-insensitively.)
    private def self.head_has_encoding?(head : Bytes) : Bool
      AsciiBytes.contains_ci?(head, CE_NEEDLE) || AsciiBytes.contains_ci?(head, TE_NEEDLE)
    end

    # Whether `head` declares a real (non-identity) Content-Encoding — gzip/br/deflate/zstd,
    # as opposed to Transfer-Encoding (chunked), which the caller de-chunks separately.
    # Content-Encoding is never inflated on the live wire path (only for DISPLAY, above) —
    # a Match&Replace body rule matching against still-compressed bytes can incidentally hit
    # inside the compressed stream and corrupt it (a short/common literal pattern needs no
    # more than a byte-value coincidence), so callers on that path use this to refuse rather
    # than risk it. See `ClientConn#apply_body_rewrite`.
    # This is a WIRE gate, not a display read, so it must fail CLOSED where the tolerant parser
    # below cannot see a value. `encoding_headers` walks whole lines and skips any without a
    # colon, so an obs-folded header (RFC 7230 §3.2.4, `Content-Encoding:\r\n gzip`) parses as an
    # EMPTY value and the real `gzip` on the continuation line is never seen — which would hand
    # a compressed body straight to the rule engine, the one outcome this predicate exists to
    # prevent. `Http1.obfuscated_header?` is the codebase's single home for "this head is folded
    # or otherwise not cleanly parseable" (see AGENTS.md §1), so ask it rather than re-deriving
    # the scan here. Response framing deliberately lets obs-folds through byte-exact (see
    # `Http1.framing_ambiguous?`), so such a head really does reach this gate.
    def self.content_encoded?(head : Bytes) : Bool
      return false unless AsciiBytes.contains_ci?(head, CE_NEEDLE)
      _, ce_values = encoding_headers(head)
      return true unless content_layers(ce_values).empty?
      # A Content-Encoding field-name IS present (a bare `Vary: Content-Encoding` yields no
      # entry here at all, so it still returns false) but no readable token came back: refuse
      # only when the head is folded/obfuscated, which is the shape that hides one.
      !ce_values.empty? && Http1.obfuscated_header?(head)
    end

    # `chunked` frames the body only when it's the FINAL transfer-coding (RFC 7230
    # §3.3.1) — mirror the strict wire codec (Body.chunked?) rather than a loose
    # substring scan, which would wrongly de-chunk a body whose TE merely contains
    # the word (e.g. a non-final coding, or a token like "xchunked").
    private def self.transfer_encoding_chunked?(values : Array(String)) : Bool
      codings(values).last? == "chunked"
    end

    # The Content-Encoding layers to undo, in the order they were applied. `identity` means
    # "no transformation" (RFC 9110 §8.4.1), so it is dropped rather than reported.
    private def self.content_layers(values : Array(String)) : Array(String)
      codings(values).reject { |e| e == "identity" }
    end

    # The Transfer-Encoding layers this projection still has to undo. Everything the header
    # lists EXCEPT the final `chunked`, which is framing, not compression: the wire codec
    # framed on it (Body.chunked?, same last-token rule) and `dechunk_step` has already removed
    # it, so leaving it here would decode it twice and then report it as an unknown coding.
    # `identity` is dropped exactly as it is for Content-Encoding.
    #
    # A NON-final `chunked` is deliberately kept: framing did not read it as chunked framing
    # either (it is malformed per RFC 9112 §6.1), so it stays in the chain and is named as an
    # undecodable layer instead of pretending the bytes beneath it are plain.
    private def self.transfer_layers(values : Array(String), chunked : Bool) : Array(String)
      layers = content_layers(values)
      layers.pop if chunked # the last token IS that `chunked` — rejecting `identity` cannot displace it
      layers
    end

    # Split a header family's values into lowercase codings, in wire order.
    private def self.codings(values : Array(String)) : Array(String)
      values.flat_map(&.split(',')).map(&.strip.downcase).reject(&.empty?)
    end

    # {decoded | nil, note | nil, clean end-of-stream}. nil decoded => stop (unsupported or
    # hard error). `clean` is false when the decoder produced a PARTIAL result — the stream
    # was cut or corrupt mid-way, or `max_out` stopped it — which is folded into the note so
    # no surface can report a truncated decode as a finished one.
    private def self.inflate(data : Bytes, enc : String, max_out : Int32) : {Bytes?, String?, Bool}
      case enc
      when "gzip", "x-gzip" then partial_note(gunzip(data, max_out), "gzip")
      when "deflate"        then partial_note(inflate_deflate(data, max_out), "deflate")
      when "br"
        return {nil, "compressed: br — decoder not built in", true} unless Brotli::AVAILABLE
        # The FFI decoders return bytes only; they carry no end-of-stream signal here, so
        # they keep reporting a clean decode rather than guessing.
        {Brotli.decode(data, max_out), "decoded: br", true}
      when "zstd"
        return {nil, "compressed: zstd — decoder not built in", true} unless Zstd::AVAILABLE
        {Zstd.decode(data, max_out), "decoded: zstd", true}
      else
        {nil, "compressed: #{enc} — decode unsupported", true}
      end
    rescue ex
      {nil, "decode error (#{enc}): #{ex.message}", false}
    end

    # Fold a {bytes, clean} pair into the note. A stream that stopped early is the FINDING
    # when the probe was a truncated or bomb-shaped encoded body, so it is named in the same
    # place a successful decode is named rather than in a field only JSON readers see.
    private def self.partial_note(result : {Bytes, Bool}, enc : String) : {Bytes?, String?, Bool}
      bytes, clean = result
      {bytes, clean ? "decoded: #{enc}" : "decoded: #{enc} (stream truncated)", clean}
    end

    private def self.gunzip(data : Bytes, max_out : Int32) : {Bytes, Bool}
      read_all(Compress::Gzip::Reader.new(IO::Memory.new(data)), max_out)
    end

    # HTTP "deflate" is ambiguous: usually zlib-wrapped (RFC 1950), sometimes raw
    # (RFC 1951). Try zlib first; if it produced nothing, retry as raw deflate.
    private def self.inflate_deflate(data : Bytes, max_out : Int32) : {Bytes, Bool}
      zlib = begin
        read_all(Compress::Zlib::Reader.new(IO::Memory.new(data)), max_out)
      rescue
        {Bytes.empty, false}
      end
      return zlib unless zlib[0].empty?
      read_all(Compress::Deflate::Reader.new(IO::Memory.new(data)), max_out)
    end

    # Drain a decompressing reader into a buffer, tolerant of a truncated/corrupt
    # stream (returns what decoded so far) and capped at `max_out` (a prefix-only caller
    # passes a small cap so inflation stops early instead of expanding the whole body).
    # The second element says whether the stream ENDED cleanly: false for a raise mid-way
    # (truncated/corrupt) and false when `max_out` cut it short, since in both cases the
    # bytes returned are a prefix and calling that a finished decode is a lie.
    private def self.read_all(reader : IO, max_out : Int32 = MAX_OUT) : {Bytes, Bool}
      out = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      clean = true
      begin
        while (n = reader.read(buf)) > 0
          out.write(buf[0, n])
          if out.bytesize >= max_out
            clean = false
            break
          end
        end
      rescue
        # truncated/corrupt stream — return the partial we managed to decode
        clean = false
      end
      {out.to_slice, clean}
    end

    # Recover the entity body from a stored h1 chunked wire form
    # ("<hex>[;ext]\r\n<data>\r\n...0\r\n"). Tolerant: stops at the terminating
    # 0-chunk, EOF, or a malformed size line, returning bytes recovered so far.
    # Public so the Match&Replace body path can rewrite the entity, not the wire form.
    def self.dechunk(body : Bytes) : Bytes
      out = IO::Memory.new
      scan_chunks(body) { |chunk| out.write(chunk) }
      out.to_slice
    end

    # Walk a chunked wire body, yielding each chunk's data span, and return the offset just
    # PAST the terminating 0-chunk's size line — where RFC 7230 §4.1.2's trailer section
    # begins — or nil when the body never got there (truncated, EOF, malformed size line).
    #
    # One scanner for `dechunk` and `trailers` so the two can never disagree about where the
    # chunk data ends and the trailer section starts.
    private def self.scan_chunks(body : Bytes, & : Bytes ->) : Int32?
      pos = 0
      while pos < body.size
        eol = index_of(body, 0x0a_u8, pos)
        return nil unless eol
        line = String.new(body[pos, eol - pos]).strip
        pos = eol + 1
        semi = line.index(';')
        hex = (semi ? line[0...semi] : line).strip
        size = hex.each_char.all?(&.to_i?(16)) ? hex.to_i?(base: 16) : nil # pure hex only (reject +/garbage)
        return nil if size.nil? || size < 0                                # malformed size line
        return pos if size == 0                                            # terminating chunk — the trailer section starts here
        avail = {size, body.size - pos}.min
        yield body[pos, avail]
        return nil if avail < size # truncated mid-chunk
        pos += size
        # Skip the chunk-data terminator byte-accurately: an OPTIONAL CR then the LF.
        # A blind 2-byte skip eats the first byte of the next chunk-size line when the
        # wire form uses a bare LF (non-conformant but seen), misaligning every later
        # chunk in this display/scan projection.
        pos += 1 if pos < body.size && body[pos] == 0x0d_u8 # CR (optional)
        pos += 1 if pos < body.size && body[pos] == 0x0a_u8 # LF
      end
      nil
    end

    # Ceiling on trailer fields lifted into the projection. The wire reader already bounds
    # the trailer section (Body::MAX_TRAILER_BYTES), but a stored/imported body reaches this
    # without passing through it, so the display projection carries its own bound.
    MAX_TRAILERS = 64

    NO_TRAILERS = [] of {String, String}

    # The trailer fields of a chunked wire body: the header lines that follow the
    # terminating 0-chunk (RFC 7230 §4.1.2).
    #
    # The old code encoded the belief that a chunked body's only content is its chunk DATA:
    # `dechunk` stops at the 0-chunk and the rendered head stops at the blank line BEFORE the
    # body, so a trailer was captured by neither half and vanished from every decoded
    # projection while `Trailer:` was still echoed in the head — which reads as "the origin
    # sent none". For trailer-based header injection, trailer smuggling, and gRPC-over-h1
    # (where `grpc-status` arrives here and IS the call's real status) the trailer is the
    # whole result.
    #
    # They are surfaced AS trailers, never folded into the header list: whether a target
    # treats a trailer as a header is itself the test, so the projection must not decide it.
    # Tolerant like `dechunk` — an unterminated trailer section yields what was recovered.
    def self.trailers(body : Bytes) : Array({String, String})
      pos = scan_chunks(body) { } || return NO_TRAILERS
      out = [] of {String, String}
      while pos < body.size && out.size < MAX_TRAILERS
        stop = index_of(body, 0x0a_u8, pos) || body.size
        len = stop - pos
        len -= 1 if len > 0 && body[pos + len - 1] == 0x0d_u8 # the optional CR before the LF
        line = body[pos, len]
        pos = stop + 1
        break if line.empty? # the blank line ends the trailer section
        # Split on the colon in BYTE space: a trailer VALUE is remote bytes and may not be
        # valid UTF-8, and a char-indexed split of such a String does not land where the
        # colon actually is.
        colon = index_of(line, 0x3a_u8, 0)
        next unless colon # not a field line — skip it rather than guessing at its shape
        out << {String.new(line[0, colon]).strip, String.new(line[(colon + 1)..]).strip}
      end
      out
    end

    # Trailers for a whole message, gated on the head actually declaring `chunked` framing —
    # the same test `decode` uses before it de-chunks, so a body that merely happens to look
    # chunk-shaped is never mined for fields. Empty for every other message.
    def self.trailers(head : Bytes?, body : Bytes?) : Array({String, String})
      return NO_TRAILERS if head.nil? || body.nil? || body.empty?
      return NO_TRAILERS unless head_has_encoding?(head)
      te_values, _ = encoding_headers(head)
      return NO_TRAILERS unless transfer_encoding_chunked?(te_values)
      trailers(body)
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
