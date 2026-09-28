require "../spec_helper"
require "json"

private alias S = Gori::Graphql::Schema
private alias Ops = Gori::Graphql::Operations

private def ref(name : String, kind : S::Kind = S::Kind::Scalar) : S::TypeRef
  S::TypeRef.new(kind, name, nil)
end

private def nn(inner : S::TypeRef) : S::TypeRef
  S::TypeRef.new(S::Kind::NonNull, nil, inner)
end

private def lst(inner : S::TypeRef) : S::TypeRef
  S::TypeRef.new(S::Kind::List, nil, inner)
end

private def arg(name : String, type : S::TypeRef, default : String? = nil) : S::InputValue
  S::InputValue.new(name, type, default)
end

private def fld(name : String, type : S::TypeRef, args = [] of S::InputValue) : S::Field
  S::Field.new(name, args, type)
end

private def type(kind : S::Kind, name : String, fields = [] of S::Field, *,
                 inputs = [] of S::InputValue, values = [] of String, members = [] of String) : S::Type
  S::Type.new(kind, name, fields, inputs, values, members)
end

private def scalars : Array(S::Type)
  %w[String Int Float Boolean ID DateTime].map { |n| type(S::Kind::Scalar, n) }
end

private def schema_of(types : Array(S::Type), query = "Query", mutation : String? = nil,
                      subscription : String? = nil) : S
  S.new((scalars + types).to_h { |t| {t.name, t} }, query, mutation, subscription)
end

# The shop the examples below query: users with a role, organisations, a search union and a
# node interface, plus a mutation whose input nests a required input object.
private def shop : S
  user = type(S::Kind::Object, "User", [
    fld("id", nn(ref("ID"))),
    fld("name", ref("String")),
    fld("role", ref("Role", S::Kind::Enum)),
    fld("org", ref("Org", S::Kind::Object)),
    fld("friends", lst(ref("User", S::Kind::Object)), [arg("first", nn(ref("Int")))]),
    fld("__secret", ref("String")),
  ])
  org = type(S::Kind::Object, "Org", [fld("name", ref("String"))])
  node = type(S::Kind::Interface, "Node", [fld("id", nn(ref("ID")))], members: ["User", "Org"])
  hit = type(S::Kind::Union, "Hit", members: ["User", "Org"])
  role = type(S::Kind::Enum, "Role", values: ["ADMIN", "USER"])
  filter = type(S::Kind::InputObject, "UserFilter", inputs: [arg("q", ref("String"))])
  inner = type(S::Kind::InputObject, "Inner", inputs: [arg("flag", nn(ref("Boolean"))), arg("ratio", ref("Float"))])
  create = type(S::Kind::InputObject, "CreateUserInput", inputs: [
    arg("name", nn(ref("String"))),
    arg("role", nn(ref("Role", S::Kind::Enum))),
    arg("tags", nn(lst(nn(ref("String"))))),
    arg("age", nn(ref("Int")), "18"),
    arg("note", ref("String")),
    arg("inner", nn(ref("Inner", S::Kind::InputObject))),
    arg("at", nn(ref("DateTime"))),
  ])
  query = type(S::Kind::Object, "Query", [
    fld("user", ref("User", S::Kind::Object), [arg("id", nn(ref("ID"))), arg("filter", ref("UserFilter", S::Kind::InputObject))]),
    fld("search", lst(ref("Hit", S::Kind::Union)), [arg("term", nn(ref("String")))]),
    fld("node", ref("Node", S::Kind::Interface), [arg("id", nn(ref("ID")))]),
    fld("version", ref("String")),
    fld("__schema", ref("String")),
  ])
  mutation = type(S::Kind::Object, "Mutation", [
    fld("createUser", ref("User", S::Kind::Object), [arg("input", nn(ref("CreateUserInput", S::Kind::InputObject)))]),
  ])
  subscription = type(S::Kind::Object, "Subscription", [fld("onEvent", ref("String")), fld("onUser", ref("String"))])
  schema_of([user, org, node, hit, role, filter, inner, create, query, mutation, subscription],
    "Query", "Mutation", "Subscription")
