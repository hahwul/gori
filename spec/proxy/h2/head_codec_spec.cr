require "../../spec_helper"

private alias HeadCodec = Gori::Proxy::H2::HeadCodec
private alias Field = Gori::Proxy::H2::HPACK::Field

private def f(name : String, value : String, never = false) : Field
  Field.new(name, value, never)
end

private def tuples(fields : Array(Field))
  fields.map(&.to_tuple)
end

private def req_fields : Array(Field)
  [f(":method", "GET"), f(":scheme", "https"), f(":authority", "api.example.com"), f(":path", "/x")]
end

# The round trip exactly as `HeadRewrite` drives it, with no rule in between: whatever comes
# back differing from what went in is a field the h1 text could not carry.
private def round_trip(fields : Array(Field), request : Bool) : Array(Field)?
  return HeadCodec.parse_response(HeadCodec.synth_response(tuples(fields)), fields) unless request
  authority = HeadCodec.pseudo(tuples(fields), ":authority") || "conn.example.com"
  HeadCodec.parse_request(HeadCodec.synth_request(tuples(fields), authority), fields)
end

private record Entry, label : String, fields : Array(Field), request : Bool, faithful : Bool

# A request/response carrying one field under test, plus a tail field so a truncating or
# field-dropping round trip is visible and not just a shorter list of one.
private def rq(field : Field, faithful : Bool, label : String) : Entry
  Entry.new(label, req_fields + [field, f("x-tail", "z")], true, faithful)
end

private def rs(field : Field, faithful : Bool, label : String) : Entry
  Entry.new(label, [f(":status", "200"), field, f("x-tail", "z")], false, faithful)
end

private def both(field : Field, faithful : Bool, label : String) : Array(Entry)
  [rq(field, faithful, "#{label} (request)"), rs(field, faithful, "#{label} (response)")]
end

private INVALID_UTF8_VALUE = String.new(Bytes[0x61_u8, 0xff_u8, 0xfe_u8, 0x62_u8])
private INVALID_UTF8_NAME  = String.new(Bytes[0x78_u8, 0xff_u8, 0x2d_u8, 0x61_u8])

