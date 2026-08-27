require "../spec_helper"
require "json"
require "file_utils"

# The MCP side of agent presence (#815): a bound `gori mcp` server lays a marker beside its
# database for the session's lifetime, carries the peer's clientInfo into it, moves it on a
# project switch, and clears it when the session ends. Most of this is observable directly on
# `Gori::MCP::Tools` (it takes `db_path:` and exposes client_seen/release_presence); the full
# run() lifecycle — where release must happen only AFTER the worker drains — is exercised
# through a real pipe with the server on a background fiber.

# Roots the registry at GORI_HOME/projects — the same place `Tools#registry` builds from — so
# a switch_project the server runs finds the projects this spec created. Restores GORI_HOME.
private def with_registry(&)
  home = File.tempname("gori-mcp-presence")
  saved = ENV["GORI_HOME"]?
  ENV["GORI_HOME"] = home
  begin
    yield Gori::ProjectRegistry.new(Gori::Paths.projects_dir), home
  ensure
    saved ? (ENV["GORI_HOME"] = saved) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(home) if Dir.exists?(home)
  end
end

private def tools_for(project, allow_actions = true) : Gori::MCP::Tools
  store = Gori::Store.open(project.db_path, read_only: !allow_actions)
  Gori::MCP::Tools.new(store, allow_actions, false, project_name: project.name,
    db_path: project.db_path, selection_source: "workspace-created")
end

private def live(db_path : String)
  Gori::AgentPresence.live(db_path)
end

describe "MCP agent presence" do
  it "lays a marker for the session and clears it on release" do
    with_registry do |reg, root|
      project = reg.create("target")
      tools = tools_for(project)
      begin
        # The marker exists from the moment the server binds — before any handshake, so the
        # name is not known yet.
        entries = live(project.db_path)
        entries.size.should eq(1)
        entries.first.client.should be_nil
        entries.first.read_only.should be_false
        entries.first.selection_source.should eq("workspace-created")

        tools.client_seen("claude-code", "2.1.0")
        named = live(project.db_path).first
        named.client.should eq("claude-code")
        named.client_version.should eq("2.1.0")
      ensure
        tools.release_presence
      end
      live(project.db_path).should be_empty # the marker's lifetime is the session's
    end
  end

  it "moves the marker to the project it switches to" do
    with_registry do |reg, root|
      a = reg.create("alpha")
      b = reg.create("beta")
      tools = tools_for(a)
      begin
        live(a.db_path).size.should eq(1)
        live(b.db_path).should be_empty
        tools.call("switch_project", JSON.parse(%({"project":"beta"}))).is_error.should be_false
        # The bind path is the marker path: leaving A empties it, B gains one.
        live(a.db_path).should be_empty
        live(b.db_path).size.should eq(1)
      ensure
        tools.release_presence
      end
    end
  end

  it "lays no marker while unbound, and one once a project is created" do
    with_registry do |reg, root|
      # A server that started outside a workspace has no store and no db_path — nothing to
      # mark. create_project auto-binds when unbound, and THAT is the bind path.
      tools = Gori::MCP::Tools.new(nil, true, false)
      begin
        created = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"fresh"}))).text)
        created["switched"].as_bool.should be_true
        db = created["db_path"].as_s
        live(db).size.should eq(1)
      ensure
        tools.release_presence
      end
    end
  end

  it "records read-only when the server has no action tools" do
    with_registry do |reg, root|
      project = reg.create("ro")
      tools = tools_for(project, allow_actions: false)
      begin
        live(project.db_path).first.read_only.should be_true
      ensure
        tools.release_presence
      end
    end
  end
end

# The one thing only the real server run() can show: the marker outlives the whole session and
# is gone once the input pipe closes — and clientInfo delivered over the wire reaches the marker.
private def wait_until(deadline : Time::Span, &block : -> Bool) : Bool
  giveup = Time.instant + deadline
  until block.call
    return false if Time.instant >= giveup
    sleep 5.milliseconds
  end
  true
end

describe "MCP agent presence over the wire" do
  it "shows the client during the session and clears the marker at EOF" do
    with_registry do |reg, root|
      project = reg.create("wire")
      store = Gori::Store.open(project.db_path)
      reader, to_server = IO.pipe
      from_server = IO::Memory.new
      server = Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        project_name: project.name, db_path: project.db_path,
        selection_source: "workspace-created", input: reader, output: from_server)
      done = Channel(Nil).new(1)
      # Do NOT wait on the fiber bare — a writer-side hang would wedge the example forever.
      # The pipe close below is what ends run(); the channel is how we join it with a deadline.
      spawn do
        server.run
        done.send(nil)
      end
      begin
        init = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"9.9"}}})
        to_server.puts(init)
        # Mid-session: the marker is present and named from the handshake.
        wait_until(2.seconds) { live(project.db_path).map(&.client) == ["claude-code"] }.should be_true
        live(project.db_path).first.client_version.should eq("9.9")

        to_server.close # client vanished → run() returns
        # release_presence runs in run()'s ensure, after the worker drains — so the marker
        # going empty is proof the whole session tore down, not just that we stopped writing.
        wait_until(2.seconds) { live(project.db_path).empty? }.should be_true
        done.receive? # join the fiber; run() has already returned by here
      ensure
        to_server.close rescue nil
        store.close
      end
    end
  end

  it "treats a non-string clientInfo.name as absent, not coerced" do
    with_registry do |reg, root|
      project = reg.create("hostile")
      store = Gori::Store.open(project.db_path)
      reader, to_server = IO.pipe
      from_server = IO::Memory.new
      server = Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
        project_name: project.name, db_path: project.db_path,
        selection_source: "workspace-created", input: reader, output: from_server)
      done = Channel(Nil).new(1)
      spawn do
        server.run
        done.send(nil)
      end
      begin
        # A NUMBER in the name slot alongside a VALID version. The version is the observable
        # proof the handshake was processed: the marker starts nameless at bind, so waiting on
        # `client == nil` alone would pass before the worker ever ran initialize (a vacuous
        # green). Waiting on `client_version == "9.9"` — which only the handshake can set —
        # guarantees `client_seen` ran; THEN a nil name means the number was dropped, not
        # coerced to "5".
        init = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":5,"version":"9.9"}}})
        to_server.puts(init)
        wait_until(2.seconds) { live(project.db_path).first?.try(&.client_version) == "9.9" }.should be_true
        live(project.db_path).first.client.should be_nil
      ensure
        to_server.close rescue nil
        done.receive?
        store.close
      end
    end
  end
end
