require "../spec_helper"

private def schema_doc : JSON::Any
  JSON.parse(File.read(File.join(__DIR__, "..", "fixtures", "graphql", "introspection.json")))
end

private def parse_graphql(doc = schema_doc, endpoint : String? = "https://api.test/graphql?tenant=1", *, raw : String? = nil) : Gori::Import::ParseResult
  file = File.tempfile("gori-graphql", ".json") { |f| f.print(raw || doc.to_json) }
  begin
    Gori::Import::Graphql.parse_file(file.path, endpoint)
  ensure
    file.delete
  end
end

private def gql_types(doc : JSON::Any) : Array(JSON::Any)
  doc["data"]["__schema"]["types"].as_a
end

private def envelope(pair : Gori::Import::Builder::FlowPair) : JSON::Any
  JSON.parse(String.new(pair.request.body.not_nil!))
end

describe Gori::Import::Graphql do
  it "accepts the introspection response envelope or the result value alone" do
    wrapped = schema_doc
    expected = parse_graphql(wrapped).flows.map { |pair| envelope(pair) }
    expected.size.should eq(5)
    parse_graphql(wrapped["data"]).flows.map { |pair| envelope(pair) }.should eq(expected)
  end

  it "prefers data.__schema and falls back to a top-level schema object" do
    doc = schema_doc
    doc.as_h["__schema"] = JSON.parse("{}")
    parse_graphql(doc).flows.size.should eq(5)
    doc.as_h["__schema"] = doc["data"]["__schema"]
    doc.as_h["data"] = JSON.parse(%({"__schema":null}))
    parse_graphql(doc).flows.size.should eq(5)
  end

  it "names both supported shapes when neither has a schema object" do
    [%({}), %({"__schema":42}), %({"data":{"__schema":[]}})].each do |raw|
      expect_raises(Gori::Error, "GraphQL document has no data.__schema or top-level __schema object") do
        parse_graphql(raw: raw)
      end
    end
  end

  it "builds one inert, framed JSON POST for each query/mutation and reports subscriptions" do
    parsed = parse_graphql
    parsed.skipped.should eq(0)
    parsed.flows.size.should eq(5)
    parsed.notes.join.should contain("skipped 1 subscription")
    parsed.flows.each do |pair|
      req = pair.request
      req.source.import?.should be_true
      req.host.should eq("api.test")
      req.target.should eq("/graphql?tenant=1")
      req.method.should eq("POST")
      req.body_truncated?.should be_false
      pair.response.should be_nil
      String.new(req.head).should contain("Content-Type: application/json\r\n")
      String.new(req.head).should contain("Content-Length: #{req.body.not_nil!.size}\r\n")
    end
  end

  it "declares and uses variables with matching list/non-null syntax and input values" do
    bodies = parse_graphql.flows.map { |p| envelope(p) }
    me = bodies[0]
    me["operationName"].as_s.should eq("me")
    me["query"].as_s.should eq("query me($id: ID!, $filter: Filter, $roles: [Role!]!) { me(id: $id, filter: $filter, roles: $roles) { __typename id name friends { __typename } profile { __typename label owner { __typename } } } }")
    vars = me["variables"]
    vars["id"].as_s.should eq("id")
    vars["roles"].as_a.should be_empty
    input = vars["filter"]
    input["text"].as_s.should eq("text")
    input["count"].as_i.should eq(0)
    input["ratio"].as_i.should eq(0)
    input["enabled"].as_bool.should be_true
    input["role"].as_s.should eq("ADMIN")
    input["next"].raw.should be_nil
    input["children"].as_a.should be_empty
    bodies[4]["query"].as_s.should start_with("mutation create($input: Filter!) { create(input: $input)")
    bodies[4]["variables"]["input"].should eq(input)
  end

  it "generates valid scalar, interface and union selections, without required nested arguments" do
    bodies = parse_graphql.flows.map { |p| envelope(p)["query"].as_s }
    bodies[1].should eq("query search { search { __typename ... on User { __typename gori_0_id: id gori_0_name: name gori_0_friends: friends { __typename } gori_0_profile: profile { __typename label owner { __typename } } } ... on Profile { __typename gori_1_label: label gori_1_owner: owner { __typename id name friends { __typename } profile { __typename } } } } }")
    bodies[2].should eq("query node { node { __typename id } }")
    bodies[3].should eq("query ping { ping }")
    bodies.each(&.should_not(contain("secret")))
  end

  it "stamps provenance and stores only pending imported flows through the shared entrypoint" do
    with_store do |store|
      result = Gori::Import.import_text(store, :graphql, schema_doc.to_json,
        Gori::FlowSource::Surface::Cli, endpoint: "https://api.test/graphql")
      result.count.should eq(5)
      store.recent_flows(10).each do |row|
        detail = store.get_flow(row.id).not_nil!
        detail.row.source.should eq(Gori::FlowSource::Kind::Import)
        detail.row.source_surface.should eq(Gori::FlowSource::Surface::Cli)
        detail.row.source_ref.should eq("graphql text")
        detail.response_body.should be_nil
      end
    end
  end

  it "reports wrong-shaped JSON and missing endpoints as domain errors" do
    ["null", "[]", "123456789012345678901234567890", %({"data":[]}), %({"data":{"__schema":42}})].each do |raw|
      expect_raises(Gori::Error) { parse_graphql(raw: raw) }
    end
    expect_raises(Gori::Error, "requires an endpoint") { parse_graphql(endpoint: nil) }
    expect_raises(Gori::Error) { parse_graphql(endpoint: "ftp://api.test/graphql") }
  end

  it "skips malformed operations without losing their siblings" do
    doc = schema_doc
    gql_types(doc)[5]["fields"].as_a[0].as_h["args"] = JSON::Any.new(false)
    result = parse_graphql(doc)
    result.flows.size.should eq(4)
    result.skipped.should eq(1)
    result.notes.join.should contain("args is not an array")
  end

  it "rejects malformed and overlong names before they reach generated syntax" do
    ["bad) { injected }", "x" * (Gori::Import::Graphql::MAX_NAME + 1), String.new(Bytes[0xff])].each do |n|
      doc = schema_doc
      gql_types(doc)[5]["fields"].as_a[0].as_h["name"] = JSON::Any.new(n)
      result = parse_graphql(doc)
      result.flows.size.should eq(4)
      result.skipped.should eq(1)
    end
  end

  it "bounds type and operation counts" do
    doc = schema_doc
    types = gql_types(doc)
    (Gori::Import::Graphql::MAX_TYPES + 1).times do |i|
      types << JSON.parse({kind: "SCALAR", name: "Extra#{i}"}.to_json)
    end
    expect_raises(Gori::Error, "types exceeds") { parse_graphql(doc) }
    doc = schema_doc
    fields = gql_types(doc)[5]["fields"].as_a
    (Gori::Import::Graphql::MAX_OPERATIONS + 1).times { fields << fields[0] }
    expect_raises(Gori::Error, "fields exceeds") { parse_graphql(doc) }
  end

  it "bounds selection width and terminates on recursive output types" do
    doc = schema_doc
    fields = gql_types(doc)[8]["fields"].as_a # User
    fields.clear
    20.times { |i| fields << JSON.parse({name: "f#{i}", args: [] of String, type: {kind: "OBJECT", name: "User"}}.to_json) }
    q = envelope(parse_graphql(doc).flows[0])["query"].as_s
    q.should contain("f7 { __typename }")
    q.should_not contain("f8")
    q.bytesize.should be < 1000
  end

  it "refuses required input cycles, unknown references and excessive wrapper depth per operation" do
    doc = schema_doc
    fields = gql_types(doc).find { |t| t["name"].as_s == "Filter" }.not_nil!["inputFields"].as_a
    fields << JSON.parse(%({"name":"required","type":{"kind":"NON_NULL","ofType":{"kind":"INPUT_OBJECT","name":"Filter"}}}))
    parse_graphql(doc).skipped.should eq(2)
    doc = schema_doc
    gql_types(doc)[5]["fields"].as_a[0].as_h["type"] = JSON.parse(%({"kind":"OBJECT","name":"Missing"}))
    parse_graphql(doc).notes.join.should contain("unknown GraphQL type Missing")
    ref = %({"kind":"SCALAR","name":"String"})
    Gori::Import::Graphql::MAX_REF_DEPTH.times { ref = %({"kind":"LIST","ofType":#{ref}}) }
    doc = schema_doc
    gql_types(doc)[5]["fields"].as_a[0].as_h["type"] = JSON.parse(ref)
    parse_graphql(doc).notes.join.should contain("type reference exceeds")
  end

  it "bounds argument/input width and generated work per operation" do
    doc = schema_doc
    args = gql_types(doc)[5]["fields"].as_a[0]["args"].as_a
    65.times { |i| args << JSON.parse({name: "a#{i}", type: {kind: "SCALAR", name: "String"}}.to_json) }
    parse_graphql(doc).notes.join.should contain("args exceeds 64")

    doc = schema_doc
    inputs = gql_types(doc).find { |t| t["name"].as_s == "Filter" }.not_nil!["inputFields"].as_a
    inputs.clear
    65.times { |i| inputs << JSON.parse({name: "a#{i}", type: {kind: "SCALAR", name: "String"}}.to_json) }
    parse_graphql(doc).notes.join.should contain("inputFields exceeds 64")

    doc = schema_doc
    types = gql_types(doc)
    leaf = JSON.parse({name: "LeafInput", kind: "INPUT_OBJECT", inputFields: (0...64).map { |i| {name: "f#{i}", type: {kind: "SCALAR", name: "String"}} }}.to_json)
    types << leaf
    inputs = types.find { |t| t["name"].as_s == "Filter" }.not_nil!["inputFields"].as_a
    inputs.clear
    8.times { |i| inputs << JSON.parse({name: "f#{i}", type: {kind: "INPUT_OBJECT", name: "LeafInput"}}.to_json) }
    result = parse_graphql(doc)
    result.flows.size.should eq(3)
    result.notes.join.should contain("generated nodes")
  end

  it "validates each input object once, not once per visit" do
    # A 15-deep LIST chain on every leaf field, reached through 64×64 nullable input fields:
    # re-validated per visit this was ~650k name checks per operation before the node budget
    # threw it away, ~200 ms of a blocked scheduler each (P6).
    deep = %({"kind":"SCALAR","name":"String"})
    15.times { deep = %({"kind":"LIST","name":null,"ofType":#{deep}}) }
    input = ->(n : String, ref : String) do
      JSON.parse(%({"kind":"INPUT_OBJECT","name":"#{n}","inputFields":[#{(0...64).map { |i| %({"name":"f#{i}","type":#{ref}}) }.join(",")}]}))
    end
    doc = schema_doc
    types = gql_types(doc)
    types << input.call("DeepC", deep)
    types << input.call("DeepB", %({"kind":"INPUT_OBJECT","name":"DeepC"}))
    types << input.call("DeepA", %({"kind":"INPUT_OBJECT","name":"DeepB"}))
    fields = types[5]["fields"].as_a
    fields.clear
    24.times { |i| fields << JSON.parse(%({"name":"q#{i}","args":[{"name":"x","type":{"kind":"INPUT_OBJECT","name":"DeepA"}}],"type":{"kind":"SCALAR","name":"String"}})) }
    doc["data"]["__schema"].as_h["mutationType"] = JSON::Any.new(nil)
    started = Time.instant
    result = parse_graphql(doc)
    elapsed = Time.instant - started
    result.skipped.should eq(24)
    result.notes.join.should contain("generated nodes")
    # Main spent ~200 ms per operation here (~5 s); memoized it is tens of ms in all.
    elapsed.should be < 2.seconds
  end

  it "limits acyclic output expansion by depth" do
    doc = schema_doc
    types = gql_types(doc)
    6.times do |i|
      types << JSON.parse({name: "Depth#{i}", kind: "OBJECT", fields: [{name: "next", args: [] of String, type: {kind: "OBJECT", name: "Depth#{i + 1}"}}]}.to_json)
    end
    types << JSON.parse({name: "Depth6", kind: "OBJECT", fields: [] of String}.to_json)
    types[5]["fields"].as_a[0].as_h["type"] = JSON.parse(%({"kind":"OBJECT","name":"Depth0"}))
    q = envelope(parse_graphql(doc).flows[0])["query"].as_s
    q.should contain("{ __typename next { __typename next { __typename next { __typename } } } }")
  end

  it "aliases union member fields so incompatible response shapes never overlap" do
    doc = schema_doc
    types = gql_types(doc)
    types[8]["fields"].as_a << JSON.parse({name: "value", args: [] of String, type: {kind: "SCALAR", name: "String"}}.to_json)
    types[9]["fields"].as_a << JSON.parse({name: "value", args: [] of String, type: {kind: "SCALAR", name: "Int"}}.to_json)
    q = envelope(parse_graphql(doc).flows[1])["query"].as_s
    q.should contain("gori_0_value: value")
    q.should contain("gori_1_value: value")
  end

  it "keeps a valid operation when a wide output graph exhausts the node budget" do
    doc = schema_doc
    types = gql_types(doc)
    4.times do |depth|
      fields = (0...8).map do |i|
        {name: "f#{i}", args: [] of String, type: {kind: "OBJECT", name: "Wide#{depth + 1}"}}
      end
      types << JSON.parse({name: "Wide#{depth}", kind: "OBJECT", fields: fields}.to_json)
    end
    types << JSON.parse({name: "Wide4", kind: "OBJECT", fields: [] of String}.to_json)
    types[5]["fields"].as_a[0].as_h["type"] = JSON.parse(%({"kind":"OBJECT","name":"Wide0"}))
    result = parse_graphql(doc)
    result.skipped.should eq(0)
    q = envelope(result.flows[0])["query"].as_s
    q.count('{').should be <= Gori::Import::Graphql::MAX_NODES
    q.count('{').should eq(q.count('}'))
    q.should end_with("} }")
  end

  it "keeps the subscription count ahead of capped malformed-operation notes" do
    doc = schema_doc
    fields = gql_types(doc)[5]["fields"].as_a
    30.times { fields << JSON.parse(%({"name":"bad-name","args":[]})) }
    result = parse_graphql(doc)
    result.skipped.should eq(30)
    result.notes.first.should contain("skipped 1 subscription")
    result.notes.size.should be <= Gori::Import::Skips::CAP + 1
  end

  it "reports the subscription count even when there are no HTTP operations" do
    doc = schema_doc
    doc["data"]["__schema"].as_h["queryType"] = JSON::Any.new(nil)
    doc["data"]["__schema"].as_h["mutationType"] = JSON::Any.new(nil)
    expect_raises(Gori::Error, "skipped 1 subscription") { parse_graphql(doc) }
  end

  it "bounds document bytes and JSON nesting before generation" do
    file = File.tempfile("gori-graphql", ".json")
    begin
      file.print(" " * (Gori::Import::Graphql::MAX_BYTES + 1))
      file.close
      expect_raises(Gori::Error, "document exceeds") { Gori::Import::Graphql.parse_file(file.path, "https://a.test") }
      File.write(file.path, "[" * 65 + "0" + "]" * 65)
      expect_raises(Gori::Error, "not valid JSON") { Gori::Import::Graphql.parse_file(file.path, "https://a.test") }
      File.write(file.path, "{bad")
      expect_raises(Gori::Error, "not valid JSON") { Gori::Import::Graphql.parse_file(file.path, "https://a.test") }
    ensure
      file.delete
    end
  end
end
