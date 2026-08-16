require "./spec_helper"
require "socket"

# The MCP authorize_* tools replay captured requests under several identities on a background
# fiber, so — like the fuzz tools — they are driven here through a Tools instance directly
# (with sleeps that yield to the job fiber) against a local origin. The IO::Memory server
# harness never yields between scripted lines, so a polled async job cannot progress there.

private def with_store(&)
  path = File.tempname("gori-mcpauthz", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# An origin that either serves the same page to everyone (`enforce: false` — a broken
# access-control target) or refuses a request carrying no Cookie (`enforce: true`). One
# connection per request, because `Authorize::Engine.live` deliberately does not keep-alive.
private def start_authz_origin(enforce : Bool) : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      begin
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        authed = head ? String.new(head).downcase.includes?("cookie:") : false
        if enforce && !authed
          body = "denied"
          conn << "HTTP/1.1 403 Forbidden\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        else
          body = "top secret admin dashboard: employee list, payroll totals, and pending invoices"
          conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        end
        conn.flush
        conn.close
      rescue
        conn.close rescue nil
      end
    end
  end
  port
end

# A completed capture pointing at the local origin. `cookie` decides whether any identity that
# REMOVES Cookie would change the request — without it `Passive.skip_reason` answers
# `:no_effect` and the flow is (correctly) never replayed.
private def seed_authz_flow(store, port, method = "GET", target = "/admin", cookie = true) : Int64
  head = String.build do |s|
    s << method << ' ' << target << " HTTP/1.1\r\nHost: 127.0.0.1:" << port << "\r\n"
    s << "Cookie: session=abc123\r\n" if cookie
    s << "\r\n"
  end
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: nil, content_type: nil))
  id
end

# The identity set every example replays under: the request as captured (added as the
# baseline automatically) plus one anonymous client that drops the session cookie.
private def anon : Array(Hash(String, String | Array(String)))
  [{"name" => "anonymous", "remove" => ["Cookie"]} of String => String | Array(String)]
end

private def call_result(tools, name, args : String) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args))
end

# Parsed JSON for a successful call (fails loudly if the tool errored).
private def call_json(tools, name, args : String) : JSON::Any
  r = call_result(tools, name, args)
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def tool_names(tools) : Array(String)
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
end

