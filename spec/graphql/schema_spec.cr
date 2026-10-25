require "../spec_helper"
require "compress/gzip"
require "../../src/gori/graphql/schema"

private alias Schema = Gori::Graphql::Schema

private def named(kind : String, name : String)
  {"kind" => kind, "name" => name, "ofType" => nil}
end

private def non_null(inner)
  {"kind" => "NON_NULL", "name" => nil, "ofType" => inner}
end

private def list(inner)
  {"kind" => "LIST", "name" => nil, "ofType" => inner}
end

private def field(name : String, type, args = [] of Hash(String, JSON::Any), deprecated = false)
  {"name" => name, "args" => args, "type" => type, "isDeprecated" => deprecated}
end

private def arg(name : String, type, default : String? = nil)
  {"name" => name, "type" => type, "defaultValue" => default}
end

# A small schema in the shape graphql-js answers `IntrospectionQuery` with.
private def demo_result : String
  {"data" => {"__schema" => {
    "queryType"        => {"name" => "Query"},
    "mutationType"     => {"name" => "Mutation"},
    "subscriptionType" => nil,
    "types"            => [
      {"kind" => "OBJECT", "name" => "Query", "interfaces" => [] of String, "fields" => [
        field("user", named("OBJECT", "User"), [arg("id", non_null(named("SCALAR", "ID")))]),
        field("users", non_null(list(non_null(named("OBJECT", "User")))),
          [arg("first", named("SCALAR", "Int"), "10"), arg("role", named("ENUM", "Role"))]),
        field("legacyUser", named("OBJECT", "User"), deprecated: true),
      ]},
      {"kind" => "OBJECT", "name" => "Mutation", "interfaces" => [] of String, "fields" => [
        field("createUser", named("OBJECT", "User"), [arg("input", non_null(named("INPUT_OBJECT", "UserInput")))]),
      ]},
      {"kind" => "OBJECT", "name" => "User", "interfaces" => [named("INTERFACE", "Node")], "fields" => [
        field("id", non_null(named("SCALAR", "ID"))),
        field("email", named("SCALAR", "String")),
        field("role", named("ENUM", "Role")),
        field("result", named("UNION", "SearchResult")),
      ]},
      {"kind" => "INTERFACE", "name" => "Node", "fields" => [field("id", non_null(named("SCALAR", "ID")))],
       "possibleTypes" => [named("OBJECT", "User")]},
      {"kind" => "ENUM", "name" => "Role", "enumValues" => [{"name" => "ADMIN"}, {"name" => "USER"}]},
      {"kind" => "UNION", "name" => "SearchResult", "possibleTypes" => [named("OBJECT", "User")]},
      {"kind" => "INPUT_OBJECT", "name" => "UserInput", "inputFields" => [
        arg("email", non_null(named("SCALAR", "String"))), arg("when", named("SCALAR", "DateTime")),
      ]},
      {"kind" => "SCALAR", "name" => "DateTime"},
      {"kind" => "SCALAR", "name" => "String"},
      {"kind" => "SCALAR", "name" => "ID"},
      {"kind" => "OBJECT", "name" => "__Schema", "fields" => [] of String},
      {"kind" => "OBJECT", "name" => "Orphan", "fields" => [field("x", named("SCALAR", "Int"))]},
    ],
  }}}.to_json
end

private def demo_schema : JSON::Any
  Schema.parse(nil, demo_result.to_slice).as(JSON::Any)
end

