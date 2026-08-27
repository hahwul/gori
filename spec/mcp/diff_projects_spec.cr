require "../spec_helper"
require "file_utils"
require "json"

# MCP `diff_projects` — the retest diff over the tool surface. The comparison itself is
# covered in spec/diff_spec.cr; what is pinned here is the tool contract an agent reads:
# which project each side resolves to, that the verdict vocabulary survives into JSON, and
# that the coverage caveat travels with the counts (an agent that reads `removed` as
# "deleted" would report a thin retest as a wave of fixes).

# A fresh `$GORI_HOME`, so the registry the tool resolves through holds only this
# example's projects and not the suite-wide temp home.
private def with_diff_home(&)
  previous = ENV["GORI_HOME"]?
  home = File.tempname("gori-diffhome")
  Dir.mkdir_p(File.join(home, "projects"))
  ENV["GORI_HOME"] = home
  begin
    yield Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
  ensure
    previous ? (ENV["GORI_HOME"] = previous) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(home)
  end
end

private def seed_diff_project(registry : Gori::ProjectRegistry, name : String,
                              &block : Gori::Store ->) : Gori::Project
  project = registry.create(name)
  store = Gori::Store.open(project.db_path, background_index: false)
  begin
    block.call(store)
    store.flush
  ensure
    store.close
  end
  project
end

private def diff_seed_flow(store : Gori::Store, target : String, status : Int32, size : Int32) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  body = "x" * size
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, content_type: "application/json",
    head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice, body: body.to_slice,
    body_size: body.bytesize.to_i64))
  id
end

private def diff_call(args : String) : String
  %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"diff_projects","arguments":#{args}}})
end

# The server is constructed the way `gori mcp` constructs it — bound project NAMED and its
# db_path carried — because that identity is what `to`-less resolution and the
# same-project refusal are built on.
private def drive_diff_raw(project : Gori::Project, store, args : String) : JSON::Any
  input = IO::Memory.new(diff_call(args) + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: false, verify_upstream: false,
    project_name: project.name, db_path: project.db_path,
    input: input, output: output).run
  JSON.parse(output.to_s.each_line.reject(&.strip.empty?).first)
end

private def drive_diff(project : Gori::Project, store, args : String) : JSON::Any
  JSON.parse(drive_diff_raw(project, store, args)["result"]["content"][0]["text"].as_s)
end

# An `isError` result carries its message as TEXT, not as a JSON payload.
private def diff_error(project : Gori::Project, store, args : String) : String
  result = drive_diff_raw(project, store, args)["result"]
  result["isError"]?.try(&.as_bool).should be_true
  result["content"][0]["text"].as_s
end