# Poll to a terminal state and return the final status payload.
private def drain_job(tools, job_id : String) : JSON::Any
  400.times do
    status = call_json(tools, "authorize_status", %({"job_id":#{job_id.to_json}}))
    return status unless status["status"].as_s == "running"
    sleep 0.02.seconds
  end
  fail "authorize job #{job_id} never finished"
end

describe "MCP authorize tools" do
  describe "job lifecycle" do
    it "replays under every identity and reports a bypass unmistakably" do
      port = start_authz_origin(enforce: false)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start", {
          "flow_ids"       => [flow],
          "identities"     => anon,
          "allow_unscoped" => true,
        }.to_json)
        start["status"].as_s.should eq("running")
        start["requests"].as_i.should eq(1)
        # baseline (as-captured) + anonymous
        start["identities"].as_a.map(&.as_s).should eq(["as-captured", "anonymous"])
        start["baseline_identity"].as_s.should eq("as-captured")
        start["sends_planned"].as_i.should eq(2)
        start["scope_gate"].as_s.should eq("waived")
        start["skipped"].as_a.should be_empty

        job_id = start["job_id"].as_s
        status = drain_job(tools, job_id)
        status["status"].as_s.should eq("done")
        status["requests_replayed"].as_i.should eq(1)
        status["sent"].as_i.should eq(2)
        status["errors"].as_i.should eq(0)
        status["blocked"].as_i.should eq(0)
        status["access_control"].as_s.should eq("BYPASS")
        status["bypass"].as_bool.should be_true
        status["bypass_count"].as_i.should eq(1)

        results = call_json(tools, "authorize_results", %({"job_id":#{job_id.to_json}}))
        results["access_control"].as_s.should eq("BYPASS")
        results["bypass"].as_bool.should be_true
        results["summary"].as_s.should contain("BROKEN ACCESS CONTROL")
        # The flat, never-paged finding list is the headline a model must not be able to miss.
        results["bypasses"].as_a.size.should eq(1)
        finding = results["bypasses"][0]
        finding["flow_id"].as_i64.should eq(flow)
        finding["url"].as_s.should contain("/admin")
        finding["identities"].as_a.map(&.as_s).should eq(["anonymous"])
        finding["baseline_identity"].as_s.should eq("as-captured")
        finding["finding"].as_s.should contain("broken access control")

        results["results"].as_a.size.should eq(1)
        row = results["results"][0]
        row["bypass"].as_bool.should be_true
        row["fully_blocked"].as_bool.should be_false
        trials = row["trials"].as_a
        trials.size.should eq(2)
        trials[0]["identity"].as_s.should eq("as-captured")
        trials[0]["baseline"].as_bool.should be_true
        trials[0]["verdict"].as_s.should eq("baseline")
        trials[0]["status"].as_i.should eq(200)
        trials[1]["identity"].as_s.should eq("anonymous")
        trials[1]["verdict"].as_s.should eq("same")
        trials[1]["matches_baseline"].as_bool.should be_true
        results["job_complete"].as_bool.should be_true
        results["has_more"].as_bool.should be_false
      end
    end

    it "reports an enforced endpoint as enforced, with no bypass" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start", {
          "flow_ids"       => flow, # a bare id, not an array
          "identities"     => anon,
          "allow_unscoped" => true,
        }.to_json)
        drain_job(tools, start["job_id"].as_s)["access_control"].as_s.should eq("enforced")
        results = call_json(tools, "authorize_results", %({"job_id":#{start["job_id"].as_s.to_json}}))
        results["bypass"].as_bool.should be_false
        results["bypass_count"].as_i.should eq(0)
        results["bypasses"].as_a.should be_empty
        results["summary"].as_s.should contain("no identity matched the baseline")
        trials = results["results"][0]["trials"].as_a
        trials[1]["verdict"].as_s.should eq("different")
        trials[1]["status"].as_i.should eq(403)
        trials[1]["matches_baseline"].as_bool.should be_false
      end
    end

    it "defaults to the identities saved in the project" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY, Gori::Authorize.serialize([
          Gori::Authorize::Identity.as_captured,
          Gori::Authorize::Identity.new("anon", remove_headers: ["Cookie"]),
        ]))
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start",
          {"flow_ids" => [flow], "allow_unscoped" => true}.to_json)
        start["identities"].as_a.map(&.as_s).should eq(["as-captured", "anon"])
        drain_job(tools, start["job_id"].as_s)["status"].as_s.should eq("done")
      end
    end

    it "selects by QL query as well as by id, and reports skipped flows with reasons" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        get = seed_authz_flow(store, port, target: "/admin")
        post = seed_authz_flow(store, port, method: "POST", target: "/admin/delete")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start", {
          "query"          => "host:127.0.0.1",
          "identities"     => anon,
          "allow_unscoped" => true,
        }.to_json)
        start["requests"].as_i.should eq(1)
        start["skipped_count"].as_i.should eq(1)
        start["skipped_summary"].as_s.should contain("not a safe method to repeat")
        skipped = start["skipped"].as_a
        skipped[0]["flow_id"].as_i64.should eq(post)
        skipped[0]["reason"].as_s.should eq("unsafe_method")
        skipped[0]["reason_label"].as_s.should eq("not a safe method to repeat")
        drain_job(tools, start["job_id"].as_s)["skipped_count"].as_i.should eq(1)

        # …and unsafe_methods:true takes the same POST.
        both = call_json(tools, "authorize_start", {
          "query"          => "host:127.0.0.1",
          "identities"     => anon,
          "unsafe_methods" => true,
          "allow_unscoped" => true,
        }.to_json)
        both["requests"].as_i.should eq(2)
        both["skipped"].as_a.should be_empty
        drain_job(tools, both["job_id"].as_s)
        rows = call_json(tools, "authorize_results", %({"job_id":#{both["job_id"].as_s.to_json}}))
        rows["results"].as_a.map(&.["flow_id"].as_i64).should contain(get)
      end
    end

    it "stops a running job, and the job appears in list_jobs / get_job / stop_job" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start", {
          "flow_ids" => [flow], "identities" => anon, "allow_unscoped" => true,
        }.to_json)
        job_id = start["job_id"].as_s
        job_id.should start_with("az_")

        listed = call_json(tools, "list_jobs", "{}")
        row = listed["jobs"].as_a.find { |r| r["job_id"].as_s == job_id }.not_nil!
        row["kind"].as_s.should eq("authorize")
        row["bypass_count"].as_i.should eq(0)

        stop = call_json(tools, "authorize_stop", %({"job_id":#{job_id.to_json}}))
        stop["status"].as_s.should eq("stopping")
        final = drain_job(tools, job_id)
        # A one-request run may well have finished before the stop landed; either terminal
        # state is correct, and neither may be :running.
        ["done", "stopped"].should contain(final["status"].as_s)
        # The unified job tools dispatch on the az_ prefix.
        call_json(tools, "get_job", %({"job_id":#{job_id.to_json}}))["job_id"].as_s.should eq(job_id)
        call_json(tools, "stop_job", %({"job_id":#{job_id.to_json}}))["job_id"].as_s.should eq(job_id)
      end
    end
  end

  # `Authorize::PlanError::Reason` documents that every member obligates an arm on all three
  # surfaces. All five are exercised here, each asserting the CODE a caller's policy reads and
  # the sentence that says what to change.
  describe "PlanError arms" do
    it "NoTarget: neither flow_ids nor query" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start", {"identities" => anon}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.field.should eq("flow_ids")
        r.text.should contain("'flow_ids'")
        r.text.should contain("'query'")
      end
    end

    it "NoFlows: ids that no longer exist, and a query that matched nothing" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        byid = call_result(tools, "authorize_start", {"flow_ids" => [98765], "identities" => anon}.to_json)
        byid.error_code.should eq("NOT_FOUND")
        byid.text.should contain("list_history")

        seed_authz_flow(store, 1, target: "/x")
        byquery = call_result(tools, "authorize_start",
          {"query" => "host:nothing.invalid", "identities" => anon}.to_json)
        byquery.error_code.should eq("NOT_FOUND")
        byquery.text.should contain("host:nothing.invalid")
      end
    end

    it "BadQuery: a query that compiles to no clause is refused, not run as match-all" do
      with_store do |store|
        seed_authz_flow(store, 1)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start",
          {"query" => "status:>=foo", "identities" => anon, "allow_unscoped" => true}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("QUERY_SYNTAX")
        r.field.should eq("query")
        r.text.should contain("WHOLE history")
      end
    end

    it "NoIdentities: names the argument for an inline set and the tab for the project's" do
      with_store do |store|
        flow = seed_authz_flow(store, 1)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        # An explicit-but-empty set: the baseline alone would be judged against itself.
        inline = call_result(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => [] of String}.to_json)
        inline.error_code.should eq("INVALID_ARGUMENT")
        inline.field.should eq("identities")
        inline.text.should contain("'identities' resolved to fewer than two")

        # No argument at all, and nothing saved in the project.
        project = call_result(tools, "authorize_start", {"flow_ids" => [flow]}.to_json)
        project.error_code.should eq("INVALID_ARGUMENT")
        project.field.should eq("identities")
        project.text.should contain("no saved authorize identities")
        project.text.should contain("Authorize tab")
      end
    end

    it "NothingToSend: every selected flow was skipped, with the per-reason tally" do
      with_store do |store|
        # A POST is not a safe method to repeat, so it is skipped unless asked for by name.
        post = seed_authz_flow(store, 1, method: "POST", target: "/pay")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start",
          {"flow_ids" => [post], "identities" => anon, "allow_unscoped" => true}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("NOTHING_TO_SEND")
        r.text.should contain("not a safe method to repeat")
        r.text.should contain("unsafe_methods:true")
        details = r.details.not_nil!
        details["skipped"].as_i.should eq(1)
        details["reasons"]["unsafe_method"].as_i.should eq(1)
      end
    end
  end

  describe "scope" do
    it "refuses an unscoped project with SCOPE_BLOCKED, and runs with allow_unscoped" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        blocked = call_result(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => anon}.to_json)
        blocked.is_error.should be_true
        blocked.error_code.should eq("SCOPE_BLOCKED")
        blocked.field.should eq("allow_unscoped")
        blocked.text.should contain("no scope is configured")
        blocked.text.should contain("allow_unscoped:true")
        blocked.details.not_nil!["scope_decision"].as_s.should eq("unscoped")

        ok = call_json(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => anon, "allow_unscoped" => true}.to_json)
        ok["scope_gate"].as_s.should eq("waived")
        drain_job(tools, ok["job_id"].as_s)
      end
    end

    it "refuses an out-of-scope host even when the project HAS a scope" do
      with_store do |store|
        flow = seed_authz_flow(store, 1)
        store.add_scope_rule("include", "host", "only.example.com")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start", {"flow_ids" => [flow], "identities" => anon}.to_json)
        r.error_code.should eq("SCOPE_BLOCKED")
        r.text.should contain("127.0.0.1")
        r.details.not_nil!["scope_decision"].as_s.should eq("out_of_scope")
      end
    end

    # Sandbox is Layer 2 and `allow_unscoped` deliberately does NOT lift it, so a waived run
    # can still have every send refused at the socket. Reporting that as "no identity matched
    # the baseline" would be a clean bill of health for traffic that never left (DESIGN.md §7).
    it "says nothing was sent when Sandbox refused every send, rather than 'enforced'" do
      port = start_authz_origin(enforce: false)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        store.add_scope_rule("include", "host", "only.example.com")
        store.set_setting(Gori::Scope::SETTING_SANDBOX, "1")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => anon, "allow_unscoped" => true}.to_json)
        status = drain_job(tools, start["job_id"].as_s)
        status["blocked"].as_i.should be > 0
        status["access_control"].as_s.should eq("nothing_sent")
        status["bypass"].as_bool.should be_false
        status["summary"].as_s.should contain("NOT evidence")
        results = call_json(tools, "authorize_results", %({"job_id":#{start["job_id"].as_s.to_json}}))
        results["results"][0]["fully_blocked"].as_bool.should be_true
        results["bypasses"].as_a.should be_empty
      end
    end

    it "keeps an in-scope flow and reports the out-of-scope one as skipped" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        keep = seed_authz_flow(store, port, target: "/admin")
        drop = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 2_i64, scheme: "http", host: "elsewhere.invalid", port: 80,
          method: "GET", target: "/", http_version: "HTTP/1.1",
          head: "GET / HTTP/1.1\r\nHost: elsewhere.invalid\r\nCookie: s=1\r\n\r\n".to_slice, body: nil))
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: drop, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: nil, content_type: nil))
        store.add_scope_rule("include", "host", "127.0.0.1")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start",
          {"flow_ids" => [keep, drop], "identities" => anon}.to_json)
        start["scope_gate"].as_s.should eq("allowlist")
        start["requests"].as_i.should eq(1)
        start["skipped"].as_a.map(&.["reason"].as_s).should eq(["out_of_scope"])
        drain_job(tools, start["job_id"].as_s)
      end
    end
  end

  describe "listing and gating" do
    it "lists all four tools alongside its siblings, and hides them all in read-only" do
      with_store do |store|
        full = tool_names(Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false))
        %w[authorize_start authorize_status authorize_results authorize_stop].each do |n|
          full.should contain(n)
        end
        # …exactly like the four other active-sending job families.
        %w[fuzz_start mine_start sequence_start discover_start].each { |n| full.should contain(n) }

        ro = tool_names(Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false))
        %w[authorize_start authorize_status authorize_results authorize_stop].each do |n|
          ro.should_not contain(n)
        end
        %w[fuzz_start mine_start sequence_start discover_start].each { |n| ro.should_not contain(n) }
      end
    end

    it "rejects every authorize call in read-only mode with TOOL_DISABLED" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
        %w[authorize_start authorize_status authorize_results authorize_stop].each do |name|
          r = call_result(tools, name, %({"job_id":"az_1"}))
          r.is_error.should be_true
          r.error_code.should eq("TOOL_DISABLED")
        end
      end
    end

    it "declares every schema well-formed and rejects an undeclared argument" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
          .select(&.["name"].as_s.starts_with?("authorize_"))
        listed.size.should eq(4)
        listed.each do |t|
          t["description"].as_s.should_not be_empty
          t["inputSchema"]["type"].as_s.should eq("object")
        end
        # The singular `flow_id` every sibling takes is NOT an argument here; the refusal names
        # the accepted set rather than silently running with no selection.
        r = call_result(tools, "authorize_start", {"flow_id" => 1, "identities" => anon}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.text.should contain("flow_ids")
      end
    end
  end

  describe "arguments" do
    it "reads flow_ids as an array, a bare id, a comma list, or a JSON-encoded array" do
      with_store do |store|
        a = seed_authz_flow(store, 1, target: "/a")
        b = seed_authz_flow(store, 1, target: "/b")
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        base = {"identities" => anon, "allow_unscoped" => true}
        ["#{a},#{b}", "[#{a},#{b}]"].each do |spelling|
          start = call_json(tools, "authorize_start", base.merge({"flow_ids" => spelling}).to_json)
          start["requests"].as_i.should eq(2)
          drain_job(tools, start["job_id"].as_s)
        end
        arr = call_json(tools, "authorize_start", base.merge({"flow_ids" => [a, b]}).to_json)
        arr["requests"].as_i.should eq(2)
        drain_job(tools, arr["job_id"].as_s)
      end
    end

    it "names a non-integer flow id instead of dropping it" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start", {"flow_ids" => ["7", "oops"], "identities" => anon}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.text.should contain("oops")
      end
    end

    # The house rule (spec/mcp_bool_args_spec.cr): a boolean argument is coerced leniently
    # ("true"/"false") but NEVER silently — a `1` for unsafe_methods would otherwise replay a
    # POST nobody authorised, and a `0` for allow_unscoped would look like a waiver.
    it "refuses boolean garbage by name instead of running a different test" do
      with_store do |store|
        flow = seed_authz_flow(store, 1)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        # {flag, a legal STRING spelling that still lets the run start}
        {"unsafe_methods" => "false", "verify" => "false", "allow_unscoped" => "true"}.each do |flag, legal|
          # `flag` is written LAST, so it overrides the allow_unscoped default below it.
          bad = call_result(tools, "authorize_start",
            {"flow_ids" => [flow], "identities" => anon, "allow_unscoped" => true, flag => 1}.to_json)
          bad.is_error.should be_true
          bad.error_code.should eq("INVALID_ARGUMENT")
          bad.text.should contain("'#{flag}'")
          # …while the string spellings a client may send are still honoured.
          ok = call_json(tools, "authorize_start",
            {"flow_ids" => [flow], "identities" => anon, "allow_unscoped" => true, flag => legal}.to_json)
          drain_job(tools, ok["job_id"].as_s)
        end
      end
    end

    it "refuses a malformed identities string rather than degrading it to an empty set" do
      with_store do |store|
        flow = seed_authz_flow(store, 1)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => "{not json"}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.text.should contain("JSON array of identity objects")
      end
    end

    it "accepts identities as a JSON-encoded string (LLM clients stringify)" do
      port = start_authz_origin(enforce: true)
      with_store do |store|
        flow = seed_authz_flow(store, port)
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        start = call_json(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => anon.to_json, "allow_unscoped" => true}.to_json)
        start["identities"].as_a.map(&.as_s).should eq(["as-captured", "anonymous"])
        drain_job(tools, start["job_id"].as_s)
      end
    end

    it "refuses a selection whose flows × identities exceeds the send cap" do
      with_store do |store|
        # One flow, many identities: the cap is on the PRODUCT, so either factor can trip it.
        flow = seed_authz_flow(store, 1)
        idents = (1..2100).map { |i| {"name" => "id#{i}", "remove" => ["Cookie"]} }
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        r = call_result(tools, "authorize_start",
          {"flow_ids" => [flow], "identities" => idents, "allow_unscoped" => true}.to_json)
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.text.should contain("over the")
      end
    end

    it "reports an unknown job id as NOT_FOUND on all three pollers" do
      with_store do |store|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
        %w[authorize_status authorize_results authorize_stop].each do |name|
          call_result(tools, name, %({"job_id":"az_999"})).error_code.should eq("NOT_FOUND")
          call_result(tools, name, "{}").error_code.should eq("INVALID_ARGUMENT")
        end
      end
    end
  end
end
