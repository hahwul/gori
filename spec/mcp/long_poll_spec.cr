require "../spec_helper"
require "../support/mcp_harness"
require "socket"

# `wait_ms` long polls: an empty cursor page, or a job still running, is held until something
# arrives instead of answered at once, so an agent does not spend a turn per empty poll.

private def call_json(tools : Gori::MCP::Tools, name : String, args : String,
                      cancelled : Proc(Bool)? = nil) : JSON::Any
  r = tools.call(name, JSON.parse(args), cancelled)
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def elapsed(&) : Time::Span
  t = Time.instant
  yield
  Time.instant - t
end

# A writer on its OWN connection to the project's file, as the TUI's proxy is to `gori mcp`:
# the wait has no in-process signal to lean on.
private def with_two_connections(&)
  dir = File.tempname("gori-long-poll")
  Dir.mkdir_p(dir)
  db = File.join(dir, "p.db")
  writer = Gori::Store.open(db)
  reader = Gori::Store.open(db)
  begin
    yield writer, reader
  ensure
    reader.close
    writer.close
    FileUtils.rm_rf(dir)
  end
end

# An origin that answers each request after `delay`, so a short fuzz run is still running
# when its status is first read.
private def slow_origin(delay : Time::Span) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      sleep delay
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      conn.flush
      conn.close
    end
  end
  origin.local_address.port
end

describe "MCP wait_ms long polls" do
  it "list_history{since, wait_ms} returns a flow another connection commits mid-wait" do
    with_two_connections do |writer, reader|
      tools = tools_for(reader)
      top = mcp_seed_flow(writer, "/before")
      spawn do
        sleep 200.milliseconds
        mcp_seed_flow(writer, "/during")
      end
      j = nil
      took = elapsed { j = call_json(tools, "list_history", %({"since":#{top},"wait_ms":10000})) }
      j.not_nil!["flows"].as_a.map(&.["target"].as_s).should eq(["/during"])
      took.should be < 5.seconds
    end
  end

  it "list_history keeps waiting past a new flow its query rejects" do
    with_store do |store|
      tools = tools_for(store)
      top = mcp_seed_flow(store, "/a")
      spawn do
        sleep 150.milliseconds
        mcp_seed_flow(store, "/skip")
        sleep 150.milliseconds
        mcp_seed_flow(store, "/want")
      end
      j = call_json(tools, "list_history", %({"since":#{top},"wait_ms":10000,"query":"path:/want"}))
      j["flows"].as_a.map(&.["target"].as_s).should eq(["/want"])
    end
  end

  it "list_history wakes a filtered tail when a response lands on a flow it already has" do
    with_store do |store|
      tools = tools_for(store)
      top = mcp_seed_flow(store, "/a")
      pending = mcp_seed_flow(store, "h.test", "GET", "/slow")
      spawn do
        sleep 200.milliseconds
        store.update_response(Gori::Store::CapturedResponse.new(
          flow_id: pending, status: 500, head: "HTTP/1.1 500 Oops\r\n\r\n".to_slice, body: nil, content_type: nil))
      end
      j = call_json(tools, "list_history", %({"since":#{top},"wait_ms":10000,"query":"status:500"}))
      j["flows"].as_a.map(&.["id"].as_i64).should eq([pending])
    end
  end

  it "list_history returns the empty page once wait_ms runs out" do
    with_store do |store|
      tools = tools_for(store)
      top = mcp_seed_flow(store, "/a")
      j = nil
      took = elapsed { j = call_json(tools, "list_history", %({"since":#{top},"wait_ms":250})) }
      j.not_nil!["flows"].as_a.should be_empty
      took.should be >= 250.milliseconds
    end
  end

  it "refuses list_history{wait_ms} without 'since'" do
    with_store do |store|
      r = tools_for(store).call("list_history", JSON.parse(%({"wait_ms":1000})))
      r.is_error.should be_true
      r.text.should contain("since")
    end
  end

  it "stops waiting when the call is cancelled" do
    with_store do |store|
      tools = tools_for(store)
      top = mcp_seed_flow(store, "/a")
      cancel = false
      spawn do
        sleep 150.milliseconds
        cancel = true
      end
      took = elapsed { call_json(tools, "list_history", %({"since":#{top},"wait_ms":30000}), -> { cancel }) }
      took.should be < 5.seconds
    end
  end

  it "list_events{wait_ms} returns the next matching event, past ones the filter drops" do
    with_store do |store|
      tools = tools_for(store)
      since = store.insert_event("probe", "a", :info, "old")
      spawn do
        sleep 150.milliseconds
        store.insert_event("probe", "noise", :info, "skip")
        sleep 150.milliseconds
        store.insert_event("probe", "a", :info, "new")
      end
      j = call_json(tools, "list_events", %({"since":#{since},"kind":"a","wait_ms":10000}))
      j["events"].as_a.map(&.["message"].as_s).should eq(["new"])
      j["next_cursor"].as_i64.should be > since
    end
  end

  it "operator_messages{wait_ms} returns a message the operator writes mid-wait" do
    with_two_connections do |writer, reader|
      tools = tools_for(reader)
      tools.call("operator_messages", JSON.parse("{}")) # take the floor
      spawn do
        sleep 200.milliseconds
        writer.post_agent_message("go", "all", nil)
      end
      j = call_json(tools, "operator_messages", %({"wait_ms":10000}))
      j["messages"].as_a.map(&.["text"].as_s).should eq(["go"])
    end
  end

  it "fuzz_status{wait_ms} holds while the job runs and answers once it ends" do
    with_store do |store|
      port = slow_origin(150.milliseconds)
      tools = tools_for(store)
      job_id = call_json(tools, "fuzz_start", {
        template:       "GET /f?q=§FUZZ§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url:            "http://127.0.0.1:#{port}",
        payloads:       [{list: ["a", "b", "c"]}],
        allow_unscoped: true,
      }.to_json)["job_id"].as_s
      call_json(tools, "fuzz_status", {job_id: job_id}.to_json)["status"].as_s.should eq("running")
      call_json(tools, "get_job", {job_id: job_id, wait_ms: 15000}.to_json)["status"].as_s.should eq("done")
    end
  end
end
