require "./spec_helper"

# Builds an HTTP head Bytes from a request line + header pairs.
private def head(line : String, *headers) : Bytes
  String.build do |io|
    io << line << "\r\n"
    headers.each { |h| io << h << "\r\n" }
    io << "\r\n"
  end.to_slice
end

# Builds a multipart/form-data body (CRLF-delimited) from ready-made part blocks.
# Each block is the text between two boundaries, e.g.
#   "Content-Disposition: form-data; name=\"a\"\r\n\r\nval"
private def multipart_body(boundary : String, *parts : String) : String
  String.build do |io|
    parts.each { |p| io << "--" << boundary << "\r\n" << p << "\r\n" }
    io << "--" << boundary << "--\r\n"
  end
end

private def urlencoded_head : Bytes
  head("POST / HTTP/1.1", "Content-Type: application/x-www-form-urlencoded")
end

private def multipart_head(boundary : String) : Bytes
  head("POST / HTTP/1.1", "Content-Type: multipart/form-data; boundary=#{boundary}")
end

# Fetch the (first) field with the given name from a from_flow result.
private def field_named(fields : Array(Gori::FormData::Field)?, name : String) : Gori::FormData::Field?
  fields.try(&.find { |f| f.name == name })
end

describe Gori::FormData do
  describe ".from_flow — urlencoded body + query folding" do
    it "decodes a urlencoded body into two :body fields" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "a=1&b=2".to_slice)
      fields.should_not be_nil
      fields = fields.not_nil!
      fields.size.should eq(2)
      fields[0].should eq(Gori::FormData::Field.new("a", "1", :body))
      fields[1].should eq(Gori::FormData::Field.new("b", "2", :body))
    end

    it "folds the target query string in as :query fields alongside the body" do
      fields = Gori::FormData.from_flow("/login?next=%2Fhome&t=1", urlencoded_head, "a=1".to_slice)
      fields.should_not be_nil
      fields = fields.not_nil!
      # query fields come first (source :query), then body fields (source :body)
      field_named(fields, "next").should eq(Gori::FormData::Field.new("next", "/home", :query))
      field_named(fields, "t").should eq(Gori::FormData::Field.new("t", "1", :query))
      field_named(fields, "a").should eq(Gori::FormData::Field.new("a", "1", :body))
    end

    it "url-decodes percent-encoded multibyte (CJK) and emoji values" do
      # %EC%95%88%EB%85%95 = 안녕 ; %F0%9F%98%80 = 😀
      fields = Gori::FormData.from_flow("/", urlencoded_head,
        "greet=%EC%95%88%EB%85%95&face=%F0%9F%98%80".to_slice)
      field_named(fields, "greet").not_nil!.value.should eq("안녕")
      field_named(fields, "face").not_nil!.value.should eq("😀")
    end

    it "decodes percent-encoded names as well as values" do
      # %ED%95%9C = 한
      fields = Gori::FormData.from_flow("/", urlencoded_head, "%ED%95%9C=x".to_slice)
      field_named(fields, "한").not_nil!.value.should eq("x")
    end

    it "decodes a '+' as a space per www-form rules" do
      Gori::FormData.from_flow("/", urlencoded_head, "q=a+b".to_slice)
        .not_nil!.first.value.should eq("a b")
    end
  end

  describe ".from_flow — urlencoded edges" do
    it "treats a pair with no '=' as an empty value" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "flag".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("flag", "", :body))
    end

    it "rejects the empty pairs produced by adjacent separators (a=1&&b=2)" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "a=1&&b=2".to_slice)
      fields.not_nil!.size.should eq(2)
      fields.not_nil!.map(&.name).should eq(["a", "b"])
    end

    it "drops leading/trailing/duplicate separators entirely" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "&&a=1&&&".to_slice)
      fields.not_nil!.size.should eq(1)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("a", "1", :body))
    end

    it "falls back to the raw token on a malformed percent-escape (no raise)" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "x=%ZZ".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("x", "%ZZ", :body))
    end

    it "falls back to the raw name on a malformed escape in the key" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "%GG=v".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("%GG", "v", :body))
    end

    it "keeps everything after the first '=' as the value (partition, not split)" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "a=b=c".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("a", "b=c", :body))
    end

    it "handles a bare '=' as an empty name and empty value" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "=".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("", "", :body))
    end

    it "distinguishes a=  (present-but-empty) from flag (no '=') — both value \"\"" do
      fields = Gori::FormData.from_flow("/", urlencoded_head, "a=&flag".to_slice)
      fields.not_nil!.map { |f| {f.name, f.value} }.should eq([{"a", ""}, {"flag", ""}])
    end
  end

  describe ".from_flow — content-type detection" do
    it "detects the header case-insensitively (lowercase 'content-type:')" do
      fields = Gori::FormData.from_flow("/",
        head("POST / HTTP/1.1", "content-type: application/x-www-form-urlencoded"),
        "a=1".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("a", "1", :body))
    end

    it "detects the header case-insensitively (UPPERCASE 'CONTENT-TYPE:')" do
      fields = Gori::FormData.from_flow("/",
        head("POST / HTTP/1.1", "CONTENT-TYPE: application/x-www-form-urlencoded"),
        "a=1".to_slice)
      fields.not_nil!.first.should eq(Gori::FormData::Field.new("a", "1", :body))
    end

    it "handles a bare 'Content-Type:' header (13 chars, empty value) — body not folded" do
      fields = Gori::FormData.from_flow("/x?q=1",
        head("POST / HTTP/1.1", "Content-Type:"), "a=1".to_slice)
      # empty CT matches neither urlencoded nor multipart → only the query field survives
      fields.not_nil!.map(&.name).should eq(["q"])
      field_named(fields, "q").not_nil!.source.should eq(:query)
    end

    it "yields only query fields when there is no Content-Type header at all" do
      fields = Gori::FormData.from_flow("/search?q=hi&p=2",
        head("POST / HTTP/1.1"), "a=1".to_slice)
      fields.not_nil!.map(&.source).uniq!.should eq([:query])
      fields.not_nil!.map(&.name).should eq(["q", "p"])
    end

    it "ignores a header line whose name only shares a prefix with content-type" do
      # "Content-Type-Options" must NOT be read as the Content-Type value.
      fields = Gori::FormData.from_flow("/?q=1",
        head("POST / HTTP/1.1", "X-Content-Type-Options: nosniff"), "a=1".to_slice)
      fields.not_nil!.map(&.name).should eq(["q"])
    end
  end

  describe ".from_flow — multipart parts" do
    it "inlines a text part as a :body field with no note" do
      body = multipart_body("BND", %(Content-Disposition: form-data; name="title"\r\n\r\nHello))
      fields = Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice)
      field_named(fields, "title").should eq(Gori::FormData::Field.new("title", "Hello", :body))
    end

    it "summarises a file part as 'file: <name> (N bytes)' with an empty value" do
      body = multipart_body("BND",
        %(Content-Disposition: form-data; name="avatar"; filename="x.png"\r\nContent-Type: image/png\r\n\r\nABCDE))
      f = field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "avatar").not_nil!
      f.value.should eq("")
      f.note.should eq("file: x.png (5 bytes)")
      f.source.should eq(:body)
    end

    it "notes a binary (invalid-encoding) part as 'binary, N bytes'" do
      io = IO::Memory.new
      io << "--BND\r\nContent-Disposition: form-data; name=\"blob\"\r\n\r\n"
      io.write(Bytes[0xff, 0xfe, 0x00])
      io << "\r\n--BND--\r\n"
      f = field_named(Gori::FormData.from_flow("/", multipart_head("BND"), io.to_slice), "blob").not_nil!
      f.value.should eq("")
      f.note.should eq("binary, 3 bytes")
    end

    it "notes an over-PART_MAX text part by size instead of inlining it" do
      big = "x" * (64 * 1024 + 1) # PART_MAX + 1
      body = multipart_body("BND", %(Content-Disposition: form-data; name="t"\r\n\r\n#{big}))
      f = field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "t").not_nil!
      f.value.should eq("") # not inlined
      f.note.not_nil!.should contain("65537 bytes")
    end

    it "inlines a text part exactly at PART_MAX (boundary, off-by-one)" do
      exact = "y" * (64 * 1024) # == PART_MAX
      body = multipart_body("BND", %(Content-Disposition: form-data; name="t"\r\n\r\n#{exact}))
      f = field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "t").not_nil!
      f.value.should eq(exact)
      f.note.should be_nil
    end

    it "names a part '(unnamed)' when its Content-Disposition has no name=" do
      body = multipart_body("BND", %(Content-Disposition: form-data\r\n\r\nhi))
      field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "(unnamed)")
        .should eq(Gori::FormData::Field.new("(unnamed)", "hi", :body))
    end

    it "preserves a multibyte (CJK/emoji) filename in the file note" do
      body = multipart_body("BND",
        %(Content-Disposition: form-data; name="f"; filename="사진😀.png"\r\n\r\nZZ))
      field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "f")
        .not_nil!.note.should eq("file: 사진😀.png (2 bytes)")
    end

    # SUSPECTED BUG: a browser sends `filename=""` for a file input with NO file selected.
    # part_field does `if filename = FILENAME_RE.match(cd).try(&.[1])`, and an empty String is
    # truthy in Crystal, so the empty filename is treated as a real FILE part and emits the
    # meaningless note "file:  (0 bytes)". The documented contract is that `note` carries a
    # file/binary summary — an unselected file is neither. It should fall through to the
    # inline-text branch (an empty :body field, note nil). Marked pending so the suite stays
    # green without enshrining the buggy note.
    it "treats filename=\"\" (no file selected) as an empty field, not a file part" do
      body = multipart_body("BND", %(Content-Disposition: form-data; name="f"; filename=""\r\n\r\n))
      f = field_named(Gori::FormData.from_flow("/", multipart_head("BND"), body.to_slice), "f").not_nil!
      f.note.should be_nil
      f.value.should eq("")
    end
  end

  describe ".from_flow — multipart limits & tolerance" do
    it "stops collecting parts at MAX_PARTS (256)" do
      parts = Array.new(300) { |i| %(Content-Disposition: form-data; name="p#{i}"\r\n\r\nv) }
      # build the body manually (splat of a runtime array is not allowed)
      raw = String.build do |io|
        parts.each { |p| io << "--BND\r\n" << p << "\r\n" }
        io << "--BND--\r\n"
      end
      fields = Gori::FormData.from_flow("/", multipart_head("BND"), raw.to_slice)
      fields.not_nil!.size.should eq(256)
    end

    it "keeps whatever parsed before a malformed/truncated part (rescue, no raise)" do
      raw = "--BND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nval\r\n" \
            "--BND\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\ntrunc"
      fields = Gori::FormData.from_flow("/", multipart_head("BND"), raw.to_slice)
      # the fully-formed first part must survive the tolerant parse
      field_named(fields, "a").not_nil!.value.should eq("val")
    end

    it "yields no multipart fields when the boundary is absent" do
      body = multipart_body("BND", %(Content-Disposition: form-data; name="a"\r\n\r\nv))
      Gori::FormData.from_flow("/",
        head("POST / HTTP/1.1", "Content-Type: multipart/form-data"), body.to_slice)
        .should be_nil
    end

    it "yields no multipart fields when the boundary is empty" do
      Gori::FormData.from_flow("/",
        head("POST / HTTP/1.1", "Content-Type: multipart/form-data; boundary="),
        "--\r\n".to_slice).should be_nil
    end

    it "still folds the query string when the multipart body is unparseable" do
      Gori::FormData.from_flow("/u?ok=1",
        head("POST / HTTP/1.1", "Content-Type: multipart/form-data"), "garbage".to_slice)
        .not_nil!.map(&.name).should eq(["ok"])
    end
  end

  describe ".from_flow — ceilings & nil" do
    it "skips a body over MAX_BODY (8MiB+1) and returns query fields only" do
      big = Bytes.new(8 * 1024 * 1024 + 1, 'a'.ord.to_u8) # MAX_BODY + 1
      fields = Gori::FormData.from_flow("/q?keep=1", urlencoded_head, big)
      fields.not_nil!.map(&.name).should eq(["keep"])
      fields.not_nil!.first.source.should eq(:query)
    end

    it "still parses a body exactly at MAX_BODY (boundary, off-by-one)" do
      # "a=" + 'x' repeated to hit exactly MAX_BODY bytes.
      pad = "x" * (8 * 1024 * 1024 - 2)
      fields = Gori::FormData.from_flow("/", urlencoded_head, "a=#{pad}".to_slice)
      fields.not_nil!.first.name.should eq("a")
      fields.not_nil!.first.value.bytesize.should eq(pad.bytesize)
    end

    it "returns nil when there is neither a query nor a parseable body" do
      Gori::FormData.from_flow("/api",
        head("POST /api HTTP/1.1", "Content-Type: application/json"),
        %({"a":1}).to_slice).should be_nil
    end

    it "returns nil for an empty body and no query" do
      Gori::FormData.from_flow("/", urlencoded_head, "".to_slice).should be_nil
    end

    it "returns nil when req_body is nil and there is no query" do
      Gori::FormData.from_flow("/", urlencoded_head, nil).should be_nil
    end

    it "returns nil for a bare target with no '?'" do
      Gori::FormData.from_flow("/plain", nil, nil).should be_nil
    end

    it "returns nil for a target with a '?' but an empty query" do
      Gori::FormData.from_flow("/plain?", nil, nil).should be_nil
    end

    it "caps the total field list at MAX_FIELDS (500)" do
      raw = (1..600).map { |i| "k#{i}=#{i}" }.join("&")
      fields = Gori::FormData.from_flow("/", urlencoded_head, raw.to_slice)
      fields.not_nil!.size.should eq(500)
    end
  end

  describe ".from_flow — adversarial / robustness" do
    it "completes quickly on a huge urlencoded body (no pathological blowup)" do
      raw = (["a=1"] * 200_000).join("&")
      elapsed = Time.measure do
        Gori::FormData.from_flow("/", urlencoded_head, raw.to_slice)
      end
      elapsed.total_seconds.should be < 5.0
    end

    it "does not raise on invalid-UTF-8 bytes in a urlencoded body (String.new tolerant)" do
      io = IO::Memory.new
      io << "a="
      io.write(Bytes[0xff, 0xfe])
      # must not raise; the field is produced with whatever String.new yields
      Gori::FormData.from_flow("/", urlencoded_head, io.to_slice).should_not be_nil
    end

    it "does not raise on a truncated percent-escape at the very end of a value" do
      Gori::FormData.from_flow("/", urlencoded_head, "a=%E".to_slice)
        .not_nil!.first.value.should eq("%E")
    end

    it "extracts unquoted and single-quoted name and filename parameters in multipart forms" do
      boundary = "----Boundary123"
      body = multipart_body(boundary,
        "Content-Disposition: form-data; name=unquoted_name; filename=unquoted.txt\r\n\r\ncontent",
        "Content-Disposition: form-data; name='single_quoted'; filename='single.txt'\r\n\r\ncontent")
      fields = Gori::FormData.from_flow("/", multipart_head(boundary), body.to_slice).not_nil!
      fields.size.should eq(2)
      fields[0].name.should eq("unquoted_name")
      fields[0].note.not_nil!.should contain("file: unquoted.txt")
      fields[1].name.should eq("single_quoted")
      fields[1].note.not_nil!.should contain("file: single.txt")
    end
  end
end
