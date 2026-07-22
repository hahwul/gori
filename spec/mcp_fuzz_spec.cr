require "./spec_helper"
require "socket"

# The MCP fuzz tools run the engine in a background fiber, so they're driven here
# through a Tools instance directly (with sleeps that yield to the job fiber)
# against a local origin — the IO::Memory server harness never yields between
# scripted lines, so a polled async job can't progress there.

private def with_store(&)
  path = File.tempname("gori-mcpfuzz", ".db")
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

# Raw {text, is_error} — error tools return a plain message, not JSON.
private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

# Parsed JSON for a successful call (fails loudly if the tool errored).
private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

describe "MCP fuzz tools" do
  it "starts a job, polls to completion, returns matched results" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      args = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => %([{"list":["a","b","c"]}]),
        "allow_unscoped" => true,
      }.to_json

      start = call_json(tools, "fuzz_start", args)
      job_id = start["job_id"].as_s
      start["total"].as_i.should eq(3)

      done = false
      30.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        status["status"].as_s.should eq("done")
        status["sent"].as_i.should eq(3)
        status["matched"].as_i.should eq(3)
        done = true
        break
      end
      done.should be_true

      results = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))
      results["results"].as_a.size.should eq(3)
      results["results"][0]["status"].as_i.should eq(200)
      results["job_complete"].as_bool.should be_true
    end
  end

  it "accepts payloads as a JSON array (not only a JSON string)" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      args = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => [{"list" => ["only"]}],
        "allow_unscoped" => true,
      }.to_json
      start = call_json(tools, "fuzz_start", args)
      start["total"].as_i.should eq(1)
    end
  end

  it "accepts structured object payload sets for numbers and brute" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "allow_unscoped" => true,
      }
      # numbers {from,to,step} == the "1-100:2" string form (50 candidates).
      nums = call_json(tools, "fuzz_start",
        base.merge({"payloads" => [{"numbers" => {"from" => 1, "to" => 100, "step" => 2}}]}).to_json)
      nums["total"].as_i.should eq(50)
      # brute {charset,min,max} == the "ab:1-2" string form (2 + 4 = 6 candidates).
      brute = call_json(tools, "fuzz_start",
        base.merge({"payloads" => [{"brute" => {"charset" => "ab", "min" => 1, "max" => 2}}]}).to_json)
      brute["total"].as_i.should eq(6)
      # A malformed object fails cleanly (is_error), not a generic "tool error".
      _, bad = call_raw(tools, "fuzz_start",
        base.merge({"payloads" => %([{"numbers":{"to":100}}])}).to_json)
      bad.should be_true
    end
  end

  # Splicing is byte-exact by design (Burp/ffuf-style: what you type between §…§ is
  # what's sent) — but unlike the CLI's `gori run fuzz --encode=url`, fuzz_start had NO
  # way at all to opt in to encoding, so a payload with a space/quote (most SQLi/XSS)
  # silently corrupted the request line instead of reaching the app. `processors`
  # closes that gap; this pins it down at the wire level via the recorded flow's
  # actual request_head, the same way the bug was originally found.
  it "processors:[encode:url] percent-encodes a payload before it's spliced in" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list":["a b"]}]),
         "processors"     => %([{"type":"encode","kind":"url"}]),
         "record_history" => "all",
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s

      done = false
      30.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        done = true
        break
      end
      done.should be_true

      results = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))
      fid = results["results"][0]["flow_id"].as_i64
      flow = call_json(tools, "get_flow", %({"id":#{fid}}))
      # Encoded: a well-formed request line the origin actually receives as one field.
      flow["request_head"].as_s.should contain("GET /?q=a%20b HTTP/1.1")
      flow["request_head"].as_s.should_not contain("GET /?q=a b HTTP/1.1")
    end
  end

  it "rejects an unknown or malformed processor spec cleanly" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {"template" => "GET /?q=§x§ HTTP/1.1\r\n\r\n", "url" => "http://127.0.0.1:1",
              "payloads" => %([{"list":["a"]}]), "allow_unscoped" => true}

      _, unknown_type = call_raw(tools, "fuzz_start", base.merge({"processors" => %([{"type":"gzip"}])}).to_json)
      unknown_type.should be_true

      _, bad_kind = call_raw(tools, "fuzz_start", base.merge({"processors" => %([{"type":"encode","kind":"rot13"}])}).to_json)
      bad_kind.should be_true
    end
  end

  it "rejects a processor's text/pattern given as JSON null or a non-string value" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {"template" => "GET /?q=§x§ HTTP/1.1\r\n\r\n", "url" => "http://127.0.0.1:1",
              "payloads" => %([{"list":["a"]}]), "allow_unscoped" => true}

      # A JSON `null` must NOT silently become an empty-string prefix — `jstr`'s
      # `v.to_s` fallback turns `nil` into `""`, which is truthy in Crystal and used to
      # slip straight past a `jstr(...) || raise` guard.
      _, null_text = call_raw(tools, "fuzz_start",
        base.merge({"processors" => %([{"type":"prefix","text":null}])}).to_json)
      null_text.should be_true

      # A JSON array for `pattern` must NOT stringify into something that can itself
      # compile as a regex (e.g. `["id","="]`.to_s is a non-empty, technically-valid
      # regex source) and silently pass the emptiness guard.
      _, array_pattern = call_raw(tools, "fuzz_start",
        base.merge({"processors" => %([{"type":"regex_replace","pattern":["id","="]}])}).to_json)
      array_pattern.should be_true
    end
  end

  it "matches a processor's type case-insensitively, same as kind/algo" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list":["a b"]}]),
         "processors"     => %([{"type":"ENCODE","kind":"URL"}]),
         "record_history" => "all",
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s

      done = false
      30.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        done = true
        break
      end
      done.should be_true

      results = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))
      fid = results["results"][0]["flow_id"].as_i64
      flow = call_json(tools, "get_flow", %({"id":#{fid}}))
      flow["request_head"].as_s.should contain("GET /?q=a%20b HTTP/1.1")
    end
  end

  it "rejects bad args, and gates the tool under --read-only" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      _, no_payloads = call_raw(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\n\r\n", "url" => "http://127.0.0.1:1"}.to_json)
      no_payloads.should be_true

      _, no_positions = call_raw(tools, "fuzz_start",
        {"template" => "GET / HTTP/1.1\r\n\r\n", "url" => "http://127.0.0.1:1", "payloads" => %([{"list":["a"]}])}.to_json)
      no_positions.should be_true

      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      _, gated = call_raw(ro, "fuzz_start", %({"template":"x"}))
      gated.should be_true
    end
  end

  it "rejects a request count over the hard cap" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      _, capped = call_raw(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\n\r\n", "url" => "http://127.0.0.1:1",
         "payloads" => %([{"numbers":"1-200000"}]), "allow_unscoped" => true}.to_json)
      capped.should be_true
    end
  end

  it "blocks fuzz_start when the origin host is out of the configured scope" do
    with_store do |store|
      store.add_scope_rule("include", "host", "example.com")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      text, err = call_raw(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
         "payloads" => %([{"list":["a"]}])}.to_json)
      err.should be_true
      text.should contain("outside the project's configured scope")
    end
  end

  it "runs fuzz_start when the origin host is in the configured scope" do
    port = start_origin
    with_store do |store|
      store.add_scope_rule("include", "host", "127.0.0.1")
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:#{port}",
         "payloads" => %([{"list":["a"]}])}.to_json)
      start["scope_decision"].as_s.should eq("in_scope")
    end
  end

  it "lists jobs, gets one by id, and stop_job(wait:true) converges to terminal" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url" => "http://127.0.0.1:#{port}",
         "payloads" => %([{"numbers":"1-500"}]),
         "rate" => 50, "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s

      jobs = call_json(tools, "list_jobs", "{}")["jobs"].as_a
      jobs.any? { |jj| jj["job_id"].as_s == job_id && jj["kind"].as_s == "fuzz" }.should be_true
      call_json(tools, "get_job", %({"job_id":#{job_id.to_json}}))["job_id"].as_s.should eq(job_id)

      stopped = call_json(tools, "stop_job", %({"job_id":#{job_id.to_json},"wait":true,"wait_timeout_ms":5000}))
      stopped["stopped"].as_bool.should be_true
      stopped["status"].as_s.should_not eq("running")
      stopped["stop_requested_at"].as_i64.should be > 0
    end
  end

  it "always reaches a terminal state (never stuck :running) against a dead origin" do
    # Bind then release a port so every connect is refused deterministically — the
    # run_fuzz_job fiber must still land the job terminal (finalize_job guarantee),
    # never leaving a poller to spin on :running forever.
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.local_address.port
    probe.close
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list":["a","b"]}]),
         "retries"        => 0,
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s

      terminal = nil.as(JSON::Any?)
      100.times do
        sleep 0.02.seconds
        st = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if st["status"].as_s == "running"
        terminal = st
        break
      end
      terminal.should_not be_nil
      t = terminal.not_nil!
      t["job_complete"].as_bool.should be_true
      # finalize_job always stamps an end time on a terminal job (emitted in audit).
      t["audit"]["ended_at"].raw.should_not be_nil
    end
  end

  it "records matched results to History with a redacted flow_id when record_history:matched" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer sekret\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list":["a","b"]}]),
         "match"          => {"status" => "200"},
         "record_history" => "matched",
         "allow_unscoped" => true}.to_json)
      start["record_history"].as_s.should eq("matched")
      job_id = start["job_id"].as_s

      done = false
      60.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        status["recorded_flows"].as_i.should be > 0
        status["audit"]["target"].as_s.should contain("127.0.0.1")
        done = true
        break
      end
      done.should be_true

      results = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))
      fid = results["results"][0]["flow_id"].as_i64
      fid.should be > 0
      # The recorded flow is a real History flow; get_flow redacts its auth header.
      flow = call_json(tools, "get_flow", %({"id":#{fid}}))
      flow["request_head"].as_s.should contain("Authorization: [REDACTED]")
      flow["request_head"].as_s.should_not contain("sekret")
    end
  end

  it "ends budget_exhausted (not done) when max_requests halts before all candidates" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url" => "http://127.0.0.1:#{port}",
         "payloads" => %([{"list":["a","b","c","d","e"]}]),
         "max_requests" => 2, "allow_unscoped" => true}.to_json)
      start["total"].as_i.should eq(5)
      start["budget_warning"].as_s.should contain("below the 5 candidate total")
      job_id = start["job_id"].as_s

      done = false
      60.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        status["status"].as_s.should eq("budget_exhausted")
        status["incomplete_reason"].as_s.should eq("budget_exhausted")
        status["sent"].as_i.should be < 5
        status["candidates_remaining"].as_i.should be > 0
        done = true
        break
      end
      done.should be_true
    end
  end
end
