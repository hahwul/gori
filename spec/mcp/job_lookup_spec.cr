require "../spec_helper"
require "socket"

# The job-addressed tools of all five async kinds (fuzz, mine, sequence, discover, authorize):
# how `<kind>_status` / `<kind>_results` / `<kind>_stop` resolve a `job_id`, what the stop
# replies say across a job's life, and the rows `list_jobs` draws. Every refusal is compared
# as a whole `Result` (text, code, field, details), so a refusal that keeps its words but loses
# its code still fails here.

module Gori::MCP
  class Tools
    # Point the server at another project without closing anything, so every job reads as
    # started elsewhere (`job_project_mismatch`).
    def job_lookup_spec_rebind(path : String?) : String?
      prev = @db_path
      @db_path = path
      prev
    end
  end
end

JOB_LOOKUP_KINDS = %w[fuzz mine sequence discover authorize]

# Every response waits, so each job is still in flight when the example stops it.
private def start_slow_origin : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while accepted = server.accept?
      spawn_with(accepted) do |conn|
        Gori::Proxy::Codec::Http1.read_head(conn)
        sleep 400.milliseconds
        body = "token #{Random::Secure.hex(8)}"
        conn << "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{Random::Secure.hex(8)}\r\n" \
                "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
        conn.flush
      rescue
      ensure
        conn.close rescue nil
      end
    end
  end
  port
end

private def seed_flow(store, port, target) : Int64
  head = "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nCookie: session=abc123\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: nil, content_type: nil))
  id
end

private def invoke(tools, name, args) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args.to_json))
end

private def ok_json(tools, name, args) : JSON::Any
  r = invoke(tools, name, args)
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# One running job of each kind, keyed by kind.
private def start_all(tools, store, port) : Hash(String, String)
  url = "http://127.0.0.1:#{port}"
  template = "GET /t?q=§FUZZ§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
  plain = "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
  ids = {} of String => String
  ids["fuzz"] = ok_json(tools, "fuzz_start", {template: template, url: url, concurrency: 1,
                                              payloads: [{list: (1..50).map(&.to_s)}], allow_unscoped: true})["job_id"].as_s
  ids["mine"] = ok_json(tools, "mine_start", {template: plain, url: url, concurrency: 1,
                                              allow_unscoped: true})["job_id"].as_s
  ids["sequence"] = ok_json(tools, "sequence_start", {template: plain, url: url, cookie: "sid",
                                                      count: 50, allow_unscoped: true})["job_id"].as_s
  ids["discover"] = ok_json(tools, "discover_start", {url: "#{url}/", concurrency: 1,
                                                      allow_unscoped: true})["job_id"].as_s
  flows = (1..10).map { |i| seed_flow(store, port, "/admin/#{i}") }
  ids["authorize"] = ok_json(tools, "authorize_start", {flow_ids: flows,
                                                        identities: [{name: "anonymous", remove: ["Cookie"]}], allow_unscoped: true})["job_id"].as_s
  ids
end

private def wait_stopped(tools, id : String) : JSON::Any
  ok_json(tools, "stop_job", {job_id: id, wait: true, wait_timeout_ms: 30_000})
end

private def result(text, code = nil, field = nil, details = nil) : Gori::MCP::Tools::Result
  Gori::MCP::Tools::Result.new(text, is_error: true, error_code: code, field: field,
    details: details.try { |d| JSON.parse(d.to_json) })
end

JOB_STOP_KEYS = %w[job_id status stop_requested stopped stop_requested_at stopped_at]

