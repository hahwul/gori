require "../spec_helper"
require "socket"

# `fuzz_results` / `get_fuzz_run` with `clusters` and `cluster` (#1351), driven through a
# Tools instance against a local origin whose answers have three SHAPES: a reflected 401 for
# most usernames (every one a different length), a 200 for `admin`, a 500 for `boom`.

private def start_shape_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      line = head ? String.new(head).lines.first : ""
      user = line[/q=([^ ]*)/, 1]? || ""
      status, body =
        case user
        when "admin" then {"200 OK", "<h1>Welcome back</h1>"}
        when "boom"  then {"500 Internal Server Error", "<pre>stack trace</pre>"}
        else              {"401 Unauthorized", "<p>No user named #{user} (ref #{Random.rand(100000)})</p>"}
        end
      conn << "HTTP/1.1 #{status}\r\nDate: #{Time.utc}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
      conn.flush
      conn.close
    end
  end
  port
end

private def call_raw(tools, name, args) : {String, Bool}
  r = tools.call(name, JSON.parse(args.to_json))
  {r.text, r.is_error}
end

private def call_json(tools, name, args) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

private def wait_done(tools, job_id : String) : Nil
  200.times do
    sleep 0.02.seconds
    return unless call_json(tools, "fuzz_status", {job_id: job_id})["status"].as_s == "running"
  end
  fail "fuzz job #{job_id} did not finish"
end

private def start_job(tools, port : Int32, save : Bool = false) : JSON::Any
  call_json(tools, "fuzz_start", {
    "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    "url"            => "http://127.0.0.1:#{port}",
    "payloads"       => [{"list" => ["alpha", "bravo", "charlie-long-name", "delta", "admin", "boom"]}],
    "match"          => {"status" => "500"},
    "save_results"   => save,
    "allow_unscoped" => true,
  })
end

