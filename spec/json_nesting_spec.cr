require "./spec_helper"

# `src/gori/json_nesting.cr` raises `JSON::Builder`'s nesting cap from stdlib's 99 past the
# parser's 512. A document 100–512 deep PARSES, and every site that wrote it back out raised
# `JSON::Error: Nesting of 100 is too deep` — on bodies, tokens and cookies the peer shapes.
# These examples hit one entry per way a site reached the builder: a hand-written `JSON.build`
# walk, `RawJson.reformat`'s `read_raw`, a bare `JSON::Any#to_pretty_json`, a parsed tree
# written INSIDE a document gori wraps around it, and an import that re-serializes a value.

private DEPTH = 150

private def deep_array(n : Int32) : String
  "[" * n + "1" + "]" * n
end

describe "JSON builder nesting" do
  # The reopen only works when it runs AFTER stdlib's class body; this is what catches a
  # require-order regression that would quietly put the 99 back.
  it "is raised past the parser's limit in the compiled program" do
    JSON::Builder.new(IO::Memory.new).max_nesting.should be > 512
  end

  it "re-emits a deep document through RawJson (JWT, cookie, jsonpath, retest)" do
    Gori::RawJson.reformat(%({"d":#{deep_array(DEPTH)}})).should eq(%({"d":#{deep_array(DEPTH)}}))
  end

  it "redacts a deep JSON body instead of raising out of the walk" do
    m = Gori::Redact::Policy.resolve(nil, on: true).matcher.not_nil!
    r = m.body(%({"a":#{deep_array(DEPTH)}}).to_slice, "application/json")
    r.shape.should eq(Gori::Redact::Shape::Json)
    r.text.should contain(deep_array(DEPTH))
  end

  it "recognises a GraphQL request whose variables are deep" do
    op = Gori::Graphql.from_json(%({"query":"query{a}","variables":{"x":#{deep_array(DEPTH)}}}))
    op.should_not be_nil
  end

  # 33 nested protobuf messages is within `Protobuf::MAX_DEPTH`'s reach and ~99 JSON levels on
  # its own; the few levels of the flow document around it pushed it over.
  it "writes a deep protobuf message inside a document that wraps it" do
    inner = Bytes[0x08, 0x01]
    32.times { inner = Bytes[0x0a, inner.size.to_u8] + inner }
    msg = Gori::Protobuf.decode(inner)
    json = JSON.build do |j|
      j.object { j.field("a") { j.array { j.object { j.field("protobuf") { msg.to_json(j) } } } } }
    end
    JSON.parse(json)["a"][0]["protobuf"].should_not be_nil
  end

  it "imports an OpenAPI operation whose example is deep" do
    # Spelled as text: building it with `to_json` would itself need the raised cap.
    spec = %({"openapi":"3.0.0","servers":[{"url":"https://h.test"}],"paths":{"/deep":{"post":{) +
           %("requestBody":{"content":{"application/json":{"schema":{"type":"object",) +
           %("example":{"a":#{deep_array(DEPTH)}}}}}},"responses":{"200":{"description":"ok"}}}}}})
    path = File.tempname("gori-oas-deep", ".json")
    File.write(path, spec)
    begin
      result = Gori::Import::Oas.parse_file(path)
      result.skipped.should eq(0)
      result.flows.size.should eq(1)
      String.new(result.flows.first.request.body.not_nil!).should eq(%({"a":#{deep_array(DEPTH)}}))
    ensure
      File.delete?(path)
    end
  end
end