describe Gori::Graphql::Schema do
  describe ".parse" do
    it "returns __schema from an introspection result" do
      demo_schema["queryType"]["name"].as_s.should eq("Query")
    end

    it "reads a gzip-encoded response" do
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io) { |gz| gz << demo_result }
      head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n".to_slice
      Schema.parse(head, io.to_slice).should be_a(JSON::Any)
    end

    it "says what the server said when introspection is off" do
      body = %({"errors":[{"message":"GraphQL introspection is not allowed"}]})
      Schema.parse(nil, body.to_slice).should eq("the server answered with an error: GraphQL introspection is not allowed")
    end

    it "refuses non-JSON, a batched array and a missing body without raising" do
      Schema.parse(nil, "<html>".to_slice).should eq("the response is not JSON")
      Schema.parse(nil, %([{"data":{}}]).to_slice).should eq("the response has no data.__schema")
      Schema.parse(nil, %({"data":"x","errors":"y"}).to_slice).should eq("the response has no data.__schema")
      Schema.parse(nil, nil).should eq("the response has no body")
    end
  end

  describe ".summarize" do
    it "renders roots first, then the reachable types, without builtins or orphans" do
      s = Schema.summarize(demo_schema)
      s.sdl.should eq(<<-SDL)
        type Query {
          user(id: ID!): User
          users(first: Int = 10, role: Role): [User!]!
          legacyUser: User @deprecated
        }
        type Mutation {
          createUser(input: UserInput!): User
        }
        type User implements Node {
          id: ID!
          email: String
          role: Role
          result: SearchResult
        }
        enum Role { ADMIN USER }
        input UserInput {
          email: String!
          when: DateTime
        }
        union SearchResult = User
        interface Node {
          id: ID!
        }
        scalar DateTime
        SDL
      s.query_type.should eq("Query")
      s.mutation_type.should eq("Mutation")
      s.subscription_type.should be_nil
      s.types_total.should eq(9) # String, ID and __Schema are builtins; Orphan counts but is unreachable
      s.types_shown.should eq(8)
      s.truncated.should be_false
    end

    it "filters root fields and types by name" do
      s = Schema.summarize(demo_schema, "USER")
      s.sdl.should contain("  user(id: ID!): User")
      s.sdl.should contain("  legacyUser: User @deprecated")
      s.sdl.should contain("type Mutation {\n  createUser(")
      s.sdl.should contain("input UserInput {")
      s.sdl.should_not contain("enum Role")
      s.sdl.should_not contain("scalar DateTime")

      s = Schema.summarize(demo_schema, "email")
      s.sdl.should_not contain("type Query") # no root field matches
      s.sdl.should contain("type User implements Node {")
    end

    it "cuts by line at max_bytes and says so" do
      s = Schema.summarize(demo_schema, nil, 40)
      s.sdl.should eq("type Query {\n  user(id: ID!): User")
      s.truncated.should be_true
      s.types_shown.should eq(1) # only Query's opening survived the cut
    end

    it "keeps a root whole when the filter names the root itself" do
      s = Schema.summarize(demo_schema, "mutation")
      s.sdl.should eq("type Mutation {\n  createUser(input: UserInput!): User\n}")
      s.types_shown.should eq(1)
    end

    it "skips malformed entries instead of raising" do
      schema = JSON.parse(%({"queryType":{"name":"Q"},"types":[1,{"kind":"OBJECT","name":"Q","fields":["x",{"name":"ok","type":{"kind":"LIST","ofType":"bad"}}]}]}))
      Schema.summarize(schema).sdl.should eq("type Q {\n  ok: [?]\n}")
    end

    # The demo project's `types { name kind }` introspection: `type Query {` + `}` alone.
    it "notes a root the introspection lists with no fields" do
      schema = JSON.parse(%({"queryType":{"name":"Query"},"types":[{"name":"Query","kind":"OBJECT"}]}))
      s = Schema.summarize(schema)
      s.sdl.should eq("type Query {\n}")
      s.note.not_nil!.should contain("carried no fields for root type Query")
      Schema.summarize(demo_schema).note.should be_nil
    end
  end

  describe ".rejected?" do
    it "is true only for a server's error answer, the one legacy can change" do
      Schema.rejected?(Schema.parse(nil, %({"errors":[{"message":"no"}]}).to_slice).as(String)).should be_true
      Schema.rejected?(Schema.parse(nil, "<html>".to_slice).as(String)).should be_false
    end
  end

  describe ".plan_options" do
    it "refuses a WebSocket handshake flow instead of posting its Upgrade headers" do
      with_store do |store|
        head = "GET /graphql HTTP/1.1\r\nHost: api.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" \
               "Sec-WebSocket-Protocol: graphql-transport-ws\r\n\r\n"
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
          method: "GET", target: "/graphql", http_version: "HTTP/1.1",
          head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        expect_raises(Gori::Error, /WebSocket handshake/) { Schema.plan_options(store.get_flow(id).not_nil!) }
      end
    end

    it "rewrites the captured request into the introspection POST, keeping its headers" do
      with_store do |store|
        head = "GET /graphql?query=%7Bme%7D&key=1 HTTP/1.1\r\nHost: api.test\r\nAuthorization: Bearer t\r\n\r\n"
        id = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
          method: "GET", target: "/graphql?query=%7Bme%7D&key=1", http_version: "HTTP/1.1",
          head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
        opts = Schema.plan_options(store.get_flow(id).not_nil!)
        text = String.new(opts.requests.first)
        text.should start_with("POST /graphql?key=1 HTTP/1.1\r\nHost: api.test\r\nAuthorization: Bearer t\r\n")
        text.should contain(%("operationName":"IntrospectionQuery"))
        opts.default_target.should eq("https://api.test")
        opts.expand_request?.should be_false
        opts.auto_content_length?.should be_false
      end
    end
  end
end
