require "./spec_helper"

private alias MT = Gori::MediaType

private def head(*lines : String) : Bytes
  (["POST /x HTTP/1.1"] + lines.to_a + ["", ""]).join("\r\n").to_slice
end

# Five surfaces had grown their own copy of this scan and they did not agree — which is how a
# body ends up parsed on one surface and shown as an ordinary request on the next.
# The `String` scan `MediaType.of` was, frozen here as the oracle for its byte-scan fast path
# (and still the path any head with a byte >= 0x80 takes). The fast path is only correct if it
# answers EXACTLY this on every ASCII head, hostile ones included — the chomp, the blank-line
# stop, the first colon and `strip`'s whitespace set are all part of that answer.
private def legacy_of(h : Bytes) : String?
  String.new(h).scrub.each_line do |raw|
    line = raw.chomp
    break if line.empty?
    idx = line.index(':') || next
    next unless line[0, idx].strip.compare("content-type", case_insensitive: true) == 0
    return line[(idx + 1)..].strip
  end
  nil
end

# Heads that pull on every rule the byte scan re-implements. Each is also run with CRLF → LF
# and CRLF → CR CR LF, and cut at every length, below.
private HOSTILE_HEADS = [
  "",
  "\n",
  "\r\n",
  "\r",
  "\r\r\n",
  "\r\r\r\n",
  "Content-Type: a/b",
  "Content-Type: a/b\r",
  "Content-Type: a/b\r\r",
  "Content-Type: a/b\r\n",
  "POST / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n",
  "POST / HTTP/1.1\r\nHost: a\r\n\r\nContent-Type: after-blank\r\n",
  "POST / HTTP/1.1\r\nHost: a\r\r\nContent-Type: after-cr-cr-blank\r\n",
  "POST / HTTP/1.1\r\nHost: a\r\n\r\r\nContent-Type: after-cr-blank\r\n",
  "POST / HTTP/1.1\r\nHost: a\r\n\r\r\r\nContent-Type: not-blank-3cr\r\n",
  "POST / HTTP/1.1\r\nHost: a\n\r\rContent-Type: bare-cr-last",
  "POST / HTTP/1.1\r\nHost: a\r\nContent-Type: no-blank-line",
  "POST / HTTP/1.1\r\nHost: a\r\nContent-Type: no-blank-line\r",
  "POST / HTTP/1.1\r\nContent-Type: first\r\nContent-Type: second\r\n\r\n",
  "POST / HTTP/1.1\r\ncontent-type: lower\r\n\r\n",
  "POST / HTTP/1.1\r\nCONTENT-TYPE:upper\r\n\r\n",
  "POST / HTTP/1.1\r\n  Content-Type  :  padded  \r\n\r\n",
  "POST / HTTP/1.1\r\n\tContent-Type\t:\ttabbed\t\r\n\r\n",
  "POST / HTTP/1.1\r\n\v\fContent-Type\v\f:\v\fvt-ff\v\f\r\n\r\n",
  "POST / HTTP/1.1\r\n\x1cContent-Type\x1f: not-strip-ws\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type: \x1c keeps-x1c \x1f\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type:\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type:   \r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type\r\nContent-Type: after-no-colon\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type: a:b:c\r\n\r\n",
  "POST / HTTP/1.1\r\nContent:Type: colon-in-name\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Typ: short\r\nContent-Types: long\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type : a\r\n folded-continuation\r\n\r\n",
  "POST / HTTP/1.1\r\nX: a\r\n Content-Type: folded-looking\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type: a\rContent-Type: bare-cr-mid\r\n\r\n",
  "POST / HTTP/1.1\r\nX: y\rContent-Type: after-bare-cr\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type: nul\0inside\r\n\r\n",
  "POST / HTTP/1.1\r\nContent-Type\0: nul-in-name\r\n\r\n",
  "\0\r\nContent-Type: after-nul-line\r\n\r\n",
  "Content-Type: request-line-slot\r\n\r\n",
  "GET http://h:8080/x HTTP/1.1\r\nContent-Type: after-colon-request-line\r\n\r\n",
  "content-type: http://h/ HTTP/1.1\r\n\r\n",
  ":\r\n: empty-name\r\nContent-Type: x\r\n\r\n",
  "   \r\nContent-Type: after-space-only-line\r\n\r\n",
  "\t\r\nContent-Type: after-tab-only-line\r\n\r\n",
  "Content-Type: multipart/form-data; boundary=\"----X\"\r\n\r\n",
  "Content-Type: \"x\"; Charset=UTF-8 \r\n\r\n",
  "Content-Type: trailing-lf-only\n",
  "Content-Type: trailing-lf-lf\n\n",
  "\nContent-Type: after-leading-lf\n",
]

