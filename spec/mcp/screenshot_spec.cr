require "../spec_helper"
require "../support/mcp_harness"
require "file_utils"

# The MCP `screenshot` tool: draw the real TUI over the bound project, write a file, and
# optionally hand the picture back in the result.
#
# Three things worth pinning, in the order they can go wrong. It needs a project FILE, not just
# a store handle, and says so rather than crashing on a nil path. It refuses BEFORE it writes —
# an existing file, a directory, a parent that is not there. And it leaves the process exactly
# as it found it: `gori mcp` binds `Env.layer` once at construction, so a render that left the
# session's layer behind would silently unbind every `$BIND.NAME` the agent had extracted.

private def with_project_db(&)
  root = File.tempname("gori-mcp-shot")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).create("shotmcp")
  store = Gori::Store.open(project.db_path)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "shotmcp.test", port: 443,
    method: "GET", target: "/widgets/1", http_version: "HTTP/1.1",
    head: "GET /widgets/1 HTTP/1.1\r\nHost: shotmcp.test\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<html>ok</html>".to_slice, content_type: "text/html"))
  store.flush
  begin
    yield store, project
  ensure
    store.close
    FileUtils.rm_rf(root)
  end
end

private def shot_tools(store, db_path : String) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
    project_name: "shotmcp", db_path: db_path)
end

private def shot_call(store, db_path : String, args : String) : Gori::MCP::Tools::Result
  shot_tools(store, db_path).call("screenshot", JSON.parse(args))
end

