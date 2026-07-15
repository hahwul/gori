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
        "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"      => "http://127.0.0.1:#{port}",
        "payloads" => %([{"list":["a","b","c"]}]),
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
      results["complete"].as_bool.should be_true
    end
  end

  it "accepts payloads as a JSON array (not only a JSON string)" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      args = {
        "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"      => "http://127.0.0.1:#{port}",
        "payloads" => [{"list" => ["only"]}],
      }.to_json
      start = call_json(tools, "fuzz_start", args)
      start["total"].as_i.should eq(1)
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
         "payloads" => %([{"numbers":"1-200000"}])}.to_json)
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
      text.should contain("out of the project's configured scope")
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

  it "ends budget_exhausted (not done) when max_requests halts before all candidates" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"     => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"          => "http://127.0.0.1:#{port}",
         "payloads"     => %([{"list":["a","b","c","d","e"]}]),
         "max_requests" => 2}.to_json)
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
