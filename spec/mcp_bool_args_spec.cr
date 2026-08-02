require "./spec_helper"
require "socket"

# Every MCP boolean argument, driven with the SEVEN forms a client can send:
#   true / false      — the two legal ones
#   "true" / "false"  — the lenient string forms clients and LLMs actually emit
#   1 / 0 / "yes"     — unintelligible: must be REFUSED BY NAME, never coerced
#   absent            — must keep the tool's documented default, which for
#                       auto_content_length / spider / bruteforce / keep_alive is ON
#
# `bool(h, key) || false` collapsed the last two rows together, so `probe_scan{active:1}`
# ran a passive scan and reported a clean active one, and `create_repeater{auto_content_length:1}`
# stored the OPPOSITE of the absent-default. See `Tools#bool_value`.

private def with_store(&)
  path = File.tempname("gori-mcp-bools", ".db")
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

private def bool_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def bool_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name}#{args} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# The three forms that must now be refused, and the assertion that the refusal NAMES the
# argument (an unnamed "invalid arguments" would be no better than the silent coercion).
private def refuses_garbage(tools : Gori::MCP::Tools, name : String, field : String,
                            args : Proc(String, String))
  {"1", "0", %("yes")}.each do |bad|
    r = tools.call(name, JSON.parse(args.call(bad)))
    unless r.is_error
      fail "#{name}{#{field}: #{bad}} was accepted (#{r.text[0, 200]})"
    end
    r.text.should contain("'#{field}'")
    r.text.should contain("expected true or false")
  end
end

private def seed_bool_flow(store, target = "/x", host = "acme.test") : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

private def repeater_row(store, id : Int64)
  store.get_repeater(id).not_nil!
end

