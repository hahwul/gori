require "../spec_helper"
require "../support/mcp_harness"

# Project lifecycle drives Tools directly against an ISOLATED GORI_HOME so it
# never touches the developer's real ~/.gori/projects (delete is destructive).
describe "Gori::MCP::Tools project lifecycle" do
  it "creates, lists, switches, and (dry-run → token) deletes projects in isolation" do
    root = File.tempname("gori-projhome")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    cur_db = File.join(root, "current.db")
    store = Gori::Store.open(cur_db)
    tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, db_path: cur_db)
    begin
      # create two projects (already bound → create does NOT auto-switch)
      doomed = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Doomed","description":"scratch"}))).text)
      doomed["created"].as_bool.should be_true
      doomed["switched"]?.try(&.as_bool?).should be_false
      doomed_slug = doomed["slug"].as_s
      alt = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Alt"}))).text)["slug"].as_s

      # list shows both (neither current — server serves current.db, not a registry project)
      listed = JSON.parse(tools.call("list_projects", JSON.parse("{}")).text)["projects"].as_a.map(&.["slug"].as_s)
      listed.should contain(doomed_slug)
      listed.should contain(alt)

      # switch to Alt → subsequent tools serve it
      sw = JSON.parse(tools.call("switch_project", JSON.parse(%({"project":#{alt.to_json}}))).text)
      sw["switched"].as_bool.should be_true
      JSON.parse(tools.call("project_info", JSON.parse("{}")).text)["project_slug"].as_s.should eq(alt)

      # delete Doomed: a real delete without a token is refused
      no_token = tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false})))
      no_token.is_error.should be_true

      # dry_run issues a confirmation token + preview
      dry = JSON.parse(tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json}}))).text)
      dry["dry_run"].as_bool.should be_true
      token = dry["confirmation_token"].as_s
      dry["flows"].as_i.should eq(0)

      # a wrong token is refused
      tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false,"confirmation_token":"del_bogus"}))).is_error.should be_true

      # the real delete with the issued token succeeds
      done = JSON.parse(tools.call("delete_project", JSON.parse(%({"project":#{doomed_slug.to_json},"dry_run":false,"confirmation_token":#{token.to_json}}))).text)
      done["deleted"].as_bool.should be_true

      # Doomed is gone, Alt remains
      after = JSON.parse(tools.call("list_projects", JSON.parse("{}")).text)["projects"].as_a.map(&.["slug"].as_s)
      after.should_not contain(doomed_slug)
      after.should contain(alt)

      # deleting the currently-served project (Alt) is refused
      tools.call("delete_project", JSON.parse(%({"project":#{alt.to_json}}))).is_error.should be_true
    ensure
      store.close rescue nil
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end
end

describe "Gori::MCP::Tools unbound mode" do
  it "connects without a store, refuses traffic tools, and binds on create" do
    root = File.tempname("gori-unbound")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false,
      selection_source: "unbound")
    begin
      info = JSON.parse(tools.call("project_info", JSON.parse("{}")).text)
      info["bound"].as_bool.should be_false
      info["selection_source"].as_s.should eq("unbound")
      info["note"]?.try(&.as_s?).should_not be_nil

      hist = tools.call("list_history", JSON.parse("{}"))
      hist.is_error.should be_true
      hist.error_code.should eq("NO_PROJECT")

      # pure tools work unbound
      dec = tools.call("decode", JSON.parse(%({"input":"aGVsbG8=","spec":"base64-decode"})))
      dec.is_error.should be_false

      # `ql_explain` is a GRAMMAR tool and is listed in UNBOUND_SAFE, so it must not reach for a
      # project — including for the `scope:` lens, whose `store` raises here. It answers about the
      # query and says the project question could not be asked, rather than "no scope rules".
      ex = tools.call("ql_explain", JSON.parse(%({"query":"host:acme"})))
      ex.is_error.should be_false
      JSON.parse(ex.text)["scope_rules_configured"].raw.should be_nil

      scoped = tools.call("ql_explain", JSON.parse(%({"query":"scope:in"})))
      scoped.is_error.should be_false
      p_scoped = JSON.parse(scoped.text)
      p_scoped["applied_terms"].as_a.map(&.as_s).should eq(["scope:in"]) # compiled, not dropped
      p_scoped["scope_rules_configured"].raw.should be_nil
      p_scoped["warnings"].as_a.map(&.as_s).join(" ").should contain("no project is selected")

      # create auto-binds when unbound
      created = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"First"}))).text)
      created["created"].as_bool.should be_true
      created["switched"].as_bool.should be_true

      info2 = JSON.parse(tools.call("project_info", JSON.parse("{}")).text)
      info2["bound"].as_bool.should be_true
      info2["project"].as_s.should eq("First")

      hist2 = tools.call("list_history", JSON.parse("{}"))
      hist2.is_error.should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end

  it "allows switch_project and create_project under read-only when unbound" do
    root = File.tempname("gori-unbound-ro")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    # Seed a project via registry so switch has a target without using create.
    reg = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
    seeded = reg.create("Seeded")
    Gori::Store.open(seeded.db_path).close

    tools = Gori::MCP::Tools.new(nil, allow_actions: false, verify_upstream: false,
      selection_source: "unbound")
    begin
      send = tools.call("send_request", JSON.parse(%({"url":"http://example.test/"})))
      send.is_error.should be_true
      # unbound gate fires first for traffic tools that need a project
      send.error_code.should eq("NO_PROJECT")

      sw = JSON.parse(tools.call("switch_project", JSON.parse(%({"project":"Seeded"}))).text)
      sw["switched"].as_bool.should be_true

      # after bind, send is still disabled by read-only
      send2 = tools.call("send_request", JSON.parse(%({"url":"http://example.test/"})))
      send2.is_error.should be_true
      send2.error_code.should eq("TOOL_DISABLED")

      # create under read-only is refused once bound
      cr = tools.call("create_project", JSON.parse(%({"name":"Nope"})))
      cr.is_error.should be_true
      cr.error_code.should eq("TOOL_DISABLED")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end

  # A project that cannot be OPENED (corrupt db, unreadable projects dir) used to abort the
  # process before the handshake, which every MCP client reports as one dead "server failed
  # to start" line — the reason reachable only in a log, and no way for the agent to fix it.
  # The server now starts unbound CARRYING the reason, so the failure is visible on the
  # surface the agent reads and the tools that repair it stay reachable.
  describe "degraded start (bind_error)" do
    it "names the failure in instructions and in every NO_PROJECT error" do
      input = IO::Memory.new(<<-JSON)
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_history","arguments":{}}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_info","arguments":{}}}
        JSON
      output = IO::Memory.new
      Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: false,
        selection_source: "unbound", bind_error: "cannot open database /tmp/x.db: file is not a database",
        input: input, output: output).run
      lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a

      lines[0]["result"]["instructions"].as_s.should contain("file is not a database")

      lines[1]["result"]["isError"].as_bool.should be_true
      err = lines[1]["result"]["structuredContent"]
      err["error_code"].as_s.should eq("NO_PROJECT")
      err["message"].as_s.should contain("file is not a database")
      err["message"].as_s.should contain("switch_project") # the recovery, still named

      info = JSON.parse(lines[2]["result"]["content"][0]["text"].as_s)
      info["bound"].as_bool.should be_false
      info["bind_error"].as_s.should contain("file is not a database")
    end

    it "stops blaming the failed db once a switch binds a working one" do
      root = File.tempname("gori-bind-error")
      Dir.mkdir_p(root)
      prev = ENV["GORI_HOME"]?
      ENV["GORI_HOME"] = root
      reg = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
      seeded = reg.create("Seeded")
      Gori::Store.open(seeded.db_path).close

      tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false,
        selection_source: "unbound", bind_error: "cannot open database /tmp/x.db: file is not a database")
      begin
        tools.call("list_history", JSON.parse("{}")).text.should contain("file is not a database")
        JSON.parse(tools.call("switch_project", JSON.parse(%({"project":"Seeded"}))).text)["switched"].as_bool.should be_true
        JSON.parse(tools.call("project_info", JSON.parse("{}")).text)["bind_error"]?.should be_nil
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(root)
      end
    end
  end

  it "handshakes an unbound Server over stdio" do
    input = IO::Memory.new(<<-JSON)
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
      JSON
    output = IO::Memory.new
    Gori::MCP::Server.new(nil, allow_actions: true, verify_upstream: false,
      selection_source: "unbound", input: input, output: output).run
    lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
    lines.size.should eq(2)
    init = lines[0]["result"]
    init["serverInfo"]["name"].as_s.should eq("gori")
    init["instructions"].as_s.should match(/No project is bound/i)
    names = lines[1]["result"]["tools"].as_a.map(&.["name"].as_s)
    names.should contain("list_projects")
    names.should contain("create_project")
    names.should contain("switch_project")
    names.should contain("list_history")
  end
