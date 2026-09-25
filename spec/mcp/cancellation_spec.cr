require "../spec_helper"
require "../support/mcp_harness"
require "socket"

# `notifications/cancelled` STOPS THE WORK (#1103).
#
# Before this, a cancellation bought silence and nothing else: the response was suppressed and
# the tool ran to completion. For `probe_scan{active:true}` that meant a client which had
# stopped waiting still had real attack probes sent on its behalf, up to
# `PROBE_ACTIVE_MAX_FLOWS` flows of them — the resource gori was failing to free was a third
# party's server.
#
# So the examples here count requests at an origin rather than asserting a flag was set. A
# spec that checked the predicate was consulted would pass against the bug.

# A loopback origin that answers everything and counts request lines. `on_hit` fires with the
# running count, on the serving fiber, which is how an example makes the cancellation land
# MID-SCAN without timing anything.
private class CountingOrigin
  getter hits = 0

  def initialize(@body : String = "hello q=hello world", @cache_headers : String = "",
                 &@on_hit : Int32 -> Nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @closed = false
    spawn do
      while conn = @server.accept?
        serve(conn)
      end
    rescue
      # the listener was closed under the accept loop — the teardown path
    end
  end

  def self.new(body : String = "hello q=hello world", cache_headers : String = "") : CountingOrigin
    new(body, cache_headers) { }
  end

  def port : Int32
    @server.local_address.port
  end

  def close : Nil
    return if @closed
    @closed = true
    @server.close rescue nil
  end

  # `serve(conn)` and not `spawn do … conn … end` at the accept site: a block there captures
  # the LOOP VARIABLE, and two probes arriving back to back are then both answered on the
  # second socket (see `spawn_with` in spec_helper).
  private def serve(conn : TCPSocket) : Nil
    spawn do
      first = conn.gets("\r\n", chomp: true)
      if first
        @hits += 1
        @on_hit.call(@hits)
      end
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" << @cache_headers <<
        "Content-Length: #{@body.bytesize}\r\n" \
        "Connection: close\r\n\r\n#{@body}"
      conn.flush rescue nil
      conn.close rescue nil
    rescue
      conn.close rescue nil
    end
  end
end

private def cancel_flow(store : Gori::Store, port : Int32, target : String, cookie = false) : Int64
  head = String.build do |s|
    s << "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n"
    s << "Cookie: session=secret\r\n" if cookie
    s << "\r\n"
  end
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 19\r\n\r\n".to_slice,
    body: "hello q=hello world".to_slice, duration_us: 1_000_i64))
  store.flush
  id
end

private def cancel_flows(store : Gori::Store, port : Int32) : Nil
  %w[/a /b /c].each { |p| cancel_flow(store, port, "#{p}?q=hello") }
end

private def scan_call(id : Int32) : String
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"probe_scan",) +
    %("arguments":{"active":true,"allow_unscoped":true,"insecure":true}}})
end

private CANCEL_7 = %({"jsonrpc":"2.0","method":"notifications/cancelled",) +
                   %("params":{"requestId":7,"reason":"the user pressed escape"}})

# Runs the server with the request lines already queued and the input CLOSED — the control
# shape, where nothing arrives mid-call.
private def drive_closed(store, *lines) : Array(JSON::Any)
  sink = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: IO::Memory.new(lines.join('\n') + "\n"), output: sink).run
  sink.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

