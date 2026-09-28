require "../spec_helper"
require "json"

private alias Introspection = Gori::Graphql::Introspection

# The request's head lines and its body, split at the blank line.
private def split_request(text : String) : {Array(String), String}
  head, _, body = text.partition("\n\n")
  {head.split('\n'), body}
end

describe Gori::Graphql::Introspection do
  describe ".body" do
    it "names the operation the query declares" do
      json = JSON.parse(Introspection.body)
      json["operationName"].as_s.should eq("IntrospectionQuery")
      json["query"].as_s.should start_with("query IntrospectionQuery {")
      json["query"].as_s.should contain("fragment TypeRef on __Type")
    end

    it "asks for subscriptions and directives only in the standard query" do
      standard = JSON.parse(Introspection.body)["query"].as_s
      legacy = JSON.parse(Introspection.body(legacy: true))["query"].as_s
      standard.should contain("subscriptionType")
      standard.should contain("directives")
      legacy.should_not contain("subscriptionType")
      legacy.should_not contain("directives")
      legacy.should contain("fragment FullType on __Type")
    end
  end

  describe ".rewrite_request" do
    it "turns a GET binding into a POST and keeps the unrelated params" do
      text = "GET /graphql?apikey=k1&query=%7Bme%7D&operationName=Me&variables=%7B%7D&tenant=t HTTP/1.1\nHost: api.test\n\n"
      lines, _ = split_request(Introspection.rewrite_request(text))
      lines[0].should eq("POST /graphql?apikey=k1&tenant=t HTTP/1.1")
    end

    it "drops the query string entirely when only binding params were in it" do
      text = "GET /graphql?query=%7Bme%7D&extensions=%7B%7D HTTP/2\nhost: api.test\n\n"
      lines, _ = split_request(Introspection.rewrite_request(text))
      lines[0].should eq("POST /graphql HTTP/2")
    end

    it "keeps an absolute-form target absolute" do
      text = "GET https://api.test/gql?query=x&k=v HTTP/1.1\nHost: api.test\n\n"
      lines, _ = split_request(Introspection.rewrite_request(text))
      lines[0].should eq("POST https://api.test/gql?k=v HTTP/1.1")
    end

    it "replaces the framing headers where the first stood and keeps every other header in order" do
      text = "POST /graphql HTTP/1.1\nHost: api.test\nContent-Type: application/x-www-form-urlencoded\n" \
             "Authorization: Bearer t\nTransfer-Encoding: chunked\nContent-Encoding: gzip\nCookie: s=1\n\nquery=%7Bme%7D"
      rewritten = Introspection.rewrite_request(text)
      lines, body = split_request(rewritten)
      lines.should eq([
        "POST /graphql HTTP/1.1",
        "Host: api.test",
        "Content-Type: application/json",
        "Content-Length: #{body.bytesize}",
        "Authorization: Bearer t",
        "Cookie: s=1",
      ])
      body.should eq(Introspection.body)
    end

    it "appends the framing pair when the request had none" do
      text = "GET /graphql HTTP/1.1\nHost: api.test\nX-Api-Key: k\n\n"
      lines, body = split_request(Introspection.rewrite_request(text, legacy: true))
      lines.last(2).should eq(["Content-Type: application/json", "Content-Length: #{body.bytesize}"])
      lines[1..2].should eq(["Host: api.test", "X-Api-Key: k"])
      body.should eq(Introspection.body(legacy: true))
    end

    it "reads and writes LF text, never CRLF" do
      text = "GET /graphql HTTP/1.1\nHost: api.test"
      rewritten = Introspection.rewrite_request(text)
      rewritten.should_not contain('\r')
      rewritten.should start_with("POST /graphql HTTP/1.1\nHost: api.test\nContent-Type: application/json\n")
      rewritten.should contain("\n\n{")
    end

    it "keeps each kept line's own terminator and gives gori's lines the request line's" do
      text = "GET /graphql HTTP/1.1\r\nHost: api.test\r\nX-A: v\r\r\nX-B: w\n\r\n"
      Introspection.rewrite_request(text).should eq(
        "POST /graphql HTTP/1.1\r\nHost: api.test\r\nX-A: v\r\r\nX-B: w\n" \
        "Content-Type: application/json\r\nContent-Length: #{Introspection.body.bytesize}\r\n\r\n#{Introspection.body}")
    end

    it "moves a folded continuation with its header, dropped or kept" do
      text = "POST /graphql HTTP/1.1\nContent-Type: application/x-www-form-urlencoded;\n charset=utf-8\n" \
             "X-Foo: bar\n baz\n\nquery=x"
      lines, _ = split_request(Introspection.rewrite_request(text))
      lines[1..].should eq([
        "Content-Type: application/json",
        "Content-Length: #{Introspection.body.bytesize}",
        "X-Foo: bar",
        " baz",
      ])
    end

    it "refuses a request line that is not METHOD TARGET VERSION" do
      expect_raises(Gori::Error, /request line/) { Introspection.rewrite_request("garbage\nHost: x\n\n") }
      expect_raises(Gori::Error, /request line/) { Introspection.rewrite_request("") }
    end
  end

  describe ".post_target" do
    it "leaves a target with no query alone" do
      Introspection.post_target("/graphql").should eq("/graphql")
    end

    it "matches binding keys verbatim, as Graphql.from_query reads them, and keeps the fragment" do
      Introspection.post_target("/g?query=x&%71uery=y&a=1#frag").should eq("/g?%71uery=y&a=1#frag")
    end
  end
end
