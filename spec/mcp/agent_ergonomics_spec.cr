require "../spec_helper"

# Four places the MCP surface tripped the caller it was written for. Each one answered a
# reasonable call with something an agent could not act on — a wrong name, a wrong diagnosis,
# a silently opposite result, or a capability the schema said existed and the tool ignored.

# An origin that answers 200 with a Set-Cookie, so redaction has something to hide.
private def with_cookie_origin(&)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 200 OK\r\nSet-Cookie: sid=s3cret\r\nContent-Length: 0\r\n\r\n"
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  begin
    yield port
  ensure
    server.close
  end
end

private def erg_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def set_cookie_of(res : JSON::Any) : String
  res["headers"].as_a.find { |h| h["name"].as_s == "Set-Cookie" }.not_nil!["value"].as_s
end

describe "MCP agent ergonomics" do
  # `include_sensitive` is what get_flow, compare_flows, intercept_get, get_repeater_context,
  # list_env and five more spell. send_request alone said `include_sensitive_headers`, and
  # `unknown_args` refuses by name — so an agent that read a flow and then replayed it got
  # INVALID_ARGUMENT on the one call whose point is reading back the Set-Cookie it just earned.
  it "send_request accepts include_sensitive, the name every other redacting tool uses" do
    with_cookie_origin do |port|
      with_store do |store|
        tools = tools_for(store)
        url = "http://127.0.0.1:#{port}/x"

        redacted = erg_json(tools, "send_request", %({"url":"#{url}","allow_unscoped":true}))
        set_cookie_of(redacted).should eq("[REDACTED]")

        aliased = erg_json(tools, "send_request",
          %({"url":"#{url}","allow_unscoped":true,"include_sensitive":true}))
        set_cookie_of(aliased).should eq("sid=s3cret")

        # The original spelling still works — this is an alias, not a rename.
        original = erg_json(tools, "send_request",
          %({"url":"#{url}","allow_unscoped":true,"include_sensitive_headers":true}))
        set_cookie_of(original).should eq("sid=s3cret")
      end
    end
  end

  # An OMITTED session_id and a STALE one answered identically ("unknown or expired
  # session_id"), which told an agent that had simply left the argument out that its listener
  # had died — under which the correct move is to abandon a session still collecting hits.
  it "tells a missing OAST session_id apart from an expired one" do
    with_store do |store|
      tools = tools_for(store)

      {"oast_poll", "oast_payload", "oast_stop"}.each do |name|
        missing = tools.call(name, JSON.parse("{}"))
        missing.is_error.should be_true
        missing.text.should contain("missing required 'session_id'")
        missing.field.should eq("session_id")

        stale = tools.call(name, JSON.parse(%({"session_id":"oast_deadbeef"})))
        stale.is_error.should be_true
        stale.text.should contain("unknown or expired")
        stale.text.should contain("oast_deadbeef") # names the id it could not find
        stale.error_code.should eq("NOT_FOUND")
      end
    end
  end

  it "tells a missing 'direction' apart from an unreadable one" do
    with_store do |store|
      tools = tools_for(store)

      missing = tools.call("intercept_set_direction", JSON.parse("{}"))
      missing.text.should contain("missing required 'direction'")
      bad = tools.call("intercept_set_direction", JSON.parse(%({"direction":"sideways"})))
      bad.text.should contain("invalid 'direction'")
      bad.text.should contain("sideways")

      mv = tools.call("move_color_rule", JSON.parse(%({"id":1})))
      mv.text.should contain("missing required 'direction'")
      mv2 = tools.call("move_color_rule", JSON.parse(%({"id":1,"direction":"sideways"})))
      mv2.text.should contain("invalid 'direction'")
    end
  end

  # `base64`/`hex`/`url` are aliases of the ENCODE converters, so the most natural call
  # anyone makes against a tool named `decode` double-ENCODED its input and reported success
  # (#1554). A bare name decodes here instead; a spelled direction still runs as typed.
  it "decode runs a bare format name as its decode half" do
    with_store do |store|
      tools = tools_for(store)
      converters = ->(doc : JSON::Any) { doc["steps"].as_a.map(&.["converter"].as_s) }

      bare = erg_json(tools, "decode", %({"spec":"base64","input":"aGVsbG8="}))
      bare["output"].as_s.should eq("hello")
      converters.call(bare).should eq(["base64-decode"])
      erg_json(tools, "decode", %({"spec":"hex","input":"6869"}))["output"].as_s.should eq("hi")
      erg_json(tools, "decode", %({"spec":"url","input":"a%20b"}))["output"].as_s.should eq("a b")
      erg_json(tools, "decode", %({"spec":"html","input":"&lt;a&gt;"}))["output"].as_s.should eq("<a>")
      erg_json(tools, "decode", %({"spec":"xml","input":"&lt;a&gt;"}))["output"].as_s.should eq("<a>")

      # Each token on its own, in the order written: `base64 > gzip` decodes, then decompresses.
      packed = erg_json(tools, "decode", %({"spec":"gzip-compress > base64-encode","input":"hello"}))["output"].as_s
      chain = erg_json(tools, "decode", %({"spec":"base64 > gzip","input":#{packed.to_json}}))
      chain["output"].as_s.should eq("hello")
      converters.call(chain).should eq(["base64-decode", "gzip-decompress"])
      converters.call(erg_json(tools, "decode", %({"spec":"deflate","input":"eJzLSM3JyQcABiwCFQ==","input_base64":true})))
        .should eq(["zlib-decompress"])

      # A spelled direction — in any of the three spellings, wherever in the token it sits —
      # a hash, and a ONE-WAY transform with no counterpart all run as typed.
      {
        %({"spec":"base64-encode","input":"hello"}) => "base64-encode",
        %({"spec":"gzip-compress","input":"hi"})    => "gzip-compress",
        %({"spec":"html-escape","input":"<a>"})     => "html-escape",
        %({"spec":"url-encode-all","input":"ab"})   => "url-encode-all",
        %({"spec":"sha256","input":"hello"})        => "sha256",
        %({"spec":"shell-escape","input":"a b"})    => "shell-escape",
        %({"spec":"homoglyph","input":"ab"})        => "homoglyph",
      }.each { |args, conv| converters.call(erg_json(tools, "decode", args)).should eq([conv]), args }
      erg_json(tools, "decode", %({"spec":"base64-encode","input":"hello"}))["output"].as_s.should eq("aGVsbG8=")
    end
  end

  # The provider CRUD tools exist so an operator configures a private collaborator ONCE.
  # oast_start could not consume one: the agent had to re-supply host and token inline, and
  # tokens read back [REDACTED], so a token-bearing provider was unreachable from MCP.
  describe "oast_start provider_id" do
    it "registers against a saved provider, supplying its host" do
      with_store do |store|
        tools = tools_for(store)
        created = erg_json(tools, "create_oast_provider",
          %({"name":"House","kind":"custom-http","host":"https://oast.house.test","token":"t0ken"}))
        id = created["id"].as_s

        started = erg_json(tools, "oast_start", %({"provider_id":"#{id}"}))
        started["provider_id"].as_s.should eq(id)
        started["server"].as_s.should eq("https://oast.house.test")
        started["payload_url"].as_s.should contain("oast.house.test")
      end
    end

    it "refuses an unknown id, and names the ones that exist" do
      with_store do |store|
        tools = tools_for(store)
        erg_json(tools, "create_oast_provider",
          %({"name":"House","kind":"custom-http","host":"https://oast.house.test"}))

        r = tools.call("oast_start", JSON.parse(%({"provider_id":"p_404"})))
        r.is_error.should be_true
        r.text.should contain("no saved OAST provider")
        r.text.should contain("House")
      end
    end

    it "refuses a DISABLED provider rather than registering against it" do
      with_store do |store|
        tools = tools_for(store)
        id = erg_json(tools, "create_oast_provider",
          %({"name":"Off","kind":"custom-http","host":"https://off.test","enabled":false}))["id"].as_s

        r = tools.call("oast_start", JSON.parse(%({"provider_id":"#{id}"})))
        r.is_error.should be_true
        r.text.should contain("DISABLED")
        r.text.should contain("set_oast_provider_enabled")
      end
    end

    it "refuses provider_id together with an ad-hoc server/token" do
      with_store do |store|
        tools = tools_for(store)
        id = erg_json(tools, "create_oast_provider",
          %({"name":"House","kind":"custom-http","host":"https://oast.house.test"}))["id"].as_s

        r = tools.call("oast_start", JSON.parse(%({"provider_id":"#{id}","server":"https://other.test"})))
        r.is_error.should be_true
        r.text.should contain("not both")
      end
    end
  end
  # `Outbound` gates active sends on `Scope#configured?`, which reads the rules "REGARDLESS
  # of the enabled flag". `list_scope` reported only `enabled`, and its schema called that
  # "the scope lens/gate" — so `enabled:false` beside a populated rule list read as "sends
  # are ungated", and an agent whose send came back SCOPE_BLOCKED would reach for
  # `set_scope_enabled`, the one call that cannot change the outcome either way.
  describe "list_scope active-send gate" do
    it "reports the send gate as ON while the capture lens is off" do
      with_store do |store|
        tools = tools_for(store)
        erg_json(tools, "add_scope_rule", %({"pattern":"in.test","kind":"include","match_type":"host"}))
        erg_json(tools, "set_scope_enabled", %({"enabled":false}))

        scope = erg_json(tools, "list_scope", "{}")
        scope["enabled"].as_bool.should be_false # the capture lens really is off
        scope["active_send_gate"].as_s.should eq("rules")
        scope["active_send_gate_note"].as_s.should contain("whatever `enabled` says")

        # And the gate the field describes is the one that actually answers.
        blocked = tools.call("send_request", JSON.parse(%({"url":"http://out.test/"})))
        blocked.is_error.should be_true
        blocked.text.should contain("outside the project's configured scope")
      end
    end

    it "reports `unscoped` when no rules exist, where everything is refused" do
      with_store do |store|
        scope = erg_json(tools_for(store), "list_scope", "{}")
        scope["active_send_gate"].as_s.should eq("unscoped")
        scope["active_send_gate_note"].as_s.should contain("EVERY active request is refused")
      end
    end
  end
  # project_info is the orienting call, and `earliest_created_at` was its only timestamp — the
  # OLDEST flow in the project, handed to an agent whose actual question is how fresh the
  # capture is. On a long-running engagement that is wrong by the whole length of it.
  describe "project_info capture window" do
    it "reports both ends, not just the oldest" do
      with_store do |store|
        first = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_000_000_i64, scheme: "http", host: "a.test", port: 80,
          method: "GET", target: "/1", http_version: "HTTP/1.1",
          head: "GET /1 HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
        store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 9_000_000_i64, scheme: "http", host: "a.test", port: 80,
          method: "GET", target: "/2", http_version: "HTTP/1.1",
          head: "GET /2 HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
        first.should be > 0

        info = erg_json(tools_for(store), "project_info", "{}")
        info["earliest_created_at"].as_i64.should eq(1_000_000)
        info["latest_created_at"].as_i64.should eq(9_000_000)
        info["latest_created_at_iso"].as_s.should_not be_empty
      end
    end

    it "leaves both null on an empty project rather than inventing a window" do
      with_store do |store|
        info = erg_json(tools_for(store), "project_info", "{}")
        info["earliest_created_at"].raw.should be_nil
        info["latest_created_at"].raw.should be_nil
        info.as_h.has_key?("latest_created_at_iso").should be_false
      end
    end
  end

  # `create_project{description}` and `gori run project create --description` both STORE the
  # operator's note about what this engagement is for, and until now nothing headless ever
  # handed it back: an agent could write it and then never read it, its own included. The
  # orienting call is where it belongs — this one already holds the store open, while
  # `list_projects` deliberately opens no databases.
  describe "project_info description" do
    it "reads back the description a project was created with" do
      with_store do |store|
        store.set_setting(Gori::Project::DESCRIPTION_KEY, "staging sweep, prod is out of scope")
        info = erg_json(tools_for(store), "project_info", "{}")
        info["description"].as_s.should eq("staging sweep, prod is out of scope")
      end
    end

    it "is null for a project that was never described" do
      with_store do |store|
        info = erg_json(tools_for(store), "project_info", "{}")
        info.as_h.has_key?("description").should be_true # the field is always present
        info["description"].raw.should be_nil
      end
    end
  end
end