private CORPUS = [
  # --- regular fields: what the line-split and the `name: value` cut cannot carry ----------
  both(f("x-echo", "safe\r\nset-cookie: injected=1"), false, "a CRLF in a value (it becomes TWO fields)"),
  both(f("x-echo", "a\r\n\r\nGET /x HTTP/1.1"), false, "a double CRLF in a value (it TRUNCATES the head)"),
  both(f("x-echo", "safe\rset-cookie: injected=1"), false, "a lone CR in a value"),
  both(f("x-echo", "safe\nset-cookie: injected=1"), false, "a lone LF in a value"),
  both(f("x-a\rb", "v"), false, "a CR in a field name"),
  both(f("x-a\nb", "v"), false, "an LF in a field name"),
  both(f("x-a:b", "v"), false, "a colon in a field name (it renames the field)"),
  both(f(" x-echo ", "v"), false, "whitespace around a field name"),
  both(f("X-Echo", "v"), false, "an uppercase field name the PEER sent"),
  both(f("", "v"), false, "an empty field name"),
  both(f("x-echo", "   lead"), false, "a leading space in a value (h1 OWS strips it)"),
  both(f("x-echo", "   "), false, "an all-spaces value"),
  # --- regular fields the text carries exactly ---------------------------------------------
  both(f("x-echo", "trail   "), true, "a trailing space in a value"),
  both(f("x-echo", "\tlead\t"), true, "tabs around a value"),
  both(f("x-echo", "a: b"), true, "a colon-space inside a value"),
  both(f("x-echo", "HTTP/1.1 200 OK"), true, "a value shaped like a status line"),
  both(f("x-echo", "a\u0000b"), true, "a NUL in a value"),
  both(f("x-echo", "a\vb\fc\td"), true, "other control bytes in a value"),
  both(f("x-echo", ""), true, "an empty value"),
  both(f("x-echo", INVALID_UTF8_VALUE), true, "invalid UTF-8 in a value"),
  both(f(INVALID_UTF8_NAME, "v"), true, "invalid UTF-8 in a field name"),
  both(f("x a", "v"), true, "a space inside a field name"),
].flatten + [
  # --- pseudo-headers: the start line and the synthetic Host line -------------------------
  Entry.new("a CRLF in :path (it splits the START line)",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/a\r\nx-admin: true")], true, false),
  Entry.new("a lone LF in :path",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/a\nx-admin: true")], true, false),
  Entry.new("an empty :path",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "")], true, false),
  Entry.new("a space in :method (it moves the tail into :path)",
    [f(":method", "GE T"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("a CRLF in :method",
    [f(":method", "GET\r\nx: y"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("an empty :method",
    [f(":method", ""), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("a CRLF in :authority (it splits the synthetic Host line)",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test\r\nx-admin: true"), f(":path", "/")], true, false),
  Entry.new("a leading space in :authority",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", " a.test"), f(":path", "/")], true, false),
  Entry.new("an empty :authority with no host field (it DROPS :authority)",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", ""), f(":path", "/")], true, false),
  Entry.new("no :authority and no host field (it INVENTS one from the connection)",
    [f(":method", "GET"), f(":scheme", "https"), f(":path", "/")], true, false),
  Entry.new("no :path at all (it INVENTS `/`)",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test")], true, false),
  Entry.new("a CRLF in :scheme, which is preserved off the original",
    [f(":method", "GET"), f(":scheme", "https\r\nx: y"), f(":authority", "a.test"), f(":path", "/")], true, true),
  Entry.new("a CRLF in an unknown pseudo, likewise preserved",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/"), f(":proto", "w\r\nx: y")], true, true),
  Entry.new("a trailing space in :authority",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test "), f(":path", "/")], true, true),
  Entry.new("a :path that is only a space",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", " ")], true, true),
  Entry.new("a :path ending in a version token",
    [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/a HTTP/9")], true, true),
  Entry.new("a tab in :method",
    [f(":method", "GE\tT"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, true),
  Entry.new("no :authority but an explicit host field",
    [f(":method", "GET"), f(":scheme", "https"), f(":path", "/"), f("host", "h.test")], true, true),
  # --- :status, which `synth_response` normalizes through to_i ----------------------------
  Entry.new("a zero-padded :status (it becomes an ACCEPTED three-digit one)",
    [f(":status", "0200"), f("x-a", "1")], false, false),
  Entry.new("a :status with a CRLF", [f(":status", "200\r\nset-cookie: e=1"), f("x-a", "1")], false, false),
  Entry.new("a non-numeric :status", [f(":status", "abc"), f("x-a", "1")], false, false),
  Entry.new("a plain :status", [f(":status", "204"), f("x-a", "1")], false, true),
  # --- pseudo-header count and order (RFC 9113 §8.3) --------------------------------------
  Entry.new("a duplicate :method (the second is DROPPED)",
    [f(":method", "GET"), f(":method", "POST"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("a duplicate :path", [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"),
                                  f(":path", "/a"), f(":path", "/b")], true, false),
  Entry.new("a duplicate :scheme", [f(":method", "GET"), f(":scheme", "https"), f(":scheme", "http"),
                                    f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("a duplicate :status", [f(":status", "200"), f(":status", "404"), f("x-a", "1")], false, false),
  Entry.new("a pseudo-header AFTER a regular one (the order is CORRECTED)",
    [f(":method", "GET"), f("x-first", "1"), f(":scheme", "https"), f(":authority", "a.test"), f(":path", "/")], true, false),
  Entry.new("a pseudo-header after a regular one, response",
    [f("x-first", "1"), f(":status", "200")], false, false),
  # --- duplicates that DO survive ---------------------------------------------------------
  Entry.new("duplicate regular fields (h2 cookie crumbs)",
    [f(":status", "200"), f("cookie", "a=1"), f("cookie", "b=2")], false, true),
  Entry.new("duplicate host fields", [f(":method", "GET"), f(":scheme", "https"), f(":authority", "a.test"),
                                      f(":path", "/"), f("host", "one.test"), f("host", "two.test")], true, true),
]

describe Gori::Proxy::H2::HeadCodec do
  describe "synth" do
    it "renders :authority as a Host line and omits the pseudo-headers" do
      fields = req_fields + [f("user-agent", "curl/8"), f("accept", "*/*")]
      head = String.new(HeadCodec.synth_request(tuples(fields), "api.example.com"))
      head.should eq("GET /x HTTP/2\r\nHost: api.example.com\r\nuser-agent: curl/8\r\naccept: */*\r\n\r\n")
    end

    it "does not add a second Host line when the peer sent an explicit host field" do
      fields = req_fields + [f("host", "other.example.com")]
      head = String.new(HeadCodec.synth_request(tuples(fields), "api.example.com"))
      head.should_not contain("Host: api.example.com")
      head.should contain("host: other.example.com")
    end

    it "renders a response status line with no reason phrase (h2 has none)" do
      head = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("content-type", "text/html")])))
      head.should eq("HTTP/2 200\r\ncontent-type: text/html\r\n\r\n")
    end

    # #517 on the CAPTURE side. `h1_faithful?` guards `parse_*`/`rewrite`/`encode_edited`, but
    # `Assembler` calls these two DIRECTLY to build the stored head, so a peer field whose value
    # carried a CRLF was projected as two well-formed headers into `gori run show`, MCP get_flow,
    # QL `header:`, the Rewriter preview, and the bytes the Repeater replays. Measured at the
    # wire: the client received ONE h2 field (HEADERS len=83, forwarded verbatim) while gori's
    # own record showed two. The projection has to stay injective at the line level.
    it "does not project a CRLF-bearing request value as a second header" do
      fields = req_fields + [f("x-evil", "A\r\nx-injected: yes")]
      head = String.new(HeadCodec.synth_request(tuples(fields), "api.example.com"))
      # One line, bytes still visible, and no invented field anywhere in the head.
      head.should eq("GET /x HTTP/2\r\nHost: api.example.com\r\nx-evil: A\\r\\nx-injected: yes\r\n\r\n")
      head.lines.count(&.starts_with?("x-injected")).should eq(0)
    end

    it "does not project a CRLF-bearing response value as a second header (the origin's bytes)" do
      fields = [f(":status", "200"), f("x-evil", "A\r\nset-cookie: injected=1")]
      head = String.new(HeadCodec.synth_response(tuples(fields)))
      head.should eq("HTTP/2 200\r\nx-evil: A\\r\\nset-cookie: injected=1\r\n\r\n")
      head.should_not contain("\r\nset-cookie:")
    end

    it "escapes a lone CR or LF too, and leaves an ordinary value byte-exact" do
      fields = [f(":status", "200"), f("a", "x\ry"), f("b", "x\ny"), f("c", "plain value")]
      head = String.new(HeadCodec.synth_response(tuples(fields)))
      head.should eq("HTTP/2 200\r\na: x\\ry\r\nb: x\\ny\r\nc: plain value\r\n\r\n")
    end

    # Injectivity in the direction that matters: an operator opens this view to ask "did the
    # ORIGIN inject a CRLF here, or did the value always contain that text?" A literal
    # backslash-r used to render identically to a real CR, so the view could not answer it.
    it "distinguishes a real CRLF from a value that literally contains backslash-r-backslash-n" do
      injected = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "A\r\nB")])))
      literal = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "A\\r\\nB")])))
      injected.should contain("x: A\\r\\nB")
      literal.should contain("x: A\\\\r\\\\nB")
      injected.should_not eq(literal)
    end

    it "distinguishes a backslash immediately before a REAL CR/LF from a literal backslash-r" do
      # `x\<CR>y` (backslash then a real CR) must not render the same as `x\ry` (backslash then
      # the letter r), or the injected CR is disguised as innocuous literal text.
      injected_cr = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "x\\\ry")])))
      literal_r = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "x\\ry")])))
      injected_cr.should contain("x: x\\\\\\ry") # three backslashes then r
      literal_r.should contain("x: x\\\\ry")     # two backslashes then r
      injected_cr.should_not eq(literal_r)

      injected_lf = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "x\\\ny")])))
      literal_n = String.new(HeadCodec.synth_response(tuples([f(":status", "200"), f("x", "x\\ny")])))
      injected_lf.should_not eq(literal_n)
    end

    it "leaves an ordinary backslash byte-identical, so a rule written against it still matches" do
      head = String.new(HeadCodec.synth_response(tuples([f(":status", "200"),
                                                         f("x-path", "C:\\Users\\admin"), f("x-re", "\\d+\\s*")])))
      head.should contain("x-path: C:\\Users\\admin")
      head.should contain("x-re: \\d+\\s*")
    end

    it "keeps the start line and the synthetic Host line to one line each" do
      fields = [f(":method", "GET"), f(":scheme", "https"), f(":authority", "h\r\nx: 1"),
                f(":path", "/p\r\nx: 2")]
      head = String.new(HeadCodec.synth_request(tuples(fields), "h\r\nx: 1"))
      head.lines.size.should eq(3) # start line, Host, and the blank terminator
      head.should contain("GET /p\\r\\nx: 2 HTTP/2")
      head.should contain("Host: h\\r\\nx: 1")
    end
  end

  describe "round trip" do
    it "returns the same fields, in the same order, for an unchanged head" do
      fields = req_fields + [f("user-agent", "curl/8"), f("accept", "*/*")]
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      tuples(HeadCodec.parse_request(head, fields).not_nil!).should eq(tuples(fields))
    end

    it "preserves :scheme, which the synthesized head has nowhere to carry" do
      fields = [f(":method", "GET"), f(":scheme", "http"), f(":authority", "h"), f(":path", "/")]
      head = HeadCodec.synth_request(tuples(fields), "h")
      HeadCodec.pseudo_of(HeadCodec.parse_request(head, fields).not_nil!, ":scheme").should eq("http")
    end

    it "maps a rewritten Host line back to :authority instead of duplicating it as a field" do
      fields = req_fields
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      rewritten = String.new(head).sub("Host: api.example.com", "Host: evil.example.com").to_slice
      back = HeadCodec.parse_request(rewritten, fields).not_nil!
      HeadCodec.pseudo_of(back, ":authority").should eq("evil.example.com")
      back.any? { |x| x.name == "host" }.should be_false
    end

    it "keeps an explicit host field a field, and leaves :authority alone" do
      fields = req_fields + [f("host", "other.example.com")]
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      back = HeadCodec.parse_request(head, fields).not_nil!
      HeadCodec.pseudo_of(back, ":authority").should eq("api.example.com")
      back.select { |x| x.name == "host" }.map(&.value).should eq(["other.example.com"])
    end

    it "drops :authority when a rule removed the Host line — the operator asked for that" do
      fields = req_fields
      head = "GET /x HTTP/2\r\n\r\n".to_slice
      HeadCodec.pseudo_of(HeadCodec.parse_request(head, fields).not_nil!, ":authority").should be_nil
    end

    it "keeps a :path holding a raw space, which Codec::Http1 would truncate" do
      fields = [f(":method", "GET"), f(":scheme", "https"), f(":authority", "h"), f(":path", "/a b")]
      head = HeadCodec.synth_request(tuples(fields), "h")
      HeadCodec.pseudo_of(HeadCodec.parse_request(head, fields).not_nil!, ":path").should eq("/a b")
    end

    it "preserves duplicate field names and their order (h2 cookie crumbs)" do
      fields = req_fields + [f("cookie", "a=1"), f("cookie", "b=2")]
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      back = HeadCodec.parse_request(head, fields).not_nil!
      back.select { |x| x.name == "cookie" }.map(&.value).should eq(["a=1", "b=2"])
    end

    it "lowercases a field name a rule added in mixed case (RFC 9113 §8.2.1)" do
      # The identical add-header rule is legal on h1; an uppercase name in h2 is malformed
      # and would RST the stream, and field names are case-insensitive so nothing is lost.
      head = "GET /x HTTP/2\r\nHost: h\r\nX-Request-Id: 7\r\n\r\n".to_slice
      back = HeadCodec.parse_request(head, req_fields).not_nil!
      back.map(&.name).should contain("x-request-id")
      back.map(&.name).should_not contain("X-Request-Id")
    end

    it "carries a §6.2.3 never-indexed marking across the round trip, by name" do
      # The h1 text has nowhere to hold the marking; dropping it would launder a header the
      # SENDER asked every intermediary to keep out of compression tables.
      fields = req_fields + [f("authorization", "Bearer old", true)]
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      rewritten = String.new(head).sub("Bearer old", "Bearer new").to_slice
      auth = HeadCodec.parse_request(rewritten, fields).not_nil!.find { |x| x.name == "authorization" }.not_nil!
      auth.value.should eq("Bearer new")
      auth.never_indexed?.should be_true
    end

    it "leaves a field the peer did NOT mark unmarked (no name-based guessing)" do
      fields = req_fields + [f("authorization", "Bearer x")]
      head = HeadCodec.synth_request(tuples(fields), "api.example.com")
      back = HeadCodec.parse_request(head, fields).not_nil!
      back.find { |x| x.name == "authorization" }.not_nil!.never_indexed?.should be_false
    end

    it "takes a rewritten status code and drops the reason phrase a rule wrote" do
      fields = [f(":status", "200"), f("content-type", "text/html")]
      back = HeadCodec.parse_response("HTTP/2 404 Not Found\r\ncontent-type: text/html\r\n\r\n".to_slice, fields)
      HeadCodec.pseudo_of(back.not_nil!, ":status").should eq("404")
      back.not_nil!.map(&.name).should_not contain("reason")
    end

    it "refuses a head a destructive rule mangled, rather than guessing at it" do
      HeadCodec.parse_request("no-spaces-at-all\r\n\r\n".to_slice, req_fields).should be_nil
      HeadCodec.parse_request("GET /x HTTP/2\r\nnot a header line\r\n\r\n".to_slice, req_fields).should be_nil
      HeadCodec.parse_response("nonsense\r\n\r\n".to_slice, [f(":status", "200")]).should be_nil
    end
  end

  # #517. The round trip is only sound while it is INJECTIVE, and #492's hazard table never
  # said so. `CORPUS` is the audit that found the ones it missed, kept as an oracle: for every
  # entry it asserts that `h1_faithful?` and what the round trip ACTUALLY does agree. A future
  # change to either side that makes them disagree fails here rather than on the wire.
  describe "h1_faithful? (injectivity)" do
    CORPUS.each do |entry|
      it "#{entry.faithful ? "round-trips" : "refuses"} #{entry.label}" do
        HeadCodec.h1_faithful?(entry.fields, entry.request).should eq(entry.faithful)
        back = round_trip(entry.fields, entry.request)
        if entry.faithful
          # Faithful means EXACTLY these fields back, in this order — not "close enough".
          tuples(back.not_nil!).should eq(tuples(entry.fields))
        else
          back.should be_nil
        end
      end
    end

    it "judges what the PEER sent, never what a rule produced" do
      # A rule whose replacement carries a CRLF adds two headers here for the same reason the
      # identical rule does on h1: those are the operator's bytes (P7). Only the peer's head
      # gates the round trip.
      fields = [f(":status", "200"), f("x-tag", "a")]
      HeadCodec.h1_faithful?(fields, false).should be_true
      back = HeadCodec.parse_response("HTTP/2 200\r\nx-tag: a\r\nset-cookie: op=1\r\n\r\n".to_slice, fields)
      tuples(back.not_nil!).should eq([{":status", "200"}, {"x-tag", "a"}, {"set-cookie", "op=1"}])
    end

    it "does not refuse ordinary traffic" do
      req = req_fields + [f("user-agent", "curl/8"), f("cookie", "a=1"), f("cookie", "b=2"),
                          f("accept-encoding", "gzip, deflate, br"), f("authorization", "Bearer x", true)]
      HeadCodec.h1_faithful?(req, true).should be_true
      resp = [f(":status", "204"), f("date", "Mon, 01 Jan 2024 00:00:00 GMT"),
              f("content-length", "0"), f("set-cookie", "s=1; Path=/; HttpOnly")]
      HeadCodec.h1_faithful?(resp, false).should be_true
    end
  end

  describe "restore_content_length" do
    it "puts the original value back so the untouched DATA frames still match the head" do
      original = [f(":method", "POST"), f("content-length", "12")]
      rewritten = [f(":method", "POST"), f("content-length", "999")]
      tuples(HeadCodec.restore_content_length(rewritten, original))
        .should eq([{":method", "POST"}, {"content-length", "12"}])
    end

    it "returns the fields untouched when the rule left content-length alone" do
      fields = [f(":method", "POST"), f("content-length", "12")]
      HeadCodec.restore_content_length(fields, fields).should be(fields)
    end

    it "removes a content-length a rule invented on a head that never had one" do
      original = [f(":method", "GET")]
      rewritten = [f(":method", "GET"), f("content-length", "5")]
      tuples(HeadCodec.restore_content_length(rewritten, original)).should eq([{":method", "GET"}])
    end
  end
end
