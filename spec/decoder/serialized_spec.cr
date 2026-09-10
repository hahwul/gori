require "../spec_helper"
require "../support/serialized_vectors"

private alias S = Gori::Decoder::Serialized

private def sniffed(data : Bytes) : String?
  S.sniff(data).try(&.[0])
end

describe Gori::Decoder::Serialized do
  it "claims a body by its own structural marker, not by a content-type" do
    # None of these four formats has a content-type of its own — a Java stream arrives as
    # `application/octet-stream`, a serialized PHP value as `text/plain` — so the bytes have
    # to carry the decision.
    sniffed(SerializedVectors::JAVA_HASHMAP).should eq("java-serialized")
    sniffed(SerializedVectors::VIEWSTATE_CLASSIC).should eq("aspnet-viewstate")
    sniffed(SerializedVectors::PICKLE_REDUCE).should eq("python-pickle")
    sniffed(SerializedVectors::PHP_OBJECT).should eq("php-serialized")
    sniffed(%(a:1:{i:0;s:1:"x";}).to_slice).should eq("php-serialized")
  end

  it "declines a protocol-0 pickle, whose opcodes are indistinguishable from prose" do
    # Protocol 0 has no header at all and its opcodes are printable ASCII, so English text
    # disassembles into plausible garbage. The SNIFF therefore needs the `\x80` PROTO opener;
    # the `pickle-disasm` CONVERTER does not, because typing the name is a decision the sniff
    # never gets to make.
    p0 = "cposix\nsystem\np0\n(V id\np1\ntp2\nRp3\n.".to_slice
    sniffed(p0).should be_nil
    Gori::Decoder::Serialized::Pickle.render(p0).complete.should be_true
  end

  it "declines the PHP scalar forms, which are two characters a body could hold by accident" do
    ["i:5;", "s:2:\"ab\";", "b:1;", "N;", "d:1.5;"].each { |v| sniffed(v.to_slice).should be_nil }
  end

  it "declines an ordinary body, whatever it opens with" do
    tail = Bytes.new(2_000) { |i| (i * 7 % 251).to_u8 }
    {
      "png"   => Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + tail,
      "gzip"  => Bytes[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03] + tail,
      "zlib"  => Bytes[0x78, 0x9c] + tail,
      "json"  => %({"a":1,"b":"hi","c":[1,2,3]}).to_slice,
      "html"  => "<html><body>a:1:{}</body></html>".to_slice,
      "prose" => "hello world, an ordinary page".to_slice,
      "empty" => Bytes.empty,
    }.each { |label, body| sniffed(body).should be_nil, label }
  end

  it "declines a body whose marker is right and whose bytes are not" do
    # The whole point of the `describes?` test: a rendering that is wrong is worse than a hex
    # dump that is right. A ViewState with 300 bytes of tail is not a signed ViewState.
    sniffed(SerializedVectors::VIEWSTATE_CLASSIC + Bytes.new(300, 0x41_u8)).should be_nil
    sniffed(Bytes[0xac, 0xed, 0x00, 0x05, 0x73, 0x72, 0xff, 0xff]).should be_nil
    sniffed(Bytes[0x80, 0x04, 0xfd, 0x01, 0x02, 0x03]).should be_nil
    # A body that is nothing but pickle's FRAMING PREAMBLE and a length that ran out is the
    # "first header lied" shape `describes?`'s third test exists for, and it wears the same
    # `{truncated, consumed == size}` a capture cap does — so the reader declines to count
    # `PROTO`/`FRAME` as having decoded anything.
    sniffed(Bytes[0x80, 0x04, 0x95, 0xff, 0xfd]).should be_nil
    sniffed(Bytes[0x80, 0x02, 0x58, 0xff, 0xff, 0xff, 0x7f, 0x41]).should be_nil
    # …while a pickle the capture cap cut short past the preamble IS kept: it read real
    # opcodes, then stopped for want of input having consumed every byte it had.
    sniffed(SerializedVectors::PICKLE_REDUCE[0, 20]).should eq("python-pickle")
  end

  it "keeps a signed ViewState, whose MAC the reader consumes rather than calling it trailing" do
    signed = SerializedVectors::VIEWSTATE_CLASSIC + Bytes.new(20, 0xab_u8)
    name, r = S.sniff(signed).not_nil!
    name.should eq("aspnet-viewstate")
    r.json.should contain(%("algorithm":"SHA1 / HMACSHA1"))
  end
end
