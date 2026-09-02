require "../spec_helper"

# `Gori::Export::Escape` — the one byte→literal escaper the code serializers share, plus the
# URL rule every one of them now runs a captured URL through.

describe Gori::Export::Escape do
  describe ".percent_encode_non_ascii" do
    it "returns an all-ASCII URL unchanged" do
      url = "https://h.test/a/b?q=1&r=%20#frag"
      Gori::Export::Escape.percent_encode_non_ascii(url).should be(url)
    end

    it "percent-encodes non-ASCII bytes in the path, the query and the fragment" do
      Gori::Export::Escape.percent_encode_non_ascii("https://h.test/안?q=안#안")
        .should eq("https://h.test/%EC%95%88?q=%EC%95%88#%EC%95%88")
    end

    # A host is not text a client re-encodes, it is IDNA-encoded — and the parsers that get a raw
    # one right refuse the encoded form. Measured on the demo project's `https://쇼핑몰.한국/…`:
    # `urllib3.util.parse_url` answers `xn--352bl7khqr.xn--3e0b707e` for the raw URL and the
    # literal `%ec%87%bc…` for the encoded one, which is a name no resolver answers.
    it "leaves a non-ASCII authority alone and starts at the path" do
      Gori::Export::Escape.percent_encode_non_ascii("https://쇼핑몰.한국/api/주문/9")
        .should eq("https://쇼핑몰.한국/api/%EC%A3%BC%EB%AC%B8/9")
    end

    it "leaves an authority-only URL alone, with or without a port" do
      Gori::Export::Escape.percent_encode_non_ascii("https://쇼핑몰.한국")
        .should eq("https://쇼핑몰.한국")
      Gori::Export::Escape.percent_encode_non_ascii("https://쇼핑몰.한국:8443")
        .should eq("https://쇼핑몰.한국:8443")
    end

    it "starts at a query or fragment that follows the authority with no path" do
      Gori::Export::Escape.percent_encode_non_ascii("https://쇼핑몰.한국?q=안")
        .should eq("https://쇼핑몰.한국?q=%EC%95%88")
    end

    # Byte-wise: a captured URL that is not valid UTF-8 says exactly which bytes to request
    # rather than being scrubbed into U+FFFD (P7).
    it "encodes a byte sequence that is not valid UTF-8" do
      io = IO::Memory.new
      io << "https://h.test/"
      io.write(Bytes[0x80_u8, 0xff_u8])
      Gori::Export::Escape.percent_encode_non_ascii(String.new(io.to_slice))
        .should eq("https://h.test/%80%FF")
    end

    it "encodes from byte 0 when there is no scheme://authority to skip" do
      Gori::Export::Escape.percent_encode_non_ascii("/안").should eq("/%EC%95%88")
    end
  end
end
