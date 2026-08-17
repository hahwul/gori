require "../spec_helper"
require "socket"

# Every MCP integer argument that ends up in an Int32 has to be BOUNDED IN Int64 FIRST.
# Crystal's `.to_i` / `.to_i32` are checked, so a large-but-legal integer — `{"limit":
# 10000000000}`, the "no limit" number an LLM reaches for — raised OverflowError at the call
# site, sailed past the INVALID_ARGUMENT arm in `Tools#call` and came back as INTERNAL
# "tool error: Arithmetic overflow". An INTERNAL code tells an agent's error policy "the
# server is broken, back off / escalate" over a mistake in its own arguments.
#
# `Tools#clamp` and `mine_bucket` were already written in the right order; preview_color_rule,
# compare_flows and the extract-rule offsets inverted it.

private def with_store(&)
  path = File.tempname("gori-mcp-ints", ".db")
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

private def int_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

# The failure this file exists for: an INTERNAL result carrying the OverflowError's message.
private def refute_overflow(r : Gori::MCP::Tools::Result, what : String)
  r.error_code.should_not eq("INTERNAL")
  if r.text.includes?("Arithmetic overflow")
    fail "#{what} came back as an arithmetic overflow: #{r.text[0, 200]}"
  end
end

private def int_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  refute_overflow(r, "#{name}#{args}")
  fail "tool #{name}#{args} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_int_flow(store, body : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
    body: body.to_slice, content_type: "text/plain"))
  id
end

