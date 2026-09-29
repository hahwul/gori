require "../spec_helper"
require "../support/macro_origin"

# Request-time macros through `fuzz_start` / `mine_start` (#1350): the same spec, parsed by this
# surface, reaching the same runtime stage through the same `Plan.build`.

private def call_raw(tools, name, args) : {String, Bool}
  r = tools.call(name, JSON.parse(args.to_json))
  {r.text, r.is_error}
end

private def call_json(tools, name, args) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

private def wait_done(tools, status_tool : String, job_id : String) : JSON::Any
  300.times do
    sleep 0.02.seconds
    st = call_json(tools, status_tool, {job_id: job_id})
    return st unless st["status"].as_s == "running"
  end
  fail "#{status_tool} job #{job_id} did not finish"
end

private def fuzz_args(origin : MacroTokenOrigin, extra = {} of String => JSON::Any) : Hash(String, JSON::Any)
  base = {
    "template"       => JSON::Any.new("GET /submit?v=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: $CSRF\r\n\r\n"),
    "url"            => JSON::Any.new("http://127.0.0.1:#{origin.port}"),
    "payloads"       => JSON.parse(%([{"list":["a","b","c","d"]}])),
    "allow_unscoped" => JSON::Any.new(true),
    "keep_alive"     => JSON::Any.new(false),
    "macro_steps"    => JSON.parse(%(["csrf-fetch"])),
  }
  base.merge(extra)
end

