require "../spec_helper"
require "socket"

# `payload_from` over MCP (#1352): on `fuzz_start` (a payload set), `mine_start` (candidate
# names) and `save_wordlist` (a saved list). What these pin is what an agent can rely on: the
# reply says what each source read and which secret policy applied and NEVER carries a value, a
# credential is withheld unless the opt-in is passed, an empty or malformed source is refused by
# name, and only the bound project is ever read.
private def start_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      conn.flush
      conn.close
    end
  end
  port
end

private CLOCK = [1_700_000_000_000_000_i64]

private def seed(store : Gori::Store, target : String, host = "api.test", req_headers = "",
                 method = "GET", body : String? = nil) : Int64
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443, method: method, target: target,
    http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n#{req_headers}\r\n".to_slice,
    body: body.try(&.to_slice), source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ok".to_slice))
  id
end

private def call(tools, name : String, args) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args.is_a?(String) ? args : args.to_json))
end

private def ok(tools, name : String, args) : JSON::Any
  r = call(tools, name, args)
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def wait_done(tools, status_tool : String, job_id : String) : Nil
  100.times do
    sleep 0.02.seconds
    return unless ok(tools, status_tool, {job_id: job_id})["status"].as_s == "running"
  end
  fail "#{status_tool} #{job_id} did not finish"
end