describe "MCP cancellation stops the work" do
  # THE defect. A real `notifications/cancelled` arrives on stdin while the scan is in flight —
  # written by the origin the moment the first probe lands, so nothing here is timed — and the
  # sends have to stop.
  it "stops an in-flight active probe_scan from sending, and answers nothing" do
    full = 0
    control = CountingOrigin.new
    begin
      with_store do |store|
        cancel_flows(store, control.port)
        answers = drive_closed(store, scan_call(7))
        # The control run answers, and it really does send: without both halves the example
        # below is measuring an origin nobody dialled.
        answers.map(&.["id"].as_i).should eq([7])
        mcp_tool_payload(answers[0])["flows_scanned"].as_i.should eq(3)
        full = control.hits
      end
    ensure
      control.close
    end
    full.should be > 9

    reader, writer = IO.pipe
    # The cancellation is written by the ORIGIN, on the first probe it receives: the reader
    # fiber is parked on this pipe exactly then, which is the whole reason the server splits
    # reader from worker. Closing the writer afterwards ends the session the way a client
    # hanging up does — `run` still waits for the worker to drain.
    origin = CountingOrigin.new do |n|
      if n == 1
        writer.puts(CANCEL_7)
        writer.flush
        writer.close
      end
    end
    sink = IO::Memory.new
    begin
      with_store do |store|
        cancel_flows(store, origin.port)
        writer.puts(scan_call(7))
        writer.flush
        Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
          input: reader, output: sink).run
      end
    ensure
      origin.close
      reader.close rescue nil
      writer.close rescue nil
    end

    # The MUST: not one frame for the cancelled id — which is also what pins the probe as
    # NON-consuming. `Server#cancelled?` deletes the key (it is the write site's one-shot
    # suppression); a running tool polling that one would clear the flag on its first read and
    # the answer would be written here after all.
    sink.to_s.each_line.reject(&.strip.empty?).to_a.should be_empty
    # The SHOULD, and the only assertion that could have caught the bug: the probes stopped.
    # One flow's worth went out (a probe already on the socket owns its own timeout), not three.
    origin.hits.should be > 0
    (origin.hits * 2).should be < full
  end

  # The tools layer's half of the seam, driven directly: `Tools#call` takes the predicate and
  # every engine that can stop reads it from there. No fibers, so these are exact.
  describe "Tools#call(cancelled:)" do
    it "leaves probe_scan's origin untouched when the call is already cancelled" do
      origin = CountingOrigin.new
      begin
        with_store do |store|
          cancel_flows(store, origin.port)
          tools = tools_for(store)
          args = JSON.parse(%({"active":true,"allow_unscoped":true}))
          tools.call("probe_scan", args, cancelled: -> { true }).is_error.should be_false
          origin.hits.should eq(0)
          # …and the same call with no predicate sends, so the zero above is the cancel's doing.
          tools.call("probe_scan", args)
          origin.hits.should be > 0
        end
      ensure
        origin.close
      end
    end

    it "stops cache_deception_check before it sends when the call is cancelled" do
      origin = CountingOrigin.new
      begin
        with_store do |store|
          id = cancel_flow(store, origin.port, "/account")
          tools = tools_for(store)
          args = JSON.parse(%({"flow_id":#{id},"allow_unscoped":true,"verify":false}))
          stopped = tools.call("cache_deception_check", args, cancelled: -> { true })
          stopped.is_error.should be_true # the cancelled check has no report to return
          origin.hits.should eq(0)

          completed = tools.call("cache_deception_check", args)
          completed.is_error.should be_false
          origin.hits.should eq(2) # no cache-hit evidence, so no control request
        end
      ensure
        origin.close
      end
    end

    # A stop during CALIBRATION aborts the run, but a stop mid-SEARCH does not: it returns
    # `aborted: false` with the removals proven so far. `apply` was guarded only on `aborted`,
    # so a cancelled minimize would have rewritten the stored request under a caller that is
    # owed no response and will never learn the session changed.
    it "refuses minimize_repeater's apply after a cancel, keeping the stored request" do
      origin = CountingOrigin.new
      begin
        with_store do |store|
          request = "GET /?q=hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n" \
                    "X-Cosmetic: 1\r\nAccept: */*\r\n\r\n"
          id = store.insert_repeater("http://127.0.0.1:#{origin.port}/", request.to_slice,
            false, true, nil, 0)
          tools = tools_for(store)
          # Cancel once the search is past calibration (3 rounds) and has proven a removal, so
          # the report comes back NOT aborted with a non-empty `removed` — the exact shape the
          # old guard let through.
          r = mcp_ok_json(tools, "minimize_repeater",
            %({"id":#{id},"apply":true,"allow_unscoped":true}))
          r["aborted"].as_bool.should be_false
          r["removed_count"].as_i.should be > 0
          r["applied"].as_bool.should be_true # the control: apply works when nothing cancelled
          store.get_repeater(id).not_nil!.request.should_not eq(request.to_slice)

          id2 = store.insert_repeater("http://127.0.0.1:#{origin.port}/", request.to_slice,
            false, true, nil, 1)
          before = origin.hits
          res = tools.call("minimize_repeater",
            JSON.parse(%({"id":#{id2},"apply":true,"allow_unscoped":true})),
            cancelled: -> { origin.hits >= before + 4 })
          payload = JSON.parse(res.text)
          payload["aborted"].as_bool.should be_false  # …not the aborted shape, the other one
          payload["removed_count"].as_i.should be > 0 # …with verified removals in hand
          payload["applied"].as_bool.should be_false  # …and the store was still not written
          store.get_repeater(id2).not_nil!.request.should eq(request.to_slice)
        end
      ensure
        origin.close
      end
    end

    it "stops run_retest dialling, and keeps the steps it did not run as skipped" do
      origin = CountingOrigin.new
      begin
        with_store do |store|
          iid = store.insert_issue("broken access control", Gori::Store::Severity::High,
            "127.0.0.1", nil)
          2.times do |i|
            rid = store.insert_repeater("http://127.0.0.1:#{origin.port}/#{i}",
              "GET /#{i} HTTP/1.1\r\nHost: 127.0.0.1:#{origin.port}\r\n\r\n".to_slice,
              false, true, nil, i)
            store.add_retest_step(iid, Gori::Store::RetestRole::Variant,
              Gori::Store::LinkRefKind::Repeater, rid, "status:200")
          end
          tools = tools_for(store)
          args = JSON.parse(%({"issue_id":#{iid},"allow_unscoped":true}))
          res = tools.call("run_retest", args, cancelled: -> { true })
          payload = JSON.parse(res.text)
          origin.hits.should eq(0)
          # Skipped, never absent: a summary built from the rows that happen to be there would
          # read as a complete pass.
          payload["steps"].as_a.map(&.["outcome"].as_s).should eq(["skipped", "skipped"])
          # The control: the same two steps DO dial without a cancellation.
          tools.call("run_retest", args)
          origin.hits.should eq(2)
        end
      ensure
        origin.close
      end
    end
  end
end

describe "MCP cache_deception_check" do
  it "reports REVIEW when the cache-busted control is itself a cache hit" do
    origin = CountingOrigin.new("private account content", "X-Cache: HIT\r\nAge: 30\r\n")
    begin
      with_store do |store|
        id = cancel_flow(store, origin.port, "/account", cookie: true)
        tools = tools_for(store)
        args = JSON.parse(%({"flow_id":#{id},"allow_unscoped":true,"verify":false}))
        result = tools.call("cache_deception_check", args)

        result.is_error.should be_false
        report = JSON.parse(result.text)
        report["verdict"].as_s.should eq("review")
        report["deception"].as_bool.should be_false
        report["cache"].as_s.should eq("hit")
        report["anonymous"]["cache"].as_s.should eq("hit")
        report["cache_busted"]["cache"].as_s.should eq("hit")
        report["note"].as_s.should contain("may not have bypassed the cache")
        origin.hits.should eq(3)
      end
    ensure
      origin.close
    end
  end
end