describe "MCP request-time macro" do
  it "declares the four arguments on both tools" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
      %w[fuzz_start mine_start].each do |name|
        props = listed.find { |t| t["name"].as_s == name }.not_nil!["inputSchema"]["properties"].as_h
        %w[macro_steps macro_every macro_expect macro_on_failure].each { |k| props.has_key?(k).should be_true }
        props["macro_on_failure"]["enum"].as_a.map(&.as_s).should eq(["skip", "stop"])
      end
    end
    origin.close
  end

  it "gives every candidate a fresh token and reports what the macro did" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      started = call_json(tools, "fuzz_start", fuzz_args(origin))
      plan = started["request_macro"]
      plan["steps"].as_a.map(&.as_s).should eq(["csrf-fetch"])
      plan["cadence"].as_s.should eq("request")
      plan["on_failure"].as_s.should eq("skip")
      plan["effective_concurrency"].as_i.should eq(1)
      plan["summary"].as_s.should contain("one candidate at a time")
      done = wait_done(tools, "fuzz_status", started["job_id"].as_s)
      done["status"].as_s.should eq("done")
      done["errors"].as_i.should eq(0)
      tally = done["request_macro"]
      tally["runs"].as_i.should eq(4)
      tally["failed"].as_i.should eq(0)
      tally["requests"].as_i.should eq(4)
      tally["ended_run"].as_bool.should be_false
      origin.submits.map(&.[1]).should eq([200] * 4)
      origin.forms.should eq(4)
      # 4 candidates + 4 macro steps on the wire, both in the run's request count.
      done["sent"].as_i.should eq(4)
      done["requests"].as_i.should eq(8)
    end
    origin.close
  end

  it "accepts integer ids and a cadence given as a number" do
    origin = MacroTokenOrigin.new
    origin.max_uses = 2
    with_macro_project(origin) do |store, _, csrf|
      tools = tools_for(store)
      args = fuzz_args(origin, {"macro_steps" => JSON.parse("[#{csrf}]"), "macro_every" => JSON::Any.new(2_i64)})
      started = call_json(tools, "fuzz_start", args)
      started["request_macro"]["cadence"].as_s.should eq("2")
      wait_done(tools, "fuzz_status", started["job_id"].as_s)["status"].as_s.should eq("done")
      origin.forms.should eq(2)
      origin.submits.map(&.[1]).should eq([200] * 4)
    end
    origin.close
  end

  it "ends the job in error when the macro fails, and says why in the status" do
    origin = MacroTokenOrigin.new
    origin.form_status = 500
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      started = call_json(tools, "fuzz_start", fuzz_args(origin, {"macro_on_failure" => JSON::Any.new("stop")}))
      done = wait_done(tools, "fuzz_status", started["job_id"].as_s)
      done["status"].as_s.should eq("error")
      done["error"].as_s.should contain("stop the run on a failure")
      done["request_macro"]["failed"].as_i.should eq(1)
      done["request_macro"]["ended_run"].as_bool.should be_true
      done["request_macro"]["first_error"].as_s.should contain("the step answered 500")
      origin.submits.should be_empty
    end
    origin.close
  end

  it "refuses what the plan cannot honour, with the plan's own sentence" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      text, err = call_raw(tools, "fuzz_start", fuzz_args(origin, {"macro_steps" => JSON.parse(%(["nope"]))}))
      err.should be_true
      text.should contain("no Repeater session is named \"nope\"")
      text, err = call_raw(tools, "fuzz_start", fuzz_args(origin, {"template" => JSON::Any.new("GET /submit?v=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")}))
      err.should be_true
      text.should contain("never references it")
      text, err = call_raw(tools, "fuzz_start", fuzz_args(origin, {"race_count" => JSON::Any.new(3_i64)}))
      err.should be_true
      text.should contain("at least 3")
      origin.paths.should be_empty # nothing was sent for any of them
    end
    origin.close
  end

  it "counts the steps' requests against the run-size ceiling, before anything is sent" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      args = fuzz_args(origin, {"payloads" => JSON.parse(%([{"numbers":"1-60000"}]))})
      text, err = call_raw(tools, "fuzz_start", args)
      err.should be_true
      text.should contain("too many requests (120000 > 100000)")
      origin.paths.should be_empty
    end
    origin.close
  end

  it "refuses a companion argument with no steps, and a value it cannot read" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      args = fuzz_args(origin, {"macro_steps" => JSON.parse("[]"), "macro_every" => JSON::Any.new("5")})
      text, err = call_raw(tools, "fuzz_start", args)
      err.should be_true
      text.should contain("modifies macro_steps")
      # …but a schema-filling client's blanks are absence, not a companion.
      blank = fuzz_args(origin, {"macro_steps" => JSON.parse("[]"), "macro_every" => JSON::Any.new(""),
                                 "macro_on_failure" => JSON::Any.new(""), "macro_expect" => JSON.parse("[]"),
                                 "template" => JSON::Any.new("GET /submit?v=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")})
      started = call_json(tools, "fuzz_start", blank)
      started["request_macro"]?.should be_nil
      text, err = call_raw(tools, "fuzz_start", fuzz_args(origin, {"macro_every" => JSON::Any.new("sometimes")}))
      err.should be_true
      text.should contain("invalid macro_every")
      _, err = call_raw(tools, "fuzz_start", fuzz_args(origin, {"macro_steps" => JSON.parse(%([{"a":1}]))}))
      err.should be_true
    end
    origin.close
  end

  it "reaches the miner too, one request at a time" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      tools = tools_for(store)
      started = call_json(tools, "mine_start", {
        "template"       => "GET /submit?a=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: $CSRF\r\n\r\n",
        "url"            => "http://127.0.0.1:#{origin.port}",
        "locations"      => "query",
        "max_requests"   => 30,
        "keep_alive"     => false,
        "allow_unscoped" => true,
        "macro_steps"    => ["csrf-fetch"],
      })
      started["request_macro"]["effective_concurrency"].as_i.should eq(1)
      done = wait_done(tools, "mine_status", started["job_id"].as_s)
      done["error"]?.try(&.as_s?).should be_nil
      done["request_macro"]["failed"].as_i.should eq(0)
      done["request_macro"]["runs"].as_i.should be > 3
      origin.submits.map(&.[1]).uniq!.should eq([200])
      origin.forms.should eq(origin.submits.size)
    end
    origin.close
  end
end