end

describe "MCP agent event feed" do
  it "records the intercept write verbs the human needs to see" do
    with_store do |store|
      tools = tools_for(store)
      # No live capturing instance, so each verb fails — the feed logs failures too, which is
      # exactly what an operator wants to see an agent attempting on held traffic.
      tools.call("intercept_forward", JSON.parse(%({"item_id":1}))).is_error.should be_true
      tools.call("intercept_toggle", JSON.parse(%({"enable":false}))).is_error.should be_true

      logged = store.events_after(0_i64, 50).select { |e| e.kind == "agent_action" }.map(&.payload)
      logged.should contain "intercept_forward"
      logged.should contain "intercept_toggle"
    end
  end

  it "in_scope narrows the report to in-scope hosts, all flows still scanned" do
    with_store do |store|
      # A `?apikey=` value fires the passive secret_in_url rule on each host.
      mcp_seed_flow(store, "alpha.test", "GET", "/x?apikey=longsecretvalue123", 200)
      mcp_seed_flow(store, "beta.test", "GET", "/y?apikey=longsecretvalue123", 200)
      store.add_scope_rule("include", "host", "alpha.test") # lens never enabled
      tools = tools_for(store)

      all = mcp_ok_json(tools, "probe_scan", "{}")
      all["flows_scanned"].as_i.should eq(2) # every flow scanned regardless
      all["issues"].as_a.map(&.["host"].as_s).uniq!.sort!.should eq(["alpha.test", "beta.test"])

      scoped = mcp_ok_json(tools, "probe_scan", %({"in_scope":true}))
      scoped["flows_scanned"].as_i.should eq(2)                                  # still scanned all
      scoped["issues"].as_a.map(&.["host"].as_s).uniq!.should eq(["alpha.test"]) # report narrowed
    end
  end

  it "records an ACTIVE probe scan but not a passive one" do
    with_store do |store|
      mcp_seed_flow(store, "/a")
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      tools = tools_for(store)

      mcp_ok_json(tools, "probe_scan", "{}")                   # passive — sends nothing
      tools.call("probe_scan", JSON.parse(%({"active":true}))) # sends real requests

      logged = store.events_after(0_i64, 50).select { |e| e.kind == "agent_action" && e.payload == "probe_scan" }
      # The argument decides, not the tool name: a passive rescan would bury the outbound ones.
      logged.size.should eq 1
    end
  end
