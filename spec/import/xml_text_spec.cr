require "../spec_helper"

describe Gori::Import::XmlText do
  describe ".unescape" do
    it "keeps uppercase hex entities verbatim" do
      Gori::Import::XmlText.unescape("&#X41;").should eq("&#X41;")
      Gori::Import::XmlText.unescape("&#XA;").should eq("&#XA;")
    end

    it "keeps unknown named entities verbatim" do
      Gori::Import::XmlText.unescape("&foo;").should eq("&foo;")
    end

    it "keeps lone surrogate numeric entities verbatim" do
      Gori::Import::XmlText.unescape("&#xD800;").should eq("&#xD800;")
      Gori::Import::XmlText.unescape("&#xd800;").should eq("&#xd800;")
      Gori::Import::XmlText.unescape("&#xDFFF;").should eq("&#xDFFF;")
    end

    it "keeps out-of-range codepoints verbatim" do
      Gori::Import::XmlText.unescape("&#x110000;").should eq("&#x110000;")
      Gori::Import::XmlText.unescape("&#1114112;").should eq("&#1114112;")
    end

    it "keeps numeric overflow codepoints verbatim" do
      Gori::Import::XmlText.unescape("&#x10000000000000000;").should eq("&#x10000000000000000;")
      Gori::Import::XmlText.unescape("&#999999999999999999999999999999;").should eq("&#999999999999999999999999999999;")
    end

    it "keeps malformed ampersands verbatim" do
      Gori::Import::XmlText.unescape("&;").should eq("&;")
      Gori::Import::XmlText.unescape("&").should eq("&")
      Gori::Import::XmlText.unescape("&foo").should eq("&foo")
      Gori::Import::XmlText.unescape("trailing &").should eq("trailing &")
    end

    it "decodes decimal, lowercase hex, and the five predefined XML entities" do
      Gori::Import::XmlText.unescape("&#65;").should eq("A")
      Gori::Import::XmlText.unescape("&#x41;").should eq("A")
      Gori::Import::XmlText.unescape("&quot;&amp;&apos;&lt;&gt;").should eq("\"&'<>")
    end

    it "passes non-ASCII and invalid UTF-8 bytes around an entity through untouched" do
      raw_bytes = Bytes[0xFF, 0xFE, 0x26, 0x61, 0x6D, 0x70, 0x3B, 0xC0, 0xAF]
      raw_str = String.new(raw_bytes)
      unescaped = Gori::Import::XmlText.unescape(raw_str)
      expected_bytes = Bytes[0xFF, 0xFE, 0x26, 0xC0, 0xAF]
      unescaped.to_slice.should eq(expected_bytes)
    end
  end

  describe ".cdata?" do
    it "detects CDATA with leading whitespace" do
      Gori::Import::XmlText.cdata?("<![CDATA[test]]>").should be_true
      Gori::Import::XmlText.cdata?("   <![CDATA[test]]>").should be_true
      Gori::Import::XmlText.cdata?("\n\t<![CDATA[test]]>").should be_true
      Gori::Import::XmlText.cdata?("plain").should be_false
    end
  end

  describe ".uncdata" do
    it "strips the CDATA wrapper" do
      Gori::Import::XmlText.uncdata("<![CDATA[test]]>").should eq("test")
      Gori::Import::XmlText.uncdata("  <![CDATA[hello world]]>  ").should eq("hello world")
      Gori::Import::XmlText.uncdata("plain text").should eq("plain text")
    end
  end
end
