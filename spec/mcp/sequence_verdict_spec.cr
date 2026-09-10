require "../spec_helper"
require "socket"

# What a sequence job tells an agent ABOUT ITS OWN VERDICT.
#
# `sequence_results` renders a `Stats::Report`, and a report over nothing is not blank — it is
# `rating: "CRITICAL", rationale: "no usable tokens"`. That sentence is indistinguishable from
# a real finding unless the job also says why it has no tokens, and the three facts that answer
# it were all computed and then dropped on the MCP side:
#
#   * the engine's `first_error` (the raw samples carry the per-send reason and are never
#     returned — they are secrets — so this was the only surviving copy),
#   * `:budget_exhausted`, the shared terminal status fuzz/mine/discover already report, for a
#     run that ended UNDER its goal because the request budget ran out,
#   * `requests`, the real wire count `max_requests` and this server's ceiling are enforced
#     against (`sent` counts collection attempts, and a retry charges only the former).
private def seq_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  n = 0
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      n += 1
      body = "ok"
      conn << "HTTP/1.1 200 OK\r\nSet-Cookie: SID=#{"%08x" % (n &* 2_654_435_761)}; Path=/\r\n" \
              "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
      conn.flush
      conn.close
    end
  end
  port
end

# A port nothing is listening on: bound to learn the number, then released.
private def dead_port : Int32
  s = TCPServer.new("127.0.0.1", 0)
  port = s.local_address.port
  s.close
  port
end

private def seq_call(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seq_wait(tools, job_id : String) : JSON::Any
  400.times do
    sleep 0.02.seconds
    st = seq_call(tools, "sequence_status", {job_id: job_id}.to_json)
    return st unless st["status"].as_s == "running"
  end
  fail "sequence job #{job_id} did not reach a terminal state"
end

describe "MCP sequence job verdict honesty" do
  it "names the failure when every replay was refused, instead of grading nothing CRITICAL" do
    with_store do |store|
      tools = tools_for(store)
      port = dead_port
      job_id = seq_call(tools, "sequence_start", {
        template:       "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        cookie:         "SID",
        count:          2,
        retries:        0,
        allow_unscoped: true,
      }.to_json)["job_id"].as_s

      status = seq_wait(tools, job_id)
      status["collected"].as_i.should eq(0)
      status["status"].as_s.should eq("error")
      status["error"].as_s.should start_with("every replay failed — ")
      # The count that decided that branch comes from the ENGINE, not from the last
      # `ProgressEvent` (droppable, and never emitted at all for a raised sample) — see
      # `spec/sequencer/engine_spec.cr`. Reported to the caller, so `errors: 0` can no longer
      # sit next to an "every replay failed" reason.
      status["errors"].as_i.should eq(status["sent"].as_i)
      status["errors"].as_i.should be > 0

      results = seq_call(tools, "sequence_results", {job_id: job_id}.to_json)
      # The report still reads CRITICAL — it is honest about the sample it has — so the
      # reason has to sit beside it in the SAME payload, or `sequence_results` alone still
      # reads as a finding about the target.
      results["report"]["rating"].as_s.should eq("CRITICAL")
      results["report"]["rationale"].as_s.should eq("no usable tokens")
      results["error"].as_s.should start_with("every replay failed — ")
      results["status"].as_s.should eq("error")
    end
  end

  it "does not blame the target when the responses arrived and the descriptor missed" do
    # The other way to reach an empty sample: the origin answered every replay and the cookie
    # name is simply wrong. `note_all_refused` decides on the COUNTS for this reason — with no
    # send error there is nothing to report, and were one flaky timeout to appear among the
    # four, calling that "every replay failed" and relabelling the job :error would point an
    # agent at the target when the answer is the descriptor.
    with_store do |store|
      tools = tools_for(store)
      port = seq_origin
      job_id = seq_call(tools, "sequence_start", {
        template:       "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        cookie:         "NOT_THE_COOKIE",
        count:          50,
        max_requests:   4,
        retries:        0,
        allow_unscoped: true,
      }.to_json)["job_id"].as_s
      seq_wait(tools, job_id)
      status = seq_call(tools, "sequence_status", {job_id: job_id}.to_json)
      status["sent"].as_i.should eq(4)   # every replay answered
      status["errors"].as_i.should eq(0) # and none of them failed
      status["status"].as_s.should eq("budget_exhausted")
      status["error"].raw.should be_nil
    end
  end

  it "reports :budget_exhausted for a run that ended under its goal, not a plain done" do
    with_store do |store|
      tools = tools_for(store)
      port = seq_origin
      job_id = seq_call(tools, "sequence_start", {
        # A descriptor that matches nothing the origin sends: every sample misses, so the
        # dispatcher spends the budget and stops short of the goal with no send error at all
        # (`first_error` stays nil — this is not the all-refused case above).
        template:       "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        cookie:         "NOT_THE_COOKIE",
        count:          50,
        max_requests:   4,
        retries:        0,
        allow_unscoped: true,
      }.to_json)["job_id"].as_s

      status = seq_wait(tools, job_id)
      status["status"].as_s.should eq("budget_exhausted")
      status["collected"].as_i.should eq(0)
      status["goal"].as_i.should eq(50)
      status["error"].raw.should be_nil # a budget is not a failure
      seq_call(tools, "sequence_results", {job_id: job_id}.to_json)["goal"].as_i.should eq(50)
    end
  end

  it "publishes the wire request count a full collection put on the target" do
    with_store do |store|
      tools = tools_for(store)
      port = seq_origin
      job_id = seq_call(tools, "sequence_start", {
        template:       "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        cookie:         "SID",
        count:          3,
        retries:        0,
        allow_unscoped: true,
      }.to_json)["job_id"].as_s

      status = seq_wait(tools, job_id)
      status["status"].as_s.should eq("done")
      status["collected"].as_i.should eq(3)
      # Attempts vs the wire: equal with no retries, and never fewer than the attempts.
      status["requests"].as_i.should be >= status["sent"].as_i
      status["requests"].as_i.should eq(3)
    end
  end
end