describe "MCP diff_projects" do
  it "diffs the named baseline against the bound project" do
    with_diff_home do |registry|
      seed_diff_project(registry, "q1") do |s|
        diff_seed_flow(s, "/admin", 200, 900)
        diff_seed_flow(s, "/legacy", 200, 100)
      end
      newer = seed_diff_project(registry, "q3") do |s|
        diff_seed_flow(s, "/admin", 403, 120)
        diff_seed_flow(s, "/legacy", 404, 40)
        diff_seed_flow(s, "/v2", 200, 500)
      end
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        payload = drive_diff(newer, store, %({"from":"q1"}))
        payload["counts"]["changed"].as_i.should eq(1)
        payload["counts"]["gone"].as_i.should eq(1)
        payload["counts"]["added"].as_i.should eq(1)
        by_path = payload["endpoints"].as_a.to_h { |e| {e["path"].as_s, e["verdict"].as_s} }
        by_path["/admin"].should eq("changed")
        by_path["/legacy"].should eq("gone")
        by_path["/v2"].should eq("added")
      ensure
        store.close
      end
    end
  end

  it "carries the coverage caveat beside the counts, so 'removed' cannot be read as 'deleted'" do
    with_diff_home do |registry|
      seed_diff_project(registry, "q1") { |s| diff_seed_flow(s, "/unvisited", 200, 100) }
      newer = seed_diff_project(registry, "q3") { |s| diff_seed_flow(s, "/other", 200, 100) }
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        payload = drive_diff(newer, store, %({"from":"q1"}))
        payload["counts"]["removed"].as_i.should eq(1)
        payload["caveats"].as_a.first.as_s.should contain("coverage gap")
        payload["a"]["endpoints"].as_i.should eq(1)
        payload["b"]["endpoints"].as_i.should eq(1)
      ensure
        store.close
      end
    end
  end

  it "narrows the endpoint list by verdict while the counts stay complete" do
    with_diff_home do |registry|
      seed_diff_project(registry, "q1") { |s| diff_seed_flow(s, "/same", 200, 100) }
      newer = seed_diff_project(registry, "q3") do |s|
        diff_seed_flow(s, "/same", 200, 100)
        diff_seed_flow(s, "/new", 200, 100)
      end
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        payload = drive_diff(newer, store, %({"from":"q1","verdicts":["added"]}))
        payload["endpoints"].as_a.map(&.["path"].as_s).should eq(["/new"])
        payload["counts"]["unchanged"].as_i.should eq(1)
      ensure
        store.close
      end
    end
  end

  it "refuses an unknown project by name rather than diffing something else" do
    with_diff_home do |registry|
      newer = seed_diff_project(registry, "q3") { |s| diff_seed_flow(s, "/x", 200, 100) }
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        diff_error(newer, store, %({"from":"nope"})).should contain("no project matching 'nope'")
      ensure
        store.close
      end
    end
  end

  it "refuses to diff a project against itself" do
    with_diff_home do |registry|
      newer = seed_diff_project(registry, "q3") { |s| diff_seed_flow(s, "/x", 200, 100) }
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        diff_error(newer, store, %({"from":"q3"})).should contain("does not differ from itself")
      ensure
        store.close
      end
    end
  end

  it "answers a both-sides-named call with a query while UNBOUND" do
    # `diff_projects` is UNBOUND_SAFE, but the shared `ql_filter_or_error` reads the BOUND
    # project's scope lens — so a query on an unbound call used to raise out of `Tools#store`
    # and come back as an INTERNAL "gori is broken" for an ordinary, valid request.
    with_diff_home do |registry|
      seed_diff_project(registry, "q1") { |s| diff_seed_flow(s, "/x", 200, 100) }
      seed_diff_project(registry, "q3") { |s| diff_seed_flow(s, "/x", 200, 100) }
      input = IO::Memory.new(diff_call(%({"from":"q1","to":"q3","query":"host:acme.test"})) + "\n")
      output = IO::Memory.new
      Gori::MCP::Server.new(nil, allow_actions: false, verify_upstream: false,
        input: input, output: output).run
      result = JSON.parse(output.to_s.each_line.reject(&.strip.empty?).first)["result"]
      result["isError"]?.try(&.as_bool).should_not be_true
      payload = JSON.parse(result["content"][0]["text"].as_s)
      payload["counts"]["unchanged"].as_i.should eq(1)
    end
  end

  it "reports the issue retest without sending anything" do
    with_diff_home do |registry|
      seed_diff_project(registry, "q1") do |s|
        fid = diff_seed_flow(s, "/admin", 200, 900)
        s.insert_issue("Broken access control", Gori::Store::Severity::High, "acme.test", fid)
      end
      newer = seed_diff_project(registry, "q3") { |s| diff_seed_flow(s, "/admin", 403, 120) }
      store = Gori::Store.open(newer.db_path, background_index: false)
      begin
        issues = drive_diff(newer, store, %({"from":"q1"}))["issues"].as_a
        issues.size.should eq(1)
        issues.first["verdict"].as_s.should eq("changed")
        issues.first["path"].as_s.should eq("/admin")
      ensure
        store.close
      end
    end
  end
end