private def variants(s : String) : Array(Bytes)
  forms = [s, s.gsub("\r\n", "\n"), s.gsub("\r\n", "\r\r\n")].uniq!.map(&.to_slice)
  # Every prefix too: a head cut mid-line, mid-CRLF or mid-name is exactly what a truncated
  # capture looks like.
  forms.flat_map { |b| (0..b.size).map { |n| b[0, n] } }
end

describe Gori::MediaType do
  describe ".of against the String scan it replaced (differential)" do
    it "answers what the String scan answers on every hostile ASCII head and every prefix" do
      HOSTILE_HEADS.each do |s|
        variants(s).each do |h|
          Gori::AsciiBytes.ascii_only?(h).should be_true
          MT.of(h).should eq(legacy_of(h)), "diverged on #{String.new(h).inspect}"
        end
      end
    end

    it "answers what the String scan answers on random heads over the scan's own alphabet" do
      # Every byte the scan branches on, plus header-name fragments so a match is common.
      alphabet = ["\r", "\n", "\r\n", ":", " ", "\t", "\v", "\f", "\0", "\x1c", "a", "Z",
                  "Content-Type", "content-type", "CONTENT-TYPE", "Content-Typ", "e", ";"]
      rng = Random.new(1895)
      5000.times do
        s = String.build { |io| rng.rand(1..24).times { io << alphabet.sample(rng) } }
        h = s.to_slice
        MT.of(h).should eq(legacy_of(h)), "diverged on #{s.inspect}"
      end
    end

    it "takes the String scan for a head with any byte >= 0x80, and still agrees" do
      [
        "POST / HTTP/1.1\r\nX: d\u00e4rk\r\nContent-Type: after-utf8\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Type:\u00a0nbsp-is-unicode-ws\u00a0\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Type: a\u2028b\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-\u212Aype: kelvin-sign\r\n\r\n",
      ].each do |s|
        h = s.to_slice
        Gori::AsciiBytes.ascii_only?(h).should be_false
        MT.of(h).should eq(legacy_of(h))
      end
      invalid = Bytes[0x43, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x54, 0x79, 0x70, 0x65,
        0x3a, 0x20, 0xff, 0x78, 0x0d, 0x0a, 0x0d, 0x0a]
      MT.of(invalid).should eq(legacy_of(invalid))
      MT.of(invalid).should eq("\uFFFDx")
    end
  end

  describe ".of" do
    it "reads the value whatever the spacing and case of the name" do
      MT.of(head("Content-Type: application/json")).should eq("application/json")
      MT.of(head("content-type:application/json")).should eq("application/json")
      MT.of(head("CONTENT-TYPE:   application/json  ")).should eq("application/json")
    end

    it "keeps parameters and their original case (a boundary is case-sensitive)" do
      MT.of(head(%(Content-Type: multipart/form-data; boundary="----X")))
        .should eq(%(multipart/form-data; boundary="----X"))
    end

    it "stops at the blank line — a body is not searched for headers" do
      raw = "POST /x HTTP/1.1\r\nHost: a\r\n\r\nContent-Type: application/json".to_slice
      MT.of(raw).should be_nil
    end

    it "is nil for no head and for a head with no Content-Type" do
      MT.of(nil).should be_nil
      MT.of(head("Host: a")).should be_nil
    end

    it "does not raise on a head carrying invalid UTF-8" do
      raw = Bytes.new(40) { |i| i == 20 ? 0xFF_u8 : 0x41_u8 }
      MT.of(raw).should be_nil
    end
  end

  describe ".essence" do
    it "folds the type and drops the parameters" do
      MT.essence("Application/GraphQL+JSON; charset=utf-8").should eq("application/graphql+json")
      MT.essence(nil).should be_nil
      MT.essence("  ").should be_nil
    end
  end

  # The whole reason `essence` exists: `application/graphql` is a PREFIX of the two types
  # whose body is an ordinary JSON envelope, so a `starts_with?` dispatch sent them to the
  # raw-document parser.
  describe ".json?" do
    it "accepts application/json, any +json suffix, and a bare /json subtype" do
      MT.json?("application/json; charset=utf-8").should be_true
      MT.json?("application/graphql+json").should be_true
      MT.json?("application/graphql-response+json").should be_true
      MT.json?("application/vnd.api+json").should be_true
      MT.json?("text/json").should be_true
    end

    # PERMISSIVE on purpose — a substring gate, not the precise dispatch. The strict
    # suffix-only version dropped `application/x-amz-json-1.1` (every AWS API call) and
    # `application/x-ndjson`, and the readers this gates all JSON.parse and fall back to raw,
    # so a false positive is free while a false negative loses the feature on real traffic.
    it "accepts the vendor json spellings that carry no +json suffix" do
      MT.json?("application/x-amz-json-1.1").should be_true
      MT.json?("application/x-amz-json-1.0").should be_true
      MT.json?("application/x-ndjson").should be_true
      MT.json?("APPLICATION/JSON").should be_true # folded
    end

    it "rejects the raw document type and unrelated types" do
      MT.json?("application/graphql").should be_false # no "json" — a raw document, not JSON syntax
      MT.json?("text/plain").should be_false
      MT.json?(nil).should be_false
    end
  end

  describe ".form_urlencoded? / .multipart? / .boundary" do
    it "matches urlencoded through parameters and a comma-joined type (a parser-differential probe)" do
      MT.form_urlencoded?("application/x-www-form-urlencoded; charset=utf-8").should be_true
      MT.form_urlencoded?("application/x-www-form-urlencoded, application/json").should be_true
      MT.form_urlencoded?("application/json").should be_false
    end

    it "matches any multipart and lifts the boundary, quoted or bare" do
      MT.multipart?("multipart/mixed; boundary=zz").should be_true
      MT.boundary("multipart/form-data; boundary=----X").should eq("----X")
      MT.boundary(%(multipart/form-data; BOUNDARY="a;b")).should eq("a;b")
      MT.boundary("application/json").should be_nil
    end

    # The two probe call sites reach `boundary` with a header value read straight off the wire
    # (`Http1.parse_headers` builds values with a bare `String.new`), and PCRE RAISES on the
    # first illegal byte instead of not matching — one such Content-Type silently voided a whole
    # flow's passive scan and killed the TUI's active-scan estimate.
    it "does not raise on a boundary carrying invalid UTF-8" do
      ct = "multipart/form-data; boundary=graphql" + String.new(Bytes[0xFF_u8])
      MT.multipart?(ct).should be_true
      # Nil, not a raise: a boundary with an illegal byte cannot delimit the body anyway.
      MT.boundary(ct).should be_nil
      # A well-formed value is unchanged by the scrub.
      MT.boundary("multipart/form-data; boundary=graphql-9").should eq("graphql-9")
    end
  end
  describe ".binary_document?" do
    it "matches the spellings a msgpack or CBOR body actually carries" do
      %w[application/msgpack application/x-msgpack application/vnd.msgpack
        application/cbor application/senml+cbor application/vnd.acme+msgpack].each do |ct|
        Gori::MediaType.binary_document?(ct).should be_true
      end
      Gori::MediaType.binary_document?("application/msgpack; charset=binary").should be_true
    end

    it "is a DISPATCH test, so it does not match a type that merely mentions one" do
      # `json?` is permissive on purpose — a false positive there costs one failed parse. Here
      # it costs a body rendered as whatever a binary reader made of unrelated bytes.
      %w[text/plain application/json application/octet-stream text/cbor-ish
        application/msgpackish application/json+msgpack-ish].each do |ct|
        Gori::MediaType.binary_document?(ct).should be_false
      end
      Gori::MediaType.binary_document?(nil).should be_false
    end

    it "declines a CBOR SEQUENCE, which is several documents and not one" do
      Gori::MediaType.cbor?("application/cbor-seq").should be_false
    end
  end
end
