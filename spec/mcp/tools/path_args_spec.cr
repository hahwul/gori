require "../../spec_helper"

# `path_str` (src/gori/mcp/tools.cr) read a file-path argument through `str`, which coerces a
# JSON scalar to text: export_openapi {"output_path": true} wrote the document to a file named
# `true` in the server's cwd and reported success. A path is a string or it is refused. The cwd
# is a fresh tempdir, so an unfixed build writes there and nowhere else.
private def in_temp_cwd(&)
  cwd = File.tempname("gori-path-args")
  Dir.mkdir_p(cwd)
  begin
    Dir.cd(cwd) { yield cwd }
  ensure
    FileUtils.rm_rf(cwd)
  end
end

describe "MCP file-path arguments" do
  ["true", "false", "1.5", "-1", "1e308"].each do |scalar|
    it "export_openapi refuses output_path #{scalar} and writes nothing" do
      in_temp_cwd do |cwd|
        with_store do |store|
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
            method: "GET", target: "/x", http_version: "HTTP/1.1",
            head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
          store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
            head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
          r = tools_for(store).call("export_openapi", JSON.parse(%({"output_path":#{scalar}})))
          r.is_error.should be_true
          r.error_code.should eq("INVALID_ARGUMENT")
          r.field.should eq("output_path")
          Dir.children(cwd).should be_empty
        end
      end
    end
  end

  it "import_project and import_flows refuse a non-string path by name" do
    with_store do |store|
      t = tools_for(store)
      {"import_project" => %({"path":1}), "import_flows" => %({"path":true,"kind":"har"})}.each do |tool, args|
        r = t.call(tool, JSON.parse(args))
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.field.should eq("path")
      end
    end
  end

  it "still takes a string output_path" do
    with_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
        method: "GET", target: "/x", http_version: "HTTP/1.1",
        head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
        head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      dir = File.tempname("gori-path-args-out")
      Dir.mkdir_p(dir)
      begin
        dest = File.join(dir, "api.json")
        r = tools_for(store).call("export_openapi", JSON.parse({output_path: dest}.to_json))
        r.is_error.should be_false
        File.exists?(dest).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