describe "MCP fuzz clusters" do
  it "summarizes a live job by response shape over every result, rare first" do
    port = start_shape_origin
    with_store do |store|
      tools = tools_for(store)
      job_id = start_job(tools, port)["job_id"].as_s
      wait_done(tools, job_id)

      page = call_json(tools, "fuzz_results", {job_id: job_id, clusters: true})
      page["cluster_count"].as_i.should eq(3)
      page["clustered_rows"].as_i.should eq(6)
      page["clusters_truncated"].as_bool.should be_false
      page["cluster_order"].as_s.should eq("rare")
      clusters = page["clusters"].as_a
      clusters.map(&.["count"].as_i).should eq([1, 1, 4])
      clusters.map(&.["status"].as_i).should eq([200, 500, 401])
      reflected = clusters[2]
      reflected["representative_index"].as_i.should eq(0)
      reflected["representative_payloads"].as_a.map(&.as_s).should eq(["alpha"])
      reflected["sample_indices"].as_a.map(&.as_i).should eq([0, 1, 2, 3])
      reflected["representative"]["index"].as_i.should eq(0)
      clusters[1]["matched"].as_i.should eq(1)

      common = call_json(tools, "fuzz_results", {job_id: job_id, clusters: true, cluster_order: "common"})
      common["clusters"][0]["count"].as_i.should eq(4)
      hits = call_json(tools, "fuzz_results", {job_id: job_id, clusters: true, matched_only: true})
      hits["clusters"].as_a.map(&.["status"].as_i).should eq([500])

      # The live cache kept only the match; the 401 cluster's members are named, not stored.
      members = call_json(tools, "fuzz_results", {job_id: job_id, cluster: reflected["id"].as_s})
      members["cluster"]["count"].as_i.should eq(4)
      members["results"].as_a.should be_empty
      members["members_retained"].as_i.should eq(0)
      members["members_note"].as_s.should contain("save_results")
      boom = call_json(tools, "fuzz_results", {job_id: job_id, cluster: clusters[1]["id"].as_s})
      boom["results"].as_a.map(&.["index"].as_i).should eq([5])

      # The default page is untouched.
      rows = call_json(tools, "fuzz_results", {job_id: job_id})
      rows["clusters"]?.should be_nil
      rows["results"][0].as_h.has_key?("shape").should be_false
    end
  end

  it "refuses a malformed, unknown or contradictory cluster request" do
    port = start_shape_origin
    with_store do |store|
      tools = tools_for(store)
      job_id = start_job(tools, port)["job_id"].as_s
      wait_done(tools, job_id)
      text, err = call_raw(tools, "fuzz_results", {job_id: job_id, cluster: "nope"})
      err.should be_true
      text.should contain("16-hex-digit")
      _, err = call_raw(tools, "fuzz_results", {job_id: job_id, cluster: "0123456789abcdef"})
      err.should be_true
      _, err = call_raw(tools, "fuzz_results", {job_id: job_id, clusters: true, cluster: "0123456789abcdef"})
      err.should be_true
      _, err = call_raw(tools, "fuzz_results", {job_id: job_id, clusters: true, cluster_order: "sideways"})
      err.should be_true
    end
  end

  it "clusters a saved run with the same ids as the live job, and pages every member" do
    port = start_shape_origin
    with_store do |store|
      tools = tools_for(store)
      start = start_job(tools, port, save: true)
      job_id = start["job_id"].as_s
      run_id = start["run_id"].as_i64
      wait_done(tools, job_id)
      live = call_json(tools, "fuzz_results", {job_id: job_id, clusters: true})

      reader = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      saved = call_json(reader, "get_fuzz_run", {run_id: run_id, clusters: true})
      saved["clusters"].as_a.map(&.["id"].as_s).should eq(live["clusters"].as_a.map(&.["id"].as_s))
      saved["clusters"].as_a.map(&.["count"].as_i).should eq([1, 1, 4])
      saved["run"]["id"].as_i64.should eq(run_id)
      saved["clusters"].as_a.none? { |c| c["approximate"]? }.should be_true

      id = saved["clusters"][2]["id"].as_s
      first = call_json(reader, "get_fuzz_run", {run_id: run_id, cluster: id, limit: 3})
      first["results"].as_a.map(&.["index"].as_i).should eq([0, 1, 2])
      first["total_available"].as_i.should eq(4)
      first["has_more"].as_bool.should be_true
      rest = call_json(reader, "get_fuzz_run", {run_id: run_id, cluster: id, offset: 3, limit: 3})
      rest["results"].as_a.map(&.["index"].as_i).should eq([3])
      rest["has_more"].as_bool.should be_false
      content = call_json(reader, "get_fuzz_run", {run_id: run_id, cluster: id, limit: 1, include_content: true})
      content["results"][0]["response_body"]["text"].as_s.should contain("No user named alpha")

      _, err = call_raw(reader, "get_fuzz_run", {run_id: run_id, clusters: true, result_index: 0})
      err.should be_true
    end
  end

  it "marks the clusters of a run saved before shapes were recorded approximate" do
    with_store do |store|
      run_id = store.insert_fuzz_run(nil, "http://legacy.test", "sniper", 3_i64, surface: "mcp")
      rows = (0...3).map do |i|
        Gori::Store::FuzzResultWrite.new(i.to_i64, %(["p#{i}"]), 0, i == 2 ? 404 : 200, 2_i64,
          1, 1, 1_i64, nil, false, false, nil)
      end
      store.insert_fuzz_results(run_id, rows).should be_true
      store.finish_fuzz_run(run_id, 3_i64, 0_i64, 0_i64, "done").should be_true
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      page = call_json(tools, "get_fuzz_run", {run_id: run_id, clusters: true})
      page["clusters"].as_a.map(&.["count"].as_i).should eq([1, 2])
      page["clusters"].as_a.all? { |c| c["approximate"]?.try(&.as_bool) }.should be_true
    end
  end
end
