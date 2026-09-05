require "../spec_helper"
require "socket"

# Two contracts the async job tools owe an agent.
#
# 1. A `*_stop` reply must say what state the job is ACTUALLY in. The five per-kind stop
#    tools used to hard-code `status: "stopping"` without reading the job back, so a run that
#    had already reached `done` / `budget_exhausted` answered "stopping" — a state it is not
#    in and will never enter. An agent reads that as "I aborted a run that was in flight" and
#    reports a complete run as cancelled. `stop_job` always re-read the status; all six now
#    share `stop_and_report` / `emit_stop_result`.
#
# 2. A clamped `limit`/`offset` must be reported. `emit_clamp` is the shared pagination
#    contract; six object-returning paginated tools skipped it and did not even echo `limit`,
#    so an agent that computed `limit` down to 0 got one row back and no signal.

private def start_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      body = "ok"
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
      conn.flush
      conn.close
    end
  end
  port
end

private def call_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# Poll `<kind>_status` until the job leaves `running`, and return its terminal status.
private def wait_terminal(tools, kind : String, job_id : String) : String
  400.times do
    sleep 0.02.seconds
    status = call_json(tools, "#{kind}_status", {job_id: job_id}.to_json)["status"].as_s
    return status unless status == "running"
  end
  fail "#{kind} job #{job_id} did not reach a terminal state"
end

private def start_fuzz(tools, port : Int32) : String
  call_json(tools, "fuzz_start", {
    template:       "GET /f?q=§FUZZ§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
    url:            "http://127.0.0.1:#{port}",
    payloads:       [{list: ["a", "b", "c"]}],
    save_results:   true,
    allow_unscoped: true,
  }.to_json)["job_id"].as_s
end

describe "MCP per-kind job stop" do
  it "reports the job's real terminal status instead of a hard-coded \"stopping\"" do
    with_store do |store|
      port = start_origin
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      job_id = start_fuzz(tools, port)
      terminal = wait_terminal(tools, "fuzz", job_id)
      terminal.should eq("done")

      stop = call_json(tools, "fuzz_stop", {job_id: job_id}.to_json)
      stop["status"].as_s.should eq(terminal)
      stop["status"].as_s.should_not eq("stopping")
      stop["stopped"].as_bool.should be_true
      stop["stop_requested"].as_bool.should be_true
      stop["job_id"].as_s.should eq(job_id)
    end
  end

  it "answers a finished job the same way the unified stop_job does" do
    with_store do |store|
      port = start_origin
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      a = start_fuzz(tools, port)
      b = start_fuzz(tools, port)
      wait_terminal(tools, "fuzz", a)
      wait_terminal(tools, "fuzz", b)

      per_kind = call_json(tools, "fuzz_stop", {job_id: a}.to_json)
      unified = call_json(tools, "stop_job", {job_id: b}.to_json)
      %w(status stopped stop_requested).each do |field|
        per_kind[field].should eq(unified[field])
      end
    end
  end

  it "sequence_stop reports its real status too (the same shared emitter)" do
    with_store do |store|
      port = start_origin
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      job_id = call_json(tools, "sequence_start", {
        template:       "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        regex:          "(ok)",
        count:          2,
        allow_unscoped: true,
      }.to_json)["job_id"].as_s
      terminal = wait_terminal(tools, "sequence", job_id)

      stop = call_json(tools, "sequence_stop", {job_id: job_id}.to_json)
      stop["status"].as_s.should eq(terminal)
      stop["status"].as_s.should_not eq("stopping")
    end
  end
end

describe "MCP job-results pagination clamp" do
  it "reports a clamped limit on fuzz_results, list_fuzz_runs and get_fuzz_run" do
    with_store do |store|
      port = start_origin
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      job_id = start_fuzz(tools, port)
      wait_terminal(tools, "fuzz", job_id)
      run_id = call_json(tools, "fuzz_results", {job_id: job_id}.to_json)["run_id"].as_i64

      {
        "fuzz_results"   => {job_id: job_id, limit: -1, offset: -1}.to_json,
        "list_fuzz_runs" => {limit: -1, offset: -1}.to_json,
        "get_fuzz_run"   => {run_id: run_id, limit: -1, offset: -1}.to_json,
      }.each do |tool, args|
        res = call_json(tools, tool, args)
        res["limit"].as_i.should eq(1)
        res["requested_limit"].as_i.should eq(-1)
        res["requested_offset"].as_i.should eq(-1)
        res["pagination_warning"].as_s.should contain("clamped")
      end
    end
  end

  it "stays quiet when the pagination arguments were honoured" do
    with_store do |store|
      port = start_origin
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      job_id = start_fuzz(tools, port)
      wait_terminal(tools, "fuzz", job_id)

      res = call_json(tools, "fuzz_results", {job_id: job_id, limit: 2, offset: 1}.to_json)
      res["limit"].as_i.should eq(2)
      res["offset"].as_i.should eq(1)
      res.as_h.has_key?("requested_limit").should be_false
      res.as_h.has_key?("requested_offset").should be_false
      res.as_h.has_key?("pagination_warning").should be_false
    end
  end
end