describe "MCP payload_from" do
  describe "fuzz_start" do
    it "reads the project into a payload set, says what it read, and never returns a value" do
      port = start_origin
      with_store do |store|
        seed(store, "/a?alphaparam=secretlookingvalue&betaparam=2")
        tools = tools_for(store)
        start = ok(tools, "fuzz_start", {
          "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
          "url"            => "http://127.0.0.1:#{port}",
          "payloads"       => [{"payload_from" => "host:api.test param-names"}],
          "allow_unscoped" => true,
        })
        start["total"].as_i.should eq(2)
        src = start["payload_sources"].as_a.first
        src["source"].as_s.should eq("host:api.test param-names")
        src["projection"].as_s.should eq("param-names")
        src["values"].as_i.should eq(2)
        src["flows_scanned"].as_i.should eq(1)
        src["policy"].as_s.should eq("sensitive-excluded")
        src["truncated"].as_bool.should be_false
        src["locations"].as_a.map(&.as_s).should eq(%w[query form multipart json])
        start.to_json.should_not contain("secretlookingvalue")
        wait_done(tools, "fuzz_status", start["job_id"].as_s)
        sent = ok(tools, "fuzz_results", {job_id: start["job_id"].as_s})["results"].as_a.map(&.["payloads"].as_a.first.as_s)
        sent.sort.should eq(["alphaparam", "betaparam"])
      end
    end

    it "composes with the other sets, in order" do
      port = start_origin
      with_store do |store|
        seed(store, "/a?one=1&two=2")
        tools = tools_for(store)
        start = ok(tools, "fuzz_start", {
          "template"       => "GET /?a=§x§&b=§y§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
          "url"            => "http://127.0.0.1:#{port}",
          "mode"           => "pitchfork",
          "payloads"       => [{"list" => ["u1", "u2"]}, {"payload_from" => "param-names"}],
          "allow_unscoped" => true,
        })
        start["total"].as_i.should eq(2)
        start["payload_sources"].as_a.size.should eq(1)
      end
    end

    it "withholds credential values by default and says the source produced nothing, not that it found none" do
      with_store do |store|
        seed(store, "/a?password=hunter2&token=abc")
        tools = tools_for(store)
        r = call(tools, "fuzz_start", {
          "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
          "payloads" => [{"payload_from" => "param-values"}], "allow_unscoped" => true,
        })
        r.is_error.should be_true
        r.text.should contain("produced no values")
        r.text.should contain("2 sensitive skipped")
        r.text.should_not contain("hunter2")
      end
    end

    it "reads a credential value only under include_sensitive, and the reply carries that policy" do
      port = start_origin
      with_store do |store|
        seed(store, "/a?password=hunter2")
        tools = tools_for(store)
        start = ok(tools, "fuzz_start", {
          "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:#{port}",
          "payloads" => [{"payload_from" => "param-values", "include_sensitive" => true}], "allow_unscoped" => true,
        })
        src = start["payload_sources"].as_a.first
        src["policy"].as_s.should eq("sensitive-included")
        src["summary"].as_s.should contain("SENSITIVE INCLUDED")
        start.to_json.should_not contain("hunter2") # the reply never carries a value, opt-in or not
      end
    end

    it "honours locations, max_flows and max_values, and reports the cap that ended the read" do
      port = start_origin
      with_store do |store|
        10.times { |i| seed(store, "/a?p#{i}=1", req_headers: "Cookie: zzcookie#{i}=v\r\n") }
        tools = tools_for(store)
        start = ok(tools, "fuzz_start", {
          "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:#{port}",
          "payloads" => [{"payload_from" => "param-names", "locations" => "query,cookies", "max_values" => 4}],
          "allow_unscoped" => true,
        })
        src = start["payload_sources"].as_a.first
        src["values"].as_i.should eq(4)
        src["truncated"].as_bool.should be_true
        src["capped_by"].as_s.should eq("values")
        src["locations"].as_a.map(&.as_s).should eq(%w[query cookies])
        start["total"].as_i.should eq(4)
      end
    end

    it "refuses a malformed descriptor, an unknown projection and a non-string, by name" do
      with_store do |store|
        seed(store, "/a?x=1")
        tools = tools_for(store)
        base = {"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1", "allow_unscoped" => true}
        r = call(tools, "fuzz_start", base.merge({"payloads" => [{"payload_from" => "host:api.test"}]}))
        r.is_error.should be_true
        r.text.should contain("does not end in a projection")
        call(tools, "fuzz_start", base.merge({"payloads" => [{"payload_from" => "host:x params"}]})).text.should contain("projection")
        call(tools, "fuzz_start", base.merge({"payloads" => [{"payload_from" => 5}]})).text.should contain("must be a string")
        call(tools, "fuzz_start", base.merge({"payloads" => [{"payload_from" => "param-names", "locations" => "query,bogus"}]})).text.should contain("unknown 'locations' entry")
      end
    end

    it "refuses a query naming a field QL does not have instead of reading more" do
      with_store do |store|
        seed(store, "/a?x=1")
        r = call(tools_for(store), "fuzz_start", {
          "template" => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
          "payloads" => [{"payload_from" => "methd:GET param-names"}], "allow_unscoped" => true,
        })
        r.is_error.should be_true
        r.text.should contain("unknown field `methd:`")
      end
    end
  end

  describe "mine_start" do
    it "tests project names ahead of the built-in list, and reports what each source read" do
      port = start_origin
      with_store do |store|
        seed(store, "/a?zzprojname=1&zzsecondname=2")
        tools = tools_for(store)
        base_names = ok(tools, "mine_start", {
          "template" => "GET /s?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:#{port}",
          "allow_unscoped" => true, "max_requests" => 1,
        })["names"].as_i
        start = ok(tools, "mine_start", {
          "template" => "GET /s?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:#{port}",
          "payload_from" => "host:api.test param-names", "allow_unscoped" => true, "max_requests" => 1,
        })
        start["names"].as_i.should eq(base_names + 2)
        src = start["payload_sources"].as_a.first
        src["values"].as_i.should eq(2)
        src["source"].as_s.should eq("host:api.test param-names")
        ok(tools, "mine_stop", {job_id: start["job_id"].as_s})
      end
    end

    it "refuses a projection that is not a list of names" do
      with_store do |store|
        seed(store, "/a?x=1")
        r = call(tools_for(store), "mine_start", {
          "template" => "GET /s?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", "url" => "http://127.0.0.1:1",
          "payload_from" => "param-values", "allow_unscoped" => true,
        })
        r.is_error.should be_true
        r.text.should contain("reads parameter NAMES")
      end
    end
  end

  describe "save_wordlist" do
    it "saves the project's values as a global list, with the source's report" do
      with_wordlist_home do |dir|
        with_store do |store|
          seed(store, "/a?alphaparam=1&betaparam=2")
          seed(store, "/b?alphaparam=3")
          tools = tools_for(store)
          r = ok(tools, "save_wordlist", {"name" => "api-names.txt", "payload_from" => "host:api.test param-names"})
          r["values"].as_i.should eq(2)
          r["payload_source"]["values"].as_i.should eq(2)
          r["payload_source"]["policy"].as_s.should eq("sensitive-excluded")
          File.read(File.join(dir, "api-names.txt")).lines.sort!.should eq(["alphaparam", "betaparam"])
          (File.info(File.join(dir, "api-names.txt")).permissions.value & 0o777).should eq(0o600)
        end
      end
    end

    it "does not save credential material unless include_sensitive, and refuses the empty result" do
      with_wordlist_home do |dir|
        with_store do |store|
          seed(store, "/a?password=hunter2")
          tools = tools_for(store)
          r = call(tools, "save_wordlist", {"name" => "creds.txt", "payload_from" => "param-values"})
          r.is_error.should be_true
          Gori::WordlistCatalog.list.entries.should be_empty
          r2 = ok(tools, "save_wordlist", {"name" => "creds.txt", "payload_from" => "param-values", "include_sensitive" => true})
          r2["payload_source"]["policy"].as_s.should eq("sensitive-included")
          File.read(File.join(dir, "creds.txt")).should eq("hunter2\n")
        end
      end
    end

    it "leaves out a value with a line break, and counts it" do
      with_wordlist_home do |dir|
        with_store do |store|
          seed(store, "/a?x=fine&y=two%0aline")
          r = ok(tools_for(store), "save_wordlist", {"name" => "v.txt", "payload_from" => "param-values"})
          r["values"].as_i.should eq(1)
          r["skipped_line_break"].as_i.should eq(1)
          File.read(File.join(dir, "v.txt")).should eq("fine\n")
        end
      end
    end

    it "refuses both sources at once, and payload_from with no project bound" do
      with_wordlist_home do
        with_store do |store|
          seed(store, "/a?x=1")
          r = call(tools_for(store), "save_wordlist", {"name" => "v.txt", "values" => ["a"], "payload_from" => "param-names"})
          r.is_error.should be_true
          r.text.should contain("not both")
        end
        unbound = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false)
        r = call(unbound, "save_wordlist", {"name" => "v.txt", "payload_from" => "param-names"})
        r.is_error.should be_true
        r.error_code.should eq("NO_PROJECT")
        Gori::WordlistCatalog.list.entries.should be_empty
      end
    end
  end
end
