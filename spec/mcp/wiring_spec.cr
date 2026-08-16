require "../spec_helper"
require "socket"

# The MCP half of round 3's wiring: several fixes produced an API on the engine side of a
# file-ownership boundary with no consumer on the MCP side, so an agent could not reach a
# capability `gori run …` already had. Each case here is one such gap, driven through a real
# `Gori::MCP::Tools` (the IO::Memory server harness never yields to a job fiber).
#
# Helpers are file-local — Crystal's top-level `private def` is file-scoped, so this file
# does not depend on spec/mcp/fuzz_spec.cr's.

private def with_store(&)
  path = File.tempname("gori-mcpwire", ".db")
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

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

# A recording origin that keeps the EXACT bytes of each request it is handed, answers a
# canned 200, and publishes them on a channel.
private def recording_origin(conns = 1) : {Int32, Channel(Bytes)}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = Channel(Bytes).new(conns)
  spawn do
    conns.times do
      break unless conn = server.accept?
      spawn do
        buf = IO::Memory.new
        begin
          conn.read_timeout = 400.milliseconds
          slice = Bytes.new(65536)
          loop do
            n = conn.read(slice)
            break if n == 0
            buf.write(slice[0, n])
          end
        rescue
        end
        begin
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
          conn.flush
        rescue
        end
        seen.send(buf.to_slice)
        conn.close rescue nil
      end
    end
  ensure
    server.close rescue nil
  end
  {port, seen}
end

