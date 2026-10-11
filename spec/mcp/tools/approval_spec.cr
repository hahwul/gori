require "../../spec_helper"
require "http/server"

# #1585: a Preferences group in `ask` stays served, and each call in it comes back
# APPROVAL_PENDING until the operator answers the approval card in the TUI; the agent's retry
# of the same call reads the answer. Nothing here waits on the operator.

private def ask_tools(store, *keys : String) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, asked_permissions: keys.to_set)
end

private def call(tools, name : String, args : String) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args))
end

private def approval_id(r : Gori::MCP::Tools::Result) : Int64
  r.error_code.should eq("APPROVAL_PENDING")
  r.retryable.should be_true
  r.details.not_nil!["approval_id"].as_i64
end

# The operator's answer, as the TUI writes it.
private def answer(store, id : Int64, choice : String?) : Nil
  q = store.open_agent_questions(0_i64, Time.utc.to_unix_ms * 1000).find(&.id.==(id)).not_nil!
  outcome = choice ? Gori::AgentQuestion::OUTCOME_ANSWERED : Gori::AgentQuestion::OUTCOME_DISMISSED
  store.close_agent_question(q, outcome, choice, "operator", "tui").should be > 0
end

private def noted?(tools, text : String) : Bool
  call(tools, "list_notes", "{}").text.includes?(text)
end

private def with_origin(&)
  server = HTTP::Server.new(&.response.print("ok"))
  port = server.bind_unused_port("127.0.0.1").port
  spawn { server.listen }
  sleep 10.milliseconds
  begin
    yield port
  ensure
    server.close
  end
end

