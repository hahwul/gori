require "../../spec_helper"
require "compress/gzip"
require "compress/zlib"

private def gzip(data : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.print(data) }
  io.to_slice
end

private def gzip_bytes(data : Bytes) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.write(data) }
  io.to_slice
end

private def zlib_deflate(data : String) : Bytes
  io = IO::Memory.new
  Compress::Zlib::Writer.open(io) { |w| w.print(data) }
  io.to_slice
end

private def head(*lines) : Bytes
  (lines.join("\r\n") + "\r\n\r\n").to_slice
end

private def decode(head : Bytes, body : Bytes)
  Gori::Proxy::Codec::ContentDecode.decode(head, body)
end

private def decode_full(head : Bytes, body : Bytes,
                        max_out : Int32 = Gori::Proxy::Codec::ContentDecode::MAX_OUT)
  Gori::Proxy::Codec::ContentDecode.decode_full(head, body, max_out)
end

# ~172 KB of RANDOM word soup, seeded for determinism. A regular pattern compresses to a few
# hundred bytes and half of a few hundred bytes decodes to nothing, so the truncation examples
# need a payload whose truncated PREFIX still carries more than one output buffer.
private def word_soup(n = 30_000, seed = 11) : String
  words = %w[alpha beta gamma delta]
  rng = Random.new(seed)
  String.build { |io| n.times { io << words[rng.rand(4)] << ' ' } }
end

private def encoded?(head : Bytes)
  Gori::Proxy::Codec::ContentDecode.content_encoded?(head)
end

