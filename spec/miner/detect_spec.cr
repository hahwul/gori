require "../spec_helper"

private alias M = Gori::Miner

private def req(s : String) : Bytes
  s.to_slice
end

# Build a request whose body carries raw (possibly non-UTF-8) bytes: the request line +
# headers + blank line are written as text, then the raw body bytes are appended verbatim.
private def req_with_body(head : String, body : Bytes) : Bytes
  io = IO::Memory.new
  io << head
  io.write(body)
  io.to_slice
end

describe Gori::Miner::Detect do
  describe "json by body shape (body_looks_json?) even with a non-JSON content-type" do
    it "offers Json for a {\"a\":1} object body sent as text/plain" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
      appl = M::Detect.detect(req(base))
      appl.applicable.should contain(M::Location::Json)
      appl.default.should contain(M::Location::Json)
    end

    it "offers Json for an array-of-objects body sent as text/plain" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\n[{\"a\":1}]"
      M::Detect.detect(req(base)).applicable.should contain(M::Location::Json)
    end

    it "offers Json for a multibyte object body (CJK keys/values) sent as text/plain" do
      body = %({"\u{540D}":"\u{4E16}\u{754C}","안녕":true})
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      M::Detect.detect(req(base)).applicable.should contain(M::Location::Json)
    end

    it "does NOT offer Json for a plain-text non-JSON body under text/plain" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
      M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Json)
    end
  end

  describe "body_looks_json? whitespace tolerance (lstrip)" do
    it "tolerates leading spaces before the open brace under text/plain" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\n   {\"a\":1}"
      M::Detect.detect(req(base)).applicable.should contain(M::Location::Json)
    end

    it "tolerates mixed leading whitespace (tab/newline/CR) before an array root" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\n\t\r\n [{\"a\":1}]"
      M::Detect.detect(req(base)).applicable.should contain(M::Location::Json)
    end

    it "does not treat a body with non-whitespace leading junk as JSON" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 8\r\n\r\nx {\"a\":1}"
      M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Json)
    end
  end

  describe "body_looks_json? invalid-UTF-8 scrub (first 64 bytes)" do
    it "scrubs a body with leading invalid UTF-8 bytes without raising and offers no Json (text/plain)" do
      # 0xff/0xfe are invalid UTF-8 lead bytes; scrub -> replacement char (not whitespace),
      # so lstrip cannot expose the following brace and the shape sniff must be false.
      head = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\n"
      body = IO::Memory.new
      body.write(Bytes[0xff_u8, 0xfe_u8, 0xff_u8])
      body << "{\"a\":1}"
      bytes = req_with_body(head, body.to_slice)
      appl = M::Detect.detect(bytes)
      appl.applicable.should eq([M::Location::Query, M::Location::Headers, M::Location::Cookies])
    end

    it "does not raise when the first 64 bytes are entirely invalid UTF-8 (text/plain)" do
      head = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 80\r\n\r\n"
      junk = Bytes.new(80) { 0xff_u8 }
      bytes = req_with_body(head, junk)
      appl = M::Detect.detect(bytes)
      appl.applicable.should_not contain(M::Location::Json)
    end
  end

  describe "has_body guard for empty bodies" do
    it "does NOT offer Json for application/json with an empty body" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"
      appl = M::Detect.detect(req(base))
      appl.applicable.should eq([M::Location::Query, M::Location::Headers, M::Location::Cookies])
      appl.applicable.should_not contain(M::Location::Json)
      appl.default.should eq([M::Location::Query])
    end

    it "does NOT offer Form for x-www-form-urlencoded with an empty body" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n"
      appl = M::Detect.detect(req(base))
      appl.applicable.should eq([M::Location::Query, M::Location::Headers, M::Location::Cookies])
      appl.applicable.should_not contain(M::Location::Form)
      appl.default.should eq([M::Location::Query])
    end

    it "does NOT offer Multipart for multipart/form-data with an empty body" do
      base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: 0\r\n\r\n"
      M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Multipart)
    end
  end

  describe "multipart content-type case-insensitivity" do
    it "offers Multipart for an upper-case MULTIPART/FORM-DATA content-type" do
      body = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B--\r\n"
      base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: MULTIPART/FORM-DATA; boundary=B\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      appl = M::Detect.detect(req(base))
      appl.applicable.should contain(M::Location::Multipart)
      appl.default.should_not contain(M::Location::Multipart)
    end

    it "offers Multipart for a mixed-case content-type with leading whitespace" do
      body = "--xyz\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--xyz--\r\n"
      base = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Type: Multipart/Form-Data; boundary=xyz\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
      M::Detect.detect(req(base)).applicable.should contain(M::Location::Multipart)
    end
  end

  describe "json shape sniffs but has no object node (json_object_node_count == 0)" do
    it "does NOT offer Json for an array of scalars that looks like JSON under text/plain" do
      # body_looks_json? is true (leading '['), but there is no injectable object node.
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 7\r\n\r\n[1,2,3]"
      M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Json)
    end

    it "does NOT offer Json for a bare-scalar-ish body that does not start with brace/bracket" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\n123"
      M::Detect.detect(req(base)).applicable.should_not contain(M::Location::Json)
    end
  end

  describe "location ordering and always-applicable locations" do
    it "always appends Headers and Cookies (default OFF) after body locations" do
      base = "POST /a HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nx=1"
      appl = M::Detect.detect(req(base))
      appl.applicable.should eq([M::Location::Query, M::Location::Form, M::Location::Headers, M::Location::Cookies])
      appl.default.should eq([M::Location::Query, M::Location::Form])
    end
  end
end