describe "MCP boolean arguments — refused by name, never silently substituted" do
  it "create_repeater refuses 1/0/\"yes\" on every boolean, naming the field" do
    with_store do |store|
      tools = bool_tools(store)
      base = %("target":"http://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n")
      {"http2", "auto_content_length", "ws_keep_key", "keep_request_line"}.each do |field|
        refuses_garbage(tools, "create_repeater", field, ->(bad : String) {
          %({#{base},"#{field}":#{bad}})
        })
      end
    end
  end

  it "create_repeater keeps auto_content_length ON when the field is absent, and honours both legal forms" do
    with_store do |store|
      tools = bool_tools(store)
      base = %("target":"http://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n")

      # The trap: the absent-default is ON. `auto_content_length: 1` used to store 0.
      absent = bool_json(tools, "create_repeater", %({#{base}}))["id"].as_i64
      repeater_row(store, absent).auto_content_length?.should be_true

      on = bool_json(tools, "create_repeater", %({#{base},"auto_content_length":true}))["id"].as_i64
      repeater_row(store, on).auto_content_length?.should be_true

      off = bool_json(tools, "create_repeater", %({#{base},"auto_content_length":false}))["id"].as_i64
      repeater_row(store, off).auto_content_length?.should be_false

      # The lenient string forms still work — leniency was never the problem.
      s_on = bool_json(tools, "create_repeater", %({#{base},"auto_content_length":"true"}))["id"].as_i64
      repeater_row(store, s_on).auto_content_length?.should be_true
      s_off = bool_json(tools, "create_repeater", %({#{base},"auto_content_length":"FALSE"}))["id"].as_i64
      repeater_row(store, s_off).auto_content_length?.should be_false
    end
  end

  it "create_repeater stores http2 / ws_keep_key exactly as asked, both ways, default off" do
    with_store do |store|
      tools = bool_tools(store)
      base = %("target":"http://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n")

      d = bool_json(tools, "create_repeater", %({#{base}}))["id"].as_i64
      repeater_row(store, d).http2?.should be_false
      repeater_row(store, d).ws_keep_key?.should be_false

      on = bool_json(tools, "create_repeater", %({#{base},"http2":true,"ws_keep_key":true}))["id"].as_i64
      repeater_row(store, on).http2?.should be_true
      repeater_row(store, on).ws_keep_key?.should be_true

      off = bool_json(tools, "create_repeater", %({#{base},"http2":false,"ws_keep_key":false}))["id"].as_i64
      repeater_row(store, off).http2?.should be_false
      repeater_row(store, off).ws_keep_key?.should be_false
    end
  end

  it "update_repeater refuses garbage by name and keeps the stored value when the field is absent" do
    with_store do |store|
      id = store.insert_repeater("http://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        true, true, nil, 0, nil, true)
      tools = bool_tools(store)
      {"http2", "auto_content_length", "ws_keep_key"}.each do |field|
        refuses_garbage(tools, "update_repeater", field, ->(bad : String) {
          %({"id":#{id},"#{field}":#{bad}})
        })
      end
      # Absent → the row is unchanged (all three were seeded ON).
      bool_json(tools, "update_repeater", %({"id":#{id},"name":"n"}))
      rec = repeater_row(store, id)
      rec.http2?.should be_true
      rec.auto_content_length?.should be_true
      rec.ws_keep_key?.should be_true
      # …and an explicit false still turns each one off.
      bool_json(tools, "update_repeater", %({"id":#{id},"http2":false,"auto_content_length":false,"ws_keep_key":false}))
      rec2 = repeater_row(store, id)
      rec2.http2?.should be_false
      rec2.auto_content_length?.should be_false
      rec2.ws_keep_key?.should be_false
    end
  end

  it "probe_scan refuses active/unsafe/aggressive garbage by name — a silent passive scan is a false negative" do
    with_store do |store|
      seed_bool_flow(store)
      tools = bool_tools(store)
      {"active", "unsafe", "aggressive"}.each do |field|
        refuses_garbage(tools, "probe_scan", field, ->(bad : String) { %({"#{field}":#{bad}}) })
      end
      # The control the finding leaned on: allow_unscoped in the SAME call already refused.
      refuses_garbage(tools, "probe_scan", "allow_unscoped", ->(bad : String) { %({"allow_unscoped":#{bad}}) })
      # Absent still means a passive scan, echoed as active:false.
      bool_json(tools, "probe_scan", "{}")["active"].as_bool.should be_false
      # And active:true still reaches the scope gate rather than reporting a clean scan.
      r = tools.call("probe_scan", JSON.parse(%({"active":true})))
      r.is_error.should be_true
      r.text.should contain("scope")
    end
  end

  it "discover_start refuses spider/bruteforce garbage instead of crawling — and keeps both defaults ON" do
    with_store do |store|
      tools = bool_tools(store)
      seed = %("url":"http://127.0.0.1:1/")
      {"spider", "bruteforce", "keep_alive", "allow_unscoped"}.each do |field|
        refuses_garbage(tools, "discover_start", field, ->(bad : String) {
          %({#{seed},"#{field}":#{bad}})
        })
      end
      # `spider:false, bruteforce:false` still trips the technique guard…
      both_off = tools.call("discover_start", JSON.parse(%({#{seed},"spider":false,"bruteforce":false,"allow_unscoped":true})))
      both_off.is_error.should be_true
      both_off.text.should contain("at least one of spider/bruteforce")
      # …and `spider:0` no longer slips past it by never becoming false at all.
      zero = tools.call("discover_start", JSON.parse(%({#{seed},"spider":0,"bruteforce":false,"allow_unscoped":true})))
      zero.is_error.should be_true
      zero.text.should contain("'spider'")
      # One technique off is fine (the complement of the guard) — both default ON when absent,
      # so this reaches the scope gate, not the technique guard.
      one_off = tools.call("discover_start", JSON.parse(%({#{seed},"spider":false})))
      one_off.text.should_not contain("at least one of spider/bruteforce")
    end
  end

  it "validates 'insecure' even when the server already runs with TLS verification off" do
    with_store do |store|
      # `verify && @verify_upstream` short-circuited past the argument whenever the server was
      # started with --insecure, so the SAME call validated the flag or not depending on a
      # server-level setting the caller cannot see. The read comes first now.
      {true, false}.each do |verify_upstream|
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: verify_upstream)
        refuses_garbage(tools, "discover_start", "insecure", ->(bad : String) {
          %({"url":"http://127.0.0.1:1/","insecure":#{bad}})
        })
        refuses_garbage(tools, "send_request", "insecure", ->(bad : String) {
          %({"url":"http://127.0.0.1:1/","insecure":#{bad},"allow_unscoped":true})
        })
      end
    end
  end

  it "minimize_repeater refuses apply/verbatim garbage BEFORE it sends anything" do
    with_store do |store|
      id = store.insert_repeater("http://127.0.0.1:1/", "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
        false, true, nil, 0)
      tools = bool_tools(store)
      {"apply", "verbatim", "allow_unscoped"}.each do |field|
        refuses_garbage(tools, "minimize_repeater", field, ->(bad : String) {
          %({"repeater_id":#{id},"#{field}":#{bad}})
        })
      end
    end
  end

  it "list_sitemap / decode / clear_history / get_flow refuse garbage by name" do
    with_store do |store|
      seed_bool_flow(store)
      tools = bool_tools(store)
      refuses_garbage(tools, "list_sitemap", "collapse_transport", ->(bad : String) { %({"collapse_transport":#{bad}}) })
      refuses_garbage(tools, "decode", "input_base64", ->(bad : String) { %({"input":"aGk=","spec":"hex","input_base64":#{bad}}) })
      refuses_garbage(tools, "clear_history", "confirm", ->(bad : String) { %({"confirm":#{bad}}) })
      refuses_garbage(tools, "get_flow", "include_sensitive", ->(bad : String) { %({"id":1,"include_sensitive":#{bad}}) })
      # Complement: the legal forms still do what they say.
      bool_json(tools, "decode", %({"input":"aGk=","spec":"hex","input_base64":true}))
      bool_json(tools, "decode", %({"input":"aGk=","spec":"hex","input_base64":false}))
      bool_json(tools, "list_sitemap", %({"collapse_transport":true}))
      bool_json(tools, "list_sitemap", %({"collapse_transport":false}))
      # clear_history without confirm still refuses with CONFIRM_REQUIRED, not an arg error.
      r = tools.call("clear_history", JSON.parse("{}"))
      r.is_error.should be_true
      r.text.should contain("confirm:true")
    end
  end

  it "the three-state 'enabled' flags refuse garbage by name and still refuse a MISSING value" do
    with_store do |store|
      tools = bool_tools(store)
      rule = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "old", "")
      refuses_garbage(tools, "set_rule_enabled", "enabled", ->(bad : String) { %({"id":#{rule},"enabled":#{bad}}) })
      refuses_garbage(tools, "set_scope_enabled", "enabled", ->(bad : String) { %({"enabled":#{bad}}) })
      refuses_garbage(tools, "set_sandbox", "enabled", ->(bad : String) { %({"enabled":#{bad}}) })
      refuses_garbage(tools, "intercept_toggle", "enable", ->(bad : String) { %({"enable":#{bad}}) })
      # Absent is a DIFFERENT refusal — "missing", not "invalid" — and must stay that way.
      miss = tools.call("set_scope_enabled", JSON.parse("{}"))
      miss.is_error.should be_true
      miss.text.should contain("missing required 'enabled'")
      # Both legal values still commit.
      bool_json(tools, "set_scope_enabled", %({"enabled":false}))
      Gori::Scope.load(store).enabled?.should be_false
      bool_json(tools, "set_scope_enabled", %({"enabled":true}))
      Gori::Scope.load(store).enabled?.should be_true
    end
  end
end

# --- R2-F3: the absolute-form request line ---------------------------------------

# A flow whose stored request line is ABSOLUTE-form — how a proxy client writes it, and how
# a routing / cache-poisoning / SSRF probe recorded from a direct send is written.
private def seed_absolute_form_flow(store, host = "evil.example") : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: "http://#{host}/abs", http_version: "HTTP/1.1",
    head: "GET http://#{host}/abs HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe "MCP create_repeater / send_request keep_request_line" do
  it "create_repeater reports the rewrite and keep_request_line stores the captured line" do
    with_store do |store|
      flow = seed_absolute_form_flow(store)
      tools = bool_tools(store)

      rewritten = bool_json(tools, "create_repeater", %({"flow_id":#{flow}}))
      rewritten["request_line_rewritten"].as_bool.should be_true
      String.new(repeater_row(store, rewritten["id"].as_i64).request)
        .should start_with("GET /abs HTTP/1.1")

      kept = bool_json(tools, "create_repeater", %({"flow_id":#{flow},"keep_request_line":true}))
      kept.as_h.has_key?("request_line_rewritten").should be_false
      String.new(repeater_row(store, kept["id"].as_i64).request)
        .should start_with("GET http://evil.example/abs HTTP/1.1")
    end
  end

  it "does not claim a rewrite on an ORIGIN-form capture, or on an explicit request argument" do
    with_store do |store|
      origin_form = seed_bool_flow(store, "/plain")
      tools = bool_tools(store)
      # Complement 1: nothing to rewrite → no field, with and without the flag.
      bool_json(tools, "create_repeater", %({"flow_id":#{origin_form}}))
        .as_h.has_key?("request_line_rewritten").should be_false
      bool_json(tools, "create_repeater", %({"flow_id":#{origin_form},"keep_request_line":true}))
        .as_h.has_key?("request_line_rewritten").should be_false
      # Complement 2: an explicit `request` wins over the seed, so nothing of the caller's
      # was rewritten even though the flow's own line is absolute-form.
      abs = seed_absolute_form_flow(store, "other.example")
      res = bool_json(tools, "create_repeater",
        %({"flow_id":#{abs},"request":"GET http://other.example/abs HTTP/1.1\\r\\nHost: other.example\\r\\n\\r\\n"}))
      res.as_h.has_key?("request_line_rewritten").should be_false
      String.new(repeater_row(store, res["id"].as_i64).request)
        .should start_with("GET http://other.example/abs HTTP/1.1")
    end
  end

  it "send_request{flow_id} puts the stored absolute-form line on the wire under keep_request_line, and says so when it rewrites" do
    sink = Channel(Bytes).new(2)
    port = start_bool_recording_origin(sink, 2)
    with_store do |store|
      flow = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: port,
        method: "GET", target: "http://127.0.0.1:#{port}/abs", http_version: "HTTP/1.1",
        head: "GET http://127.0.0.1:#{port}/abs HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n".to_slice,
        body: nil))
      tools = bool_tools(store)

      rewritten = bool_json(tools, "send_request",
        %({"flow_id":#{flow},"allow_unscoped":true,"record_history":false}))
      rewritten["request_line_rewritten"].as_bool.should be_true
      rewritten["effective_request"]["target"].as_s.should eq("/abs")
      String.new(sink.receive).should start_with("GET /abs HTTP/1.1\r\n")

      kept = bool_json(tools, "send_request",
        %({"flow_id":#{flow},"keep_request_line":true,"allow_unscoped":true,"record_history":false}))
      kept.as_h.has_key?("request_line_rewritten").should be_false
      kept["effective_request"]["target"].as_s.should eq("http://127.0.0.1:#{port}/abs")
      String.new(sink.receive).should start_with("GET http://127.0.0.1:#{port}/abs HTTP/1.1\r\n")
    end
  end

  it "send_request refuses keep_request_line garbage by name" do
    with_store do |store|
      flow = seed_absolute_form_flow(store)
      tools = bool_tools(store)
      refuses_garbage(tools, "send_request", "keep_request_line", ->(bad : String) {
        %({"flow_id":#{flow},"keep_request_line":#{bad},"allow_unscoped":true})
      })
    end
  end
end

# Records the raw request bytes of the next `count` connections into `sink`, answering 204.
private def start_bool_recording_origin(sink : Channel(Bytes), count : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    count.times do
      break unless conn = origin.accept?
      buf = IO::Memory.new
      begin
        conn.read_timeout = 300.milliseconds
        tmp = Bytes.new(4096)
        while (n = conn.read(tmp)) > 0
          buf.write(tmp[0, n])
        end
      rescue
        # idle — everything the client meant to send has arrived
      end
      sink.send(buf.to_slice)
      conn << "HTTP/1.1 204 No Content\r\n\r\n" rescue nil
      conn.flush rescue nil
      conn.close rescue nil
    end
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

# --- R2-F6: minimize on a session that holds evidence ---------------------------

describe "MCP minimize_repeater verbatim" do
  # INVERTED for the owner's round-7 policy. `verbatim` used to be the ONLY way past the
  # unresolved-`$KEY` refusal on a minimize, and this pinned that asymmetry. The refusal is
  # gone from the request head entirely, so the DRAFT reaches the search too — `verbatim`
  # now differs only in what it does to expansion and framing, which the rest of this
  # example still covers.
  it "reaches the search for a CAPTURED $KEY with or without verbatim" do
    with_store do |store|
      # `$top` is stored OData, not an unresolved template variable.
      req = "GET /api?$filter=name&$top=10 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      id = store.insert_repeater("http://127.0.0.1:1/", req.to_slice, false, true, nil, 0)
      tools = bool_tools(store)

      draft = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      draft.text.should_not contain("unresolved env")

      # The search then runs and aborts on an unreachable baseline (the dead port) — which is
      # the proof that it got PAST the draft-time gate and actually tried to send.
      verbatim = tools.call("minimize_repeater",
        JSON.parse(%({"repeater_id":#{id},"verbatim":true,"allow_unscoped":true})))
      verbatim.is_error.should be_false
      verbatim.text.should_not contain("unresolved env")
      payload = JSON.parse(verbatim.text)
      payload["aborted"].as_bool.should be_true
      payload["sends"].as_i.should be > 0
      # And the request it reports is the stored one, token intact.
      payload["minimized_request"].as_s.should contain("$top=10")
    end
  end

  it "still refuses an unresolved token in the operator-typed TARGET under verbatim" do
    with_store do |store|
      # The target is not evidence — the operator typed it — so verbatim must not cover it.
      id = store.insert_repeater("http://$NOPE/", "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
        false, true, nil, 0)
      tools = bool_tools(store)
      r = tools.call("minimize_repeater",
        JSON.parse(%({"repeater_id":#{id},"verbatim":true,"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("$NOPE")
    end
  end
end

# --- R4-F2: a budget-capped discover is not a finished one ----------------------

# Answers 200 to everything, so the brute-force pass keeps finding work to queue.
private def start_bool_always200_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    loop do
      break unless conn = origin.accept?
      spawn do
        conn.read_timeout = 2.seconds
        loop do
          break unless Gori::Proxy::Codec::Http1.read_head(conn)
          conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\nhi"
          conn.flush
        end
      rescue
      ensure
        conn.close rescue nil
      end
    end
  rescue
    origin.close rescue nil
  end
  port
end

describe "MCP discover_status / discover_results incomplete_reason" do
  it "reports budget_exhausted with tasks still queued instead of a clean done" do
    port = start_bool_always200_origin
    with_store do |store|
      Gori::Scope.load(store).add("include", "host", "127.0.0.1")
      tools = bool_tools(store)
      job = bool_json(tools, "discover_start",
        %({"url":"http://127.0.0.1:#{port}/","spider":false,"max_requests":4,"concurrency":1}))
      id = job["job_id"].as_s

      status = nil.as(JSON::Any?)
      120.times do
        status = bool_json(tools, "discover_status", %({"job_id":"#{id}"}))
        break if status["job_complete"].as_bool
        sleep 100.milliseconds
      end
      s = status.not_nil!
      s["job_complete"].as_bool.should be_true
      s["queued"].as_i.should be > 0
      s["status"].as_s.should eq("budget_exhausted")
      s["incomplete_reason"].as_s.should eq("budget_exhausted")

      results = bool_json(tools, "discover_results", %({"job_id":"#{id}"}))
      results["job_complete"].as_bool.should be_true
      results["incomplete_reason"].as_s.should eq("budget_exhausted")
      results["queued"].as_i.should be > 0
    end
  end

  it "a run that empties its frontier is still a clean done with a null incomplete_reason" do
    port = start_bool_always200_origin
    with_store do |store|
      Gori::Scope.load(store).add("include", "host", "127.0.0.1")
      tools = bool_tools(store)
      # The complement: no brute-force wordlist and no crawl depth to spend, so the frontier
      # drains. A budget high enough that max_requests cannot be what stops it.
      job = bool_json(tools, "discover_start",
        %({"url":"http://127.0.0.1:#{port}/","bruteforce":false,"max_depth":1,"max_requests":500,"concurrency":1}))
      id = job["job_id"].as_s

      status = nil.as(JSON::Any?)
      200.times do
        status = bool_json(tools, "discover_status", %({"job_id":"#{id}"}))
        break if status["job_complete"].as_bool
        sleep 100.milliseconds
      end
      s = status.not_nil!
      s["job_complete"].as_bool.should be_true
      s["queued"].as_i.should eq(0)
      s["status"].as_s.should eq("done")
      s["incomplete_reason"].raw.should be_nil
    end
  end
end
