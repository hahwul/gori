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
    decoded, note = decode(head("HTTP/1.1 200 OK", "Content-Encoding: br"), br)
    String.new(decoded.not_nil!).should eq("brotli round trip works")
    note.should eq("decoded: br")
  end

  it "decodes a zstd body when the decoder is built in" do
    next unless Gori::Proxy::Codec::Zstd::AVAILABLE
    z = zstd_compress("zstd round trip works")
    next if z.nil?
    decoded, note = decode(head("HTTP/1.1 200 OK", "Content-Encoding: zstd"), z)
    String.new(decoded.not_nil!).should eq("zstd round trip works")
    note.should eq("decoded: zstd")
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
