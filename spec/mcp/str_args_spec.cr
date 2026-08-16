require "../spec_helper"
require "socket"

# Every MCP STRING argument, driven with the shapes a client actually sends:
#   "text"        — the legal one
#   42 / true     — a JSON scalar: unambiguous, so COERCED ("42"), never dropped
#   [] / {}       — a container: REFUSED BY NAME (JSON::Any#to_s renders a Hash in
#                   Crystal syntax, `{"a" => 1}`, so coercing puts text on the wire
#                   or in the store that the caller never wrote)
#   null          — absent, exactly as `present?` means it everywhere else
#
# `h[key]?.try(&.as_s?)` answered nil for EVERY non-string shape, and every caller read
# that nil as "the caller did not pass it". So the argument was accepted, validated
# against nothing, and discarded: `send_request{method:123}` sent a GET, `{body:{…}}` sent
# no body and no Content-Length, `{raw:[…]}` fell through to a structured GET,
# `create_repeater{request_base64:1234}` stored the non-byte-exact `request` instead, and
# `add_scope_rule{pattern:8080}` refused with "missing required 'pattern'" for a value it
# had just been handed. All with `isError:false` where a send was involved.
#
# The sibling primitives closed this one at a time — `bool_value` (a `1` is refused by
# name), `optional_int_arg`, `RequestBuilder.header_pairs` ("RAISE on anything else rather
# than vanish"), `ws_out_messages_arg` (`compact_map` used to store 2 of 4 frames) — and
# the string readers were what was left.

private def with_store(&)
  path = File.tempname("gori-mcp-strs", ".db")
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

private def str_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def str_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name}#{args} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

# A container in a string slot must be refused, and the refusal must NAME the argument —
# an unnamed "invalid arguments" would leave the caller no better off than the silent drop.
private def refuses_container(tools : Gori::MCP::Tools, name : String, field : String,
                              args : Proc(String, String))
  ["[1,2]", %({"a":1})].each do |bad|
    r = tools.call(name, JSON.parse(args.call(bad)))
    unless r.is_error
      fail "#{name}{#{field}: #{bad}} was accepted (#{r.text[0, 200]})"
    end
    r.text.should contain("'#{field}'")
  end
end

private def seed_str_flow(store, host = "acme.test", target = "/x") : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

# Records the raw request bytes of the next `count` connections into `sink`, answering 204.
private def start_str_recording_origin(sink : Channel(Bytes), count : Int32) : Int32
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

