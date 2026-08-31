require "../spec_helper"
require "socket"
require "base64"
require "compress/gzip"

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

# Run one fuzz_start to completion and return the recorded request head of its first row —
# the wire bytes, which is the only place an encoding decision can be checked honestly.
private def fuzz_request_head(tools, args : String) : String
  job_id = call_json(tools, "fuzz_start", args)["job_id"].as_s
  done = false
  30.times do
    sleep 0.02.seconds
    break done = true unless call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))["status"].as_s == "running"
  end
  fail "fuzz job #{job_id} did not finish" unless done
  fid = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))["results"][0]["flow_id"].as_i64
  call_json(tools, "get_flow", %({"id":#{fid}}))["request_head"].as_s
end

# Parsed JSON for a successful call (fails loudly if the tool errored).
private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

private def wait_fuzz_done(tools, job_id : String) : JSON::Any
  100.times do
    sleep 0.02.seconds
    status = call_json(tools, "fuzz_status", {job_id: job_id}.to_json)
    return status unless status["status"].as_s == "running"
  end
  fail "fuzz job #{job_id} did not finish"
end

private def mcp_fuzz_gzip(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |writer| writer.print(text) }
  io.to_slice
end

private def mcp_saved_body(head : String, body : Bytes, cap : Int32,
                           include_sensitive : Bool = false) : JSON::Any
  JSON.parse(JSON.build do |json|
    json.object do
      Gori::MCP::Serialize.emit_body(json, "body", head.to_slice, body, false, cap,
        include_sensitive: include_sensitive)
    end
  end)["body"]
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
      start["save_results"]?.should be_nil

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

  it "permanently saves every row independently of the bounded selective live cache" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => [{"list" => ["a", "b"]}],
        "match"          => {"status" => "500"}, # both clean 200 rows are absent from the live cache
        "save_results"   => true,
        "allow_unscoped" => true,
      }.to_json)
      job_id = start["job_id"].as_s
      run_id = start["run_id"].as_i64
      start["save_results"].as_bool.should be_true
      start["save_status"].as_s.should eq("running")

      status = wait_fuzz_done(tools, job_id)
      status["status"].as_s.should eq("done")
      status["save_status"].as_s.should eq("done")
      status["saved_results"].as_i.should eq(2)
      call_json(tools, "fuzz_results", {job_id: job_id}.to_json)["results"].as_a.should be_empty

      # A fresh Tools instance has no live job, but the permanent run remains project data.
      reader = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      listed = call_json(reader, "list_fuzz_runs", %({"limit":10}))
      listed["runs"][0]["id"].as_i64.should eq(run_id)
      listed["runs"][0]["stored_results"].as_i.should eq(2)
      _, delete_disabled = call_raw(reader, "delete_fuzz_run", {run_id: run_id}.to_json)
      delete_disabled.should be_true

      page = call_json(reader, "get_fuzz_run", {run_id: run_id}.to_json)
      page["results"].as_a.size.should eq(2)
      page["results"][0]["matched"].as_bool.should be_false
      page["run"]["surface"].as_s.should eq("mcp")
      page["run"]["source_ref"].as_s.should eq(job_id)

      redacted = call_json(reader, "get_fuzz_run", {
        run_id: run_id, result_index: 0, include_content: true,
      }.to_json)
      redacted["result"]["request"]["head"].as_s.should contain("Authorization: [REDACTED]")
      redacted["result"]["request"]["raw_redacted"].as_bool.should be_true
      redacted["result"]["response_body"]["text"].as_s.should eq("ok")

      exact = call_json(reader, "get_fuzz_run", {
        run_id: run_id, result_index: 0, include_content: true,
        include_sensitive: true, max_body_bytes: 4096,
      }.to_json)
      raw = Base64.decode_string(exact["result"]["request"]["raw_base64"].as_s)
      raw.should contain("Authorization: Bearer secret")
      Base64.decode_string(exact["result"]["response_body_raw_base64"].as_s).should eq("ok")
    end
  end

  it "pages saved metrics without BLOBs and caps content pages at 25 full rows" do
    with_store do |store|
      run_id = store.insert_fuzz_run(nil, "http://saved.test", "sniper", 30_i64,
        surface: "mcp")
      rows = (0...30).map do |i|
        Gori::Store::FuzzResultWrite.new(i.to_i64, %(["p#{i}"]), 0, 200, 2_i64,
          1, 1, 1_i64, nil, true, false, nil,
          "GET /#{i} HTTP/1.1\r\nHost: saved.test\r\n\r\n".to_slice,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice)
      end
      store.insert_fuzz_results(run_id, rows).should be_true
      store.finish_fuzz_run(run_id, 30_i64, 30_i64, 0_i64, "done").should be_true

      # The exact projection contract the default MCP page consumes.
      summaries = store.fuzz_result_summaries(run_id, 30)
      summaries.size.should eq(30)
      summaries.all? { |row| row.request.nil? && row.response_head.nil? &&
        row.response_body.nil? && row.wire.nil? }.should be_true

      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      metrics = call_json(tools, "get_fuzz_run", {run_id: run_id, limit: 30}.to_json)
      metrics["results"].as_a.size.should eq(30)
      metrics["results"][0]["request"]?.should be_nil
      metrics["run"]["snapshot_version"].as_i.should eq(1)
      metrics["run"]["legacy"].as_bool.should be_false
      legacy = Gori::Store::FuzzRunRecord.new(99_i64, nil, 1_i64, nil,
        "http://legacy.test", "sniper", nil, 0_i64, 0_i64, 0_i64, "done")
      legacy_json = JSON.parse(JSON.build do |json|
        Gori::MCP::Serialize.saved_fuzz_run(json, legacy, 0_i64)
      end)
      legacy_json["snapshot_version"].as_i.should eq(0)
      legacy_json["legacy"].as_bool.should be_true

      content = call_json(tools, "get_fuzz_run",
        {run_id: run_id, limit: 1000, include_content: true}.to_json)
      content["results"].as_a.size.should eq(25)
      content["returned"].as_i.should eq(25)
      content["has_more"].as_bool.should be_true
      content["results"][0]["request"]["head"].as_s.should contain("GET /0")
    end
  end

  it "bounds indexed content at SQLite and preserves empty BLOBs" do
    with_store do |store|
      run_id = store.insert_fuzz_run(nil, "http://bounded.test", "sniper", 2_i64,
        surface: "mcp")
      request = "GET / HTTP/1.1\r\nX-Large: #{"r" * 200_000}\r\n\r\nbody"
      response_head = "HTTP/1.1 200 OK\r\nX-Large: #{"h" * 200_000}\r\n\r\n"
      row = Gori::Store::FuzzResultWrite.new(0_i64, %(["p"]), 0, 200, 0_i64,
        0, 0, 1_i64, nil, true, false, nil, request.to_slice,
        response_head.to_slice, Bytes.empty, wire: request.to_slice)
      large_body = Bytes.new(Gori::MCP::Serialize::SAVED_SOURCE_BYTES * 2, 0x62_u8)
      large = Gori::Store::FuzzResultWrite.new(1_i64, %(["large"]), 0, 200,
        large_body.size.to_i64, 1, 1, 1_i64, nil, false, false, nil,
        "GET /large HTTP/1.1\r\n\r\n".to_slice, response_head.to_slice, large_body)
      store.insert_fuzz_results(run_id, [row, large]).should be_true
      store.finish_fuzz_run(run_id, 2_i64, 1_i64, 0_i64, "done").should be_true

      summary = store.get_fuzz_result_summary(run_id, 0_i64).not_nil!
      summary.request.should be_nil
      summary.response_head.should be_nil
      summary.response_body.should be_nil
      summary.wire.should be_nil

      preview = store.get_fuzz_result_preview(run_id, 0_i64, 65, 33, 65, 65).not_nil!
      preview.row.request.not_nil!.size.should eq(65)
      preview.request_size.should eq(request.bytesize.to_i64)
      preview.request_truncated?.should be_true
      preview.response_head_size.should eq(response_head.bytesize.to_i64)
      preview.response_body_size.should eq(0_i64)
      preview.row.response_body.not_nil!.should be_empty
      large_preview = store.get_fuzz_result_preview(run_id, 1_i64, 65, 33, 65, 65).not_nil!
      large_preview.row.response_body.not_nil!.size.should eq(65)
      large_preview.response_body_size.should eq(large_body.size.to_i64)
      large_preview.response_body_truncated?.should be_true

      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      metrics = call_json(tools, "get_fuzz_run", {
        run_id: run_id, result_index: 0,
      }.to_json)["result"]
      metrics["request"]?.should be_nil

      content = call_json(tools, "get_fuzz_run", {
        run_id: run_id, result_index: 0, include_content: true,
        max_head_bytes: 32, max_body_bytes: 16,
      }.to_json)["result"]
      content["request"]["head_truncated"].as_bool.should be_true
      content["request"]["size"].as_i64.should eq(request.bytesize.to_i64)
      content["response_head_truncated"].as_bool.should be_true
      content["response_head_size"].as_i64.should eq(response_head.bytesize.to_i64)
      empty = content["response_body"]
      empty["source_size"].as_i.should eq(0)
      empty["text"].as_s.should eq("")
      empty["truncated"].as_bool.should be_false
    end
  end

  it "redacts a sensitive first line in malformed saved heads" do
    with_store do |store|
      run_id = store.insert_fuzz_run(nil, "http://malformed.test", "sniper", 1_i64)
      request = "Authorization: first-secret\r\n folded-request-secret\r\n\r\nbody"
      wire = "Cookie: wire-secret\n folded-wire-secret\n\nbody"
      response_head = "Set-Cookie: response-secret\r folded-response-secret\r\r"
      row = Gori::Store::FuzzResultWrite.new(0_i64, %(["p"]), 0, 200, 0_i64,
        0, 0, 1_i64, nil, true, false, nil, request.to_slice,
        response_head.to_slice, Bytes.empty, wire: wire.to_slice)
      store.insert_fuzz_results(run_id, [row]).should be_true
      store.finish_fuzz_run(run_id, 1_i64, 1_i64, 0_i64, "done").should be_true

      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      result = call_json(tools, "get_fuzz_run", {
        run_id: run_id, result_index: 0, include_content: true,
      }.to_json)["result"]
      result["request"]["head"].as_s.should eq("Authorization: [REDACTED]\r\n [REDACTED]\r\n\r\n")
      result["wire"]["head"].as_s.should eq("Cookie: [REDACTED]\n [REDACTED]\n\n")
      result["response_head"].as_s.should eq("Set-Cookie: [REDACTED]\r [REDACTED]\r\r")
    end
  end

  it "redacts CR-only and obs-fold credentials in every saved head plus trailers" do
    with_store do |store|
      run_id = store.insert_fuzz_run(nil, "http://saved.test", "sniper", 1_i64)
      request = "GET / HTTP/1.1\rHost: saved.test\rAuthorization:\r Bearer request-secret\r\rbody"
      wire = "GET / HTTP/1.1\nHost: saved.test\nCookie:\n sid=wire-secret\n\nbody"
      response_head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nSet-Cookie:\r\n sid=head-secret\r\n\r\n"
      response_body = "2\r\nok\r\n0\r\nAuthorization: trailer-secret\r\n\r\n"
      row = Gori::Store::FuzzResultWrite.new(0_i64, %(["p"]), 0, 200, 2_i64,
        1, 1, 1_i64, nil, true, false, nil, request.to_slice, response_head.to_slice,
        response_body.to_slice, wire: wire.to_slice)
      store.insert_fuzz_results(run_id, [row]).should be_true
      store.finish_fuzz_run(run_id, 1_i64, 1_i64, 0_i64, "done").should be_true

      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      redacted = call_json(tools, "get_fuzz_run",
        {run_id: run_id, result_index: 0, include_content: true}.to_json)["result"]
      redacted["request"]["head"].as_s.should_not contain("request-secret")
      redacted["request"]["head"].as_s.should contain("Authorization: [REDACTED]\r [REDACTED]\r")
      redacted["request"]["raw_base64"]?.should be_nil
      redacted["wire"]["head"].as_s.should_not contain("wire-secret")
      redacted["wire"]["raw_base64"]?.should be_nil
      redacted["response_head"].as_s.should_not contain("head-secret")
      trailers = redacted["response_body"]["trailers"].as_a
      trailers[0]["value"].as_s.should eq("[REDACTED]")
      trailers[0]["value_base64"]?.should be_nil

      exact = call_json(tools, "get_fuzz_run", {run_id: run_id, result_index: 0,
                                                include_content: true, include_sensitive: true}.to_json)["result"]
      exact["request"]["head"].as_s.should contain("request-secret")
      exact["wire"]["head"].as_s.should contain("wire-secret")
      exact["response_head"].as_s.should contain("head-secret")
      exact["response_body"]["trailers"][0]["value"].as_s.should eq("trailer-secret")
      exact["request"]["raw_base64"]?.should_not be_nil
    end
  end

  it "bounds compressed and chunked saved previews before String/base64 work" do
    gzip = mcp_saved_body("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
      mcp_fuzz_gzip("A" * 200_000), 32)
    gzip["text"].as_s.bytesize.should eq(32)
    gzip["truncated"].as_bool.should be_true
    gzip["decode_truncated"].as_bool.should be_true

    chunk = "#{200_000.to_s(16)}\r\n#{"B" * 200_000}\r\n0\r\n" \
            "Cookie: should-not-be-scanned-after-cap\r\n\r\n"
    chunked = mcp_saved_body("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      chunk.to_slice, 32)
    chunked["text"].as_s.should eq("B" * 32)
    chunked["decode_truncated"].as_bool.should be_true
    chunked["trailers"]?.should be_nil
  end

  it "deletes a terminal permanent run and cascades its results" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template" => "GET /§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url" => "http://127.0.0.1:#{port}", "payloads" => [{"list" => ["a"]}],
        "save_results" => true, "allow_unscoped" => true,
      }.to_json)
      wait_fuzz_done(tools, start["job_id"].as_s)
      run_id = start["run_id"].as_i64

      deleted = call_json(tools, "delete_fuzz_run", {run_id: run_id}.to_json)
      deleted["deleted_results"].as_i.should eq(1)
      store.get_fuzz_run(run_id).should be_nil
      store.fuzz_result_count(run_id).should eq(0)
      _, missing = call_raw(tools, "get_fuzz_run", {run_id: run_id}.to_json)
      missing.should be_true

      stale = store.insert_fuzz_run(nil, "http://stale", "sniper", 1_i64, status: "saving")
      forced = call_json(tools, "delete_fuzz_run", {run_id: stale, force_stale: true}.to_json)
      forced["deleted"].as_bool.should be_true
    end
  end

  it "refuses to delete a permanent run while its live job can still append" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template" => "GET /§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url" => "http://127.0.0.1:#{port}", "payloads" => [{"numbers" => "1-100"}],
        "rate" => 1, "save_results" => true, "allow_unscoped" => true,
      }.to_json)
      run_id = start["run_id"].as_i64
      text, refused = call_raw(tools, "delete_fuzz_run", {run_id: run_id}.to_json)
      refused.should be_true
      text.should contain("still being written")
      _, force_refused = call_raw(tools, "delete_fuzz_run",
        {run_id: run_id, force_stale: true}.to_json)
      force_refused.should be_true # force never overrides this server's known-live writer
      call_json(tools, "fuzz_stop", {job_id: start["job_id"].as_s}.to_json)
      wait_fuzz_done(tools, start["job_id"].as_s)["save_status"].as_s.should eq("stopped")
    end
  end

  it "runs a race_count job with no payloads at all" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      args = {
        "template"       => "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "race_count"     => 6,
        "match"          => {"status" => "200"},
        "save_results"   => true,
        "allow_unscoped" => true,
      }.to_json

      start = call_json(tools, "fuzz_start", args)
      job_id = start["job_id"].as_s
      start["total"].as_i.should eq(6)

      done = false
      30.times do
        sleep 0.02.seconds
        status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
        next if status["status"].as_s == "running"
        status["status"].as_s.should eq("done")
        status["sent"].as_i.should eq(6)
        status["matched"].as_i.should eq(6)
        done = true
        break
      end
      done.should be_true
      store.get_fuzz_run(start["run_id"].as_i64).not_nil!.mode.should eq("race ×6")
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

  # "try every string" is exactly what an agent emits, and both halves of it used to be
  # unbounded: a one-symbol charset made counting the set O(max²) of yield-free arithmetic
  # (the whole process froze — before the scope gate, before the budget guard, with the
  # server's ping/cancel reader fiber starved), and a huge `min` made BruteIterator allocate
  # an odometer of that many slots (8.6 GB at Int32::MAX). Lengths are clamped here, at the
  # strict surface: FUZZ_MAX_REQUESTS caps how MANY payloads go out, never how long one is.
  it "clamps brute-force lengths so a huge one can neither freeze nor OOM the server" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "allow_unscoped" => true,
        "max_requests"   => 1, # the clamped set is still 4096 candidates — don't send them
      }
      # The string form, the shape an agent reaches for first. Without the clamp this call
      # does not RETURN: counting "a" × 1e8 takes weeks.
      s = call_json(tools, "fuzz_start", base.merge({"payloads" => [{"brute" => "a:1-100000000"}]}).to_json)
      s["total"].as_i.should eq(4096)
      # The object form's `min` is what BruteIterator allocates up front.
      o = call_json(tools, "fuzz_start",
        base.merge({"payloads" => [{"brute" => {"charset" => "ab", "min" => 2147483647}}]}).to_json)
      o["job_id"].as_s.should_not be_empty

      # Both jobs stop themselves at the 1-request cap; drain them so the store closes clean.
      # ASSERTED, not best-effort: falling through on timeout would let `with_store` close the
      # DB under a live job fiber, whose next write then hits a closed SQLite handle — an
      # intermittent failure landing in some unrelated example. The ceiling is generous
      # (12 s) because a loaded runner still has to walk the clamped 4096-candidate set.
      [s["job_id"].as_s, o["job_id"].as_s].each do |id|
        settled = false
        600.times do
          if call_json(tools, "fuzz_status", %({"job_id":#{id.to_json}}))["status"].as_s != "running"
            settled = true
            break
          end
          sleep 0.02.seconds
        end
        settled.should be_true
      end
    end
  end

  # A built-in preset (issue #566) is selectable as a payload SOURCE, composes with a
  # second set, and merges an optional user file — the same model the CLI/TUI use.
  it "accepts a built-in preset as a payload set, and merges a user file" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "allow_unscoped" => true,
      }
      sqli = Gori::Fuzz::Presets.load("sqli").size
      # A bare preset set resolves to the whole built-in list.
      one = call_json(tools, "fuzz_start", base.merge({"payloads" => [{"preset" => "sqli"}]}).to_json)
      one["total"].as_i.should eq(sqli)
      # A "file" sibling merges into the built-in (built-in first, de-duped).
      path = File.tempname("gori-mcp-preset")
      File.write(path, "EXTRA-1\nEXTRA-2\n")
      begin
        merged = call_json(tools, "fuzz_start",
          base.merge({"payloads" => [{"preset" => "sqli", "file" => path}]}).to_json)
        merged["total"].as_i.should eq(sqli + 2)
      ensure
        File.delete(path) rescue nil
      end
      # An unknown preset name is a clean arg error listing the alternatives.
      text, bad = call_raw(tools, "fuzz_start", base.merge({"payloads" => [{"preset" => "nope"}]}).to_json)
      bad.should be_true
      text.should contain("unknown preset")
    end
  end

  # `list` entries are JSON strings, so a payload reached the wire as its UTF-8 ENCODING:
  # `é` went out as `\xc3\xa9` and a byte-level set (0x00-0xFF, overlong/invalid UTF-8) could
  # not be expressed at all — the only escape hatch was a `wordlist` FILE on the server disk.
  it "list_base64 splices a payload's exact octets, which `list` cannot" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      payload = Bytes[0xc3, 0x28, 0x80] # invalid UTF-8: an overlong-looking pair plus a bare 0x80
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list_base64":[#{Base64.strict_encode(payload).to_json}]}]),
         "record_history" => "all",
         # `no_encode` because what is under test is the SET — that these three octets
         # survive base64 → payload → splice unchanged. A query position is percent-encoded
         # by default (`Fuzz::AutoEncode`), a LATER and separate stage: it would put
         # `%C3%28%80` on the wire, which is the same three octets and would prove nothing
         # about the decoding. A caller who wants the raw octets in a query string passes
         # this flag for the same reason.
         "no_encode"      => true,
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
      head = store.get_flow(fid).not_nil!.request_head
      # The RECORDED wire bytes, not the JSON echo: exactly the three octets, no re-encoding.
      String.new(head).should_not contain("GET /?q=\u{FFFD}")
      idx = head.index(0x71_u8).not_nil! # the 'q' of ?q=
      head[(idx + 2), 3].should eq(payload)
    end
  end

  it "refuses invalid base64 in list_base64 instead of fuzzing with different bytes" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      text, err = call_raw(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\n\r\n",
         "url"            => "http://127.0.0.1:1",
         "payloads"       => %([{"list_base64":["!!! not base64 !!!"]}]),
         "allow_unscoped" => true}.to_json)
      err.should be_true
      text.should contain("list_base64")
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

  # `auto:true` finds the position; it used to leave the encoding to the caller, so an
  # agent sending an XSS payload produced a corrupt request line rather than a test. The
  # default now encodes for the query/form positions, and `no_encode:true` is the way back
  # to raw. Pinned at the wire off the recorded flow, like the `processors` case above.
  it "URL-encodes a query payload by default, and sends it raw under no_encode" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
              "url"            => "http://127.0.0.1:#{port}",
              "payloads"       => %([{"list":["<script>"]}]),
              "record_history" => "all",
              "allow_unscoped" => true}

      encoded = fuzz_request_head(tools, base.to_json)
      encoded.should contain("GET /?q=%3Cscript%3E HTTP/1.1")

      raw = fuzz_request_head(tools, base.merge({"no_encode" => true}).to_json)
      raw.should contain("GET /?q=<script> HTTP/1.1")
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

  # Round 7 / H2 F4. `record_history` is a string enum here but a BOOLEAN on `send_request`,
  # the sibling tool a caller learns the argument name from — and `true` used to fall through
  # to `:none`, i.e. the audit trail the caller explicitly asked for was silently not kept,
  # with a cheerful `"record_history":"none"` in the echo. Booleans are now the obvious
  # aliases; anything else is refused BY NAME rather than degraded (the contract
  # `optional_bool_arg` already states: a lenient coercion is fine, a SILENT one is not).
  it "accepts record_history true/false as all/none and refuses any other value by name" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      base = {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
              "url"            => "http://127.0.0.1:#{port}",
              "payloads"       => %([{"list":["a"]}]),
              "allow_unscoped" => true}

      start = call_json(tools, "fuzz_start", base.merge({"record_history" => true}).to_json)
      start["record_history"].as_s.should eq("all")
      start = call_json(tools, "fuzz_start", base.merge({"record_history" => false}).to_json)
      start["record_history"].as_s.should eq("none")

      # The pre-existing valid values keep working, case-insensitively.
      {"none", "matched", "all", "ALL"}.each do |v|
        s = call_json(tools, "fuzz_start", base.merge({"record_history" => v}).to_json)
        s["record_history"].as_s.should eq(v.downcase)
      end

      # And the values that used to mean a silent "none" are now named refusals.
      [%("yes"), "1"].each do |raw|
        text, err = call_raw(tools, "fuzz_start",
          %({"template":"GET /?q=§x§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
          %("url":"http://127.0.0.1:#{port}","payloads":[{"list":["a"]}],) +
          %("allow_unscoped":true,"record_history":#{raw}}))
        err.should be_true
        text.should contain("invalid 'record_history'")
        text.should contain("none | matched | all")
      end
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

  it "persists budget_exhausted when an unknown-total run reaches its wire cap" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"      => "http://127.0.0.1:#{port}",
        # This combinatorial count overflows Int64, so the engine honestly reports total:null.
        "payloads"       => [{"brute" => {"charset" => "ab", "min" => 1, "max" => 100}}],
        "max_requests"   => 1,
        "save_results"   => true,
        "allow_unscoped" => true,
      }.to_json)
      start["total"].raw.should be_nil
      status = wait_fuzz_done(tools, start["job_id"].as_s)
      status["status"].as_s.should eq("budget_exhausted")
      status["save_status"].as_s.should eq("budget_exhausted")
      store.get_fuzz_run(start["run_id"].as_i64).not_nil!.status
        .should eq("budget_exhausted")
    end
  end
end

# An origin that is SLOW for one payload and fast for the other, with a byte-identical
# response either way — the shape of a time-based blind injection, and the one an agent could
# not name until `match:{time}` existed: status, size, words and body are the same on both
# rows, so every other dimension `fuzz_conditions` parses is blind to it.
private def start_slow_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = String.new(Gori::Proxy::Codec::Http1.read_head(conn) || Bytes.empty)
      sleep 0.3.seconds if head.includes?("q=slow")
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      conn.flush
      conn.close
    end
  end
  port
end

describe "MCP fuzz_start match:{time}" do
  it "matches on the ROUND TRIP in milliseconds — the dimension a time-based blind payload " \
     "is the only evidence for, and the one an identical-response origin leaves untouched" do
    port = start_slow_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => %([{"list":["fast","slow"]}]),
        "match"          => {"time" => ">=200"},
        "concurrency"    => 1,
        "allow_unscoped" => true,
      }.to_json)
      status = await_fuzz_done(tools, start["job_id"].as_s)
      status["sent"].as_i.should eq(2)
      status["matched"].as_i.should eq(1) # the slow one, and only it
    end
  end