private def poll_until_done(tools, status_tool : String, job_id : String, seconds = 20) : JSON::Any
  deadline = Time.instant + seconds.seconds
  loop do
    st = call_json(tools, status_tool, %({"job_id":#{job_id.to_json}}))
    return st unless st["status"].as_s == "running"
    fail "#{status_tool} #{job_id} never left :running within #{seconds}s" if Time.instant > deadline
    sleep 0.02.seconds
  end
end

# A plain HTML origin with no links on the page. Keep-alive capable (several requests per
# connection, no `Connection: close`) on purpose: discover pools its sockets, and an origin
# that hangs up after every response turns each probe into a re-dial plus a retry.
#
# Used even by the examples that only care whether an argument was ACCEPTED. A job started
# against a dead port keeps retrying for the rest of the file, which showed up as unrelated
# later examples taking twenty seconds each.
private def html_origin : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      spawn do
        begin
          conn.read_timeout = 2.seconds
          body = "<html><body>no links here</body></html>"
          while Gori::Proxy::Codec::Http1.read_head(conn)
            conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" \
                    "Content-Length: #{body.bytesize}\r\n\r\n" << body
            conn.flush
          end
        rescue
        end
        conn.close rescue nil
      end
    end
  end
  port
end

# ONE listener for the whole file: each `html_origin` leaks a listening socket plus an
# accept-loop fiber, and a dozen of them made unrelated later examples take twenty seconds.
private HTML_ORIGIN_PORT = html_origin

private def insert_flow(store, port : Int32, head : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice))
end

# ── 1. flow seeds are EVIDENCE ────────────────────────────────────────────────────────────
#
# `Fuzz`/`Miner`/`Sequencer::PlanOptions#evidence?` is the provenance bit: a captured flow's
# bytes are not a draft the operator typed, so the draft-time passes (the unresolved-`$KEY`
# refusal, the head's bare-LF → CRLF promotion) must not run over them. `gori run fuzz|mine|
# sequence --flow` set it; MCP's three `flow_id` seeds did not. An agent seeding a sweep from
# an OData capture (`$filter`, `$top`) therefore had the whole run REFUSED for a variable
# nobody typed — and the refusal's own remedy, "set the variable", would have SUBSTITUTED a
# value and swept a different request than the one it was told to sweep.
private ODATA_HEAD = "GET /api?$filter=name%20eq%20x&$top=10 HTTP/1.1\r\n" \
                     "X-Cmd: ;cat$IFS/etc/passwd\r\n"

describe "MCP flow seeds carry PROVENANCE" do
  it "fuzz_start does not refuse a captured $filter/$top head" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      id = insert_flow(store, port, ODATA_HEAD + "Host: 127.0.0.1:#{port}\r\n\r\n")
      text, err = call_raw(tools, "fuzz_start",
        {"flow_id" => id, "auto" => true, "max_requests" => 1,
         "payloads" => [{"list" => ["a"]}], "allow_unscoped" => true}.to_json)
      fail "fuzz_start refused a capture: #{text}" if err
      job_id = JSON.parse(text)["job_id"].as_s
      job_id.should start_with("fz_")
      # The point here is that the plan BUILT. Stop the job rather than let it outlive the
      # example: an engine fiber still running competes with every example after it.
      call_json(tools, "fuzz_stop", %({"job_id":#{job_id.to_json}}))
    end
  end

  it "mine_start does not refuse a captured $filter/$top head" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      id = insert_flow(store, port, ODATA_HEAD + "Host: 127.0.0.1:#{port}\r\n\r\n")
      text, err = call_raw(tools, "mine_start",
        {"flow_id" => id, "max_requests" => 1, "allow_unscoped" => true}.to_json)
      fail "mine_start refused a capture: #{text}" if err
      call_json(tools, "mine_stop", %({"job_id":#{JSON.parse(text)["job_id"].as_s.to_json}}))
    end
  end

  it "sequence_start does not refuse a captured $filter/$top head" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      tools = tools_for(store)
      id = insert_flow(store, port, ODATA_HEAD + "Host: 127.0.0.1:#{port}\r\n\r\n")
      text, err = call_raw(tools, "sequence_start",
        {"flow_id" => id, "cookie" => "sid", "count" => 1, "max_requests" => 1,
         "allow_unscoped" => true}.to_json)
      fail "sequence_start refused a capture: #{text}" if err
      call_json(tools, "sequence_stop", %({"job_id":#{JSON.parse(text)["job_id"].as_s.to_json}}))
    end
  end

  # The other half of the same bit, and the one that silently changes what a whole sweep
  # measures: `expand_wire` re-terminates a head with CRLF. A bare LF between header lines is
  # itself a front-end/back-end desync primitive, so promoting it does not merely tidy the
  # bytes — it confounds every result the run produces, and the run reports clean.
  it "fuzz_start puts a captured bare-LF head on the wire bare-LF" do
    port, seen = recording_origin(1)
    with_store do |store|
      tools = tools_for(store)
      bare = "GET /lf?q=1 HTTP/1.1\nHost: 127.0.0.1:#{port}\nX-Probe: keep\n\n"
      id = insert_flow(store, port, bare)
      start = call_json(tools, "fuzz_start",
        {"flow_id" => id, "auto" => true, "max_requests" => 1,
         "payloads" => [{"list" => ["Z"]}], "keep_alive" => false,
         "allow_unscoped" => true}.to_json)
      poll_until_done(tools, "fuzz_status", start["job_id"].as_s)
      wire = String.new(receive_within(seen))
      wire.should_not contain("\r\n")
      wire.should start_with("GET /lf?q=Z HTTP/1.1\nHost:")
    end
  end
end

# ── 3. fuzz_start{update_content_length} ──────────────────────────────────────────────────
#
# `Fuzz::Config#update_content_length` is wired to `gori run fuzz --verbatim` and to
# `intercept_forward_edit{update_content_length:false}`. fuzz_start could not reach it, so
# every payload was re-framed to fit before it left and the whole CL-desync probe class was
# unreachable for an agent — the sweep silently repaired the exact property it was measuring.
private CL_TEMPLATE = "POST /d HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                      "Content-Length: 4\r\n\r\nq=§x§"

describe "MCP fuzz_start{update_content_length}" do
  it "sends the template's DECLARED Content-Length when it is false" do
    port, seen = recording_origin(1)
    with_store do |store|
      tools = tools_for(store)
      start = call_json(tools, "fuzz_start",
        {"template" => CL_TEMPLATE, "url" => "http://127.0.0.1:#{port}",
         "payloads" => [{"list" => ["a-long-payload"]}], "keep_alive" => false,
         "update_content_length" => false, "allow_unscoped" => true}.to_json)
      poll_until_done(tools, "fuzz_status", start["job_id"].as_s)
      wire = String.new(receive_within(seen))
      wire.should contain("Content-Length: 4\r\n")
      wire.should end_with("q=a-long-payload")
    end
  end

  it "still resyncs by default" do
    port, seen = recording_origin(1)
    with_store do |store|
      tools = tools_for(store)
      start = call_json(tools, "fuzz_start",
        {"template" => CL_TEMPLATE, "url" => "http://127.0.0.1:#{port}",
         "payloads" => [{"list" => ["a-long-payload"]}], "keep_alive" => false,
         "allow_unscoped" => true}.to_json)
      poll_until_done(tools, "fuzz_status", start["job_id"].as_s)
      String.new(receive_within(seen)).should contain("Content-Length: 16\r\n")
    end
  end
end

# ── 4. mine_status{skipped} ───────────────────────────────────────────────────────────────
#
# `names_total` counts only the names that SURVIVED per-location filtering, so the same
# wordlist reported a different headline count at the query and at headers with nothing
# anywhere to say why. `Miner::Engine#skipped_names` is the fact; `gori run mine` prints it
# and MCP did not carry it, so an agent read an incomplete sweep as a clean one.
describe "MCP mine_status{skipped}" do
  it "reports the names a location cannot carry, against the wordlist's own size" do
    port = HTML_ORIGIN_PORT
    with_store do |store|
      wl = File.tempname("gori-mine-wl", ".txt")
      # Three names a header cannot carry (a separator, whitespace, and a framing header)
      # against two that it can.
      File.write(wl, "good_one\nbad(name)\nbad name\ncontent-length\nalso_good\n")
      begin
        tools = tools_for(store)
        start = call_json(tools, "mine_start",
          {"template" => "GET /m HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
           "url" => "http://127.0.0.1:#{port}", "locations" => "headers",
           "wordlist" => wl, "max_requests" => 1,
           "concurrency" => 1, "allow_unscoped" => true}.to_json)
        st = call_json(tools, "mine_status", %({"job_id":#{start["job_id"].as_s.to_json}}))
        st["candidate_names"].as_i.should be > st["names_total"].as_i
        skipped = st["skipped"].as_a
        skipped.size.should eq(1)
        skipped[0]["location"].as_s.should eq("headers")
        # At least the three this wordlist contributes; it is MERGED with the built-in list,
        # which carries header-invalid names of its own, so this is a floor and not a total.
        skipped[0]["names"].as_i.should be >= 3
        # ...and the count really is the denominator's shortfall, not an unrelated number.
        skipped[0]["names"].as_i.should eq(st["candidate_names"].as_i - st["names_total"].as_i)
        call_json(tools, "mine_stop", %({"job_id":#{start["job_id"].as_s.to_json}}))
      ensure
        File.delete?(wl)
      end
    end
  end
end
