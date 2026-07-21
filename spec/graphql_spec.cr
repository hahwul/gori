require "./spec_helper"

private alias GQL = Gori::Graphql

# round-trip helper: display then parse back.
private def round_trip(op : GQL::Op) : {String?, String, String?}
  GQL.parse_display(GQL.display(op))
end

describe Gori::Graphql do
  describe ".from_json" do
    it "parses a real GraphQL POST body into an Op" do
      GQL.from_json(%({"query":"{ me }"})).should eq(GQL::Op.new(nil, "{ me }", nil))
    end

    it "lifts operationName and pretty-prints an object variables field" do
      op = GQL.from_json(%({"query":"query Q { me }","operationName":"Q","variables":{"a":1}}))
      op.should eq(GQL::Op.new("Q", "query Q { me }", "{\n  \"a\": 1\n}"))
    end

    it "refuses to hijack a REST body whose query field has no selection set" do
      GQL.from_json(%({"query":"shoes"})).should be_nil
    end

    it "returns nil when query is absent or not a string" do
      GQL.from_json(%({"foo":1})).should be_nil
      GQL.from_json(%({"query":123})).should be_nil
    end

    it "strips a leading UTF-8 BOM (and surrounding whitespace) before parsing" do
      GQL.from_json("\u{FEFF}" + %({"query":"{ me }"})).should eq(GQL::Op.new(nil, "{ me }", nil))
      GQL.from_json("  \n\t" + %({"query":"{ me }"}) + "  ").should eq(GQL::Op.new(nil, "{ me }", nil))
    end

    it "returns nil for malformed / non-object JSON" do
      GQL.from_json("{not json").should be_nil
      GQL.from_json("").should be_nil
      GQL.from_json("[1,2,3]").should be_nil # top-level array, not an object
      GQL.from_json("null").should be_nil
    end

    it "treats variables: null as absent (nil), not the string \"null\"" do
      GQL.from_json(%({"query":"{ q }","variables":null})).should eq(GQL::Op.new(nil, "{ q }", nil))
    end

    it "de-escapes and strips the query document" do
      # \n inside the JSON string becomes a real newline; surrounding space stripped.
      op = GQL.from_json(%({"query":"  { a\\n  b }  "}))
      op.should eq(GQL::Op.new(nil, "{ a\n  b }", nil))
    end

    it "handles multibyte / CJK / emoji inside the query" do
      GQL.from_json(%({"query":"{ 사용자 世界 🎉 }"})).should eq(GQL::Op.new(nil, "{ 사용자 世界 🎉 }", nil))
    end
  end

  describe ".from_query" do
    it "decodes query/operationName/variables from a GET target" do
      op = GQL.from_query("p?query=%7Bme%7D&operationName=Op&variables=%7B%22x%22%3A1%7D")
      op.should eq(GQL::Op.new("Op", "{me}", "{\n  \"x\": 1\n}"))
    end

    it "requires an open-brace in the decoded query" do
      GQL.from_query("p?query=shoes").should be_nil
    end

    it "returns nil when the target has no query string" do
      GQL.from_query("shoes").should be_nil
      GQL.from_query("/plain/path").should be_nil
    end

    it "returns nil when there is no query param at all" do
      GQL.from_query("p?operationName=Op&variables=%7B%7D").should be_nil
    end

    it "falls back to the raw variables text when it is not valid JSON" do
      op = GQL.from_query("p?query=%7Bme%7D&variables=notjson")
      op.should eq(GQL::Op.new(nil, "{me}", "notjson"))
    end

    it "ignores a valueless (no '=') pair" do
      op = GQL.from_query("p?query=%7Bme%7D&flag")
      op.should eq(GQL::Op.new(nil, "{me}", nil))
    end
  end

  describe ".display" do
    it "emits only the sections that are present" do
      GQL.display(GQL::Op.new(nil, "{ me }", nil)).should eq("{ me }")
      GQL.display(GQL::Op.new("Foo", "{ me }", nil)).should eq("# operationName: Foo\n\n{ me }")
      GQL.display(GQL::Op.new(nil, "{ me }", "{}")).should eq("{ me }\n\n# variables\n{}")
      GQL.display(GQL::Op.new("Foo", "{ me }", "{}"))
        .should eq("# operationName: Foo\n\n{ me }\n\n# variables\n{}")
    end
  end

  describe ".parse_display" do
    it "returns {nil, \"\", nil} for empty input" do
      GQL.parse_display("").should eq({nil, "", nil})
    end

    it "keeps an in-query '# variables' comment in the query when it is not a real sentinel" do
      # doc lines 78-86: a comment followed by more GraphQL (not JSON) must NOT truncate.
      op, query, vars = GQL.parse_display("{ user { id } }\n# variables\n{ more }")
      op.should be_nil
      vars.should be_nil
      query.should eq("{ user { id } }\n# variables\n{ more }")
    end

    it "detects a real trailing sentinel and lifts a leading operationName header off the query" do
      op, query, vars = GQL.parse_display("# operationName: Foo\n\n{ user { id } }\n# variables\n{\"id\":1}")
      op.should eq("Foo")
      query.should eq("{ user { id } }")
      query.includes?("operationName").should be_false
      vars.should eq("{\"id\":1}")
    end

    it "accepts a JSON-array trailing block (tail_first == '[')" do
      GQL.parse_display("{ q }\n# variables\n[1,2,3]").should eq({nil, "{ q }", "[1,2,3]"})
    end

    it "rejects a bare JSON scalar trailing block (tail_first is not '{'/'[')" do
      # 42 is valid JSON but the tail_first gate only trusts '{'/'[' — stays in the query.
      _, query, vars = GQL.parse_display("{ q }\n# variables\n42")
      vars.should be_nil
      query.should eq("{ q }\n# variables\n42")
    end

    it "rejects a '# variables' sentinel with an EMPTY trailing block" do
      _, query, vars = GQL.parse_display("{ q }\n# variables\n")
      vars.should be_nil
      query.should eq("{ q }\n# variables")
    end

    it "treats an empty operationName value as no operation" do
      GQL.parse_display("# operationName:").should eq({nil, "", nil})
      GQL.parse_display("# operationName:   \n\n{ me }").should eq({nil, "{ me }", nil})
    end

    it "picks the LAST genuine sentinel when several exist" do
      # only the final '# variables' whose trailing is JSON wins; earlier one stays in query.
      _, query, vars = GQL.parse_display("{ a }\n# variables\nnot json\n# variables\n{\"z\":9}")
      vars.should eq("{\"z\":9}")
      query.should eq("{ a }\n# variables\nnot json")
    end

    it "stays fast and truncates nothing on hundreds of literal '# variables' comment lines" do
      # ReDoS / O(n^2) guard: each sentinel is followed by non-bracket GraphQL, so the
      # tail_first gate never invokes the JSON parse. Everything must remain in the query.
      blocks = [] of String
      2000.times { |i| blocks << "# variables"; blocks << "someField#{i} { id }" }
      text = blocks.join('\n')
      op, query, vars = GQL.parse_display(text)
      op.should be_nil
      vars.should be_nil
      query.should eq(text)
    end

    it "handles multibyte / emoji in both the query and the variables block" do
      _, query, vars = GQL.parse_display("{ 사용자 }\n# variables\n{\"이름\":\"世界🎉\"}")
      query.should eq("{ 사용자 }")
      vars.should eq("{\"이름\":\"世界🎉\"}")
    end
  end

  describe "display / parse_display round-trip" do
    it "recovers all three sections" do
      op = GQL::Op.new("MyQuery", "{ user { id } }", %({"id": 1}))
      round_trip(op).should eq({"MyQuery", "{ user { id } }", %({"id": 1})})
    end

    it "recovers an operation + query (no variables)" do
      op = GQL::Op.new("Foo", "{ x }", nil)
      round_trip(op).should eq({"Foo", "{ x }", nil})
    end

    it "recovers a query-only op" do
      op = GQL::Op.new(nil, "{ me }", nil)
      round_trip(op).should eq({nil, "{ me }", nil})
    end
  end

  describe ".recompose" do
    it "preserves an unmanaged extensions field and overlays edited query + variables (minified)" do
      base = %({"query":"{ old }","variables":{"a":1},"extensions":{"pq":true}})
      decoded = GQL.display(GQL::Op.new(nil, "{ new }", %({"b":2})))
      out = GQL.recompose(base, decoded)
      out.should eq(%({"query":"{ new }","variables":{"b":2},"extensions":{"pq":true}}))
      out.includes?('\n').should be_false # minified
    end

    it "keeps the original variables when the decoded pane carries no variables block" do
      base = %({"query":"{ old }","variables":{"a":1},"extensions":{"pq":true}})
      decoded = GQL.display(GQL::Op.new("Op", "{ new }", nil))
      out = GQL.recompose(base, decoded)
      out.should eq(%({"operationName":"Op","query":"{ new }","variables":{"a":1},"extensions":{"pq":true}}))
    end

    it "works when the original body is not valid JSON (nothing to preserve)" do
      out = GQL.recompose("garbage", GQL.display(GQL::Op.new(nil, "{ me }", nil)))
      out.should eq(%({"query":"{ me }"}))
    end
  end

  describe ".recompose_query" do
    it "preserves unmanaged params and appends the edited query (no operationName pair when absent)" do
      out = GQL.recompose_query("query=%7Bold%7D&apiKey=secret&operationName=Old", "{ new }")
      out.should eq("apiKey=secret&query=%7B+new+%7D")
      out.includes?("operationName").should be_false
    end

    it "minifies the variables and appends operationName when present" do
      decoded = GQL.display(GQL::Op.new("Op", "{ new }", %({"x": 1})))
      out = GQL.recompose_query("query=old&apiKey=x", decoded)
      out.should eq("apiKey=x&query=%7B+new+%7D&operationName=Op&variables=%7B%22x%22%3A1%7D")
    end
  end

  describe ".location" do
    it "reports :body for a GraphQL JSON POST body" do
      GQL.location(%({"query":"{ me }"}).to_slice).should eq(:body)
    end

    it "reports :query for a plain REST body" do
      GQL.location(%({"query":"shoes"}).to_slice).should eq(:query)
      GQL.location(%({"foo":1}).to_slice).should eq(:query)
    end

    it "reports :query for nil or empty bodies" do
      GQL.location(nil).should eq(:query)
      GQL.location(Bytes.new(0)).should eq(:query)
    end

    it "reports :query for an over-sized body without parsing it" do
      big = Bytes.new(Gori::Graphql::MAX_BODY + 1, 0x7b_u8) # all '{'
      GQL.location(big).should eq(:query)
    end
  end

  describe ".from_flow" do
    it "prefers a GraphQL JSON body over the GET binding" do
      op = GQL.from_flow("p?query=%7Bfrom_get%7D", nil, %({"query":"{ from_body }"}).to_slice)
      op.should eq(GQL::Op.new(nil, "{ from_body }", nil))
    end

    it "falls through to the GET query string when the body is non-GraphQL JSON" do
      op = GQL.from_flow("p?query=%7Bme%7D", nil, %({"query":"shoes"}).to_slice)
      op.should eq(GQL::Op.new(nil, "{me}", nil))
    end

    it "falls through to the GET binding for an empty / nil / oversized body" do
      GQL.from_flow("p?query=%7Bme%7D", nil, nil).should eq(GQL::Op.new(nil, "{me}", nil))
      GQL.from_flow("p?query=%7Bme%7D", nil, Bytes.new(0)).should eq(GQL::Op.new(nil, "{me}", nil))
      big = Bytes.new(Gori::Graphql::MAX_BODY + 1, 0x7b_u8)
      GQL.from_flow("p?query=%7Bme%7D", nil, big).should eq(GQL::Op.new(nil, "{me}", nil))
    end

    it "returns nil when neither the body nor the target is GraphQL" do
      GQL.from_flow("/rest/path", nil, %({"foo":1}).to_slice).should be_nil
    end
  end
end