end

# An origin that answers ONE payload with a matching body and the other with a
# `Content-Length` longer than the bytes it writes before closing. The short read is a
# premature EOF, which `Codec::Body` reports as an incomplete body — so that row is STORED
# (`store_fuzz_result` keeps retried / resent / incomplete rows) while the MATCHER rejects
# it. That mix is the whole point: it is the state in which `fuzz_results` used to hand back
# a page with no bit separating a match from a non-match.
private def start_mixed_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = String.new(Gori::Proxy::Codec::Http1.read_head(conn) || Bytes.empty)
      if head.includes?("q=b")
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 50\r\nConnection: close\r\n\r\nshort"
      else
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nMATCHME"
      end
      conn.flush
      conn.close
    end
  end
  port
end

private def await_fuzz_done(tools, job_id : String) : JSON::Any
  60.times do
    sleep 0.02.seconds
    status = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
    return status unless status["status"].as_s == "running"
  end
  fail "fuzz job #{job_id} never reached a terminal status"
end

describe "MCP fuzz_results — the stored page is not matched-only, and says so" do
  it "carries a per-row `matched` bit, and matched_only actually filters" do
    port = start_mixed_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => %([{"list":["a","b"]}]),
        "match"          => {"regex" => "MATCHME"},
        "allow_unscoped" => true,
      }.to_json)
      job_id = start["job_id"].as_s
      status = await_fuzz_done(tools, job_id)
      status["matched"].as_i.should eq(1)
      # The non-matching row was kept for its truncated response, so the stored set is
      # LARGER than the match count — the condition the "stored matched-only" claim denied.
      status["stored_results"].as_i.should eq(2)

      all = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))
      all["total_available"].as_i.should eq(2)
      all["matched_only"].as_bool.should be_false
      rows = all["results"].as_a
      rows.count { |r| r["matched"].as_bool }.should eq(1)
      rows.count { |r| !r["matched"].as_bool }.should eq(1)
      rejected = rows.find { |r| !r["matched"].as_bool }.not_nil!
      rejected["incomplete"].as_bool.should be_true

      only = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json},"matched_only":true}))
      only["matched_only"].as_bool.should be_true
      only["total_available"].as_i.should eq(1)
      only["total_stored"].as_i.should eq(2)
      only["returned"].as_i.should eq(1)
      only["has_more"].as_bool.should be_false
      only["page_complete"].as_bool.should be_true
      only["results"].as_a.map { |r| r["matched"].as_bool }.should eq([true])
    end
  end

  it "pages the FILTERED set, not the stored one" do
    port = start_mixed_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start", {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:#{port}",
        "payloads"       => %([{"list":["a","b","a2","b2"]}]),
        "match"          => {"regex" => "MATCHME"},
        "allow_unscoped" => true,
      }.to_json)
      job_id = start["job_id"].as_s
      await_fuzz_done(tools, job_id)

      # Two matches (a, a2) among four stored rows: an offset past the FILTERED end must be
      # empty rather than reaching back into the rows the filter excluded.
      page = call_json(tools, "fuzz_results",
        %({"job_id":#{job_id.to_json},"matched_only":true,"offset":1,"limit":100}))
      page["total_available"].as_i.should eq(2)
      page["returned"].as_i.should eq(1)
      page["results"].as_a.map { |r| r["matched"].as_bool }.should eq([true])

      past = call_json(tools, "fuzz_results",
        %({"job_id":#{job_id.to_json},"matched_only":true,"offset":9}))
      past["returned"].as_i.should eq(0)
      past["results"].as_a.should be_empty
      past["has_more"].as_bool.should be_false
    end
  end
end

# A `marks` token that lands on nothing new must SAY so.
#
# `marks` wraps every occurrence of a literal token in `§…§`, skipping the occurrences that
# already sit inside — or flush against — a `§…§` that `auto` (or an earlier mark, or the
# `flow_id` capture itself) had already made: re-wrapping one splices `§§`, which `Template
# .parse` reads as an escaped literal, so the position silently disappears and a `§` nobody
# typed goes on the wire. The skip is right; its SILENCE was not. `fuzz_start` echoed nothing
# about it, the run is not refusable (the earlier positions are real and the sweep is
# legitimate), and the count is legitimately 0 — indistinguishable from a token that is simply
# not in the template. So an agent that asked for a position on `admin` was told the job was
# running and concluded `admin` was being swept.
describe "MCP fuzz_start — a 'marks' token that made no position" do
  it "warns when every occurrence was already marked, and stays quiet when the mark lands" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      # Port 9 (discard) — this asserts on the START reply, so nothing needs to answer.
      base = {"url" => "http://127.0.0.1:9/", "payloads" => %([{"list":["a"]}]),
              "allow_unscoped" => true, "record_history" => false}
      shadowed = call_json(tools, "fuzz_start",
        base.merge({"template" => "GET /?role=§admin§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                    "marks"    => ["admin"]}).to_json)
      warned = shadowed["marks_warning"]?.try(&.as_s) || ""
      warned.should contain(%("admin"))
      warned.should contain("added no position")

      # CONTROL: the same template, a mark that DOES make a position (`role` is one byte clear
      # of the marker) — no warning, or the field would cry wolf on every ordinary run.
      landed = call_json(tools, "fuzz_start",
        base.merge({"template" => "GET /?role=§admin§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                    "marks"    => ["role"]}).to_json)
      landed["marks_warning"]?.should be_nil
    end
  end
end

# A row an agent can never see is a row that did not happen.
#
# `store_fuzz_result` keeps a result for six reasons now. It used to keep four, and the two it
# dropped were the two that carry a FAILURE:
#
#   * `chain_error` — a position's `¦chain` did not run on this payload, so the payload went
#     out UNTRANSFORMED: a different test than the caller declared. `Serialize.fuzz_result`
#     has a field and a paragraph for it, and no unmatched row could ever reach them.
#   * `error` — the scope-refused / dead-target / TLS-failure row. `fuzz_status` counts these
#     in `errors` and `blocked`, but a count names no PAYLOAD, so an agent could read
#     `errors: 40` with an empty `results` page and no way to ask which forty.
#
# The CLI prints both (`emit_fuzz_result`) and the TUI renders every row; MCP was the one
# surface where they vanished. `matched_only:true` is still there for a caller that wants only
# the matches — filtering is the caller's, not the store's.
describe "MCP fuzz_results — a failed row is stored, not silently dropped" do
  it "keeps an errored row against a dead origin, with its payload and reason" do
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
      100.times do
        sleep 0.02.seconds
        break unless call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))["status"].as_s == "running"
      end

      st = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
      st["errors"].as_i.should eq(2)
      st["stored_results"].as_i.should eq(2) # was 0 — the count said 2 errors and the page was empty

      rows = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))["results"].as_a
      rows.size.should eq(2)
      rows.each { |r| r["matched"].as_bool.should be_false }
      rows.map { |r| r["payloads"][0].as_s }.sort!.should eq(["a", "b"])
      rows.first["error"].as_s.should_not be_empty
      # …and the filter still filters: an agent asking for findings gets none of these.
      matched = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json},"matched_only":true}))
      matched["returned"].as_i.should eq(0)
      matched["total_stored"].as_i.should eq(2)
    end
  end

  it "keeps an unmatched row whose ¦chain could not run on its payload" do
    port = start_origin
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      # `gzip-decompress` over a payload that is not gzip: the chain resolves fine at template
      # time (so `refuse_unrunnable_chains` lets the run start) and raises on THESE bytes, which
      # is exactly the per-payload case `chain_error` exists for. `filter: {status: "200"}`
      # makes every row unmatched, which is what used to erase them.
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§v¦gzip-decompress§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"list":["notgzip"]}]),
         "filter"         => {"status" => "200"},
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s
      100.times do
        sleep 0.02.seconds
        break unless call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))["status"].as_s == "running"
      end

      st = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
      st["matched"].as_i.should eq(0)
      st["errors"].as_i.should eq(1) # a swallowed chain IS an error in the run's tally

      rows = call_json(tools, "fuzz_results", %({"job_id":#{job_id.to_json}}))["results"].as_a
      rows.size.should eq(1)
      rows[0]["matched"].as_bool.should be_false
      rows[0]["error"].raw.should be_nil # the SEND succeeded — distinct from `chain_error`
      rows[0]["chain_error"].as_s.should contain("gzip-decompress")
    end
  end
end

# …and a run's FAILURES must never crowd its FINDINGS out of the buffer.
#
# Rows are stored in send order under a hard `FUZZ_MAX_STORED` (10 000), so ONE shared FIFO
# lets a target that starts resetting — or a Sandbox that refuses every send — fill every slot
# with errored rows before the first match lands. `fuzz_results{matched_only:true}` would then
# return zero findings for a run that had them, with only `results_truncated` hinting at it:
# the same false-negative-that-reads-clean the widened keep-list exists to prevent, arriving
# from the other side. Non-matched rows get their own `FUZZ_MAX_STORED_UNMATCHED` sub-budget.
#
# Driven end to end against a CLOSED port: connect-refused is immediate and involves no
# network, so a run wide enough to cross the sub-budget is still fast.
describe "MCP fuzz — failures cannot crowd matches out of the stored set" do
  it "stops storing errored rows at the unmatched sub-budget, not at the total cap" do
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.local_address.port
    probe.close
    cap = Gori::MCP::Tools::FUZZ_MAX_STORED_UNMATCHED
    # The sub-budget is what leaves room for the matches; a run of `cap + 5` failures must
    # stop at `cap` and NOT keep climbing toward FUZZ_MAX_STORED.
    cap.should be < Gori::MCP::Tools::FUZZ_MAX_STORED

    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
      start = call_json(tools, "fuzz_start",
        {"template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
         "url"            => "http://127.0.0.1:#{port}",
         "payloads"       => %([{"numbers":"1-#{cap + 5}"}]),
         "concurrency"    => 50,
         "retries"        => 0,
         "allow_unscoped" => true}.to_json)
      job_id = start["job_id"].as_s
      start["total"].as_i.should eq(cap + 5)

      done = false
      600.times do
        sleep 0.05.seconds
        next if call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))["status"].as_s == "running"
        done = true
        break
      end
      done.should be_true

      st = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
      st["sent"].as_i.should eq(cap + 5)
      st["stored_results"].as_i.should eq(cap) # …and NOT cap + 5
      st["results_truncated"].as_bool.should be_true
    end
  end
end
