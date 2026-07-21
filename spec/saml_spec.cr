require "./spec_helper"
require "base64"
require "compress/deflate"
require "uri"

# Raw DEFLATE (RFC 1951) a string, mirroring Saml#raw_deflate, so we can build
# HTTP-Redirect binding fixtures the way the wire carries them.
private def deflate(s : String) : Bytes
  io = IO::Memory.new
  Compress::Deflate::Writer.open(io, &.write(s.to_slice))
  io.to_slice
end

# base64(xml) — the HTTP-POST binding wire value (already url-decoded form).
private def post_value(xml : String) : String
  Base64.strict_encode(xml.to_slice)
end

# base64(deflate(xml)) — the HTTP-Redirect binding wire value (url-decoded form).
private def redirect_value(xml : String) : String
  Base64.strict_encode(deflate(xml))
end

# A representative assertion body used across the binding cases.
private SAMPLE_XML = "<samlp:AuthnRequest ID=\"a\">안녕 世界</samlp:AuthnRequest>"

describe Gori::Saml do
  describe ".decode_value (binding auto-detect)" do
    it "reads a base64(literal XML) payload as the HTTP-POST binding" do
      dec = Gori::Saml.decode_value(post_value(SAMPLE_XML))
      dec.should eq({SAMPLE_XML, :post})
    end

    it "reads a base64(raw-DEFLATE(xml)) payload as the HTTP-Redirect binding" do
      dec = Gori::Saml.decode_value(redirect_value(SAMPLE_XML))
      dec.should eq({SAMPLE_XML, :redirect})
    end

    it "returns nil for base64 of a non-XML string" do
      Gori::Saml.decode_value(post_value("hello")).should be_nil
    end

    it "returns nil for a non-base64 value" do
      Gori::Saml.decode_value("!!!").should be_nil
    end

    it "returns nil for an empty value" do
      Gori::Saml.decode_value("").should be_nil
    end

    it "returns nil when base64 decodes to empty bytes" do
      # A padding-only value decodes to zero bytes -> not a document.
      Gori::Saml.decode_value("====").should be_nil
    end

    it "strips embedded whitespace before decoding (no url-decode)" do
      raw = post_value("<x/>")
      spaced = "#{raw[0, 2]} \t\r\n#{raw[2..]}"
      Gori::Saml.decode_value(spaced).should eq({"<x/>", :post})
    end

    it "detects the shortest valid XML document" do
      Gori::Saml.decode_value(post_value("<")).should eq({"<", :post})
    end
  end

  describe ".decode_value MAX_XML ceiling" do
    it "surfaces a decoded POST document sized exactly MAX_XML" do
      xml = "<" + "a" * (Gori::Saml::MAX_XML - 1)
      xml.bytesize.should eq(Gori::Saml::MAX_XML)
      dec = Gori::Saml.decode_value(post_value(xml))
      dec.should_not be_nil
      dec.not_nil![1].should eq(:post)
      dec.not_nil![0].bytesize.should eq(Gori::Saml::MAX_XML)
    end

    it "rejects a decoded POST document one byte over MAX_XML" do
      xml = "<" + "a" * Gori::Saml::MAX_XML
      xml.bytesize.should eq(Gori::Saml::MAX_XML + 1)
      Gori::Saml.decode_value(post_value(xml)).should be_nil
    end
  end

  describe ".decode_value looks_like_xml? detection" do
    it "treats leading spaces/tabs/CR/LF before '<' as XML" do
      Gori::Saml.decode_value(post_value(" \t\r\n<x/>")).should eq({" \t\r\n<x/>", :post})
    end

    it "treats a UTF-8 BOM followed by '<' as XML (BOM retained in the decoded bytes)" do
      bom = String.new(Bytes[0xEF_u8, 0xBB_u8, 0xBF_u8]) + "<x/>"
      dec = Gori::Saml.decode_value(post_value(bom))
      dec.should_not be_nil
      dec.not_nil![1].should eq(:post)
      dec.not_nil![0].should eq(bom)
    end

    it "rejects bytes whose first non-whitespace byte is not '<'" do
      Gori::Saml.decode_value(post_value("   plain text")).should be_nil
      Gori::Saml.decode_value(post_value("{\"json\":1}")).should be_nil
    end
  end

  describe ".encode_value" do
    it "base64+URL-encodes without DEFLATE for HTTP-POST" do
      # "<x/>" -> base64 "PHgvPg==" -> URL-encode -> "PHgvPg%3D%3D"
      Gori::Saml.encode_value("<x/>", :post).should eq("PHgvPg%3D%3D")
    end

    it "DEFLATEs then base64+URL-encodes for HTTP-Redirect" do
      expected = URI.encode_www_form(Base64.strict_encode(deflate(SAMPLE_XML)))
      Gori::Saml.encode_value(SAMPLE_XML, :redirect).should eq(expected)
    end

    it "round-trips through url-decode + decode_value for HTTP-Redirect" do
      wire = Gori::Saml.encode_value(SAMPLE_XML, :redirect)
      value = URI.decode_www_form(wire, plus_to_space: false)
      Gori::Saml.decode_value(value).should eq({SAMPLE_XML, :redirect})
    end

    it "round-trips through url-decode + decode_value for HTTP-POST" do
      wire = Gori::Saml.encode_value(SAMPLE_XML, :post)
      value = URI.decode_www_form(wire, plus_to_space: false)
      Gori::Saml.decode_value(value).should eq({SAMPLE_XML, :post})
    end
  end

  describe ".replace_param" do
    it "replaces only the first matching pair, leaving siblings byte-for-byte" do
      out = Gori::Saml.replace_param(
        "SAMLResponse=OLD&RelayState=/app%2Fx&SigAlg=rsa-sha256",
        "SAMLResponse", "NEW")
      out.should eq("SAMLResponse=NEW&RelayState=/app%2Fx&SigAlg=rsa-sha256")
    end

    it "replaces only the first of duplicate keys" do
      Gori::Saml.replace_param("a=1&a=2", "a", "NEW").should eq("a=NEW&a=2")
    end

    it "appends the pair when the param is absent" do
      Gori::Saml.replace_param("RelayState=x", "SAMLResponse", "V")
        .should eq("RelayState=x&SAMLResponse=V")
    end

    it "produces 'param=value' from an empty original" do
      Gori::Saml.replace_param("", "SAMLResponse", "V").should eq("SAMLResponse=V")
    end

    it "does not match a bare key with no '=', appending instead" do
      # "SAMLResponse" (no '=') partitions with an empty separator, so it is not
      # a match; the pair is appended and the bare key survives untouched.
      Gori::Saml.replace_param("SAMLResponse&x=1", "SAMLResponse", "V")
        .should eq("SAMLResponse&x=1&SAMLResponse=V")
    end

    it "matches a param whose value is empty" do
      Gori::Saml.replace_param("SAMLResponse=&x=1", "SAMLResponse", "V")
        .should eq("SAMLResponse=V&x=1")
    end
  end

  describe ".from_flow / .from_request precedence" do
    it "prefers a request-body SAMLResponse over the URL query" do
      body = "SAMLResponse=#{post_value("<body/>")}"
      target = "https://sp/acs?SAMLRequest=#{post_value("<query/>")}"
      doc = Gori::Saml.from_flow(target, nil, body.to_slice, nil, nil)
      doc.should_not be_nil
      doc.not_nil!.param.should eq("SAMLResponse")
      doc.not_nil!.location.should eq(:body)
      doc.not_nil!.xml.should eq("<body/>")
    end

    it "falls back to the URL query (HTTP-Redirect) when the body has no SAML param" do
      redir = URI.encode_www_form(redirect_value("<query/>"))
      target = "https://idp/sso?SAMLRequest=#{redir}&RelayState=rs"
      doc = Gori::Saml.from_flow(target, nil, "unrelated=1".to_slice, nil, nil)
      doc.should_not be_nil
      doc.not_nil!.param.should eq("SAMLRequest")
      doc.not_nil!.location.should eq(:query)
      doc.not_nil!.binding.should eq(:redirect)
    end

    it "url-decodes RelayState onto the Doc" do
      body = "SAMLResponse=#{post_value("<x/>")}&RelayState=%2Fapp%2Fhome"
      doc = Gori::Saml.from_flow("t", nil, body.to_slice, nil, nil)
      doc.not_nil!.relay_state.should eq("/app/home")
    end

    it "leaves relay_state nil when no RelayState pair is present" do
      body = "SAMLResponse=#{post_value("<x/>")}"
      Gori::Saml.from_flow("t", nil, body.to_slice, nil, nil).not_nil!.relay_state.should be_nil
    end

    it "keeps a literal '+' in the base64 value (plus_to_space: false)" do
      # base64 of "<a>ûÿ</a>" contains a literal '+', a valid base64 char
      # that must NOT be folded to a space before decode.
      xml = "<a>ûÿ</a>"
      value = Base64.strict_encode(xml.to_slice)
      value.includes?("+").should be_true
      body = "SAMLResponse=#{value}"
      doc = Gori::Saml.from_flow("t", nil, body.to_slice, nil, nil)
      doc.should_not be_nil
      doc.not_nil!.xml.should eq(xml)
    end

    it "returns nil for a flow carrying no SAML message" do
      Gori::Saml.from_flow("https://x/y?q=1", nil, "a=b".to_slice, nil, nil).should be_nil
      Gori::Saml.from_flow("https://x/y", nil, nil, nil, nil).should be_nil
    end
  end

  describe ".from_response_html" do
    it "extracts a SAMLResponse from a hidden input with name-before-value (AFTER)" do
      b64 = post_value("<resp/>")
      html = "<html><body><form action=\"/acs\" method=\"post\">" \
             "<input type=\"hidden\" name=\"SAMLResponse\" value=\"#{b64}\"/>" \
             "</form></body></html>"
      doc = Gori::Saml.from_flow("t", nil, nil, nil, html.to_slice)
      doc.should_not be_nil
      doc.not_nil!.param.should eq("SAMLResponse")
      doc.not_nil!.location.should eq(:response)
      doc.not_nil!.xml.should eq("<resp/>")
    end

    it "extracts a SAMLResponse from value-before-name attribute order (BEFORE)" do
      b64 = post_value("<resp/>")
      html = "<input value='#{b64}' type='hidden' name='SAMLResponse'/>"
      doc = Gori::Saml.from_flow("t", nil, nil, nil, html.to_slice)
      doc.should_not be_nil
      doc.not_nil!.location.should eq(:response)
      doc.not_nil!.xml.should eq("<resp/>")
    end

    it "unescapes '&amp;'/'&#43;' inside the attribute value before decoding" do
      # An HTML-escaped '+' (as &#43;) inside the value must be restored so the
      # base64 alphabet survives the attribute encoding.
      xml = "<a>ûÿ</a>"
      b64 = Base64.strict_encode(xml.to_slice)
      b64.includes?("+").should be_true
      escaped = b64.gsub("+", "&#43;")
      html = "<input name=\"SAMLResponse\" value=\"#{escaped}\">"
      doc = Gori::Saml.from_flow("t", nil, nil, nil, html.to_slice)
      doc.should_not be_nil
      doc.not_nil!.xml.should eq(xml)
    end

    it "scrubs a hostile invalid-UTF-8 response body containing 'SAMLResponse' and does not raise" do
      # Invalid bytes around the literal must be scrubbed (String.new doesn't validate,
      # Regex#match raises on invalid bytes) — the decoder must survive and return nil.
      hostile = Bytes[0x3C_u8, 0xFF_u8, 0xFE_u8] +
                "SAMLResponse".to_slice +
                Bytes[0xC0_u8, 0x80_u8, 0xFF_u8]
      # If the scrub were missing this would raise and fail the example.
      Gori::Saml.from_flow("t", nil, nil, nil, hostile).should be_nil
    end

    it "returns nil for a response body without the SAMLResponse marker" do
      Gori::Saml.from_flow("t", nil, nil, nil, "<html>nothing here</html>".to_slice).should be_nil
    end

    it "returns nil for a response body larger than MAX_XML" do
      big = Bytes.new(Gori::Saml::MAX_XML + 1, 0x20_u8)
      Gori::Saml.from_flow("t", nil, nil, nil, big).should be_nil
    end
  end

  describe ".summary" do
    it "labels the HTTP-POST binding and a request-body location" do
      body = "SAMLResponse=#{post_value("<x/>")}"
      doc = Gori::Saml.from_flow("t", nil, body.to_slice, nil, nil).not_nil!
      Gori::Saml.summary(doc).should eq("SAMLResponse · HTTP-POST binding · request body")
    end

    it "labels the HTTP-Redirect binding and a URL-query location, appending RelayState" do
      redir = URI.encode_www_form(redirect_value("<q/>"))
      target = "https://idp/sso?SAMLRequest=#{redir}&RelayState=state1"
      doc = Gori::Saml.from_flow(target, nil, nil, nil, nil).not_nil!
      Gori::Saml.summary(doc)
        .should eq("SAMLRequest · HTTP-Redirect binding · URL query · RelayState: state1")
    end

    it "labels a response-form location" do
      html = "<input name=\"SAMLResponse\" value=\"#{post_value("<r/>")}\">"
      doc = Gori::Saml.from_flow("t", nil, nil, nil, html.to_slice).not_nil!
      Gori::Saml.summary(doc).should eq("SAMLResponse · HTTP-POST binding · response form")
    end

    it "appends RelayState only when it is present" do
      body = "SAMLResponse=#{post_value("<x/>")}"
      no_rs = Gori::Saml.from_flow("t", nil, body.to_slice, nil, nil).not_nil!
      Gori::Saml.summary(no_rs).includes?("RelayState").should be_false

      with_rs = Gori::Saml.from_flow("t", nil, "#{body}&RelayState=r".to_slice, nil, nil).not_nil!
      Gori::Saml.summary(with_rs).should end_with("· RelayState: r")
    end
  end

  describe ".decode_value raw_inflate tolerance" do
    it "keeps the partial head of a truncated DEFLATE stream" do
      xml = "<root><child>hello world, some text worth compressing here</child></root>"
      full = deflate(xml)
      truncated = full[0, full.size // 2]
      dec = Gori::Saml.decode_value(Base64.strict_encode(truncated))
      dec.should_not be_nil
      dec.not_nil![1].should eq(:redirect)
      dec.not_nil![0].starts_with?("<root>").should be_true
    end

    it "completes quickly on a large adversarial deflate bomb (bounded output)" do
      # 8 MiB of NULs compresses to a tiny stream that inflates past MAX_XML; the
      # bounded reader must stop, not run away. Does not look like XML -> nil.
      bomb = deflate(String.new(Bytes.new(8 * 1024 * 1024, 0_u8)))
      elapsed = Time.measure do
        Gori::Saml.decode_value(Base64.strict_encode(bomb)).should be_nil
      end
      elapsed.should be < 5.seconds
    end
  end
end