describe "MCP screenshot" do
  it "writes the frame and reports the documented object" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.svg")
      begin
        r = shot_call(store, project.db_path,
          %({"tab":"history","cols":100,"rows":30,"path":#{dest.to_json}}))
        fail "screenshot errored: #{r.text}" if r.is_error
        payload = JSON.parse(r.text)
        payload["path"].as_s.should eq(dest)
        payload["format"].as_s.should eq("svg")
        payload["cols"].as_i.should eq(100)
        payload["rows"].as_i.should eq(30)
        payload["tab"].as_s.should eq("history")
        payload["bytes"].as_i.should be > 0
        File.exists?(dest).should be_true
        svg = File.read(dest)
        svg.should start_with("<svg")
        # Drawn over the STORE, not over an empty shell — the same thing the CLI's end-to-end
        # example asserts, and the reason `Headless` uses `focus_tab`.
        svg.should contain("shotmcp.test")
        payload["bytes"].as_i.should eq(svg.bytesize)
      ensure
        File.delete?(dest)
      end
    end
  end

  it "adds no content block unless inline was asked for" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.svg")
      begin
        r = shot_call(store, project.db_path, %({"cols":80,"rows":24,"path":#{dest.to_json}}))
        r.extra.should be_empty
      ensure
        File.delete?(dest)
      end
    end
  end

  it "carries an SVG back as a second TEXT block when inline is on" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.svg")
      begin
        r = shot_call(store, project.db_path,
          %({"cols":80,"rows":24,"inline":true,"path":#{dest.to_json}}))
        fail "screenshot errored: #{r.text}" if r.is_error
        r.extra.size.should eq(1)
        block = r.extra[0]
        block.type.should eq("text")
        # No mime type is what makes it a text block rather than a base64 payload.
        block.mime_type.should be_nil
        block.data.should start_with("<svg")
        block.data.should eq(File.read(dest))
      ensure
        File.delete?(dest)
      end
    end
  end

  it "refuses an existing file until overwrite says otherwise, and does not touch it" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.svg")
      File.write(dest, "PRIOR")
      begin
        r = shot_call(store, project.db_path, %({"cols":60,"rows":20,"path":#{dest.to_json}}))
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.field.should eq("path")
        r.text.should contain("already exists")
        File.read(dest).should eq("PRIOR")

        ok = shot_call(store, project.db_path,
          %({"cols":60,"rows":20,"overwrite":true,"path":#{dest.to_json}}))
        ok.is_error.should be_false
        File.read(dest).should start_with("<svg")
      ensure
        File.delete?(dest)
      end
    end
  end

  it "refuses a directory and a parent that is not there" do
    with_project_db do |store, project|
      dir = shot_call(store, project.db_path, %({"path":#{Dir.tempdir.to_json}}))
      dir.is_error.should be_true
      dir.text.should contain("directory")

      missing = File.join(Dir.tempdir, "gori-mcp-shot-no-such-dir", "a.svg")
      gone = shot_call(store, project.db_path, %({"path":#{missing.to_json}}))
      gone.is_error.should be_true
      gone.text.should contain("no directory")
    end
  end

  it "resolves a RELATIVE path under the screenshots convention dir" do
    with_project_db do |store, project|
      name = "rel-#{Random.rand(1_000_000)}.txt"
      dest = File.join(Gori::Paths.screenshots_dir, name)
      begin
        r = shot_call(store, project.db_path,
          %({"cols":50,"rows":12,"format":"txt","path":#{name.to_json}}))
        fail "screenshot errored: #{r.text}" if r.is_error
        # An agent has no way to know this server's working directory and no reason to write
        # into it, so a bare name lands where every other picture does.
        JSON.parse(r.text)["path"].as_s.should eq(dest)
        File.exists?(dest).should be_true
      ensure
        File.delete?(dest)
      end
    end
  end

  it "reports the pointer rules no frame could be asked for beside the sanitized count" do
    with_project_db do |store, project|
      before = Gori::Redact.salt
      Gori::Redact.salt = "spec-salt"
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.txt")
      begin
        # A pointer names a position in a PARSED document and a frame has none, so this
        # profile masks nothing. Reported, because `"sanitized": 0` on its own tells an agent
        # the picture was checked and came back clean.
        Gori::Redact::Policy.write_project_scope(store,
          Gori::Redact::Policy::ProjectScope.new(default: true, active: "ptr",
            profiles: [Gori::Redact::Profile.new(name: "ptr", json_pointers: ["/a", "/b"])]))
        r = shot_call(store, project.db_path,
          %({"cols":60,"rows":20,"format":"txt","path":#{dest.to_json}}))
        fail "screenshot errored: #{r.text}" if r.is_error
        payload = JSON.parse(r.text)
        payload["sanitized"].as_i.should eq(0)
        payload["unmaskable"].as_i.should eq(2)
      ensure
        Gori::Redact.salt = before
        File.delete?(dest)
      end
    end
  end

  it "refuses a PNG canvas past the pixel budget, and writes nothing" do
    with_project_db do |store, project|
      dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.png")
      begin
        # Every argument is inside its own documented cap and their PRODUCT is not: 300x300 at
        # scale 8 is a 19456x38912 canvas, three quarters of a billion pixels. Refused off
        # `Png.dimensions`, which allocates nothing.
        r = shot_call(store, project.db_path,
          %({"cols":300,"rows":300,"scale":8,"format":"png","path":#{dest.to_json}}))
        r.is_error.should be_true
        r.error_code.should eq("BUDGET_EXHAUSTED")
        r.field.should eq("scale")
        r.text.should contain("px cap")
        # A refusal that already put a file on disk is not a refusal.
        File.exists?(dest).should be_false
      ensure
        File.delete?(dest)
      end
    end
  end

  it "refuses a key script whose pauses run past the cap, before it opens anything" do
    with_project_db do |store, project|
      # A pause is the one token that costs wall time, and this server dispatches one call at a
      # time — `SLEEP99999` would park its worker fiber for a day.
      r = shot_call(store, project.db_path, %({"keys":"SLEEP99999"}))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.field.should eq("keys")
      r.text.should contain("one SLEEP may pause at most")
    end
  end

  it "refuses NO_PROJECT when the server was bound by store rather than by path" do
    with_store do |store|
      # `tools_for` binds a handle and no db_path — exactly the shape an embedder produces.
      r = tools_for(store).call("screenshot", JSON.parse(%({"format":"svg"})))
      r.is_error.should be_true
      r.error_code.should eq("NO_PROJECT")
      r.text.should contain("switch_project")
    end
  end

  it "refuses a tab and a format it does not advertise, naming the argument" do
    with_project_db do |store, project|
      bad_tab = shot_call(store, project.db_path, %({"tab":"nope"}))
      bad_tab.is_error.should be_true
      bad_tab.field.should eq("tab")
      bad_fmt = shot_call(store, project.db_path, %({"format":"jpeg"}))
      bad_fmt.is_error.should be_true
      bad_fmt.field.should eq("format")
    end
  end

  it "refuses a key script it cannot parse BEFORE it opens anything" do
    with_project_db do |store, project|
      r = shot_call(store, project.db_path, %({"keys":"C-"}))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.field.should eq("keys")
    end
  end

  it "leaves Env.layer exactly as it found it" do
    with_store_env do |_|
      with_project_db do |_, project|
        dest = File.join(Dir.tempdir, "gori-mcp-shot-#{Random.rand(1_000_000)}.txt")
        inner = Gori::Store.open(project.db_path, read_only: true)
        begin
          tools = Gori::MCP::Tools.new(inner, allow_actions: true, verify_upstream: false,
            project_name: "shotmcp", db_path: project.db_path)
          # Sampled AFTER construction: `gori mcp` binds the project's binding table ONCE,
          # here, and reads it for the life of the server. The render opens a whole second
          # session, and the layer THAT session binds must not be the one left behind.
          before = Gori::Env.layer
          before.should_not be_nil
          r = tools.call("screenshot",
            JSON.parse(%({"cols":60,"rows":20,"format":"txt","path":#{dest.to_json}})))
          fail "screenshot errored: #{r.text}" if r.is_error
          Gori::Env.layer.should be(before)
        ensure
          inner.close
          File.delete?(dest)
        end
      end
    end
  end
end
