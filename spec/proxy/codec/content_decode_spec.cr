require "../../spec_helper"
require "compress/gzip"
require "compress/zlib"

private def gzip(data : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.print(data) }
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