describe "MCP integer arguments — bounded before they are narrowed" do
  it "preview_color_rule bounds a huge 'limit' instead of overflowing into INTERNAL" do
    with_store do |store|
      tools = int_tools(store)
      pv = int_json(tools, "preview_color_rule", %({"when":"body:secret","limit":10000000000}))
      pv["scanned"].as_i.should eq(0)
      pv["would_match"].as_i.should eq(0)
    end
  end

  # The floor stays a CLAMP, not a refusal. `0` is the other spelling of "no limit" an agent
  # reaches for — right beside the huge number above — and this argument has been forgiving at
  # both ends since it existed (`list_history`'s row limit still is). Pinned so the overflow fix
  # above cannot quietly turn one way of failing the call into another.
  it "preview_color_rule clamps a 'limit' below the floor instead of failing the call" do
    with_store do |store|
      r = int_tools(store).call("preview_color_rule", JSON.parse(%({"when":"body:secret","limit":0})))
      r.is_error.should be_false
    end
  end

  it "compare_flows bounds a huge 'context' instead of overflowing into INTERNAL" do
    with_store do |store|
      a = seed_int_flow(store, "line1\nline2\nline3")
      b = seed_int_flow(store, "line1\nCHANGED\nline3")
      tools = int_tools(store)
      huge = int_json(tools, "compare_flows",
        %({"flow_id_a":#{a},"flow_id_b":#{b},"context":5000000000}))
      # A context at or past the diff's length folds nothing, so the bound is exact: the
      # huge value must diff identically to a context that already covers the whole message.
      wide = int_json(tools, "compare_flows",
        %({"flow_id_a":#{a},"flow_id_b":#{b},"context":1000}))
      huge["changed_lines"].as_i.should be > 0
      huge["diff"].should eq(wide["diff"])
    end
  end

  it "create_extract_rule bounds a huge 'pos_start' instead of overflowing into INTERNAL" do
    with_store do |store|
      tools = int_tools(store)
      int_json(tools, "create_extract_rule",
        %({"name":"TOK","kind":"cookie","selector":"sid","pos_start":5000000000}))
      row = store.extract_rules.find { |r| r.name == "TOK" }.not_nil!
      row.pos_start.should eq(Int32::MAX)
    end
  end

  it "update_extract_rule bounds a huge 'pos_end' and leaves the stored offsets alone when omitted" do
    with_store do |store|
      tools = int_tools(store)
      int_json(tools, "create_extract_rule",
        %({"name":"TOK","kind":"cookie","selector":"sid"}))
      id = store.extract_rules.find { |r| r.name == "TOK" }.not_nil!.id
      int_json(tools, "update_extract_rule", %({"id":#{id},"pos_end":5000000000}))
      row = store.extract_rules.find { |r| r.id == id }.not_nil!
      row.pos_end.should eq(Int32::MAX)
      row.pos_start.should eq(0)

      # The omitted-field contract still holds: a later update that names neither offset
      # must pass the stored values through, not re-read them as caller input.
      int_json(tools, "update_extract_rule", %({"id":#{id},"selector":"session"}))
      kept = store.extract_rules.find { |r| r.id == id }.not_nil!
      kept.pos_end.should eq(Int32::MAX)
      kept.selector.should eq("session")
    end
  end
end

# The OTHER half of the integer contract, and the one this file was missing: a value the
# caller SUPPLIED but gori cannot read as an integer must be refused BY NAME, never
# substituted with the tool's default. `Tools#int` answers nil for a container / a
# non-numeric string, and every non-id call site read that nil as "the caller did not pass
# it" — so `fuzz_start{rate:"fast", max_requests:{"n":1}, concurrency:[5]}` came back
# `isError:false` and swept with NO rate limit, NO request budget and the default
# concurrency. The two knobs that bound an active run are exactly the ones an LLM is most
# likely to spell wrong.
#
# `str_args_spec` and `bool_args_spec` pin this same contract for the other two primitives;
# `optional_int_arg` / `bounded_int_arg` are its integer half.
# A space after `{` on purpose: `{%` opens a macro expression.
private REFUSED_INT_FORMS = { %({"a":1}), "[1,2]", %("fast"), %("30s") }

private def refuses_int(tools : Gori::MCP::Tools, name : String, field : String,
                        args : Proc(String, String))
  REFUSED_INT_FORMS.each do |bad|
    r = tools.call(name, JSON.parse(args.call(bad)))
    unless r.is_error
      fail "#{name}{#{field}: #{bad}} was accepted (#{r.text[0, 240]})"
    end
    r.text.should contain("'#{field}'")
    r.text.should contain("expected an integer")
  end
end

describe "MCP integer arguments — refused by name, never silently defaulted" do
  it "refuses an unreadable pagination value instead of paging with the default" do
    with_store do |store|
      tools = int_tools(store)
      {"list_history" => {"limit", "before_id", "since"},
       "list_events"  => {"limit", "since"},
       "list_sitemap" => {"limit"},
       "list_issues"  => {"limit", "offset"},
       "probe_issues" => {"limit", "offset"}}.each do |tool, fields|
        fields.each do |field|
          refuses_int(tools, tool, field, ->(bad : String) { %({"#{field}":#{bad}}) })
        end
      end
    end
  end

  it "fuzz_start refuses an unreadable rate/max_requests/concurrency rather than running unbounded" do
    with_store do |store|
      tools = int_tools(store)
      base = %("url":"http://127.0.0.1:9/",) +
             %("template":"GET /§FUZZ§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
             %("payloads":[{"numbers":"1-2"}],"allow_unscoped":true,"record_history":false)
      # `rate` is covered separately — it is a NUMBER, so its refusal says so (see below).
      {"max_requests", "concurrency", "timeout_ms", "retries", "throttle_ms"}.each do |field|
        refuses_int(tools, "fuzz_start", field, ->(bad : String) { %({#{base},"#{field}":#{bad}}) })
      end
      REFUSED_INT_FORMS.each do |bad|
        r = tools.call("fuzz_start", JSON.parse(%({#{base},"rate":#{bad}})))
        r.is_error.should be_true
        r.text.should contain("'rate'")
        r.text.should contain("expected a number")
      end
      # Nothing was launched: a refused argument must not leave a job behind.
      JSON.parse(tools.call("list_jobs", JSON.parse("{}")).text)["jobs"].as_a.should be_empty
    end
  end

  it "keeps the lenient encodings working — an integral float and a numeric string" do
    with_store do |store|
      tools = int_tools(store)
      int_json(tools, "list_issues", %({"limit":5.0,"offset":"0"}))["limit"].as_i.should eq(5)
    end
  end

  it "SATURATES a number outside Int64 instead of refusing it or falling back to the default" do
    with_store do |store|
      tools = int_tools(store)
      3.times { |i| seed_int_flow(store, "b#{i}") }
      # `1e19` is the "no limit" value an LLM emits: unambiguous intent, so it must reach the
      # tool's own clamp. Answering nil (what `int` used to do) fell back to a default SMALLER
      # than anything the caller could have meant, and once nil became an argument error it
      # would have refused a perfectly legal number.
      {"1e19", %("99999999999999999999")}.each do |huge|
        int_json(tools, "list_history", %({"limit":#{huge}})).as_a.size.should eq(3)
      end
      # A fractional float still has no integer reading, so it stays a refusal — the same rule
      # `get_flow{id:1.9}` has always applied, now stated for a non-id argument too.
      r = tools.call("list_issues", JSON.parse(%({"limit":5.9})))
      r.is_error.should be_true
      r.text.should contain("'limit'")
    end
  end
end

# An argument that is refused must be refused BEFORE the side effect it accompanies. Making
# an unreadable integer a REFUSAL created this hazard where the value used to default
# silently: `max_body_bytes` / `limit` / `wait_timeout_ms` only shape a REPLY, so they were
# read on the way out — after the request was on the wire, after the History row and the saved
# repeater, after `job.stop`. An agent reads `isError:true` as "nothing happened", fixes the
# argument and calls again, so the send is duplicated and the stopped job is polled forever.
# The rule is `minimize_repeater`'s: every argument is validated before the sends are spent.
describe "MCP integer arguments — refused before the side effect, not after" do
  it "send_request refuses an unreadable max_body_bytes without sending or persisting anything" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    hits = 0
    spawn do
      while conn = origin.accept?
        hits += 1
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
        conn.close
      end
    end
    with_store do |store|
      tools = int_tools(store)
      r = tools.call("send_request", JSON.parse(
        %({"url":"http://127.0.0.1:#{port}/","allow_unscoped":true,) +
        %("save_as_repeater":true,"max_body_bytes":"all"})))
      r.is_error.should be_true
      r.text.should contain("'max_body_bytes'")
      sleep 50.milliseconds # give a stray send time to land, if one escaped
      hits.should eq(0)
      store.count.should eq(0) # no History flow
      store.repeaters.size.should eq(0)
    end
    origin.close
  end

  it "stop_job refuses an unreadable wait_timeout_ms without stopping the job" do
    with_store do |store|
      tools = int_tools(store)
      start = tools.call("fuzz_start", JSON.parse({
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:9/",
        "payloads"       => %([{"list":["a"]}]),
        "allow_unscoped" => true,
        "record_history" => false,
      }.to_json))
      job_id = JSON.parse(start.text)["job_id"].as_s
      r = tools.call("stop_job", JSON.parse(%({"job_id":#{job_id.to_json},"wait":true,"wait_timeout_ms":"5s"})))
      r.is_error.should be_true
      r.text.should contain("'wait_timeout_ms'")
      status = JSON.parse(tools.call("fuzz_status", JSON.parse(%({"job_id":#{job_id.to_json}}))).text)
      status["stop_requested_at"]?.try(&.raw).should be_nil
    end
  end
end

# `rate` is the one MCP number that is genuinely fractional: `Config#rps` is a Float64? and
# `gori run fuzz --rate` parses it with `to_f?`. Reading it through the integer reader first
# swallowed `0.5` (rate unset ⇒ UNLIMITED — the opposite of the ask) and then, once that
# became a refusal, made sub-1 rps inexpressible from this surface entirely.
describe "MCP 'rate' — a number, not an integer" do
  it "accepts a fractional rate and reports it back in the audit" do
    with_store do |store|
      tools = int_tools(store)
      start = tools.call("fuzz_start", JSON.parse({
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:9/",
        "payloads"       => %([{"list":["a"]}]),
        "rate"           => 0.5,
        "allow_unscoped" => true,
        "record_history" => false,
      }.to_json))
      start.is_error.should be_false
      job_id = JSON.parse(start.text)["job_id"].as_s
      status = JSON.parse(tools.call("fuzz_status", JSON.parse(%({"job_id":#{job_id.to_json}}))).text)
      status["audit"]["rate"].as_f.should eq(0.5)
      # Still refused BY NAME when it is not a number at all.
      bad = tools.call("fuzz_start", JSON.parse(%({"template":"x","rate":"fast"})))
      bad.is_error.should be_true
      bad.text.should contain("'rate'")
      bad.text.should contain("expected a number")
    end
  end
end

# The same silent default one nesting level down: `fuzz_int` answered nil for an integral
# float, so a `step`/`max` inside a payload-set object fell through to its default and the
# sweep ran a different shape than the one asked for — while the STRING spellings of those
# mistakes refused loudly.
describe "MCP fuzz payload sets — a nested integer is read, or refused by name" do
  it "reads an integral-float step/max instead of silently using the default" do
    with_store do |store|
      tools = int_tools(store)
      base = {
        "template"       => "GET /?q=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "url"            => "http://127.0.0.1:9/",
        "allow_unscoped" => true,
        "record_history" => false,
      }
      stepped = int_json(tools, "fuzz_start",
        base.merge({"payloads" => [{"numbers" => {"from" => 1, "to" => 100, "step" => 2.0}}]}).to_json)
      stepped["total"].as_i.should eq(50) # step 1 would have been 100

      bruted = int_json(tools, "fuzz_start",
        base.merge({"payloads" => [{"brute" => {"charset" => "ab", "min" => 1, "max" => 3.0}}]}).to_json)
      bruted["total"].as_i.should eq(2 + 4 + 8) # max collapsing to min would have been 2
    end
  end

  it "refuses an unreadable nested integer by name" do
    with_store do |store|
      tools = int_tools(store)
      base = %("template":"GET /?q=§x§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
             %("url":"http://127.0.0.1:9/","allow_unscoped":true,"record_history":false)
      # A space after each `{` on purpose: `{%` opens a macro expression.
      cases = [
        { %([{"numbers":{"from":1,"to":9,"step":"two"}}]), "numbers 'step'" },
        { %([{"brute":{"charset":"ab","min":1,"max":"three"}}]), "brute 'max'" },
      ]
      cases.each do |payloads, named|
        r = tools.call("fuzz_start", JSON.parse(%({#{base},"payloads":#{payloads}})))
        r.is_error.should be_true
        r.text.should contain(named)
      end
    end
  end
end
