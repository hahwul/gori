require "../spec_helper"
require "../support/mcp_harness"

# Issue-linked retest over MCP (#1036). An agent that confirms a finding leaves behind the
# ordered check rather than prose, and `run_retest` is what answers "is it still there" for
# the next one. These examples pin the reads and the refusals — not the sends, which need a
# socket (`spec/retest_spec.cr` drives the engine through a fake backend).

private def retest_repeater(store, name : String, request : String) : Int64
  id = store.insert_repeater("https://acme.test", request.to_slice, false, true, nil,
    store.next_repeater_position)
  store.set_repeater_name(id, name)
  id
end

private def retest_issue(store) : Int64
  store.insert_issue("broken access control", Gori::Store::Severity::High, "acme.test", nil)
end

describe "MCP issue retest" do
  it "adds a step, resolves what it will SEND, and reads it back in order" do
    with_store do |store|
      iid = retest_issue(store)
      login = retest_repeater(store, "login", "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      target = retest_repeater(store, "victim order", "GET /orders/7 HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)

      a = mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{login},"role":"setup"}))
      a["added"].as_bool.should be_true
      a["position"].as_i.should eq(1)
      a["method"].as_s.should eq("POST")
      a["state_changing"].as_bool.should be_true

      b = mcp_ok_json(tools, "add_retest_step",
        %({"issue_id":#{iid},"repeater_id":#{target},"role":"variant","assertion":"status:403"}))
      b["position"].as_i.should eq(2)
      b["expected"].as_s.should eq("status 403")

      listed = mcp_ok_json(tools, "list_retest_steps", %({"issue_id":#{iid}}))
      listed["total"].as_i.should eq(2)
      listed["state_changing"].as_i.should eq(1)
      listed["steps"][0]["role"].as_s.should eq("setup")
      listed["steps"][1]["url"].as_s.should eq("https://acme.test/orders/7")
      listed["steps"][1]["label"].as_s.should eq("victim order")
      # The sentence a confirm has to show, so a caller never derives the counts itself.
      listed["confirm_note"].as_s.should contain("1 of them state-changing (POST)")
      listed["last_run"]?.should be_nil
    end
  end

  it "refuses an assertion the parser cannot read, and stores nothing" do
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "r", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      r = tools.call("add_retest_step",
        JSON.parse(%({"issue_id":#{iid},"repeater_id":#{rid},"assertion":"status:999"})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
      r.text.should contain("100-599")
      store.count_retest_steps(iid).should eq(0)
    end
  end

  it "refuses an unknown role by naming every accepted one" do
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "r", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      r = tools_for(store).call("add_retest_step",
        JSON.parse(%({"issue_id":#{iid},"repeater_id":#{rid},"role":"probe"})))
      r.is_error.should be_true
      r.text.should contain("baseline")
      r.text.should contain("cleanup")
    end
  end

  it "reports a missing issue or repeater rather than filing a dangling step" do
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "r", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      tools.call("add_retest_step", JSON.parse(%({"issue_id":9999,"repeater_id":#{rid}}))).error_code.should eq("NOT_FOUND")
      tools.call("add_retest_step", JSON.parse(%({"issue_id":#{iid},"repeater_id":9999}))).error_code.should eq("NOT_FOUND")
    end
  end

  it "edits, moves and removes a step, keeping positions 1..N" do
    with_store do |store|
      iid = retest_issue(store)
      ids = Array.new(3) { |i| retest_repeater(store, "r#{i}", "GET /#{i} HTTP/1.1\r\nHost: acme.test\r\n\r\n") }
      tools = tools_for(store)
      step_ids = ids.map { |rid| mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{rid}}))["id"].as_i64 }

      edited = mcp_ok_json(tools, "update_retest_step",
        %({"id":#{step_ids[0]},"role":"baseline","assertion":"status:2xx"}))
      edited["role"].as_s.should eq("baseline")
      edited["assertion"].as_s.should eq("status:2xx")

      mcp_ok_json(tools, "move_retest_step", %({"id":#{step_ids[2]},"position":1}))["position"].as_i.should eq(1)
      store.retest_steps(iid).map(&.id).should eq([step_ids[2], step_ids[0], step_ids[1]])

      removed = mcp_ok_json(tools, "remove_retest_step", %({"id":#{step_ids[0]}}))
      removed["removed"].as_bool.should be_true
      store.retest_steps(iid).map(&.position).should eq([1, 2])
    end
  end

  it "clamps an absurd move position instead of raising out of the tool" do
    # `Int64#to_i` past `Int32::MAX` is an OverflowError — a crash, not a refusal, for an
    # argument whose only meaning is "as far as it goes".
    with_store do |store|
      iid = retest_issue(store)
      ids = Array.new(3) { |i| retest_repeater(store, "r#{i}", "GET /#{i} HTTP/1.1\r\nHost: acme.test\r\n\r\n") }
      tools = tools_for(store)
      step_ids = ids.map { |rid| mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{rid}}))["id"].as_i64 }
      mcp_ok_json(tools, "move_retest_step", %({"id":#{step_ids[0]},"position":99999999999}))["position"].as_i.should eq(3)
      mcp_ok_json(tools, "move_retest_step", %({"id":#{step_ids[0]},"position":-5}))["position"].as_i.should eq(1)
    end
  end

  it "refuses an update that changes nothing rather than reporting a write that never happened" do
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "r", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      id = mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{rid}}))["id"].as_i64
      r = tools.call("update_retest_step", JSON.parse(%({"id":#{id}})))
      r.is_error.should be_true
      r.error_code.should eq("INVALID_ARGUMENT")
    end
  end

  it "REFUSES a run whose batch changes state until confirm:true, and sends nothing" do
    # The rule the issue names: before a batch containing a state-changing method, show the
    # exact request count and require the same confirmation the other active tools use.
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "delete order", "DELETE /orders/7 HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{rid},"assertion":"status:204"}))
      r = tools.call("run_retest", JSON.parse(%({"issue_id":#{iid}})))
      r.is_error.should be_true
      r.error_code.should eq("CONFIRM_REQUIRED")
      r.text.should contain("DELETE")
      # Nothing left, and no run was recorded for a batch that never went out.
      store.retest_runs(iid).should be_empty
      store.count?.should eq(0)
    end
  end

  it "reports an issue with no steps rather than recording an empty run that 'passed'" do
    with_store do |store|
      iid = retest_issue(store)
      r = tools_for(store).call("run_retest", JSON.parse(%({"issue_id":#{iid}})))
      r.is_error.should be_true
      r.error_code.should eq("NOT_FOUND")
      r.text.should contain("add_retest_step")
      store.retest_runs(iid).should be_empty
    end
  end

  it "lists the bounded run history and one run's result table" do
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "victim order", "GET /orders/7 HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      sid = mcp_ok_json(tools, "add_retest_step",
        %({"issue_id":#{iid},"repeater_id":#{rid},"role":"variant","assertion":"status:403"}))["id"].as_i64
      step = store.get_retest_step(sid).not_nil!
      planned = Gori::Retest::Planned.new(step, "GET", "https://acme.test/orders/7", "victim order")
      row = Gori::Retest::StepResult.new(planned, Gori::Store::RetestOutcome::Fail,
        "status 200, expected 403",
        Gori::Retest::Observation.new(status: 200, duration_us: 900_i64, bytes: 120_i64, flow_id: 5_i64))
      run_id, _ = store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Fail,
        Gori::Retest.tally([row]), [row], surface: "mcp")

      runs = mcp_ok_json(tools, "list_retest_runs", %({"issue_id":#{iid}}))
      runs["total"].as_i.should eq(1)
      runs["kept"].as_i.should eq(Gori::Retest::RUN_HISTORY)
      runs["runs"][0]["verdict"].as_s.should eq("fail")
      runs["runs"][0]["failed"].as_i.should eq(1)

      one = mcp_ok_json(tools, "get_retest_run", %({"run_id":#{run_id}}))
      one["verdict"].as_s.should eq("fail")
      one["steps"][0]["assertion"].as_s.should eq("status:403")
      one["steps"][0]["detail"].as_s.should eq("status 200, expected 403")
      # The recorded History row this step's send wrote — how an old result opens the exact
      # response it reported.
      one["steps"][0]["flow_id"].as_i64.should eq(5_i64)

      # …and the step listing now names the last run beside the plan.
      mcp_ok_json(tools, "list_retest_steps", %({"issue_id":#{iid}}))["last_run"]["verdict"].as_s.should eq("fail")
    end
  end

  it "names the retest on get_issue — and says nothing at all on an issue without one" do
    # The state an agent needs to decide what to do next with a finding it just read. Omitted
    # rather than reported as `0`, the same rule the Issue detail's one-line summary follows.
    with_store do |store|
      iid = retest_issue(store)
      plain = store.insert_issue("no check here", Gori::Store::Severity::Low, nil, nil)
      rid = retest_repeater(store, "victim order", "GET /orders/7 HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      mcp_ok_json(tools, "get_issue", %({"id":#{iid}}))["retest"]?.should be_nil

      sid = mcp_ok_json(tools, "add_retest_step",
        %({"issue_id":#{iid},"repeater_id":#{rid},"assertion":"status:403"}))["id"].as_i64
      seen = mcp_ok_json(tools, "get_issue", %({"id":#{iid}}))["retest"]
      seen["steps"].as_i.should eq(1)
      seen["last_run"]?.should be_nil

      step = store.get_retest_step(sid).not_nil!
      row = Gori::Retest::StepResult.new(
        Gori::Retest::Planned.new(step, "GET", "https://acme.test/orders/7", "victim order"),
        Gori::Store::RetestOutcome::Pass, "403", Gori::Retest::Observation.new(status: 403))
      store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest.tally([row]), [row], surface: "mcp")
      after = mcp_ok_json(tools, "get_issue", %({"id":#{iid}}))["retest"]
      after["last_run"]["verdict"].as_s.should eq("pass")
      mcp_ok_json(tools, "get_issue", %({"id":#{plain}}))["retest"]?.should be_nil
      # …and NOT on the listing. It costs two per-row store reads and `list_issues` pages up
      # to 500 issues through the same serializer, whose per-row `links`/`evidence` work is
      # already why that path is slow. An agent that wants a row's check asks for it.
      listed = mcp_ok_json(tools, "list_issues", %({}))["issues"].as_a
      listed.each(&.["retest"]?.should(be_nil))
    end
  end

  it "clears an issue's steps and forgets one run — the CLI's `clear` and `forget`" do
    # Without these an agent can record a run at the wrong target and has no way to drop it,
    # while `get_issue`'s retest object keeps advertising that verdict as the last answer.
    with_store do |store|
      iid = retest_issue(store)
      rid = retest_repeater(store, "r", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n")
      tools = tools_for(store)
      sid = mcp_ok_json(tools, "add_retest_step", %({"issue_id":#{iid},"repeater_id":#{rid}}))["id"].as_i64
      step = store.get_retest_step(sid).not_nil!
      row = Gori::Retest::StepResult.new(
        Gori::Retest::Planned.new(step, "GET", "https://acme.test/", "r"),
        Gori::Store::RetestOutcome::Pass, "200", Gori::Retest::Observation.new(status: 200))
      run_id, _ = store.record_retest_run(iid, 1_i64, 2_i64, Gori::Store::RetestVerdict::Pass,
        Gori::Retest.tally([row]), [row], surface: "mcp")

      gone = mcp_ok_json(tools, "delete_retest_run", %({"run_id":#{run_id}}))
      gone["deleted"].as_bool.should be_true
      store.retest_runs(iid).should be_empty
      store.count_retest_steps(iid).should eq(1) # the steps that produced it stay

      cleared = mcp_ok_json(tools, "clear_retest_steps", %({"issue_id":#{iid}}))
      cleared["steps"].as_i.should eq(1)
      store.count_retest_steps(iid).should eq(0)
      # …and an issue with nothing to clear is reported, not silently "cleared".
      tools.call("clear_retest_steps", JSON.parse(%({"issue_id":#{iid}}))).error_code.should eq("NOT_FOUND")
    end
  end

  it "keeps every write behind --read-only while the reads stay open" do
    with_store do |store|
      iid = retest_issue(store)
      ro = tools_for(store, allow_actions: false)
      %w[add_retest_step update_retest_step move_retest_step remove_retest_step run_retest
        clear_retest_steps delete_retest_run].each do |name|
        ro.call(name, JSON.parse(%({"issue_id":#{iid},"id":1,"repeater_id":1,"position":1,"run_id":1}))).error_code.should eq("TOOL_DISABLED")
      end
      ro.call("list_retest_steps", JSON.parse(%({"issue_id":#{iid}}))).error_code.should_not eq("TOOL_DISABLED")
      ro.call("list_retest_runs", JSON.parse(%({"issue_id":#{iid}}))).error_code.should_not eq("TOOL_DISABLED")
    end
  end

  it "advertises the write tools only when actions are allowed" do
    with_store do |store|
      names = ->(allow : Bool) do
        mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/list"}),
          allow_actions: allow)[0]["result"]["tools"].as_a.map(&.["name"].as_s)
      end
      read_only = names.call(false)
      read_only.should contain("list_retest_steps")
      read_only.should contain("get_retest_run")
      read_only.should_not contain("run_retest")
      read_only.should_not contain("delete_retest_run")
      names.call(true).should contain("run_retest")
      names.call(true).should contain("clear_retest_steps")
      names.call(true).should contain("delete_retest_run")
    end
  end
end