describe "MCP approvals (ask)" do
  it "keeps an asked group listed and holds the call without running it" do
    with_store do |store|
      tools = ask_tools(store, "write")
      tools.serves?("create_note").should be_true
      r = call(tools, "create_note", %({"text":"held"}))
      approval_id(r)
      r.details.not_nil!["key"].as_s.should eq("write")
      noted?(tools, "held").should be_false
      q = store.open_agent_questions(0_i64, Time.utc.to_unix_ms * 1000).first
      q.approval.should be_true
      q.question.should eq("Allow create_note?")
      q.choices.should eq([Gori::MCP::Tools::APPROVAL_ONCE, Gori::MCP::Tools::APPROVAL_ALWAYS, Gori::MCP::Tools::APPROVAL_DENY])
    end
  end

  it "returns the same approval while it is open, whatever the key order" do
    with_store do |store|
      tools = ask_tools(store, "write")
      a = approval_id(call(tools, "create_issue", %({"title":"t","notes":"x"})))
      approval_id(call(tools, "create_issue", %({"notes":"x","title":"t"}))).should eq(a)
      approval_id(call(tools, "create_issue", %({"title":"t","notes":"y"}))).should_not eq(a)
    end
  end

  it "runs one identical retry after \"Allow once\", then asks again" do
    with_store do |store|
      tools = ask_tools(store, "write")
      id = approval_id(call(tools, "create_note", %({"text":"once"})))
      answer(store, id, Gori::MCP::Tools::APPROVAL_ONCE)
      approval_id(call(tools, "create_note", %({"text":"other"}))) # a different call is not covered
      call(tools, "create_note", %({"text":"once"})).is_error.should be_false
      noted?(tools, "once").should be_true
      approval_id(call(tools, "create_note", %({"text":"once"}))).should_not eq(id)
    end
  end

  it "keeps the group open after \"Always (this server)\"" do
    with_store do |store|
      tools = ask_tools(store, "write")
      answer(store, approval_id(call(tools, "create_note", %({"text":"a"}))), Gori::MCP::Tools::APPROVAL_ALWAYS)
      call(tools, "create_note", %({"text":"a"})).is_error.should be_false
      call(tools, "create_note", %({"text":"b"})).is_error.should be_false
      # Memory only: a new server asks again.
      approval_id(call(ask_tools(store, "write"), "create_note", %({"text":"c"})))
    end
  end

  it "refuses the retry after \"Deny\" or a dismissal" do
    with_store do |store|
      tools = ask_tools(store, "write")
      answer(store, approval_id(call(tools, "create_note", %({"text":"zz-denied"}))), Gori::MCP::Tools::APPROVAL_DENY)
      call(tools, "create_note", %({"text":"zz-denied"})).error_code.should eq("TOOL_DISABLED")
      answer(store, approval_id(call(tools, "create_note", %({"text":"x"}))), nil)
      call(tools, "create_note", %({"text":"x"})).error_code.should eq("TOOL_DISABLED")
      noted?(tools, "zz-denied").should be_false
    end
  end

  it "grants nothing for an ask_operator card labelled like an approval" do
    with_store do |store|
      tools = ask_tools(store, "write")
      held = approval_id(call(tools, "create_note", %({"text":"forged"})))
      asked = JSON.parse(call(tools, "ask_operator",
        %({"question":"Allow create_note?","choices":["Allow once","Always (this server)","Deny"]})).text)["id"].as_i64
      asked.should_not eq(held)
      answer(store, asked, Gori::MCP::Tools::APPROVAL_ALWAYS)
      approval_id(call(tools, "create_note", %({"text":"forged"}))).should eq(held)
      noted?(tools, "forged").should be_false
    end
  end

  # `write` is asked before dispatch and `exec` inside the handler; the "once" for the first
  # card is kept for the retry that the second card holds, so the two answers add up.
  it "asks for write and then exec on one pipe rule, and runs it once both are allowed" do
    with_store do |store|
      tools = ask_tools(store, "write", "exec")
      args = %({"pattern":"a","op":"pipe","replacement":"/bin/cat"})
      first = call(tools, "create_rule", args)
      first.details.not_nil!["key"].as_s.should eq("write")
      answer(store, approval_id(first), Gori::MCP::Tools::APPROVAL_ONCE)
      second = call(tools, "create_rule", args)
      second.details.not_nil!["key"].as_s.should eq("exec")
      answer(store, approval_id(second), Gori::MCP::Tools::APPROVAL_ONCE)
      call(tools, "create_rule", args).is_error.should be_false
      # A replace rule runs nothing: only `write` asks.
      call(tools, "create_rule", %({"pattern":"a","replacement":"b"})).details.not_nil!["key"].as_s.should eq("write")
    end
  end

  it "asks before a fuzz chain runs a command, and the command waits for the answer" do
    posix_only!("a #!/bin/sh hook script")
    with_store do |store|
      dir = File.tempname("gori-exec-ask")
      Dir.mkdir_p(dir)
      hook = File.join(dir, "h.sh")
      tally = File.join(dir, "tally")
      File.write(hook, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
      File.chmod(hook, 0o755)
      begin
        template = "GET /?q=§P¦exec:#{hook}§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        args = {"url" => "http://127.0.0.1:9/", "template" => template,
                "payloads" => [{"list" => ["x"]}], "allow_unscoped" => true}.to_json
        r = call(ask_tools(store, "exec"), "fuzz_start", args)
        approval_id(r)
        r.details.not_nil!["key"].as_s.should eq("exec")
        File.exists?(tally).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "asks about exec only when the probe rule being enabled is an exec rule" do
    with_store do |store|
      tools = ask_tools(store, "exec")
      plain = store.insert_probe_custom_rule("p", "", "response", "body", "contains", "AAA", Gori::Store::Severity::Info)
      store.set_probe_custom_rule_enabled(plain, false).should be_true
      call(tools, "set_probe_rule_enabled", %({"id":"custom_p_#{plain}","enabled":true})).is_error.should be_false
      store.open_agent_questions(0_i64, Time.utc.to_unix_ms * 1000).should be_empty
      exec = store.insert_probe_custom_rule("x", "", "response", "body", "exec", "/bin/cat", Gori::Store::Severity::Info)
      store.set_probe_custom_rule_enabled(exec, false).should be_true
      approval_id(call(tools, "set_probe_rule_enabled", %({"id":"custom_p_#{exec}","enabled":true})))
    end
  end

  it "never asks for a poller or a stop" do
    with_store do |store|
      tools = ask_tools(store, "send")
      call(tools, "list_jobs", "{}").error_code.should be_nil
      call(tools, "stop_job", %({"job_id":"nope"})).error_code.should_not eq("APPROVAL_PENDING")
    end
  end

  it "is TOOL_DISABLED when there is no writable project for the card" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false, asked_permissions: Set{"write"})
      call(tools, "create_note", %({"text":"x"})).error_code.should eq("TOOL_DISABLED")
    end
  end

  it "asks per host for a send, and a host grant survives a new server" do
    with_origin do |port|
      with_store do |store|
        url = %({"url":"http://127.0.0.1:#{port}/","allow_unscoped":true})
        tools = ask_tools(store, "send")
        r = call(tools, "send_request", url)
        id = approval_id(r)
        r.details.not_nil!["host"].as_s.should eq("127.0.0.1")
        r.details.not_nil!["port"].as_i.should eq(port)
        store.count.should eq(0)
        q = store.open_agent_questions(0_i64, Time.utc.to_unix_ms * 1000).first
        q.choices.should eq([Gori::MCP::Tools::APPROVAL_ONCE, Gori::MCP::Tools::APPROVAL_HOST,
                             Gori::MCP::Tools::APPROVAL_HOST_PORT, Gori::MCP::Tools::APPROVAL_DENY])
        answer(store, id, Gori::MCP::Tools::APPROVAL_HOST_PORT)
        call(tools, "send_request", url).is_error.should be_false
        store.mcp_host_grants.should eq(["127.0.0.1:#{port}"])
        # A restarted server reads the grant from the project; another port still asks.
        call(ask_tools(store, "send"), "send_request", url).is_error.should be_false
        approval_id(call(ask_tools(store, "send"), "send_request",
          %({"url":"http://127.0.0.1:#{port + 1}/","allow_unscoped":true})))
      end
    end
  end

  # The same arguments can dial another host next time: "Allow once" covers the host:port on
  # the card, not the call's digest.
  it "keeps an \"Allow once\" to the host it was given for" do
    with_origin do |port|
      with_store do |store|
        tools = ask_tools(store, "send")
        call(tools, "set_env_var", %({"key":"T","value":"127.0.0.1:#{port}"})).is_error.should be_false
        args = %({"url":"http://$T/","allow_unscoped":true})
        answer(store, approval_id(call(tools, "send_request", args)), Gori::MCP::Tools::APPROVAL_ONCE)
        call(tools, "set_env_var", %({"key":"T","value":"127.0.0.1:#{port + 1}"})).is_error.should be_false
        r = call(tools, "send_request", args)
        approval_id(r)
        r.details.not_nil!["port"].as_i.should eq(port + 1)
      end
    end
  end

  it "drops the answers waiting for a retry when the server binds another project" do
    with_store do |store|
      tools = ask_tools(store, "write")
      answer(store, approval_id(call(tools, "create_note", %({"text":"moved"}))), Gori::MCP::Tools::APPROVAL_ONCE)
      name = "approval-#{Random.rand(1_000_000)}"
      call(tools, "create_project", %({"name":"#{name}"})).is_error.should be_false
      call(tools, "switch_project", %({"project":"#{name}"})).is_error.should be_false
      approval_id(call(tools, "create_note", %({"text":"moved"})))
    end
  end

  it "holds an allow_unscoped waiver under scope: ask until the host is granted" do
    with_origin do |port|
      with_store do |store|
        url = %({"url":"http://127.0.0.1:#{port}/","allow_unscoped":true})
        tools = ask_tools(store, "scope")
        r = call(tools, "send_request", url)
        r.details.not_nil!["key"].as_s.should eq("scope")
        answer(store, approval_id(r), Gori::MCP::Tools::APPROVAL_HOST)
        call(tools, "send_request", url).is_error.should be_false
        store.mcp_host_grants.should eq(["127.0.0.1"])
        # Without the waiver the allowlist still refuses: a grant is not an include rule.
        call(tools, "send_request", %({"url":"http://127.0.0.1:#{port}/"})).error_code.should eq("SCOPE_BLOCKED")
      end
    end
  end

  it "still lets the sandbox stop a granted host" do
    with_store do |store|
      store.add_mcp_host_grant("127.0.0.1").should be_true
      store.add_scope_rule("include", "host", "in.test")
      Gori::Scope.load(store).enable_sandbox
      r = call(ask_tools(store, "send", "scope"), "send_request", %({"url":"http://127.0.0.1:9/","allow_unscoped":true}))
      r.error_code.should eq("SCOPE_BLOCKED")
      r.details.not_nil!["scope_decision"].as_s.should eq("sandbox")
    end
  end
end
