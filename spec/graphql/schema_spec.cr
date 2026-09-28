require "../spec_helper"
require "json"

private alias Schema = Gori::Graphql::Schema

private def named(kind : String, name : String)
  {"kind" => kind, "name" => name, "ofType" => nil}
end

private def non_null(of)
  {"kind" => "NON_NULL", "name" => nil, "ofType" => of}
end

private def list_of(of)
  {"kind" => "LIST", "name" => nil, "ofType" => of}
end

private def result_json(types, query = "Query", mutation = nil, envelope = true) : String
  schema = {
    "queryType"        => query ? {"name" => query} : nil,
    "mutationType"     => mutation ? {"name" => mutation} : nil,
    "subscriptionType" => nil,
    "types"            => types,
  }
  envelope ? {"data" => {"__schema" => schema}}.to_json : {"__schema" => schema}.to_json
end

private def query_type(fields)
  {"kind" => "OBJECT", "name" => "Query", "fields" => fields}
end

describe Gori::Graphql::Schema do
  it "reads a response body and a bare __schema alike" do
    types = [query_type([{"name" => "me", "args" => [] of String, "type" => named("SCALAR", "String")}])]
    [result_json(types), result_json(types, envelope: false)].each do |text|
      schema = Schema.parse(text)
      schema.query_type.should eq("Query")
      schema.mutation_type.should be_nil
      schema.types["Query"].fields.map(&.name).should eq(["me"])
    end
  end

  it "answers a GraphQL error response with the server's message" do
    text = {"errors" => [{"message" => "GraphQL introspection is not allowed"}], "data" => nil}.to_json
    expect_raises(Gori::Error, /error instead of a schema: GraphQL introspection is not allowed/) do
      Schema.parse(text)
    end
  end

  it "says what is wrong with a body that is not an introspection result" do
    expect_raises(Gori::Error, /not JSON/) { Schema.parse("<html>") }
    expect_raises(Gori::Error, /not a JSON object/) { Schema.parse("[1]") }
    expect_raises(Gori::Error, /no __schema/) { Schema.parse(%({"data":{}})) }
    expect_raises(Gori::Error, /no types/) { Schema.parse(result_json([] of String)) }
  end

  it "drops names outside the GraphQL grammar with whatever carries them" do
    types = [
      query_type([
        {"name" => "ok", "args" => [] of String, "type" => named("SCALAR", "String")},
        {"name" => "a) { evil }", "args" => [] of String, "type" => named("SCALAR", "String")},
        {"name" => "badtype", "args" => [] of String, "type" => named("OBJECT", "Bad Type")},
        # an unparseable REQUIRED argument takes the field with it…
        {"name" => "needs", "args" => [{"name" => "x y", "type" => non_null(named("SCALAR", "ID"))}],
         "type" => named("SCALAR", "String")},
        # …an unparseable optional one is only dropped, and a defaulted non-null one is optional
        {"name" => "opt", "args" => [{"name" => "x y", "type" => named("SCALAR", "ID")}],
         "type" => named("SCALAR", "String")},
        {"name" => "defaulted", "args" => [{"name" => "x y", "type" => non_null(named("SCALAR", "Int")), "defaultValue" => "5"}],
         "type" => named("SCALAR", "String")},
      ]),
      {"kind" => "ENUM", "name" => "Role", "enumValues" => [{"name" => "ADMIN"}, {"name" => "no-pe"}]},
      {"kind" => "UNION", "name" => "Hit", "possibleTypes" => [{"name" => "User"}, {"name" => "1x"}]},
      {"kind" => "OBJECT", "name" => "not valid", "fields" => [] of String},
    ]
    schema = Schema.parse(result_json(types, query: "Query", mutation: "bad name"))
    schema.types["Query"].fields.map(&.name).should eq(["ok", "opt", "defaulted"])
    schema.types["Query"].fields.last.args.should be_empty
    schema.types["Role"].enum_values.should eq(["ADMIN"])
    schema.types["Hit"].possible_types.should eq(["User"])
    schema.types.has_key?("not valid").should be_false
    schema.mutation_type.should be_nil
  end

  it "spells wrapped type references and knows which arguments are required" do
    types = [query_type([{
      "name" => "users",
      "args" => [
        {"name" => "ids", "type" => non_null(list_of(non_null(named("SCALAR", "ID")))), "defaultValue" => nil},
        {"name" => "first", "type" => non_null(named("SCALAR", "Int")), "defaultValue" => "10"},
        {"name" => "filter", "type" => named("INPUT_OBJECT", "UserFilter"), "defaultValue" => nil},
      ],
      "type" => list_of(named("OBJECT", "User")),
    }])]
    field = Schema.parse(result_json(types)).types["Query"].fields.first
    field.args.map(&.type.to_s).should eq(["[ID!]!", "Int!", "UserFilter"])
    field.args.map(&.required?).should eq([true, false, false]) # a default makes it optional
    field.type.to_s.should eq("[User]")
    field.type.named.should eq("User")
  end

  it "refuses a NON_NULL wrapping a NON_NULL" do
    types = [query_type([
      {"name" => "bad", "args" => [] of String, "type" => non_null(non_null(named("SCALAR", "ID")))},
      {"name" => "good", "args" => [] of String, "type" => non_null(named("SCALAR", "ID"))},
    ])]
    Schema.parse(result_json(types)).types["Query"].fields.map(&.name).should eq(["good"])
  end
end
