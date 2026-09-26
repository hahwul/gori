require "../spec_helper"
require "../support/demo_descriptor"
require "base64"

private alias Schemas = Gori::Protobuf::Schemas
private alias Reflection = Gori::Protobuf::Reflection

private def demo_file_descriptor : Bytes
  set = Gori::Protobuf.decode(Base64.decode(DEMO_DESC_B64))
  set.fields.find { |f| f.number == 1 }.not_nil!.bytes.not_nil!
end

private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

describe "MCP gRPC tools with unpersisted reflections" do
  it "lists in-memory unpersisted reflections in grpc_schema and forgets them via grpc_forget" do
    path = File.tempname("gori-mcp-grpc-unpersisted", ".db")
    store = Gori::Store.open(path, busy_timeout_ms: 200)
    peer = DB.open("sqlite3:#{path}?busy_timeout=100")
    cn = peer.checkout
    begin
      Schemas.load_project(store)
      tools = tools_for(store)

      # Simulate a busy store when adopting reflection
      cn.exec("BEGIN IMMEDIATE")
      set = Reflection.descriptor_set([demo_file_descriptor])
      saved = Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set)
      saved.should be_false

      # Schemas in memory has the reflection
      Schemas.reflections.size.should eq(1)
      store.grpc_reflections.should be_empty

      # 1. grpc_schema should list the in-memory reflection, matching status
      schema_res = call_json(tools, "grpc_schema", "{}")
      schema_res["status"].as_s.should contain("https://api.test:443")
      reflections = schema_res["reflections"].as_a
      reflections.size.should eq(1)
      reflections[0]["target"].as_s.should eq("https://api.test:443")

      # 2. grpc_forget should accept and drop the in-memory reflection
      forget_res = call_json(tools, "grpc_forget", %({"target": "https://api.test:443"}))
      forget_res["forgotten"].as_i.should eq(1)

      # Verify it is dropped from in-memory schema
      Schemas.reflections.should be_empty
      Schemas.status.should eq("no descriptor set loaded")

      # grpc_schema now reports empty reflections
      schema_res2 = call_json(tools, "grpc_schema", "{}")
      schema_res2["reflections"].as_a.should be_empty
    ensure
      cn.exec("ROLLBACK") rescue nil
      cn.release rescue nil
      peer.close rescue nil
      Schemas.clear
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "forgets all in-memory reflections via grpc_forget with all:true" do
    path = File.tempname("gori-mcp-grpc-all", ".db")
    store = Gori::Store.open(path, busy_timeout_ms: 200)
    peer = DB.open("sqlite3:#{path}?busy_timeout=100")
    cn = peer.checkout
    begin
      Schemas.load_project(store)
      tools = tools_for(store)

      cn.exec("BEGIN IMMEDIATE")
      set = Reflection.descriptor_set([demo_file_descriptor])
      Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set).should be_false

      forget_res = call_json(tools, "grpc_forget", %({"all": true}))
      forget_res["forgotten"].as_i.should eq(1)
      Schemas.reflections.should be_empty
      Schemas.status.should eq("no descriptor set loaded")
    ensure
      cn.exec("ROLLBACK") rescue nil
      cn.release rescue nil
      peer.close rescue nil
      Schemas.clear
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
