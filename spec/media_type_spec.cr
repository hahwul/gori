require "./spec_helper"

private alias MT = Gori::MediaType

private def head(*lines : String) : Bytes
  (["POST /x HTTP/1.1"] + lines.to_a + ["", ""]).join("\r\n").to_slice
end

# Five surfaces had grown their own copy of this scan and they did not agree — which is how a
# body ends up parsed on one surface and shown as an ordinary request on the next.
describe Gori::MediaType do
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
end
