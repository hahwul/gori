require "./spec_helper"

# Build a minimal head carrying just the Content-Type, then pretty-format a body.
private def pretty(ct : String, body : String | Bytes) : Gori::Pretty::Result?
  head = "POST /x HTTP/1.1\r\nContent-Type: #{ct}\r\n\r\n".to_slice
  Gori::Pretty.format(head, body.is_a?(String) ? body.to_slice : body)
end

private def text(res : Gori::Pretty::Result?) : String
  String.new(res.not_nil!.bytes)
end

private def jwt_token : String
  h = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}), padding: false)
  p = Base64.urlsafe_encode(%({"sub":"1","name":"alice"}), padding: false)
  "#{h}.#{p}.c2ln"
end

describe Gori::Pretty do
  describe "JSON" do
    it "reflows minified JSON (kind stays content-type-derived)" do
      res = pretty("application/json", %({"a":1,"b":[1,2]}))
      res.should_not be_nil
      res.not_nil!.kind.should be_nil
      t = text(res)
      t.should contain(%("a": 1))
      t.lines.size.should be > 1
    end

    it "is a no-op on already-pretty JSON (idempotent → nil)" do
      r1 = pretty("application/json", %({"a":1})).not_nil!
      pretty("application/json", String.new(r1.bytes)).should be_nil
    end

    it "falls back to raw (nil) on malformed / trailing / binary / empty" do
      pretty("application/json", "{bad").should be_nil
      pretty("application/json", "{}{}").should be_nil
      pretty("application/json", Bytes[0xff, 0xfe, 0x00]).should be_nil
      pretty("application/json", "").should be_nil
    end

    it "guards deep-nesting DoS via JSON max_nesting" do
      pretty("application/json", "[" * 1000 + "]" * 1000).should be_nil
    end

    it "reflows a top-level array and no-ops a scalar (shared-parse path, non-object roots)" do
      arr = pretty("application/json", "[1,2,3]").not_nil!
      arr.kind.should be_nil
      text(arr).lines.size.should be > 1                # array pretty-printed, not GraphQL-hijacked
      pretty("application/json", "42").should be_nil    # scalar → already-"pretty" → nil
      pretty("application/json", %("hi")).should be_nil # string scalar → nil
    end
  end

  describe "GraphQL" do
    it "presents operationName + query + variables, kind :graphql" do
      body = %({"operationName":"Q","query":"query Q { me { id } }","variables":{"x":1}})
      res = pretty("application/json", body)
      res.not_nil!.kind.should eq(:graphql)
      t = text(res)
      t.should contain("# operationName: Q")
      t.should contain("query Q { me { id } }")
      t.should contain("# variables")
    end

    it "un-escapes a multi-line query" do
      body = %({"query":"query {\\n  me {\\n    id\\n  }\\n}"})
      text(pretty("application/json", body)).should contain("  me {")
    end

    it "plain JSON (no query field) routes to the JSON formatter (kind nil)" do
      pretty("application/json", %({"a":1,"b":2})).not_nil!.kind.should be_nil
    end

    it "does not hijack a REST body whose 'query' is not a GraphQL document" do
      # {"query":"shoes","page":2} must render as JSON (keeping page), not as GraphQL.
      res = pretty("application/json", %({"query":"shoes","page":2,"sort":"price"}))
      res.not_nil!.kind.should be_nil
      t = text(res)
      t.should contain("page")
      t.should contain("sort")
    end

    it "treats an empty query as JSON, not a blank GraphQL panel" do
      res = pretty("application/json", %({"query":""}))
      res.not_nil!.kind.should be_nil
      text(res).should contain(%("query"))
    end
  end

  describe "JWT" do
    it "decodes header/payload (signature not verified), kind :json" do
      res = pretty("text/plain", jwt_token)
      res.not_nil!.kind.should eq(:json)
      t = text(res)
      t.should contain("// header")
      t.should contain(%("alg": "HS256"))
      t.should contain("// payload")
      t.should contain("signature (not verified)")
    end

    it "ignores dotted words whose header is not JSON" do
      pretty("text/plain", "a.b.c").should be_nil
      pretty("text/plain", "not-a-jwt").should be_nil
    end
  end

  describe "XML / SOAP / SAML" do
    it "indents nested elements, balanced, kind nil" do
      res = pretty("application/xml", "<a><b>x</b></a>")
      res.not_nil!.kind.should be_nil
      text(res).should eq("<a>\n  <b>\n    x\n  </b>\n</a>")
    end

    it "preserves comments / CDATA / declarations verbatim" do
      t = text(pretty("text/xml", %(<?xml version="1.0"?><r><!--c--><![CDATA[a<b]]></r>)))
      t.should contain(%(<?xml version="1.0"?>))
      t.should contain("<!--c-->")
      t.should contain("<![CDATA[a<b]]>")
    end

    it "is quote-aware for '>' inside attribute values" do
      text(pretty("application/xml", %(<a t="x>y"><b/></a>))).should contain(%(<a t="x>y">))
    end

    it "falls back to raw (nil) on imbalance / unterminated" do
      pretty("application/xml", "<a><b></a>").should be_nil
      pretty("application/xml", "<a>").should be_nil
      pretty("application/xml", "<a").should be_nil
    end
  end

  describe "HTML" do
    it "breaks tag seams but never drops a byte" do
      t = text(pretty("text/html", "<div><p>hi</p></div>"))
      t.should contain("<div>")
      t.should contain("<p>hi</p>")
      # insert-only: stripping inserted whitespace recovers the original
      t.gsub(/\s+/, "").should eq("<div><p>hi</p></div>")
    end

    it "passes <script>/<pre> content through verbatim (no false tag seams)" do
      t = text(pretty("text/html", "<div><script>if(a<b){x()}</script></div>"))
      t.should contain("if(a<b){x()}")
    end

    it "does not end a <script> on a false-prefix close tag (</scriptlet>)" do
      # </scriptlet> must NOT be mistaken for </script>; the inner text stays verbatim.
      t = text(pretty("text/html", "<div><script>x</scriptlet>y</script></div>"))
      t.should contain("x</scriptlet>y")
    end

    it "treats void elements as self-closing" do
      pretty("text/html", "<ul><br><br></ul>").should_not be_nil
    end
  end

  describe "form-urlencoded" do
    it "decodes one field per line, kind :form" do
      res = pretty("application/x-www-form-urlencoded", "a=1&b=hello+world&c=%2F")
      res.not_nil!.kind.should eq(:form)
      text(res).should eq("a = 1\nb = hello world\nc = /")
    end

    it "shows a bare key with no value" do
      text(pretty("application/x-www-form-urlencoded", "flag&x=1")).should contain("flag =")
    end

    it "tolerates a trailing '&' without a spurious blank field" do
      res = pretty("application/x-www-form-urlencoded", "a=1&b=2&")
      text(res).should eq("a = 1\nb = 2")
      res.not_nil!.note.should contain("2 field")
    end
  end

  describe "multipart" do
    it "splits parts with headers + bodies, kind :text" do
      body = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhello\r\n" \
             "--X\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nworld\r\n--X--\r\n"
      res = pretty("multipart/form-data; boundary=X", body)
      res.not_nil!.kind.should eq(:text)
      t = text(res)
      t.should contain("part 1")
      t.should contain("part 2")
      t.should contain("hello")
      t.should contain("world")
    end

    it "falls back to raw (nil) without a boundary" do
      pretty("multipart/form-data", "whatever").should be_nil
    end
  end

  describe "guards" do
    it "leaves oversize bodies raw (nil)" do
      big = "{\"a\":\"" + ("x" * (Gori::Pretty::MAX_PRETTY + 1)) + "\"}"
      pretty("application/json", big).should be_nil
    end

    it "returns nil for unknown content-types and missing content-type" do
      pretty("application/octet-stream", "\x00\x01").should be_nil
      Gori::Pretty.format(nil, %({"a":1}).to_slice).should be_nil
    end

    it "never mutates the input slice and returns a fresh slice (P7)" do
      body = %({"a":1}).to_slice
      orig = body.dup
      res = pretty("application/json", body).not_nil!
      body.should eq(orig)
      res.bytes.to_unsafe.should_not eq(body.to_unsafe)
    end
  end

  describe "format_request (marker-preserving pretty)" do
    it "restores every §…§ marker intact with ≥11 markers (no placeholder prefix-collision)" do
      head = "POST /x HTTP/1.1\r\nContent-Type: application/json"
      pairs = (0...12).map { |i| %("k#{i}":"§m#{i}§") }
      body = "{#{pairs.join(",")}}"
      out = Gori::Pretty.format_request(head, body)
      out.should_not be_nil
      formatted = out.not_nil!
      # Under the old ascending-order gsub, marker 10 became "§m1§0" (idx-1 placeholder
      # is a prefix of idx-10's). Every marker must survive verbatim.
      (0...12).each { |i| formatted.should contain("§m#{i}§") }
      formatted.lines.size.should be > 1 # actually reflowed
    end
  end
end
