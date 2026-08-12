require "./spec_helper"

private alias GQL = Gori::Graphql

# a request head carrying just the given Content-Type.
private def ct_head(ct : String) : Bytes
  "POST /graphql HTTP/1.1\r\nContent-Type: #{ct}\r\n\r\n".to_slice
end

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
      op.should eq(GQL::Op.new("Op", "{me}", "{\n  \"x\": 1\n}", GQL::Form::Query))
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
      op.should eq(GQL::Op.new(nil, "{me}", "notjson", GQL::Form::Query))
    end

    it "ignores a valueless (no '=') pair" do
      op = GQL.from_query("p?query=%7Bme%7D&flag")
      op.should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
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

  describe ".parse_display / operationName sentinel" do
    # `# operationName:` is also a valid GraphQL comment. The `# variables` sentinel already
    # gets disambiguated; this one did not, so a document whose FIRST line was such a comment
    # had that line deleted and its text promoted into a real operationName — changing which
    # operation the server runs.
    it "does not promote a leading GraphQL comment into a real operationName" do
      text = "# operationName: NotReallyTheName\nquery Real { a }"
      op, query, _ = GQL.parse_display(text)
      op.should be_nil
      query.should eq(text)
    end

    it "still lifts the genuine header, which display always follows with a blank line" do
      op, query, _ = GQL.parse_display(GQL.display(GQL::Op.new("Hero", "query Hero { a }", nil)))
      op.should eq("Hero")
      query.should eq("query Hero { a }")
    end

    it "treats a deleted header as an explicit unset rather than falling back to the base" do
      out = GQL.recompose(%({"query":"query Hero { a }","operationName":"Hero"}), "query Hero { a }")
      out.should eq(%({"query":"query Hero { a }"}))
    end

    it "keeps other base fields (a persisted-query extensions block) across a recompose" do
      base = %({"query":"{ a }","operationName":"Op","extensions":{"persistedQuery":{"version":1}}})
      out = GQL.recompose(base, GQL.display(GQL::Op.new("Op", "{ b }", nil)))
      out.should contain(%("extensions":{"persistedQuery":{"version":1}}))
      out.should contain(%("query":"{ b }"))
    end
  end

  describe ".recompose_query" do
    # A managed param is replaced WHERE IT STOOD. Dropping and re-appending it reordered the
    # query string — `page=2&query=…&sig=abc` came back as `page=2&sig=abc&query=…` — which is
    # a request the operator did not write and which breaks any signature or cache key computed
    # over the canonical query string. That is a real target shape for this tool, so position
    # is part of what "edit the query" must preserve.
    it "replaces the edited query in place and keeps unmanaged params where they were" do
      out = GQL.recompose_query("query=%7Bold%7D&apiKey=secret&operationName=Old", "{ new }")
      out.should eq("query=%7B+new+%7D&apiKey=secret")
      out.includes?("operationName").should be_false # the edit removed it, so it is gone
    end

    it "keeps a managed param's slot even when other params surround it" do
      decoded = GQL.display(GQL::Op.new("Op", "{ new }", nil))
      out = GQL.recompose_query("page=2&query=old&sig=abc", decoded)
      out.should eq("page=2&query=%7B+new+%7D&sig=abc&operationName=Op")
    end

    it "minifies the variables and appends params the original did not carry" do
      decoded = GQL.display(GQL::Op.new("Op", "{ new }", %({"x": 1})))
      out = GQL.recompose_query("query=old&apiKey=x", decoded)
      out.should eq("query=%7B+new+%7D&apiKey=x&operationName=Op&variables=%7B%22x%22%3A1%7D")
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
      op.should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
    end

    it "falls through to the GET binding for an empty / nil / oversized body" do
      GQL.from_flow("p?query=%7Bme%7D", nil, nil).should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
      GQL.from_flow("p?query=%7Bme%7D", nil, Bytes.new(0)).should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
      big = Bytes.new(Gori::Graphql::MAX_BODY + 1, 0x7b_u8)
      GQL.from_flow("p?query=%7Bme%7D", nil, big).should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
    end

    # The false positive that mattered: `location` answers `:query` for anything `from_flow`
    # resolved off the query string, so the Repeater re-encodes the WHOLE query string on send.
    # A POST/PUT/PATCH that sent a body has already said where its payload is; falling through
    # to a stray `?query=` param rewrote a request on the strength of a misdetection.
    it "does not fall through to a ?query= param for a POST that sent an unrelated body" do
      head = "POST /upload?query=%7Bx%7D HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      GQL.from_flow("/upload?query=%7Bx%7D", head, Bytes[0x00, 0x01, 0xff]).should be_nil
    end

    it "does not fall through for PUT or PATCH either" do
      {"PUT", "PATCH"}.each do |m|
        head = "#{m} /u?query=%7Bx%7D HTTP/1.1\r\n\r\n".to_slice
        GQL.from_flow("/u?query=%7Bx%7D", head, %({"not":"graphql"}).to_slice).should be_nil
      end
    end

    it "still prefers a real GraphQL body on a POST" do
      head = "POST /graphql HTTP/1.1\r\n\r\n".to_slice
      GQL.from_flow("/graphql", head, %({"query":"{ me }"}).to_slice)
        .should eq(GQL::Op.new(nil, "{ me }", nil))
    end

    it "still falls through for a GET carrying a stray body (what the fallback was for)" do
      head = "GET /g?query=%7Bme%7D HTTP/1.1\r\n\r\n".to_slice
      GQL.from_flow("/g?query=%7Bme%7D", head, %({"foo":1}).to_slice)
        .should eq(GQL::Op.new(nil, "{me}", nil, GQL::Form::Query))
    end

    it "returns nil when neither the body nor the target is GraphQL" do
      GQL.from_flow("/rest/path", nil, %({"foo":1}).to_slice).should be_nil
    end
  end

  # Only two of the six shapes an operator actually meets were ever recognised. `from_json`
  # required `json.as_h?` (so a BATCHED array was never GraphQL — the shape a batching-abuse /
  # rate-limit-bypass test uses), required a top-level string `query` containing `{` (so a
  # PERSISTED query, which by definition sends no document, was never GraphQL), and
  # JSON-parsed the whole body regardless of Content-Type (so a MULTIPART upload mutation and
  # an `application/graphql` document were never GraphQL either).
  describe "the request shapes a real API exposes" do
    it "recognises a batched array and says how many operations it carries" do
      op = GQL.from_json(%([{"query":"{a}"},{"query":"{b}","operationName":"B"}])).not_nil!
      op.form.should eq(GQL::Form::Batch)
      op.query.should contain("# batch of 2 operations")
      op.query.should contain("{a}")
      op.query.should contain("{b}")
      op.query.should contain("# operationName: B")
    end

    it "recognises a persisted query, which sends no document at all" do
      body = %({"operationName":"Q","variables":{"id":1},) +
             %("extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc123"}}})
      op = GQL.from_json(body).not_nil!
      op.form.should eq(GQL::Form::Persisted)
      op.operation.should eq("Q")
      op.query.should contain("# persisted query — no document was sent")
      op.query.should contain("sha256Hash: abc123")
      op.variables.not_nil!.should contain("\"id\": 1")
    end

    it "recognises an application/graphql body as the document itself" do
      head = "POST /graphql HTTP/1.1\r\nContent-Type: application/graphql\r\n\r\n".to_slice
      op = GQL.from_flow("/graphql", head, "{ me { id } }".to_slice).not_nil!
      op.form.should eq(GQL::Form::Document)
      op.query.should eq("{ me { id } }")
    end

    it "recognises a multipart upload mutation via its `operations` part" do
      b = "----X"
      body = ["--#{b}",
              %(Content-Disposition: form-data; name="operations"),
              "",
              %({"query":"mutation($f: Upload!){ upload(file: $f){ id } }","variables":{"f":null}}),
              "--#{b}",
              %(Content-Disposition: form-data; name="map"),
              "",
              %({"0":["variables.f"]}),
              "--#{b}--", ""].join("\r\n")
      head = %(POST /graphql HTTP/1.1\r\nContent-Type: multipart/form-data; boundary="#{b}"\r\n\r\n).to_slice
      op = GQL.from_flow("/graphql", head, body.to_slice).not_nil!
      op.form.should eq(GQL::Form::Multipart)
      op.query.should contain("mutation(")
      op.variables.not_nil!.should contain("\"f\": null")
    end

    it "still refuses a plain JSON array / non-GraphQL body (no hijacking)" do
      GQL.from_json(%([{"id":1},{"id":2}])).should be_nil
      GQL.from_json(%([{"query":"{a}"},{"id":2}])).should be_nil # one stray element ⇒ not a batch
      GQL.from_json("[]").should be_nil
      GQL.from_json(%({"variables":{"x":1}})).should be_nil # no query, no persistedQuery
    end

    it "does not read a multipart/application-graphql body as JSON" do
      head = "POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=zz\r\n\r\n".to_slice
      GQL.from_flow("/u", head, %({"query":"{ me }"}).to_slice).should be_nil
    end
  end

  # REGRESSION PIN. Making the four new shapes parse is what creates the hazard: `location`
  # drives which side the Repeater RE-ENCODES on send, so answering `:body` would recompose a
  # batch array into a single object and answering `:query` would rewrite the query STRING of
  # a request whose payload is in the body. Either one sends a request the operator never
  # wrote, on the strength of a projection. This guards the decision that only the two
  # invertible shapes are editable, and that the other four re-encode nothing at all.
  describe "the re-encode gate" do
    it "marks only the three invertible shapes editable" do
      GQL.from_json(%({"query":"{ me }"})).not_nil!.editable?.should be_true
      GQL.from_query("p?query=%7Bme%7D").not_nil!.editable?.should be_true
      form_head = "POST /g HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n".to_slice
      GQL.from_flow("/g", form_head, "query=%7Bme%7D".to_slice).not_nil!.editable?.should be_true
      GQL.from_json(%([{"query":"{a}"}])).not_nil!.editable?.should be_false
      GQL.from_json(%({"extensions":{"persistedQuery":{"sha256Hash":"h"}}})).not_nil!.editable?.should be_false
    end

    it "answers :none — never :body or :query — for a shape it cannot re-encode" do
      GQL.location(%([{"query":"{a}"},{"query":"{b}"}]).to_slice).should eq(:none)
      GQL.location(%({"extensions":{"persistedQuery":{"sha256Hash":"h"}}}).to_slice).should eq(:none)
      doc_head = "POST /g HTTP/1.1\r\nContent-Type: application/graphql\r\n\r\n".to_slice
      GQL.location("{ me }".to_slice, doc_head).should eq(:none)
      mp_head = "POST /g HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=zz\r\n\r\n".to_slice
      mp_body = ["--zz", %(Content-Disposition: form-data; name="operations"), "",
                 %({"query":"{ me }"}), "--zz--", ""].join("\r\n").to_slice
      GQL.location(mp_body, mp_head).should eq(:none)
    end

    it "still answers :body / :query for the two shapes that round-trip" do
      GQL.location(%({"query":"{ me }"}).to_slice).should eq(:body)
      GQL.location(nil).should eq(:query)
    end
  end

  # A GraphQL-carrying request that did NOT parse used to be reported byte-identically to
  # "this flow is not GraphQL" — no `graphql` key, no `=== GRAPHQL ===` section — for the one
  # request most worth looking at. Same treatment `fix(grpc): report a framing failure instead
  # of deleting the gRPC view` gave gRPC.
  describe ".from_flow — a parse failure is reported, not deleted" do
    private_head = "POST /gql HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"

    it "reports invalid JSON that is still obviously a GraphQL envelope" do
      op = GQL.from_flow("/gql", private_head.to_slice, %({"query":"{broken}",).to_slice).not_nil!
      op.form.should eq(GQL::Form::Invalid)
      op.note.not_nil!.should contain("not valid JSON")
      op.editable?.should be_false
      GQL.display(op).should contain("GraphQL parse failed")
    end

    it "reports a batch envelope that was cut mid-body" do
      op = GQL.from_flow("/gql", private_head.to_slice, %([{"query":"{a}"},{"que).to_slice).not_nil!
      op.form.should eq(GQL::Form::Invalid)
    end

    it "reports an application/graphql document with no selection set" do
      head = "POST /g HTTP/1.1\r\nContent-Type: application/graphql\r\n\r\n".to_slice
      op = GQL.from_flow("/g", head, "not a document".to_slice).not_nil!
      op.form.should eq(GQL::Form::Invalid)
      op.note.not_nil!.should contain("no selection set")
    end

    it "reports a multipart upload whose `operations` part is not an envelope" do
      head = "POST /g HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=zz\r\n\r\n".to_slice
      body = ["--zz", %(Content-Disposition: form-data; name="operations"), "",
              "{not json", "--zz--", ""].join("\r\n").to_slice
      op = GQL.from_flow("/g", head, body).not_nil!
      op.form.should eq(GQL::Form::Invalid)
      op.note.not_nil!.should contain("operations")
    end

    # The guard that keeps this from hijacking ordinary traffic: "opens like an envelope" is
    # not "is one". A body that PARSES and was rejected is a REST call carrying a string
    # `query` field, and it must keep getting no GraphQL section at all.
    it "stays silent for a REST body that parses but is not GraphQL" do
      GQL.from_flow("/api", private_head.to_slice, %({"query":"shoes","page":2}).to_slice).should be_nil
    end

    it "stays silent for an unrelated malformed JSON body" do
      GQL.from_flow("/api", private_head.to_slice, %({"page":2,).to_slice).should be_nil
    end

    it "stays silent for a plain multipart upload with no `operations` part" do
      head = "POST /u HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=zz\r\n\r\n".to_slice
      body = ["--zz", %(Content-Disposition: form-data; name="file"; filename="a.bin"), "",
              "bytes", "--zz--", ""].join("\r\n").to_slice
      GQL.from_flow("/u", head, body).should be_nil
    end

    # `from_body` is unchanged, so the Repeater re-encode target never becomes :body for one.
    it "leaves the re-encode gate answering :query for an unparseable body" do
      GQL.location(%({"query":"{broken}",).to_slice).should eq(:query)
    end
  end

  # The GraphQL-over-HTTP spec's own media types are `application/graphql+json` and
  # `application/graphql-response+json`, and BOTH begin with `application/graphql` — the type
  # whose body is a raw document. A `starts_with?` dispatch therefore fed the two ordinary
  # JSON envelopes to the document parser, which reported the whole JSON blob as the "query"
  # in `Form::Document` — a shape nothing can re-encode, so the Repeater opened it as a plain
  # raw tab. A GraphQL request looked like an ordinary request, which is the bug.
  describe "content-type dispatch — the +json suffix is not the document type" do
    body = %({"query":"query Me { me { id } }","operationName":"Me","variables":{"a":1}})

    it "reads application/graphql+json as the JSON envelope" do
      op = GQL.from_flow("/graphql", ct_head("application/graphql+json"), body.to_slice).not_nil!
      op.form.should eq(GQL::Form::Json)
      op.operation.should eq("Me")
      op.query.should eq("query Me { me { id } }")
      op.editable?.should be_true
      GQL.location(body.to_slice, ct_head("application/graphql+json")).should eq(:body)
    end

    it "reads application/graphql-response+json, charset and all, as the JSON envelope" do
      head = ct_head("application/graphql-response+json; charset=utf-8")
      GQL.from_flow("/graphql", head, body.to_slice).not_nil!.form.should eq(GQL::Form::Json)
    end

    it "folds the media type but keeps reading a genuine application/graphql document" do
      head = ct_head("Application/GraphQL")
      op = GQL.from_flow("/graphql", head, "{ me { id } }".to_slice).not_nil!
      op.form.should eq(GQL::Form::Document)
    end

    # Clients mislabel this one constantly — it is the type reached for when someone means
    # "GraphQL" — and a body that parses as an envelope is an envelope whatever the header says.
    it "prefers the envelope when application/graphql carries JSON anyway" do
      op = GQL.from_flow("/graphql", ct_head("application/graphql"), body.to_slice).not_nil!
      op.form.should eq(GQL::Form::Json)
      op.query.should eq("query Me { me { id } }")
    end
  end

  # `query=…&variables=…` under `application/x-www-form-urlencoded` is what express-graphql and
  # Yoga accept beside JSON — and it is the first thing reached for when a JSON content-type is
  # filtered, so the shape most likely to be a bypass attempt was the one shown as an ordinary
  # form POST with no GraphQL anywhere.
  describe "the urlencoded request body" do
    head = "POST /graphql HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n".to_slice
    body = "query=query+Me+%7B+me+%7D&variables=%7B%22a%22%3A1%7D&operationName=Me"

    it "parses it into the same triple as the JSON and GET bindings" do
      op = GQL.from_flow("/graphql", head, body.to_slice).not_nil!
      op.form.should eq(GQL::Form::Urlencoded)
      op.operation.should eq("Me")
      op.query.should eq("query Me { me }")
      op.variables.not_nil!.should contain(%("a": 1))
    end

    it "re-encodes into the BODY's own grammar, not JSON" do
      GQL.location(body.to_slice, head).should eq(:form_body)
      out = GQL.recompose_form("page=2&query=%7Bold%7D&sig=abc", "query New { x }")
      out.should eq("page=2&query=query+New+%7B+x+%7D&sig=abc") # rewritten IN PLACE
    end

    it "keeps an ordinary form POST out of it (selection-set guard)" do
      GQL.from_flow("/search", head, "query=shoes&page=2".to_slice).should be_nil
      GQL.from_flow("/login", head, "user=a&pass=b".to_slice).should be_nil
    end
  end

  # The anchored envelope test only ever runs on a body that FAILED to parse — a truncated or
  # mangled envelope. Anchoring it on `"query"` alone recognised every client except the
  # dominant one: Apollo Client serialises operationName first.
  describe "the envelope anchor" do
    head = "POST /gql HTTP/1.1\r\nContent-Type: application/json\r\n\r\n".to_slice

    it "reports a truncated envelope whose first key is operationName" do
      body = %({"operationName":"Me","variables":{},"query":"query Me { me { i).to_slice
      op = GQL.from_flow("/gql", head, body).not_nil!
      op.form.should eq(GQL::Form::Invalid)
    end

    it "reports any unparseable body under a content-type that only means GraphQL" do
      gql_json = "POST /gql HTTP/1.1\r\nContent-Type: application/graphql+json\r\n\r\n".to_slice
      op = GQL.from_flow("/gql", gql_json, "<<binary garbage>>".to_slice).not_nil!
      op.form.should eq(GQL::Form::Invalid)
      op.note.not_nil!.should contain("application/graphql+json")
    end

    it "does not claim an unparseable REST body that merely opens with variables/extensions" do
      GQL.from_flow("/api", head, %({"extensions":{"a":1},).to_slice).should be_nil
      GQL.from_flow("/api", head, %({"variables":{"a":1},).to_slice).should be_nil
    end
  end
end
