require "../../spec_helper"
require "../../support/mcp_harness"

# `background:true` on the three synchronous send tools (race_requests, timing_requests,
# minimize_repeater): the call answers a `bg_*` job id at once instead of holding every other
# call on the connection, `get_job` hands back the document the synchronous call returns, and
# `stop_job` cancels the run.

# A keep-alive origin answering every request the same, after `delay`.
private def start_bg_origin(delay : Time::Span = Time::Span.zero) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = origin.accept?
      spawn_with(conn) do |c|
        while Gori::Proxy::Codec::Http1.read_head(c)
          sleep delay if delay > Time::Span.zero
          c << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
          c.flush
        end
      rescue
      ensure
        c.close rescue nil
      end
    end
  rescue
  end
  origin
end

private def bg_repeater(store, port : Int32, path : String) : Int64
  store.insert_repeater("http://127.0.0.1:#{port}",
    "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nX-Noise: 1\r\n\r\n".to_slice, false, true, nil, 0)
end

private def bg_call(tools, name : String, args : String) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args))
end

# Poll `get_job` until the run ends, then return its answer.
private def bg_finished(tools, id : String) : Gori::MCP::Tools::Result
  r = bg_call(tools, "get_job", %({"job_id":"#{id}","wait_ms":20000}))
  200.times do
    break unless !r.is_error && (JSON.parse(r.text)["status"]?.try(&.as_s?) == "running")
    r = bg_call(tools, "get_job", %({"job_id":"#{id}","wait_ms":20000}))
  end
  r
end

