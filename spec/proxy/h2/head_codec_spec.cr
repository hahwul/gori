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