describe "MCP string arguments — the wire fields of send_request" do
  it "refuses a non-string method instead of silently sending GET" do
    with_store do |store|
      tools = str_tools(store)
      # The dead port proves nothing was sent: the refusal has to come from the builder,
      # before any dial. `method: 123` used to become the DEFAULT "GET".
      r = tools.call("send_request", JSON.parse(
        %({"url":"http://127.0.0.1:1/","method":123,"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("'method'")
      r.text.should_not contain("connection refused")
      refuses_container(tools, "send_request", "method", ->(bad : String) {
        %({"url":"http://127.0.0.1:1/","method":#{bad},"allow_unscoped":true})
      })
    end
  end

  it "refuses a JSON-object body instead of sending a bodiless request and reporting success" do
    with_store do |store|
      tools = str_tools(store)
      # The shape an LLM reaches for on any JSON API. It used to send `POST /` with NO
      # body and NO Content-Length, and answer isError:false with the origin's 400.
      r = tools.call("send_request", JSON.parse(
        %({"url":"http://127.0.0.1:1/","method":"POST","body":{"user":"admin"},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("'body'")
      refuses_container(tools, "send_request", "body_base64", ->(bad : String) {
        %({"url":"http://127.0.0.1:1/","body_base64":#{bad},"allow_unscoped":true})
      })
      # A numeric body is a container-free scalar, but this field IS the message, so it is
      # refused too rather than guessed at (same reasoning as `base64_arg`'s).
      num = tools.call("send_request", JSON.parse(
        %({"url":"http://127.0.0.1:1/","method":"POST","body":42,"allow_unscoped":true})))
      num.is_error.should be_true
      num.text.should contain("'body'")
    end
  end

  it "refuses a non-string raw instead of falling through to a structured GET" do
    with_store do |store|
      tools = str_tools(store)
      refuses_container(tools, "send_request", "raw", ->(bad : String) {
        %({"url":"http://127.0.0.1:1/","raw":#{bad},"allow_unscoped":true})
      })
      refuses_container(tools, "send_request", "raw_base64", ->(bad : String) {
        %({"url":"http://127.0.0.1:1/","raw_base64":#{bad},"allow_unscoped":true})
      })
    end
  end

  it "names 'url' when the url is not a string (not 'url is required')" do
    with_store do |store|
      tools = str_tools(store)
      r = tools.call("send_request", JSON.parse(%({"url":8080,"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("'url'")
    end
  end

  it "still sends a string body byte-for-byte, and still treats a null body as absent" do
    sink = Channel(Bytes).new(2)
    port = start_str_recording_origin(sink, 2)
    with_store do |store|
      tools = str_tools(store)
      str_json(tools, "send_request", %({"url":"http://127.0.0.1:#{port}/p","method":"POST",) +
                                      %("body":"{\\"user\\":\\"admin\\"}","allow_unscoped":true,"record_history":false}))
      sent = String.new(sink.receive)
      sent.should start_with("POST /p HTTP/1.1\r\n")
      sent.should contain("Content-Length: 16\r\n")
      sent.should end_with(%({"user":"admin"}))

      # `null` is what an LLM emits for "no body"; it must stay ABSENT, not become "null".
      str_json(tools, "send_request", %({"url":"http://127.0.0.1:#{port}/q","body":null,) +
                                      %("allow_unscoped":true,"record_history":false}))
      bodiless = String.new(sink.receive)
      bodiless.should end_with("\r\n\r\n")
      bodiless.should_not contain("Content-Length")
    end
  end
end

describe "MCP string arguments — the shared str() reader" do
  it "coerces a JSON scalar rather than reporting the argument missing" do
    with_store do |store|
      tools = str_tools(store)
      # `pattern: 8080` used to come back "missing required 'pattern'" for a value the
      # caller had just sent. A bare number in a string slot is unambiguous.
      str_json(tools, "add_scope_rule", %({"match_type":"string","pattern":8080}))
      Gori::Scope.load(store).rules.map(&.pattern).should contain("8080")

      note = str_json(tools, "create_note", %({"text":42}))["id"].as_i64
      Gori::Notes.load(store).notes.find { |n| n.id == note }.not_nil!.text.should eq("42")
    end
  end

  it "refuses a container in a string slot, naming the argument" do
    with_store do |store|
      seed_str_flow(store)
      tools = str_tools(store)
      refuses_container(tools, "add_scope_rule", "pattern", ->(bad : String) {
        %({"match_type":"string","pattern":#{bad}})
      })
      refuses_container(tools, "create_note", "text", ->(bad : String) { %({"text":#{bad}}) })
      # A dropped `query` is the sharpest one: list_history answered with the WHOLE
      # history, and the agent reasoned over a set it never asked for.
      refuses_container(tools, "list_history", "query", ->(bad : String) { %({"query":#{bad}}) })
      refuses_container(tools, "create_issue", "title", ->(bad : String) {
        %({"title":#{bad},"severity":"low"})
      })
    end
  end

  it "reads a null string argument as absent" do
    with_store do |store|
      seed_str_flow(store)
      tools = str_tools(store)
      # `query: null` is "no filter", the same as omitting it — not the string "null".
      both = str_json(tools, "list_history", %({"query":null})).as_a.size
      both.should eq(str_json(tools, "list_history", "{}").as_a.size)
      both.should be > 0
    end
  end
end

describe "MCP string arguments — byte-exact base64 fields are strict" do
  it "refuses a non-string request_base64 instead of falling back to `request`" do
    with_store do |store|
      tools = str_tools(store)
      # `base64_str` answered nil, so `|| str(h, "request")` won and create_repeater stored
      # the NON-byte-exact request while reporting success. A caller reaching for a
      # `*_base64` argument is asking for exact bytes.
      r = tools.call("create_repeater", JSON.parse(
        %({"target":"http://acme.test","request_base64":1234,) +
        %("request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"})))
      r.is_error.should be_true
      r.text.should contain("'request_base64'")
      store.repeaters.size.should eq(0)
    end
  end
end

describe "MCP string arguments — list readers keep every entry" do
  it "cookie_crack takes a bare string as one candidate, and does not drop a numeric one" do
    with_store do |store|
      tools = str_tools(store)
      forged = str_json(tools, "cookie_forge",
        %({"format":"flask","secret":"12345","payload":"{\\"user\\":\\"admin\\"}"}))["cookie"].as_s

      # A numeric secret used to be dropped by `compact_map(&.as_s?)`, so the crack tried
      # 1 of the 2 candidates and answered `found:false` with isError:false — a false
      # negative the caller cannot see.
      hit = str_json(tools, "cookie_crack",
        %({"cookie":"#{forged}","format":"flask","secrets":["nope",12345]}))
      hit["found"].as_bool.should be_true
      hit["secret"].as_s.should eq("12345")

      # A single secret sent as a bare string is the shape a caller reaches for; it used to
      # become an empty list and come back "provide 'secrets' (array) and/or 'wordlist'".
      bare = str_json(tools, "cookie_crack",
        %({"cookie":"#{forged}","format":"flask","secrets":"12345"}))
      bare["found"].as_bool.should be_true
      # …and a bare NUMBER is the same one candidate, not a shape to refuse — the scalar rule
      # has to read the same on a whole list argument as it does on one entry of it.
      scalar = str_json(tools, "cookie_crack",
        %({"cookie":"#{forged}","format":"flask","secrets":12345}))
      scalar["found"].as_bool.should be_true
      # A container in the list slot still has no reading, and the refusal names that shape.
      obj = tools.call("cookie_crack", JSON.parse(%({"cookie":"#{forged}","secrets":{"a":1}})))
      obj.is_error.should be_true
      obj.text.should contain("'secrets'")
      obj.text.should contain("an object")

      # The complement: a genuinely wrong candidate list still reports no match.
      miss = str_json(tools, "cookie_crack",
        %({"cookie":"#{forged}","format":"flask","secrets":["nope","also-nope"]}))
      miss["found"].as_bool.should be_false

      refuses_container(tools, "cookie_crack", "secrets", ->(bad : String) {
        %({"cookie":"#{forged}","format":"flask","secrets":[#{bad}]})
      })
    end
  end

  it "sequence_analyze analyzes every token it was handed, or refuses" do
    with_store do |store|
      tools = str_tools(store)
      # 2 of the 3 tokens used to reach the analyzer, so the randomness verdict described a
      # sample the caller never submitted — the `create_repeater` "stored 2 of 4 frames"
      # bug, spent on a report instead of a send.
      r = str_json(tools, "sequence_analyze", %({"tokens":["aaaa","bbbb",1234]}))
      r["sample_count"].as_i.should eq(3)
      refuses_container(tools, "sequence_analyze", "tokens", ->(bad : String) {
        %({"tokens":["aaaa",#{bad}]})
      })
    end
  end

  it "create_repeater refuses an OBJECT ws_out_messages instead of storing zero frames" do
    with_store do |store|
      tools = str_tools(store)
      # An actual upgrade request: `ws_out_messages` is only read when the stored bytes are
      # a WebSocket handshake.
      handshake = "GET /ws HTTP/1.1\\r\\nHost: acme.test\\r\\nUpgrade: websocket\\r\\n" \
                  "Connection: Upgrade\\r\\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\\r\\n" \
                  "Sec-WebSocket-Version: 13\\r\\n\\r\\n"
      base = %("target":"ws://acme.test","request":"#{handshake}")
      # The array branch was tried first and the object fell through to the string branch,
      # which answered nil — so the repeater was stored with an EMPTY frame list and
      # reported success.
      r = tools.call("create_repeater", JSON.parse(%({#{base},"ws_out_messages":{"payload":"hi"}})))
      r.is_error.should be_true
      r.text.should contain("'ws_out_messages'")

      # Both documented shapes still work: the array form and the newline-string form.
      arr = str_json(tools, "create_repeater", %({#{base},"ws_out_messages":["a","b"]}))
      arr["ws_out_message_count"].as_i.should eq(2)
      lines = str_json(tools, "create_repeater", %({#{base},"ws_out_messages":"a\\nb\\nc"}))
      lines["ws_out_message_count"].as_i.should eq(3)
    end
  end
end

describe "MCP string arguments — the fuzz payload/processor/matcher grammar" do
  # `fuzz_start` builds the whole plan before the scope gate and before any send, so every
  # refusal here happens with nothing on the wire.
  private_base = %("template":"GET /?q=§x§ HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\n\\r\\n",) +
                 %("url":"http://127.0.0.1:1","allow_unscoped":true)

  it "coerces a scalar payload entry but refuses a container one" do
    with_store do |store|
      tools = str_tools(store)
      # `x.as_s? || x.to_s` stringified a nested object in CRYSTAL syntax (`{"a" => 1}`), so
      # every request built from it carried a payload nobody wrote.
      ok = str_json(tools, "fuzz_start", %({#{private_base},"payloads":[{"list":[1,2]}]}))
      ok["total"].as_i.should eq(2)
      bad = tools.call("fuzz_start", JSON.parse(%({#{private_base},"payloads":[{"list":[{"a":1}]}]})))
      bad.is_error.should be_true
      bad.text.should contain("'list'")
    end
  end

  it "refuses a non-string replacement instead of deleting every match" do
    with_store do |store|
      tools = str_tools(store)
      # `strict_jstr(…) || ""` turned `replacement: 123` into an empty replacement, so the
      # processor STRIPPED the match rather than substituting the value the caller named.
      r = tools.call("fuzz_start", JSON.parse(%({#{private_base},"payloads":[{"list":["a"]}],) +
                                              %("processors":[{"type":"regex_replace","pattern":"a","replacement":123}]})))
      r.is_error.should be_true
      r.text.should contain("'replacement'")
    end
  end

  it "refuses a non-string matcher regex instead of dropping the matcher" do
    with_store do |store|
      tools = str_tools(store)
      # Both condition sets go through the same reader, so both are pinned.
      {"match", "filter"}.each do |arg|
        r = tools.call("fuzz_start", JSON.parse(%({#{private_base},"payloads":[{"list":["a"]}],) +
                                                %("#{arg}":{"regex":[1]}})))
        r.is_error.should be_true
        r.text.should contain("'regex'")
      end
    end
  end

  it "refuses a non-string preset file instead of running without the merged wordlist" do
    with_store do |store|
      tools = str_tools(store)
      r = tools.call("fuzz_start", JSON.parse(%({#{private_base},"payloads":[{"preset":"sqli","file":42}]})))
      r.is_error.should be_true
      r.text.should contain("'file'")
    end
  end
end

# --- the transport layer: `arguments` that is not an object ----------------------

private def drive_str(store, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

describe "MCP tools/call — a stringified `arguments` object" do
  it "parses arguments sent as a JSON string instead of dropping every one of them" do
    with_store do |store|
      flow = seed_str_flow(store)
      # `as_h?` answered nil and `Tools#call` substituted an empty hash, so a client that
      # stringifies its arguments — which happens, and which `header_pairs` already accepts
      # one level down — was told "missing required 'id'" for a call that named it.
      resp = drive_str(store,
        %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_flow","arguments":"{\\"id\\":#{flow}}"}}))
      resp.size.should eq(1)
      resp[0]["result"]["isError"].as_bool.should be_false
      JSON.parse(resp[0]["result"]["content"][0]["text"].as_s)["id"].as_i64.should eq(flow)
    end
  end

  it "refuses a non-object `arguments` at the protocol level rather than running with none" do
    with_store do |store|
      resp = drive_str(store,
        %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_flow","arguments":[1,2]}}),
        %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_flow","arguments":"not json"}}))
      resp.size.should eq(2)
      resp[0]["id"].as_i.should eq(2)
      resp[0]["error"]["code"].as_i.should eq(-32602)
      resp[0]["error"]["message"].as_s.should contain("arguments")
      resp[1]["id"].as_i.should eq(3)
      resp[1]["error"]["code"].as_i.should eq(-32602)
    end
  end

  it "still treats an absent, null, or blank `arguments` as no arguments" do
    with_store do |store|
      resp = drive_str(store,
        %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_history"}}),
        %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_history","arguments":null}}),
        %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_history","arguments":""}}))
      resp.size.should eq(3)
      resp.each do |r|
        r["error"]?.should be_nil
        r["result"]["isError"].as_bool.should be_false
      end
    end
  end
end
