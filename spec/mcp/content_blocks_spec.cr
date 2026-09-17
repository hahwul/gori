require "../spec_helper"
require "../support/mcp_harness"
require "file_utils"

# `content[]` on a tools/call response.
#
# MCP has always modelled it as an ARRAY, and gori has always written exactly one text block
# into it because every tool here answers in JSON. `screenshot` is the first tool with BYTES to
# hand back, and `Result#extra` is how they ride along. The contract this file holds is that
# adding that door changed NOTHING for the ~170 tools that do not use it: one block, type
# "text", the JSON payload — which is what every existing client parses.

private def with_project_db(&)
  root = File.tempname("gori-blocks")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).create("blockproj")
  store = Gori::Store.open(project.db_path)
  mcp_seed_flow(store, "blocks.test", "GET", "/a", 200)
  store.flush
  begin
    yield store, project
  ensure
    store.close
    FileUtils.rm_rf(root)
  end
end

private INIT = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"spec","version":"0"}}})

describe "MCP content blocks" do
  it "emits exactly one text block for a tool that carries no extras" do
    with_store do |store|
      mcp_seed_flow(store, "acme.test", "GET", "/a", 200)
      [%({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_info","arguments":{}}}),
       %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_history","arguments":{}}}),
       %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_scope","arguments":{}}}),
       # …and an ERROR result, which takes the other branch of the same method.
       %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_flow","arguments":{"id":999999}}})].each do |call|
        content = mcp_drive(store, INIT, call)[1]["result"]["content"].as_a
        content.size.should eq(1)
        content[0]["type"].as_s.should eq("text")
        content[0]["text"].as_s.should_not be_empty
        content[0]["data"]?.should be_nil
      end
    end
  end

  it "appends a text extra as a second block, with no mimeType" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-blocks-#{Random.rand(1_000_000)}.svg")
      begin
        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"cols":80,"rows":24,"inline":true,"path":#{dest.to_json}}}})
        resp = mcp_drive(store, INIT, call, db_path: project.db_path)[1]
        resp["result"]["isError"].as_bool.should be_false
        content = resp["result"]["content"].as_a
        content.size.should eq(2)
        # Block 0 stays the JSON summary every client already reads.
        content[0]["type"].as_s.should eq("text")
        JSON.parse(content[0]["text"].as_s)["path"].as_s.should eq(dest)
        # Block 1 is the document itself, as TEXT — no mime type is what makes it one.
        content[1]["type"].as_s.should eq("text")
        content[1]["text"].as_s.should start_with("<svg")
        content[1]["mimeType"]?.should be_nil
        content[1]["data"]?.should be_nil
      ensure
        File.delete?(dest)
      end
    end
  end

  it "carries binary back as an image block, or refuses rather than writing an empty one" do
    # Two arms on purpose. `Screenshot::Png` is a stub until the rasterizer package lands, and
    # a stub that answers zero bytes must NOT produce a 0-byte .png — so today this pins the
    # refusal. The moment real bytes arrive the other arm takes over and pins the image block,
    # with no edit here.
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-blocks-#{Random.rand(1_000_000)}.png")
      begin
        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"cols":60,"rows":20,"format":"png","inline":true,"path":#{dest.to_json}}}})
        resp = mcp_drive(store, INIT, call, db_path: project.db_path)[1]
        content = resp["result"]["content"].as_a
        if resp["result"]["isError"].as_bool
          content.size.should eq(1)
          content[0]["text"].as_s.should contain("no bytes")
          File.exists?(dest).should be_false
        else
          content.size.should eq(2)
          content[1]["type"].as_s.should eq("image")
          content[1]["mimeType"].as_s.should eq("image/png")
          content[1]["data"].as_s.should_not be_empty
          content[1]["text"]?.should be_nil
          Base64.decode(content[1]["data"].as_s).should eq(File.read(dest).to_slice)
        end
      ensure
        File.delete?(dest)
      end
    end
  end

  it "leaves structuredContent alone — the text block is still the object" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-blocks-#{Random.rand(1_000_000)}.txt")
      begin
        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{"cols":50,"rows":12,"format":"txt","inline":true,"path":#{dest.to_json}}}})
        result = mcp_drive(store, INIT, call, db_path: project.db_path)[1]["result"]
        # An extra block is a second DOCUMENT, not a second structured payload: the machine
        # answer stays the one JSON object block 0 carries.
        result["structuredContent"]["path"].as_s.should eq(dest)
        result["content"].as_a.size.should eq(2)
      ensure
        File.delete?(dest)
      end
    end
  end
end
