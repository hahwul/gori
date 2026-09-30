require "../spec_helper"
require "../support/mcp_harness"
require "yaml"
require "file_utils"

# #1394: what a call costs an agent's context when it names no size. `get_flow` inlined up to
# 64 KB of every body by default, `list_sitemap` 200 rows, `export_openapi` its whole document,
# and every `limit` kept its default and maximum in description prose only.

private def body_flow(store, size : Int32) : Int64
  mcp_seed_flow(store, "ex.test", "GET", "/big", 200,
    resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n",
    resp_body: ("a" * size).to_slice, content_type: "text/plain")
end

private def eo_flow(store : Gori::Store, target : String) : Int64
  mcp_seed_flow(store, "api.test", "GET", target, 200,
    resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
    resp_body: %({"ok":true}).to_slice, content_type: "application/json")
end

describe "MCP default body size" do
  it "inlines a small body whole, with no pointer" do
    with_store do |store|
      id = body_flow(store, 100)
      body = mcp_ok_json(tools_for(store), "get_flow", %({"id":#{id}}))["response_body"]
      body["text"].as_s.size.should eq(100)
      body.as_h.has_key?("more").should be_false
    end
  end

  it "cuts a large body at AUTO_BODY_BYTES and names the chunk call that pages the rest" do
    with_store do |store|
      id = body_flow(store, 20_000)
      body = mcp_ok_json(tools_for(store), "get_flow", %({"id":#{id}}))["response_body"]
      body["text"].as_s.size.should eq(Gori::MCP::Tools::AUTO_BODY_BYTES)
      body["truncated"].as_bool.should be_true
      body["more"].as_s.should contain("get_response_body_chunk{flow_id: #{id}}")
    end
  end

  it "keeps body_mode:full and an explicit max_body_bytes as they were" do
    with_store do |store|
      id = body_flow(store, 20_000)
      tools = tools_for(store)
      full = mcp_ok_json(tools, "get_flow", %({"id":#{id},"body_mode":"full"}))["response_body"]
      full["text"].as_s.size.should eq(20_000)
      full.as_h.has_key?("more").should be_false
      capped = mcp_ok_json(tools, "get_flow", %({"id":#{id},"max_body_bytes":15000}))["response_body"]
      capped["text"].as_s.size.should eq(15_000)
      capped.as_h.has_key?("more").should be_false
    end
  end
end

# `limit` whose numbers depend on the call's mode: result rows, cluster listings, and (for a
# saved run) rows carrying their content each clamp differently.
private MODE_DEPENDENT_LIMITS = %w[fuzz_results get_fuzz_run]

describe "MCP limit schemas" do
  it "gives every `limit` a machine-readable default and range" do
    with_store do |store|
      JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a.each do |tool|
        next unless limit = tool.dig?("inputSchema", "properties", "limit")
        name = tool["name"].as_s
        if MODE_DEPENDENT_LIMITS.includes?(name)
          # One default/maximum pair would be wrong for some mode, so these say it in prose.
          limit.as_h.has_key?("default").should be_false, name
          limit.as_h.has_key?("maximum").should be_false, name
          limit["description"].as_s.should contain("cluster listing"), name
          next
        end
        limit["type"].as_s.should eq("integer"), name
        limit["minimum"].as_i.should eq(1), name
        (limit["default"].as_i <= limit["maximum"].as_i).should be_true, name
        limit["description"].as_s.should_not match(/default \d/), "#{name}: the default belongs in the schema keyword, not the prose"
      end
    end
  end

  it "pages list_sitemap and list_params at 50 rows by default" do
    with_store do |store|
      60.times { |i| eo_flow(store, "/p#{i}?q=#{i}") }
      tools = tools_for(store)
      sitemap = mcp_ok_json(tools, "list_sitemap", %({"fold_query":false}))
      sitemap["returned"].as_i.should eq(50)
      sitemap["has_more"].as_bool.should be_true
      mcp_ok_json(tools, "list_params", "{}")["limit"].as_i.should eq(50)
    end
  end
end

describe "MCP export_openapi output_path" do
  it "writes the document to the file and leaves it out of the reply" do
    with_store do |store|
      eo_flow(store, "/users/1")
      dir = File.tempname("gori-oas")
      Dir.mkdir(dir)
      path = File.join(dir, "api.yaml")
      begin
        out = mcp_ok_json(tools_for(store), "export_openapi", {output_path: path}.to_json)
        out.as_h.has_key?("document").should be_false
        out["output_path"].as_s.should eq(path)
        out["format"].as_s.should eq("yaml") # picked by the extension
        written = File.read(path)
        out["bytes_written"].as_i.should eq(written.bytesize)
        YAML.parse(written)["openapi"].as_s.should eq("3.0.3")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "refuses an existing file without overwrite, and replaces it with overwrite:true" do
    with_store do |store|
      eo_flow(store, "/users/1")
      path = File.tempname("gori-oas", ".json")
      File.write(path, "keep me")
      begin
        tools = tools_for(store)
        r = tools.call("export_openapi", JSON.parse({output_path: path}.to_json))
        r.is_error.should be_true
        r.field.should eq("output_path")
        File.read(path).should eq("keep me")
        mcp_ok_json(tools, "export_openapi", {output_path: path, overwrite: true}.to_json)
        JSON.parse(File.read(path))["openapi"].as_s.should eq("3.0.3")
      ensure
        File.delete?(path)
      end
    end
  end

  it "reads a blank output_path as absent, the way a property-filling client means it" do
    with_store do |store|
      eo_flow(store, "/users/1")
      denied = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
        denied_permissions: Set{"write"})
      out = mcp_ok_json(denied, "export_openapi", %({"output_path":""}))
      out["document"]["openapi"].as_s.should eq("3.0.3")
      store.events_after(0_i64, 50).none? { |e| e.kind == "agent_action" }.should be_true
    end
  end

  it "refuses a dangling symlink and a database a gori has open" do
    with_store do |store|
      eo_flow(store, "/users/1")
      tools = tools_for(store)
      dir = File.tempname("gori-oas")
      Dir.mkdir(dir)
      begin
        link = File.join(dir, "out.json")
        File.symlink(File.join(Gori::Paths.home_dir, "nowhere.json"), link)
        r = tools.call("export_openapi", JSON.parse({output_path: link, overwrite: true}.to_json))
        r.is_error.should be_true
        r.text.should contain("symlink to nothing")

        db = File.join(dir, "loose.db")
        other = Gori::Store.open(db)
        begin
          r = tools.call("export_openapi", JSON.parse({output_path: db, overwrite: true}.to_json))
          r.is_error.should be_true
          r.text.should contain("open in a running gori")
          File.exists?(db).should be_true
        ensure
          other.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "refuses a path inside gori's home, and any output_path under --read-only" do
    with_store do |store|
      eo_flow(store, "/users/1")
      inside = File.join(Gori::Paths.home_dir, "oas.json")
      r = tools_for(store).call("export_openapi", JSON.parse({output_path: inside}.to_json))
      r.is_error.should be_true
      r.text.should contain("gori's home")
      File.exists?(inside).should be_false

      ro = tools_for(store, allow_actions: false).call("export_openapi",
        JSON.parse({output_path: File.tempname("gori-oas", ".json")}.to_json))
      ro.error_code.should eq("TOOL_DISABLED")
      # The inline document stays served read-only.
      tools_for(store, allow_actions: false).call("export_openapi", JSON.parse("{}")).is_error.should be_false
    end
  end

  it "sits behind the write permission for that call only, and is logged as an agent action" do
    with_store do |store|
      eo_flow(store, "/users/1")
      denied = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
        denied_permissions: Set{"write"})
      denied.call("export_openapi", JSON.parse("{}")).is_error.should be_false
      r = denied.call("export_openapi", JSON.parse({output_path: File.tempname("gori-oas", ".json")}.to_json))
      r.error_code.should eq("TOOL_DISABLED")

      path = File.tempname("gori-oas", ".json")
      begin
        mcp_ok_json(tools_for(store), "export_openapi", {output_path: path}.to_json)
        store.events_after(0_i64, 50).count { |e| e.kind == "agent_action" && e.payload == "export_openapi" }.should eq(1)
      ensure
        File.delete?(path)
      end
    end
  end
end