end

describe "MCP job project binding" do
  # A finished job outlives a switch_project (only a RUNNING one blocks the switch), and its
  # buffered results carry History flow ids that resolve to unrelated rows in the new DB.
  # Isolated GORI_HOME, like the project-lifecycle spec — switch_project touches the registry.
  it "refuses to serve a finished job's results after switch_project" do
    root = File.tempname("gori-jobhome")
    Dir.mkdir_p(root)
    prev = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = root
    cur_db = File.join(root, "current.db")
    store = Gori::Store.open(cur_db)
    tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, db_path: cur_db)
    begin
      Gori::Scope.load(store).add("include", "host", "127.0.0.1")
      started = mcp_ok_json(tools, "fuzz_start",
        %({"url":"http://127.0.0.1:1","template":"GET /§x§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
        %("payloads":[{"list":["a"]}],"max_requests":1,"retries":0,"timeout_ms":50}))
      job_id = started["job_id"].as_s

      # Let the job reach a terminal state so it does not block the switch.
      40.times do
        break unless JSON.parse(tools.call("fuzz_status", JSON.parse(%({"job_id":"#{job_id}"}))).text)["status"].as_s == "running"
        sleep 25.milliseconds
      end
      mcp_ok_json(tools, "fuzz_status", %({"job_id":"#{job_id}"}))["job_complete"].as_bool.should be_true

      other = JSON.parse(tools.call("create_project", JSON.parse(%({"name":"Other"}))).text)["slug"].as_s
      mcp_ok_json(tools, "switch_project", %({"project":#{other.to_json}}))

      # The job is still remembered, but its results are no longer meaningful here.
      %w[fuzz_status fuzz_results fuzz_stop get_job stop_job].each do |verb|
        r = tools.call(verb, JSON.parse(%({"job_id":"#{job_id}"})))
        r.error_code.should eq "PROJECT_CHANGED"
      end
      # list_jobs still SHOWS it, flagged, so the agent can see why its id refuses.
      listed = mcp_ok_json(tools, "list_jobs", "{}")["jobs"].as_a.find { |x| x["job_id"].as_s == job_id }
      listed.should_not be_nil
      listed.not_nil!["project_changed"].as_bool.should be_true
    ensure
      store.close rescue nil
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(root)
    end
  end
end