describe Gori::Proxy::Codec::ContentDecode do
  it "passes an identity body through unchanged (nil => caller uses raw)" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Content-Type: text/plain"), "hello".to_slice)
    decoded.should be_nil
    note.should be_nil
  end

  it "decodes a gzip body" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Content-Encoding: gzip"), gzip("the quick brown fox"))
    String.new(decoded.not_nil!).should eq("the quick brown fox")
    note.should eq("decoded: gzip")
  end

  it "decodes a zlib-wrapped deflate body (header case-insensitive)" do
    decoded, _ = decode(head("HTTP/1.1 200 OK", "content-encoding: deflate"), zlib_deflate("deflate payload"))
    String.new(decoded.not_nil!).should eq("deflate payload")
  end

  it "de-chunks THEN gunzips a chunked gzip body (order-critical)" do
    gz = gzip("chunked gzip body")
    buf = IO::Memory.new
    buf << gz.size.to_s(16) << "\r\n"
    buf.write(gz)
    buf << "\r\n0\r\n\r\n"
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked", "Content-Encoding: gzip"), buf.to_slice)
    String.new(decoded.not_nil!).should eq("chunked gzip body")
    note.not_nil!.should contain("de-chunked")
    note.not_nil!.should contain("gzip")
  end

  it "de-chunks an identity chunked body (multiple chunks)" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked"),
      "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".to_slice)
    String.new(decoded.not_nil!).should eq("hello world")
    note.should eq("de-chunked")
  end

  it "bounds a chunk-amplified preview before walking the remaining entity/trailers" do
    entity = "x" * 200_000
    wire = "#{entity.bytesize.to_s(16)}\r\n#{entity}\r\n0\r\nCookie: late-secret\r\n\r\n".to_slice
    decoded, note, clean = decode_full(
      head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked"), wire, 33)
    decoded.not_nil!.size.should eq(33)
    String.new(decoded.not_nil!).should eq("x" * 33)
    note.not_nil!.should contain("truncated")
    clean.should be_false
  end

  it "returns at most max_out bytes for a gzip amplification" do
    decoded, note, clean = decode_full(
      head("HTTP/1.1 200 OK", "Content-Encoding: gzip"), gzip("z" * 200_000), 33)
    decoded.not_nil!.size.should eq(33)
    note.not_nil!.should contain("truncated")
    clean.should be_false
  end

  it "treats a chunk size with a leading '+' as malformed (no smuggled length)" do
    decoded, _ = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked"),
      "+5\r\nhello\r\n0\r\n\r\n".to_slice)
    String.new(decoded || Bytes.empty).should_not contain("hello") # "+5" must NOT parse as size 5
  end

  it "does NOT de-chunk a body whose TE only CONTAINS 'chunked' as a substring" do
    # "xchunked" is not the chunked coding — a loose substring match used to
    # wrongly de-chunk this, mangling the displayed body. The bytes come back
    # untouched; the unknown transfer coding is NAMED rather than passed off as plain.
    body = "5\r\nhello\r\n0\r\n\r\n".to_slice
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: xchunked"), body)
    decoded.should eq(body) # not de-chunked: the chunk framing is still there
    note.not_nil!.should contain("xchunked")
    note.not_nil!.should contain("unsupported")
  end

  # `Transfer-Encoding: gzip` is legal (RFC 9112 §6.1) and close-delimited (Body.response_framing).
  # gori used to consult Transfer-Encoding for `chunked` alone, so the gzip layer was neither
  # inflated NOR labelled — silent garbage, strictly worse than an unknown Content-Encoding.
  it "decodes a Transfer-Encoding: gzip body (close-delimited, no chunk framing)" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip"), gzip("transfer coded body"))
    String.new(decoded.not_nil!).should eq("transfer coded body")
    note.should eq("decoded: gzip")
  end

  it "de-chunks THEN gunzips a 'Transfer-Encoding: gzip, chunked' body" do
    gz = gzip("te gzip then chunked")
    buf = IO::Memory.new
    buf << gz.size.to_s(16) << "\r\n"
    buf.write(gz)
    buf << "\r\n0\r\n\r\n"
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip, chunked"), buf.to_slice)
    String.new(decoded.not_nil!).should eq("te gzip then chunked")
    note.should eq("de-chunked · decoded: gzip")
  end

  it "reports an unsupported TRANSFER coding instead of silent garbage" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: compress"), "rawbytes".to_slice)
    decoded.should eq("rawbytes".to_slice)
    note.not_nil!.should contain("compress")
    note.not_nil!.should contain("unsupported")
  end

  it "ignores a Transfer-Encoding: identity (nothing applied, nothing to undo)" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Transfer-Encoding: identity"), "plain".to_slice)
    decoded.should be_nil
    note.should be_nil
  end

  # Layer order is the whole point: RFC 9110 §8.4.1 makes the content coding a property of the
  # representation, and RFC 9112 §6.1 applies the transfer codings "to the content in order to
  # form the message body" — so TE is OUTSIDE CE and must come off first. Decoding CE first
  # here would hand zlib a gzip stream and recover nothing.
  it "undoes Transfer-Encoding BEFORE Content-Encoding (order-critical)" do
    body = gzip_bytes(zlib_deflate("outer gzip over inner deflate"))
    decoded, note = decode(
      head("HTTP/1.1 200 OK", "Content-Encoding: deflate", "Transfer-Encoding: gzip"), body)
    String.new(decoded.not_nil!).should eq("outer gzip over inner deflate")
    note.should eq("decoded: gzip · decoded: deflate")
  end

  it "reports an unsupported encoding instead of decoding to garbage" do
    _, note = decode(head("HTTP/1.1 200 OK", "Content-Encoding: compress"), "rawbytes".to_slice)
    note.not_nil!.should contain("unsupported")
  end

  it "tolerates a truncated gzip body (partial output, never raises)" do
    full = gzip("a much longer body cut in half to simulate capture-cap truncation, repeated " * 4)
    truncated = full[0, full.size // 2]
    decoded, _ = decode(head("HTTP/1.1 200 OK", "Content-Encoding: gzip"), truncated)
    decoded.should_not be_nil # got SOME partial output, no exception
  end

  it "decodes a brotli body when the decoder is built in" do
    next unless Gori::Proxy::Codec::Brotli::AVAILABLE
    br = br_compress("brotli round trip works")
    next if br.nil? # `brotli` CLI not installed — skip rather than fail
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: br"), br)
    String.new(decoded.not_nil!).should eq("brotli round trip works")
    note.should eq("decoded: br")
    clean.should be_true # an INTACT stream must never pick up a truncation warning
  end

  it "decodes a zstd body when the decoder is built in" do
    next unless Gori::Proxy::Codec::Zstd::AVAILABLE
    z = zstd_compress("zstd round trip works")
    next if z.nil?
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), z)
    String.new(decoded.not_nil!).should eq("zstd round trip works")
    note.should eq("decoded: zstd")
    clean.should be_true
  end

  # `Brotli`/`Zstd.decode_full` report their own end-of-stream and `inflate` threw that answer
  # away, calling the one-value `decode` and hard-coding `true` beside it. So a br or zstd body
  # cut mid-stream — the ordinary shape of a capture-capped response — decoded to a PREFIX and
  # was reported "decoded: br", the clean note, on every surface that reads one: the History
  # detail note, `--format json`'s `decode_truncated`, and Probe, for which an encoded body
  # that never finished is the point of the scan. Its gzip sibling had said "(stream
  # truncated)" the whole time, which is what made the silence hard to see.
  it "reports a truncated brotli body as truncated, exactly as gzip does" do
    next unless Gori::Proxy::Codec::Brotli::AVAILABLE
    full = br_compress(word_soup)
    next if full.nil?
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: br"), full[0, full.size // 2])
    decoded.not_nil!.size.should be > 0
    decoded.not_nil!.size.should be < word_soup.bytesize # a PREFIX, not the document
    note.should eq("decoded: br (stream truncated)")
    clean.should be_false
  end

  it "reports a truncated zstd body as truncated, exactly as gzip does" do
    next unless Gori::Proxy::Codec::Zstd::AVAILABLE
    # Bigger than the brotli example's payload on purpose: libzstd emits nothing until it has a
    # whole block, so half of a 170 KB body decodes to zero bytes — which is a decode FAILURE
    # (below), not a partial one. This pins the partial case, so the body has to be large
    # enough that the surviving prefix carries real output.
    body = word_soup(200_000)
    full = zstd_compress(body)
    next if full.nil?
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), full[0, full.size // 2])
    decoded.not_nil!.size.should be > 0
    decoded.not_nil!.size.should be < body.bytesize
    note.should eq("decoded: zstd (stream truncated)")
    clean.should be_false
  end

  # A `Content-Encoding` that does not describe the bytes at all — a forged header, or a body
  # cut before the decoder's first output byte. Neither library raises on it: they hand back
  # nothing. Reported as a FAILURE (nil decoded ⇒ `decode_full` returns the captured entity)
  # rather than a non-nil EMPTY slice, because every display prefers the decoded view over the
  # raw one (`src = display || body`) and an empty one wins that test — the operator got a
  # blank pane under a green "decoded: br" and could only reach the bytes through the hex view.
  it "refuses a br/zstd label over bytes that were never that stream, keeping the raw body" do
    raw = "this is plain text, not a compressed stream at all".to_slice
    if Gori::Proxy::Codec::Brotli::AVAILABLE
      decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: br"), raw)
      decoded.should eq(raw) # the CAPTURED bytes, so the pane has something to show
      note.not_nil!.should start_with("decode error (br)")
      clean.should be_false
      Gori::Proxy::Codec::ContentDecode.decode_failed?(note).should be_true
    end
    if Gori::Proxy::Codec::Zstd::AVAILABLE
      decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), raw)
      decoded.should eq(raw)
      note.not_nil!.should start_with("decode error (zstd)")
      clean.should be_false
    end
    # Same verdict for a REAL stream cut before its first output byte: libzstd emits nothing
    # until it has a whole block, so half of a 170 KB body is indistinguishable from garbage
    # here — and either way the honest answer is the captured bytes, not an empty pane.
    if Gori::Proxy::Codec::Zstd::AVAILABLE && (z = zstd_compress(word_soup))
      cut = z[0, z.size // 2]
      decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), cut)
      decoded.should eq(cut)
      note.not_nil!.should start_with("decode error (zstd)")
      clean.should be_false
    end
  end

  # `decode_failed?` is the predicate a caller that WRITES the bytes needs, and it reads the
  # LAST note segment: the chain stops at the first layer it cannot undo, so a successful
  # `de-chunked` ahead of the failure must not mask it.
  it "names a failed decode apart from a successful or merely truncated one" do
    failed = Gori::Proxy::Codec::ContentDecode.decode_failed?("de-chunked · compressed: compress — decode unsupported")
    failed.should be_true
    Gori::Proxy::Codec::ContentDecode.decode_failed?("decode error (gzip): Invalid gzip header").should be_true
    Gori::Proxy::Codec::ContentDecode.decode_failed?("de-chunked · decoded: gzip").should be_false
    Gori::Proxy::Codec::ContentDecode.decode_failed?("decoded: br (stream truncated)").should be_false
    Gori::Proxy::Codec::ContentDecode.decode_failed?(nil).should be_false
  end

  # The truncated-body case is the one a capture cap produces every day, and it was silently
  # capped at exactly one output buffer. With a large window — the default for a CDN-sized body
  # — libbrotlidec swallows the whole truncated input in ONE call, hands back 64 KiB and asks
  # for more input; stopping there threw away everything still buffered inside the decoder, so
  # a 340 KB body cut anywhere decoded to exactly 65,536 bytes whatever the cap had kept.
  # Measured on this payload: 65,536 before, 171,915 after.
  it "keeps draining a truncated brotli body past the first output buffer" do
    next unless Gori::Proxy::Codec::Brotli::AVAILABLE
    full = br_compress(word_soup(60_000))
    next if full.nil?
    truncated = full[0, full.size // 2]
    # The NOTE as well as the bytes. This example used to destructure `decoded, _` and drop it,
    # which is why it could pin the drain fix and still pass while the truncation went
    # unreported: the pair is one answer, and reading half of it is how the silence survived.
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: br"), truncated)
    decoded.not_nil!.size.should be > 65_536
    note.should eq("decoded: br (stream truncated)")
    clean.should be_false
  end

  # A zstd STREAM is one or more frames back to back, and a `Content-Encoding: zstd` body
  # legitimately is several. Stopping at the first returned half a body with nothing saying so.
  it "decodes every frame of a multi-frame zstd body" do
    next unless Gori::Proxy::Codec::Zstd::AVAILABLE
    one = zstd_compress("first frame. ")
    next if one.nil?
    two = zstd_compress("second frame.")
    next if two.nil?
    decoded, note, clean = decode_full(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), one + two)
    String.new(decoded.not_nil!).should eq("first frame. second frame.")
    # And no false alarm: every frame ended and every input byte was consumed, so a multi-frame
    # body is a COMPLETE decode. Adding a truncation signal must not invent one here.
    note.should eq("decoded: zstd")
    clean.should be_true
  end

  # A zstd stream is many frames, and `ZSTD_decompressStream` returns 0 at the END OF EVERY ONE
  # — so a `next` at the frame boundary skipped the bomb guard entirely, and the cap was never
  # consulted for a multi-frame body. Measured before the fix: 25 KB of input, 131 MB out
  # against a 32 MiB cap, linear in the input, on the path an operator reaches by opening a flow.
  it "holds the decompression cap across a multi-frame zstd body" do
    next unless Gori::Proxy::Codec::Zstd::AVAILABLE
    one = zstd_compress("a" * 2048)
    next if one.nil?
    bomb = IO::Memory.new
    400.times { bomb.write(one) }
    cap = 64 * 1024
    bytes, _ = Gori::Proxy::Codec::Zstd.decode_full(bomb.to_slice, cap)
    bytes.size.should be < cap * 4 # the cap binds; one output buffer of slack
  end

  # The cap has to stop one buffer PAST the ceiling, not on it. Both decoders drain into a
  # power-of-two buffer (64 KiB brotli, 128 KiB zstd) and the real cap is 32 MiB, which both
  # divide exactly — so a `>= max_out` stop landed a bomb on PRECISELY the ceiling, and every
  # consumer's guard is `size > max_out` (`Chain.run`'s, `ExternalOpen`'s). Measured before the
  # fix: a brotli and a zstd bomb both produced 33,554,432 bytes and both reported `Ok`, while
  # the gzip sibling — whose stdlib drain already used `>` — failed with "output exceeds …".
  # Same input, two answers, decided by buffer alignment. The caps here are chosen to divide
  # exactly, which is the shape that hid it.
  it "stops a br/zstd bomb PAST the cap, so an over-cap consumer guard can see it" do
    if Gori::Proxy::Codec::Brotli::AVAILABLE && (bomb = br_compress("a" * 4_000_000))
      cap = 4 * 64 * 1024 # an exact multiple of the brotli drain buffer
      bytes, clean = Gori::Proxy::Codec::Brotli.decode_full(bomb, cap)
      bytes.size.should be > cap
      bytes.size.should be <= cap + 64 * 1024 # …by at most one buffer
      clean.should be_false
    end
    if Gori::Proxy::Codec::Zstd::AVAILABLE && (bomb = zstd_compress("a" * 4_000_000))
      cap = 4 * 128 * 1024 # an exact multiple of the zstd drain buffer
      bytes, clean = Gori::Proxy::Codec::Zstd.decode_full(bomb, cap)
      bytes.size.should be > cap
      bytes.size.should be <= cap + 128 * 1024
      clean.should be_false
    end
  end

  # The other half of the same rule: a body that decompresses to EXACTLY the cap is not a bomb.
  # Moving the guard past the ceiling must not start reporting those as cut.
  it "reports a stream that decodes to exactly the cap as complete" do
    payload = "a" * (64 * 1024)
    if Gori::Proxy::Codec::Brotli::AVAILABLE && (b = br_compress(payload))
      bytes, clean = Gori::Proxy::Codec::Brotli.decode_full(b, payload.bytesize)
      bytes.size.should eq(payload.bytesize)
      clean.should be_true
    end
    if Gori::Proxy::Codec::Zstd::AVAILABLE && (z = zstd_compress(payload))
      bytes, clean = Gori::Proxy::Codec::Zstd.decode_full(z, payload.bytesize)
      bytes.size.should eq(payload.bytesize)
      clean.should be_true
    end
  end

  # `decode_full`'s second element is the only honest failure signal either library has: both
  # answer a buffer that was never one of their streams the same way they answer a stream of an
  # empty payload — no bytes, no raise. The Decoder workbench has to tell those apart.
  it "reports whether a native stream ended cleanly" do
    if Gori::Proxy::Codec::Zstd::AVAILABLE && (z = zstd_compress("complete"))
      bytes, clean = Gori::Proxy::Codec::Zstd.decode_full(z, 1 << 20)
      String.new(bytes).should eq("complete")
      clean.should be_true
      _, dirty = Gori::Proxy::Codec::Zstd.decode_full("not a zstd stream at all".to_slice, 1 << 20)
      dirty.should be_false
    end
    if Gori::Proxy::Codec::Brotli::AVAILABLE && (b = br_compress("complete"))
      bytes, clean = Gori::Proxy::Codec::Brotli.decode_full(b, 1 << 20)
      String.new(bytes).should eq("complete")
      clean.should be_true
      _, dirty = Gori::Proxy::Codec::Brotli.decode_full("not brotli at all".to_slice, 1 << 20)
      dirty.should be_false
    end
  end

  # The zero-alloc `-encoding` gate must be ASCII case-insensitive: an all-caps header
  # name still reaches the decoder (a false gate-negative here would silently pass a gzip
  # body through as garbage).
  it "gates case-insensitively: an UPPERCASE Content-Encoding still decodes" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "CONTENT-ENCODING: GZIP"), gzip("caps work"))
    String.new(decoded.not_nil!).should eq("caps work")
    note.should eq("decoded: gzip")
  end

  # A head that CONTAINS the "-encoding" substring only in an unrelated value (Vary:
  # Accept-Encoding) but carries no real content/transfer-encoding: the gate lets it
  # through, and the full parse correctly finds nothing to do → passthrough (nil).
  it "gate false-positive (Vary: Accept-Encoding) still resolves to passthrough" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Vary: Accept-Encoding", "Content-Type: text/plain"), "plain".to_slice)
    decoded.should be_nil
    note.should be_nil
  end

  # No "-encoding" anywhere in the head → the gate short-circuits before building any
  # head String, and the result is the same passthrough as an unmatched full parse.
  it "no encoding header at all → passthrough (gate short-circuits)" do
    decoded, note = decode(head("HTTP/1.1 200 OK", "Content-Type: application/json", "Server: nginx"), %({"ok":true}).to_slice)
    decoded.should be_nil
    note.should be_nil
  end

  # The WIRE gate: `ClientConn#apply_body_rewrite` refuses to run a Match&Replace body rule
  # when this says the body carries a compression layer. Compression is never inflated on that
  # path, so a rule that matched would be matching opaque compressed bytes — and the re-frame
  # that follows drops Transfer-Encoding, handing the client a compressed body labelled as an
  # identity one.
  describe ".content_encoded?" do
    it "refuses a Content-Encoding body and allows a plain one" do
      encoded?(head("HTTP/1.1 200 OK", "Content-Encoding: gzip")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "content-encoding: BR")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "Content-Type: text/html")).should be_false
      encoded?(head("HTTP/1.1 200 OK", "Content-Encoding: identity")).should be_false
      # the "-encoding" byte gate's false positives resolve to a real parse, not a refusal
      encoded?(head("HTTP/1.1 200 OK", "Vary: Accept-Encoding")).should be_false
      encoded?(head("HTTP/1.1 200 OK", "Vary: Content-Encoding")).should be_false
    end

    # #740: a `Transfer-Encoding: gzip` response carries NO Content-Encoding at all, so the
    # Content-Encoding-only gate returned false on its first line and handed the rule engine a
    # raw DEFLATE stream — silently no-matching, or matching by byte-coincidence and corrupting
    # the body it then advertised as identity.
    it "refuses a body compressed by a TRANSFER coding (#740)" do
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "TRANSFER-ENCODING: GZIP")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip, chunked")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip", "Transfer-Encoding: chunked")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: br")).should be_true
      # an unknown/unsupported transfer coding is still a coding — the bytes beneath it are not
      # the entity, so the rule must not see them
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: compress, chunked")).should be_true
    end

    # The regression guard for the obvious over-fix: `chunked` is FRAMING, not compression
    # (RFC 9112 §6.1), and `apply_body_rewrite` de-chunks to the entity itself before matching.
    # Counting it here would silently disable body rules across most of the web.
    it "allows a plain chunked body — chunked is framing, not compression" do
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked")).should be_false
      encoded?(head("HTTP/1.1 200 OK", "transfer-encoding: CHUNKED")).should be_false
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: identity, chunked")).should be_false
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked", "Content-Type: text/html")).should be_false
    end

    # A NON-final `chunked` is malformed (RFC 9112 §6.1) and the wire codec rejects it outright,
    # so this shape should not reach the gate at all — but the layer split keeps it in the list
    # rather than pretending the bytes beneath it are plain, and the gate agrees: the entity is
    # under both a gzip layer AND chunk framing nobody removed.
    it "refuses a non-final chunked (the malformed shape is not framing gori removed)" do
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked, gzip")).should be_true
    end

    # Fail CLOSED, symmetrically with the Content-Encoding side: `encoding_headers` skips a
    # continuation line (it has no colon), so an obs-folded header (RFC 7230 §3.2.4) hides the
    # real coding from this parse while a lenient recipient still reads it. Response framing
    # deliberately lets obs-folds through byte-exact, so such a head really does arrive here.
    it "fails closed on an obs-folded encoding header" do
      encoded?(head("HTTP/1.1 200 OK", "Content-Encoding:", " gzip")).should be_true
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding:", " gzip")).should be_true
      # the fold hides a coding INSIDE the value list, so the visible tokens look like ordinary
      # chunked framing — which is why the refusal cannot be narrowed to an empty value
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked,", " gzip")).should be_true
      # deliberately blunt: a fold ANYWHERE in a head that names either family refuses, because
      # this parse cannot tell which header the continuation belonged to
      encoded?(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked", "X-Note: a", " folded")).should be_true
      # but a fold in a head naming NEITHER family is not this gate's business
      encoded?(head("HTTP/1.1 200 OK", "X-Note: a", " folded")).should be_false
    end

    # A wire gate must never raise: it runs on every rewrite-eligible response, and the head is
    # remote bytes (not necessarily valid UTF-8, not necessarily well-formed).
    it "never raises on a hostile or truncated head" do
      encoded?(Bytes.new(0)).should be_false
      encoded?("Transfer-Encoding".to_slice).should be_false # no colon, no blank line
      io = IO::Memory.new
      io << "HTTP/1.1 200 OK\r\nX-Bin: "
      io.write(Bytes[0x80, 0xff]) # a header value that is not valid UTF-8
      io << "\r\nContent-Encoding: gzip\r\n\r\n"
      encoded?(io.to_slice).should be_true
    end
  end

  # A chunked body's trailer section (RFC 7230 §4.1.2) used to be captured by NEITHER half of
  # the projection: `dechunk` stops at the terminating 0-chunk and the rendered head stops at
  # the blank line before the body. The `Trailer:` announcement was still echoed, so the loss
  # read as "the origin sent none".
  describe ".trailers" do
    it "reads the fields after the terminating 0-chunk" do
      body = "5\r\nhello\r\n6\r\n world\r\n0\r\nX-T: gotcha\r\nX-Sum: 99\r\n\r\n".to_slice
      trailers(body).should eq([{"X-T", "gotcha"}, {"X-Sum", "99"}])
      # and the entity is unchanged — the trailers are a separate reading of the same bytes
      Gori::Proxy::Codec::ContentDecode.dechunk(body).should eq("hello world".to_slice)
    end

    it "reads a trailer-only body (gRPC-over-h1: the status IS the trailer)" do
      trailers("0\r\ngrpc-status: 7\r\ngrpc-message: denied\r\n\r\n".to_slice)
        .should eq([{"grpc-status", "7"}, {"grpc-message", "denied"}])
    end

    it "keeps a trailer VALUE's exact bytes (it is remote data, not necessarily UTF-8)" do
      body = Bytes.new(0)
      io = IO::Memory.new
      io << "0\r\nX-Bin: "
      io.write(Bytes[0x80, 0xff])
      io << "\r\n\r\n"
      body = io.to_slice
      t = trailers(body)
      t.size.should eq(1)
      t[0][1].to_slice.should eq(Bytes[0x80, 0xff])
    end

    it "stops at the blank line and ignores a non-field line" do
      trailers("0\r\nnot-a-field\r\nX-A: 1\r\n\r\nX-B: 2\r\n".to_slice).should eq([{"X-A", "1"}])
    end

    it "is empty when the body never reaches a 0-chunk (truncated capture)" do
      trailers("5\r\nhel".to_slice).should be_empty
      trailers("".to_slice).should be_empty
    end

    it "tolerates a bare-LF wire form and an unterminated trailer section" do
      trailers("0\nX-T: v\n".to_slice).should eq([{"X-T", "v"}])
    end

    it "is bounded so a hostile body cannot grow the projection without limit" do
      io = IO::Memory.new
      io << "0\r\n"
      200.times { |i| io << "X-#{i}: v\r\n" }
      io << "\r\n"
      trailers(io.to_slice).size.should eq(Gori::Proxy::Codec::ContentDecode::MAX_TRAILERS)
    end

    # The head-gated overload: only a message whose head actually declares `chunked` framing
    # is mined for fields, so a body that merely looks chunk-shaped is never misread.
    it "only reads trailers when the HEAD declares chunked framing" do
      wire = "0\r\nX-T: v\r\n\r\n".to_slice
      Gori::Proxy::Codec::ContentDecode.trailers(head("HTTP/1.1 200 OK", "Transfer-Encoding: chunked"), wire)
        .should eq([{"X-T", "v"}])
      Gori::Proxy::Codec::ContentDecode.trailers(head("HTTP/1.1 200 OK", "Content-Length: 13"), wire)
        .should be_empty
      Gori::Proxy::Codec::ContentDecode.trailers(head("HTTP/1.1 200 OK", "Transfer-Encoding: gzip"), wire)
        .should be_empty
      Gori::Proxy::Codec::ContentDecode.trailers(nil, wire).should be_empty
    end
  end
end

private def trailers(body : Bytes)
  Gori::Proxy::Codec::ContentDecode.trailers(body)
end

# Compress via the system CLI (decoder-only libs are linked; encoders aren't).
private def br_compress(s : String) : Bytes?
  cli_compress("brotli", ["-c"], s)
end

private def zstd_compress(s : String) : Bytes?
  cli_compress("zstd", ["-q", "-c"], s)
end

private def cli_compress(cmd : String, args : Array(String), input : String) : Bytes?
  return nil unless Process.find_executable(cmd)
  sink = IO::Memory.new
  status = Process.run(cmd, args, input: IO::Memory.new(input), output: sink, error: Process::Redirect::Close)
  status.success? ? sink.to_slice : nil
rescue
  nil
end