end

private def op(generated : Ops::Generated, kind : String, field : String) : Ops::Operation
  generated.operations.find { |o| o.kind == kind && o.field == field }.not_nil!
end

describe Gori::Graphql::Operations do
  it "writes one operation per root query and mutation field, skipping introspection fields" do
    g = Ops.generate(shop)
    g.operations.map { |o| {o.kind, o.field} }.should eq([
      {"query", "user"}, {"query", "search"}, {"query", "node"}, {"query", "version"},
      {"mutation", "createUser"},
    ])
  end

  it "only notes the subscriptions" do
    g = Ops.generate(shop)
    g.operations.none? { |o| o.kind == "subscription" }.should be_true
    g.notes.should eq(["2 subscription fields not generated — subscriptions run over a WebSocket"])
  end

  it "declares every argument but gives a value only to the required ones" do
    user = op(Ops.generate(shop), "query", "user")
    user.document.should start_with("query user($id: ID!, $filter: UserFilter) {\n  user(id: $id, filter: $filter) {\n")
    JSON.parse(user.variables.not_nil!).should eq(JSON.parse(%({"id":""})))
    op(Ops.generate(shop), "query", "version").variables.should be_nil
  end

  it "selects object fields, skipping the ones that need an argument and the __ ones" do
    doc = op(Ops.generate(shop), "query", "user").document
    doc.should eq(<<-GRAPHQL)
      query user($id: ID!, $filter: UserFilter) {
        user(id: $id, filter: $filter) {
          id
          name
          role
          org {
            name
          }
        }
      }
      GRAPHQL
  end

  it "selects a union through __typename and an inline fragment per member" do
    doc = op(Ops.generate(shop), "query", "search").document
    doc.should contain("    __typename\n    ... on User {\n      id\n")
    doc.should contain("    ... on Org {\n      name\n    }")
  end

  it "selects an interface's own fields" do
    doc = op(Ops.generate(shop), "query", "node").document
    doc.should eq("query node($id: ID!) {\n  node(id: $id) {\n    id\n  }\n}")
  end

  it "writes a leaf root field without a selection set" do
    op(Ops.generate(shop), "query", "version").document.should eq("query version {\n  version\n}")
  end

  it "fills a required input object with placeholders of the right shape" do
    create = op(Ops.generate(shop), "mutation", "createUser")
    create.document.should start_with("mutation createUser($input: CreateUserInput!) {\n  createUser(input: $input) {\n")
    JSON.parse(create.variables.not_nil!).should eq(JSON.parse(
      %({"input":{"name":"","role":"ADMIN","tags":[""],"inner":{"flag":false},"at":""}})))
  end

  it "writes the document shallower when the full depth is past the size budget" do
    leafy = type(S::Kind::Object, "Leafy", (0...60).map { |i| fld("scalar_field_number_#{i}", ref("String")) })
    mid = type(S::Kind::Object, "Mid", (0...10).map { |i| fld("leafy#{i}", ref("Leafy", S::Kind::Object)) })
    big = type(S::Kind::Object, "Big", (0...10).map { |i| fld("mid#{i}", ref("Mid", S::Kind::Object)) } +
                                       [fld("title", ref("String"))])
    query = type(S::Kind::Object, "Query", [fld("big", ref("Big", S::Kind::Object))])
    doc = op(Ops.generate(schema_of([leafy, mid, big, query])), "query", "big").document
    doc.bytesize.should be <= Ops::MAX_DOCUMENT
    doc.should_not contain("scalar_field_number_") # the level that blew the budget is gone…
    doc.should contain("    mid0 {\n")             # …and the levels above it stay
    doc.should contain("    title")
  end

  it "notes a root type the schema names but does not describe" do
    g = Ops.generate(schema_of([] of S::Type, "Query", "Mutation"))
    g.operations.should be_empty
    g.notes.should eq([
      "the schema names Query as its query type but does not describe it",
      "the schema names Mutation as its mutation type but does not describe it",
    ])
  end
end