describe "MCP job lookup and stop, across all five kinds" do
  it "resolves each kind's job_id, and refuses missing, unknown, and wrong-kind ids exactly" do
    with_store do |store|
      port = start_slow_origin
      tools = tools_for(store)
      ids = start_all(tools, store, port)
      ids.keys.should eq(JOB_LOOKUP_KINDS)
      ids.values.map(&.[0, 3]).should eq(%w[fz_ mn_ sq_ ds_ az_])

      JOB_LOOKUP_KINDS.each do |kind|
        own = ids[kind]
        invoke(tools, "#{kind}_status", {job_id: own}).is_error.should be_false
        JSON.parse(invoke(tools, "#{kind}_status", {job_id: own}).text)["job_id"].as_s.should eq(own)
        JSON.parse(invoke(tools, "get_job", {job_id: own}).text)["job_id"].as_s.should eq(own)

        %w[status results stop].each do |verb|
          tool = "#{kind}_#{verb}"
          # authorize names the field; the four older kinds leave it to the generic classifier,
          # which codes the refusal but names no field.
          missing = result("missing required 'job_id'", "INVALID_ARGUMENT", kind == "authorize" ? "job_id" : nil)
          invoke(tools, tool, {job_id: ""}).should eq(missing)
          invoke(tools, tool, {} of String => String).should eq(missing)

          invoke(tools, tool, {job_id: "zz_9"}).should eq(result("no #{kind} job zz_9", "NOT_FOUND"))

          JOB_LOOKUP_KINDS.each do |other|
            next if other == kind
            foreign = ids[other]
            invoke(tools, tool, {job_id: foreign}).should eq(result(
              "no #{kind} job #{foreign} — #{foreign} is a #{other} job: use #{other}_#{verb} " \
              "(or get_job / stop_job, which take any kind)", "NOT_FOUND", "job_id", {"job_kind" => other}))
          end
          # An id no map holds still names its kind by its prefix.
          prefixed = kind == "fuzz" ? "mn_999" : "fz_999"
          named = kind == "fuzz" ? "mine" : "fuzz"
          invoke(tools, tool, {job_id: prefixed}).should eq(result(
            "no #{kind} job #{prefixed} — #{prefixed} is a #{named} job: use #{named}_#{verb} " \
            "(or get_job / stop_job, which take any kind)", "NOT_FOUND", "job_id", {"job_kind" => named}))
        end
      end
      invoke(tools, "get_job", {job_id: "zz_9"}).should eq(result("no job zz_9", "NOT_FOUND"))
      invoke(tools, "stop_job", {job_id: "zz_9"}).should eq(result("no job zz_9", "NOT_FOUND"))

      # Nothing above stopped anything.
      ids.each_value { |id| ok_json(tools, "get_job", {job_id: id})["status"].as_s.should eq("running") }
      ids.each_value { |id| wait_stopped(tools, id) }
    end
  end

  it "lists every kind's row with its own fields" do
    with_store do |store|
      port = start_slow_origin
      tools = tools_for(store)
      ids = start_all(tools, store, port)
      listed = ok_json(tools, "list_jobs", {} of String => String)
      listed.as_h.keys.should eq(%w[count jobs])
      listed["count"].as_i.should eq(5)
      rows = listed["jobs"].as_a
      rows.map(&.["job_id"].as_s).should eq(%w[fuzz mine discover sequence authorize].map { |k| ids[k] })
      by_kind = rows.to_h { |r| {r["kind"].as_s, r} }
      by_kind["fuzz"].as_h.keys.should eq(%w[job_id kind status sent requests total matched target])
      by_kind["mine"].as_h.keys.should eq(%w[job_id kind status sent names_total found target])
      by_kind["discover"].as_h.keys.should eq(%w[job_id kind status sent found target])
      by_kind["sequence"].as_h.keys.should eq(%w[job_id kind status goal collected target])
      by_kind["authorize"].as_h.keys.should eq(%w[job_id kind status sent requests_total requests_replayed bypass_count target])
      rows.each(&.["status"].as_s.should(eq("running")))
      by_kind["fuzz"]["total"].as_i.should eq(50)
      by_kind["sequence"]["goal"].as_i.should eq(50)
      by_kind["authorize"]["requests_total"].as_i.should eq(10)
      by_kind["fuzz"]["target"].as_s.should eq("http://127.0.0.1:#{port}")

      ids.each_value { |id| wait_stopped(tools, id) }

      # Terminal rows carry no clock, so the whole listing is stable from here on.
      before = invoke(tools, "list_jobs", {} of String => String).text
      invoke(tools, "list_jobs", {} of String => String).text.should eq(before)
      JSON.parse(before)["jobs"].as_a.each(&.["status"].as_s.should(eq("stopped")))

      # A job started in another project is flagged on its row, and every per-kind read of it
      # refuses with PROJECT_CHANGED.
      original = tools.job_lookup_spec_rebind("/elsewhere.db")
      begin
        flagged = ok_json(tools, "list_jobs", {} of String => String)["jobs"].as_a
        flagged.each do |r|
          r["project_changed"].as_bool.should be_true
          r["job_db_path"].as_s?.should eq(original)
        end
        JOB_LOOKUP_KINDS.each do |kind|
          id = ids[kind]
          %w[status results stop].each do |verb|
            invoke(tools, "#{kind}_#{verb}", {job_id: id}).should eq(result(
              "job #{id} ran against a different project (#{original || "unknown"}); " \
              "switch back to that project to read its results", "PROJECT_CHANGED", nil,
              {"job_db_path" => original, "current_db_path" => "/elsewhere.db"}))
          end
          invoke(tools, "stop_job", {job_id: id}).error_code.should eq("PROJECT_CHANGED")
        end
      ensure
        tools.job_lookup_spec_rebind(original)
      end
    end
  end

  it "walks each kind's stop reply from running, through a repeat stop, to finished" do
    with_store do |store|
      port = start_slow_origin
      tools = tools_for(store)
      ids = start_all(tools, store, port)

      first = {} of String => JSON::Any
      JOB_LOOKUP_KINDS.each do |kind|
        id = ids[kind]
        stop = ok_json(tools, "#{kind}_stop", {job_id: id})
        stop.as_h.keys.should eq(JOB_STOP_KEYS)
        stop["job_id"].as_s.should eq(id)
        stop["status"].as_s.should eq("running")
        stop["stop_requested"].as_bool.should be_true
        stop["stopped"].as_bool.should be_false
        stop["stop_requested_at"].as_i64.should be > 0
        stop["stopped_at"].raw.should be_nil
        first[kind] = stop
      end

      # A second stop while the run winds down keeps the first request's time.
      JOB_LOOKUP_KINDS.each do |kind|
        again = ok_json(tools, "#{kind}_stop", {job_id: ids[kind]})
        again.should eq(first[kind])
      end

      JOB_LOOKUP_KINDS.each do |kind|
        id = ids[kind]
        400.times do
          break unless ok_json(tools, "get_job", {job_id: id})["status"].as_s == "running"
          sleep 50.milliseconds
        end
        requested = first[kind]["stop_requested_at"]
        late = invoke(tools, "#{kind}_stop", {job_id: id}).text
        stopped_at = JSON.parse(late)["stopped_at"].as_i64
        stopped_at.should be >= requested.as_i64
        late.should eq(%({"job_id":"#{id}","status":"stopped","stop_requested":true,"stopped":true,) +
                       %("already_finished":true,"stop_requested_at":#{requested},"stopped_at":#{stopped_at}}))
        invoke(tools, "stop_job", {job_id: id}).text.should eq(late)
        invoke(tools, "stop_job", {job_id: id, wait: true}).text.should eq(late)
      end
    end
  end
end