describe "MCP background calls" do
  it "answers minimize_repeater's job id at once and get_job returns the synchronous document" do
    origin = start_bg_origin
    port = origin.local_address.port
    begin
      with_store do |store|
        id = bg_repeater(store, port, "/m?a=1")
        tools = tools_for(store)
        args = %({"repeater_id":#{id},"allow_unscoped":true})
        sync = bg_call(tools, "minimize_repeater", args)
        sync.is_error.should be_false

        started = JSON.parse(bg_call(tools, "minimize_repeater", args.rchop("}") + %(,"background":true})).text)
        started["kind"].as_s.should eq("background")
        started["tool"].as_s.should eq("minimize_repeater")
        started["status"].as_s.should eq("running")
        job_id = started["job_id"].as_s
        job_id.should start_with("bg_")

        bg_finished(tools, job_id).should eq(sync)
        row = JSON.parse(bg_call(tools, "list_jobs", "{}").text)["jobs"].as_a.find! { |r| r["job_id"].as_s == job_id }
        row["status"].as_s.should eq("done")
        row["tool"].as_s.should eq("minimize_repeater")
      end
    ensure
      origin.close
    end
  end

  # The run read the repeater once, at the call. An edit landing while it runs is the stored
  # request now, and apply:true must not put the old target and a request minimized from text
  # that is no longer stored back over it.
  it "does not apply a background minimize over an edit that landed during the run" do
    origin = start_bg_origin(20.milliseconds)
    port = origin.local_address.port
    begin
      with_store do |store|
        id = bg_repeater(store, port, "/m?a=1")
        tools = tools_for(store)
        started = JSON.parse(bg_call(tools, "minimize_repeater",
          %({"repeater_id":#{id},"allow_unscoped":true,"apply":true,"background":true})).text)
        edited = "GET /edited HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
        store.update_repeater(id: id, target: "http://127.0.0.1:#{port}", request: edited.to_slice,
          http2: false, auto_cl: true).should be_true

        report = JSON.parse(bg_finished(tools, started["job_id"].as_s).text)
        report["removed_count"].as_i.should be > 0
        report["applied"].as_bool.should be_false
        report["apply_skipped"].as_s.should contain("changed during the run")
        String.new(store.get_repeater(id).not_nil!.request).should eq(edited)
      end
    ensure
      origin.close
    end
  end

  it "cancels a background timing run with stop_job, and answers other calls while it runs" do
    origin = start_bg_origin(50.milliseconds)
    port = origin.local_address.port
    begin
      with_store do |store|
        a = bg_repeater(store, port, "/a")
        b = bg_repeater(store, port, "/b")
        tools = tools_for(store)
        sync = JSON.parse(bg_call(tools, "timing_requests", %({"repeater_ids":[#{a},#{b}],"count":2,"warmup":0,"allow_unscoped":true})).text)

        started = JSON.parse(bg_call(tools, "timing_requests",
          %({"repeater_ids":[#{a},#{b}],"count":2000,"warmup":0,"allow_unscoped":true,"background":true})).text)
        job_id = started["job_id"].as_s
        # The run is still going; the server is free for the next call.
        running = JSON.parse(bg_call(tools, "get_job", %({"job_id":"#{job_id}"})).text)
        running["status"].as_s.should eq("running")
        running["tool"].as_s.should eq("timing_requests")
        # Leaving the project would pull the store out from under the run, so it waits for it.
        bg_call(tools, "switch_project", %({"unbind":true})).text.should contain("background job(s) are running")

        stop = JSON.parse(bg_call(tools, "stop_job", %({"job_id":"#{job_id}","wait":true,"wait_timeout_ms":30000})).text)
        stop["status"].as_s.should eq("stopped")
        report = JSON.parse(bg_finished(tools, job_id).text)
        report.as_h.keys.should eq(sync.as_h.keys)
        report["iterations"].as_i.should be < 2000 if report["iterations"]?
      end
    ensure
      origin.close
    end
  end

  # Over the real server: the call after a background run is answered while the run goes on,
  # and the session's end stops it.
  it "answers the next call on the connection while a background run goes on" do
    origin = start_bg_origin(50.milliseconds)
    port = origin.local_address.port
    begin
      with_store do |store|
        a = bg_repeater(store, port, "/a")
        b = bg_repeater(store, port, "/b")
        start = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"timing_requests","arguments":) +
                %({"repeater_ids":[#{a},#{b}],"count":2000,"warmup":0,"allow_unscoped":true,"background":true}}})
        list = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_jobs","arguments":{}}})
        resps = mcp_drive(store, start, list, verify_upstream: false)
        job_id = mcp_tool_payload(resps[0])["job_id"].as_s
        row = mcp_tool_payload(resps[1])["jobs"].as_a.find! { |r| r["job_id"].as_s == job_id }
        row["status"].as_s.should eq("running")
        sleep 200.milliseconds # the shutdown's stop lands at the next pair
      end
    ensure
      origin.close
    end
  end

  it "races in the background with the synchronous document's shape" do
    origin = start_bg_origin
    port = origin.local_address.port
    begin
      with_store do |store|
        a = bg_repeater(store, port, "/a")
        b = bg_repeater(store, port, "/b")
        tools = tools_for(store)
        args = %({"repeater_ids":[#{a},#{b}],"allow_unscoped":true)
        sync = JSON.parse(bg_call(tools, "race_requests", args + "}").text)
        job_id = JSON.parse(bg_call(tools, "race_requests", args + %(,"background":true})).text)["job_id"].as_s
        raced = JSON.parse(bg_finished(tools, job_id).text)
        raced.as_h.keys.should eq(sync.as_h.keys)
        raced["responded"].as_i.should eq(2)
      end
    ensure
      origin.close
    end
  end

  it "refuses a background call exactly as a synchronous one, with no job" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      tools = tools_for(store)
      sync = bg_call(tools, "minimize_repeater", %({"repeater_id":#{id}}))
      sync.error_code.should eq("SCOPE_BLOCKED")
      bg_call(tools, "minimize_repeater", %({"repeater_id":#{id},"background":true})).should eq(sync)
      JSON.parse(bg_call(tools, "list_jobs", "{}").text)["count"].as_i.should eq(0)
    end
  end

  it "serves get_job and stop_job with every tool that can return a job" do
    %w[race_requests timing_requests minimize_repeater].each do |tool|
      filter = Gori::MCP::ToolFilter.parse(tool, Gori::MCP::Tools::TOOL_NAMES,
        Gori::MCP::Tools::TOOL_DEPENDENCIES).as(Gori::MCP::ToolFilter)
      filter.allows?("get_job").should be_true
      filter.allows?("stop_job").should be_true
    end
  end
end
