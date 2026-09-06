require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Server do
  describe "create_repeater and update_repeater" do
    it "creates a new repeater from raw payload and returns context fields" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"target":"https://api.test","request":"GET /x HTTP/1.1\\r\\nHost: api.test\\r\\n\\r\\n","name":"My Repeater Tab"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"]?.should_not be_true
        payload = mcp_tool_payload(resp)
        payload["id"].as_i64.should_not eq(0)
        payload["name"].as_s.should eq("My Repeater Tab")
        payload["target"].as_s.should eq("https://api.test")
        payload["summary"].as_s.should eq("GET /x")
        payload["position"].as_i64.should eq(0)

        # Let's test update_repeater
        id = payload["id"].as_i64
        upd_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_repeater","arguments":{"id":#{id},"target":"https://updated.test","name":"Updated Name"}}})
        resp2 = mcp_drive(store, upd_call)[0]
        resp2["result"]["isError"]?.should_not be_true
        payload2 = mcp_tool_payload(resp2)
        payload2["id"].as_i64.should eq(id)
        payload2["name"].as_s.should eq("Updated Name")
        payload2["target"].as_s.should eq("https://updated.test")
        payload2["summary"].as_s.should eq("GET /x")
      end
    end

    it "creates a new repeater from a flow_id" do
      with_store do |store|
        flow_id = mcp_seed_flow(store, "ex.test", "GET", "/flow-endpoint", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"flow_id":#{flow_id}}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("GET /flow-endpoint")
      end
    end

    it "creates a new repeater from a issue_id" do
      with_store do |store|
        flow_id = mcp_seed_flow(store, "ex.test", "POST", "/submit", 200)
        store.insert_issue("Vuln Title", Gori::Store::Severity::High, "ex.test", flow_id)
        store.flush
        issue_id = store.issues.first.id

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_repeater","arguments":{"issue_id":#{issue_id}}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["target"].as_s.should eq("https://ex.test")
        payload["summary"].as_s.should eq("POST /submit")
        links = store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id)
        links.any? { |link| link.ref_kind.repeater? && link.ref_id == payload["id"].as_i64 }.should be_true
      end
    end
  end

  describe "get_repeater_context" do
    it "lists persisted repeater sessions with last response status" do
      with_store do |store|
        store.insert_repeater("https://ex.test", "GET /x HTTP/1.1\nHost: ex.test\n\n".to_slice, false, true, nil, 0)
        id = store.repeaters_meta.last.id
        store.update_repeater_response(id, "HTTP/1.1 400 Bad\r\n\r\n".to_slice, "nope".to_slice, nil, 99_i64)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["sessions"].as_a.size.should eq(1)
        sess = payload["sessions"][0]
        sess["db_id"].as_i64.should eq(id)
        sess["last_status"].as_i64.should eq(400)
        sess.as_h.has_key?("request").should be_false
        sess.as_h.has_key?("last_response_head").should be_false
        payload["content_included"].as_bool.should be_false

        with_content = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"id":#{id},"include_content":true}}})
        detailed = mcp_tool_payload(mcp_drive(store, with_content)[0])
        detailed["sessions"].as_a.size.should eq(1)
        detailed["sessions"][0]["request"].as_s.should contain("GET /x")
        detailed["sessions"][0]["last_response_head"].as_s.should contain("400 Bad")
      end
    end

    it "base64-encodes a binary WebSocket frame (keeps the JSON-RPC stream valid UTF-8)" do
      with_store do |store|
        store.insert_repeater("wss://ex.test/ws",
          "GET /ws HTTP/1.1\r\nHost: ex.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice, false, true, nil, 0)
        id = store.repeaters_meta.last.id
        store.insert_ws_message(0_i64, "out", 1, "ping".to_slice, repeater_id: id)        # text frame
        store.insert_ws_message(0_i64, "in", 2, Bytes[0x00, 0xff, 0x80], repeater_id: id) # binary (invalid UTF-8)
        store.flush
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        msgs = mcp_tool_payload(mcp_drive(store, call)[0])["sessions"][0]["ws_messages"].as_a
        text = msgs.find { |m| m["opcode"].as_i == 1 }.not_nil!
        text["payload"].as_s.should eq("ping")
        bin = msgs.find { |m| m["opcode"].as_i == 2 }.not_nil!
        bin["binary"].as_bool.should be_true
        bin["payload_base64"].as_s.should eq(Base64.strict_encode(Bytes[0x00, 0xff, 0x80]))
        bin.as_h.has_key?("payload").should be_false # raw bytes never emitted as a string
      end
    end

    it "includes the live TUI repeater snapshot when ui_state carries it" do
      with_store do |store|
        ui = JSON.build do |j|
          j.object do
            j.field "active_tab", "repeater"
            j.field "focus_pane", "body"
            j.field "subtab", 0
            j.field "repeater" do
              j.object do
                j.field "count", 1
                j.field "active_subtab", 0
                j.field "active" do
                  j.object do
                    j.field "subtab", 0
                    j.field "db_id", 7
                    j.field "target", "https://ex.test"
                    j.field "http2", true
                    j.field "request", "GET /gw HTTP/2"
                  end
                end
              end
            end
          end
        end
        store.set_setting(Gori::Store::UI_STATE_KEY, ui)
        metadata = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{}}})
        metadata_payload = mcp_tool_payload(mcp_drive(store, metadata, project_name: "demo", project_slug: "demo")[0])
        metadata_payload.as_h.has_key?("tui_repeater").should be_false
        metadata_payload["tui_repeater_available"].as_bool.should be_true

        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call, project_name: "demo", project_slug: "demo")[0])
        payload["tui_on_repeater_tab"].as_bool.should be_true
        payload["tui_repeater"]["active"]["http2"].as_bool.should be_true
        payload["project_slug"].as_s.should eq("demo")
      end
    end

    it "redacts sensitive headers in the nested tui_repeater snapshot unless include_sensitive" do
      with_store do |store|
        req = "GET / HTTP/1.1\r\nHost: ex.test\r\nAuthorization: Bearer s3cr3t\r\nCookie: sid=abc\r\n\r\n"
        ui = JSON.build do |j|
          j.object do
            j.field "active_tab", "repeater"
            j.field "repeater" do
              j.object do
                j.field "count", 1
                j.field "active" do
                  j.object do
                    j.field "http2", false
                    j.field "request", req # NESTED under "active" — the real TUI shape
                  end
                end
              end
            end
          end
        end
        store.set_setting(Gori::Store::UI_STATE_KEY, ui)

        # Default (include_sensitive:false): the nested request's credential values must be redacted.
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true}}})
        redacted = mcp_tool_payload(mcp_drive(store, call, project_name: "demo", project_slug: "demo")[0])
        text = redacted["tui_repeater"]["active"]["request"].as_s
        text.should_not contain("s3cr3t")
        text.should_not contain("sid=abc")
        text.should contain("[REDACTED]")
        redacted["sensitive_headers_redacted"].as_bool.should be_true

        # include_sensitive:true passes the raw request through (matches the sessions[] policy).
        call2 = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_repeater_context","arguments":{"include_content":true,"include_sensitive":true}}})
        raw = mcp_tool_payload(mcp_drive(store, call2, project_name: "demo", project_slug: "demo")[0])
        raw["tui_repeater"]["active"]["request"].as_s.should contain("s3cr3t")
      end
    end
  end

  describe "compare_flows" do
    it "diffs two flows' response bodies line by line" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nline2\nline3".to_slice)
        b = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nCHANGED\nline3".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b}}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["pane"].as_s.should eq("response")
        payload["identical"].as_bool.should be_false
        payload["changed_lines"].as_i.should be > 0
        kinds = payload["diff"].as_a.map(&.["kind"].as_s)
        kinds.should contain("add")
        kinds.should contain("del")
      end
    end

    it "reports identical:true and zero changed_lines for identical flows" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "same".to_slice)
        b = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "same".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b}}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["identical"].as_bool.should be_true
        payload["changed_lines"].as_i.should eq(0)
      end
    end

    it "diffs the request pane when pane:request" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200)
        b = mcp_seed_flow(store, "a.test", "POST", "/y", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request"}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["pane"].as_s.should eq("request")
        payload["identical"].as_bool.should be_false
      end
    end

    it "redacts auth headers in the request-pane diff, reveals them with include_sensitive" do
      with_store do |store|
        a = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "https", host: "a.test", port: 443,
          method: "GET", target: "/x", http_version: "HTTP/1.1",
          head: "GET /x HTTP/1.1\r\nHost: a.test\r\nAuthorization: Bearer topsecret\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy))
        b = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 2_i64, scheme: "https", host: "a.test", port: 443,
          method: "GET", target: "/y", http_version: "HTTP/1.1",
          head: "GET /y HTTP/1.1\r\nHost: a.test\r\nAuthorization: Bearer topsecret\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Proxy))

        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request"}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        texts = payload["diff"].as_a.map(&.["text"].as_s)
        texts.any?(&.includes?("Authorization: [REDACTED]")).should be_true
        texts.any?(&.includes?("topsecret")).should be_false

        sensitive_call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"pane":"request","include_sensitive":true}}})
        sensitive_payload = mcp_tool_payload(mcp_drive(store, sensitive_call)[0])
        sensitive_texts = sensitive_payload["diff"].as_a.map(&.["text"].as_s)
        sensitive_texts.any?(&.includes?("Bearer topsecret")).should be_true
      end
    end

    it "changes_only omits unchanged (same) lines from the diff" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nline2\nline3".to_slice)
        b = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: "line1\nCHANGED\nline3".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"changes_only":true}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["diff"].as_a.map(&.["kind"].as_s).should_not contain("same")
      end
    end

    # `changes_only` answers "what changed" but erases WHERE: a body of 40 identical lines
    # with one edit comes back as two lines with no position. `context` keeps the change in
    # place and states how much it skipped, so an agent can quote a real region.
    it "context folds unchanged runs into counted markers instead of dropping them" do
      with_store do |store|
        body = ->(mid : String) { (1..40).map { |i| i == 20 ? mid : "line#{i}" }.join("\n") }
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: body.call("BEFORE").to_slice)
        b = mcp_seed_flow(store, "a.test", "GET", "/x", 200, resp_body: body.call("AFTER").to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"context":3}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        rows = payload["diff"].as_a
        folds = rows.select { |r| r["kind"].as_s == "fold" }
        folds.size.should be > 0
        folds.each(&.["hidden"].as_i.should(be > 1))
        texts = rows.compact_map { |r| r["text"]?.try(&.as_s) }
        texts.any?(&.includes?("BEFORE")).should be_true
        texts.any?(&.includes?("line19")).should be_true # context kept
        texts.any?(&.includes?("line5")).should be_false # …and the distance folded away
        rows.size.should be < 40
      end
    end

    it "refuses context together with changes_only rather than silently picking one" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200)
        b = mcp_seed_flow(store, "a.test", "GET", "/y", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b},"context":3,"changes_only":true}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
      end
    end

    # The first answer to most comparisons is not in the body: a status flip, a size shift.
    it "reports each side's status/size/time and the A→B delta" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/admin", 403, resp_body: "no".to_slice)
        b = mcp_seed_flow(store, "a.test", "GET", "/admin", 200, resp_body: "yes ok".to_slice)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":#{b}}}})
        payload = mcp_tool_payload(mcp_drive(store, call)[0])
        payload["meta"]["a"]["status"].as_i.should eq(403)
        payload["meta"]["b"]["status"].as_i.should eq(200)
        payload["meta"]["delta"].as_s.should contain("403 → 200")
      end
    end

    it "returns NOT_FOUND for a missing flow id" do
      with_store do |store|
        a = mcp_seed_flow(store, "a.test", "GET", "/x", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"compare_flows","arguments":{"flow_id_a":#{a},"flow_id_b":999999}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("NOT_FOUND")
      end
    end
  end
end

describe "MCP repeater tags" do
  it "sets and clears tags through update_repeater, and lists them back" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      tools = tools_for(store)

      mcp_ok_json(tools, "update_repeater", %({"id":#{id},"tags":"auth prod"}))
      # repeaters_mcp is the loader every listing surface reads — it must SELECT tags,
      # or a stored tag reads back as nil everywhere but the TUI.
      store.repeaters_mcp.first.tags.should eq("auth prod")

      mcp_ok_json(tools, "update_repeater", %({"id":#{id},"tags":""}))
      store.repeaters_mcp.first.tags.should be_nil
    end
  end
end

describe "MCP minimize_repeater" do
  it "refuses a WebSocket session, an unknown id, and a bad scheme" do
    with_store do |store|
      ws = store.insert_repeater("https://acme.test/",
        "GET /ws HTTP/1.1\r\nHost: acme.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
        false, true, nil, 0)
      bad = store.insert_repeater("ftp://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 1)
      tools = tools_for(store)

      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":9999}))).is_error.should be_true
      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{ws}}))).is_error.should be_true
      tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{bad}}))).is_error.should be_true
    end
  end

  it "refuses an out-of-scope target before sending anything" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      tools = tools_for(store)

      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}})))
      r.is_error.should be_true
      r.text.should contain("scope")
    end
  end

  it "refuses a sandbox-blocked target even under allow_unscoped" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      scope.enable_sandbox
      tools = tools_for(store)

      # allow_unscoped bypasses the include gate but NEVER the sandbox — same two-layer
      # model the other active tools use.
      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id},"allow_unscoped":true})))
      r.is_error.should be_true
      r.text.should contain("sandbox")
    end
  end

  it "is refused under --read-only (it sends real requests)" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/", "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
        false, true, nil, 0)
      ro = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      ro.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}}))).is_error.should be_true
    end
  end
end

describe "code-review follow-ups" do
  it "refuses to minimize a repeater whose saved request holds §fuzz§ markers" do
    with_store do |store|
      id = store.insert_repeater("https://acme.test/",
        "GET /a?id=§1§ HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, false, true, nil, 0)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      tools = tools_for(store)

      # A marked-up template is not a request: minimizing it would send real requests full of
      # literal § bytes, and apply:true would overwrite the user's template with the result.
      r = tools.call("minimize_repeater", JSON.parse(%({"repeater_id":#{id}})))
      r.is_error.should be_true
      r.text.should contain("marker")
      # Untouched.
      String.new(store.get_repeater(id).not_nil!.request).should contain("§1§")
    end
  end

  it "flags a sitemap tag whose path matches no captured endpoint" do
    with_store do |store|
      mcp_seed_flow(store, "/api/users")
      tools = tools_for(store)

      hit = mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/api/users","tag":"ok"}))
      hit["matches_endpoint"].as_bool.should be_true
      hit.as_h.has_key?("warning").should be_false

      # Sitemap.add drops a trailing slash, so /api/users/ is a key no node ever has.
      miss = mcp_ok_json(tools, "set_sitemap_tag", %({"host":"acme.test","path":"/api/users/","tag":"typo"}))
      miss["matches_endpoint"].as_bool.should be_false
      miss["warning"].as_s.should contain("no captured endpoint")
    end
  end
end

describe "MCP update_repeater" do
  it "masks a secret in the summary it hands back" do
    with_store do |store|
      Gori::Env.save_project(store, [{"TOKEN", "s3cr3t-value"}])
      tools = tools_for(store)
      created = mcp_ok_json(tools, "create_repeater",
        %({"target":"https://acme.test","request":"GET / HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))

      updated = mcp_ok_json(tools, "update_repeater",
        %({"id":#{created["id"]},"request":"GET /a?token=s3cr3t-value HTTP/1.1\\r\\nHost: acme.test\\r\\n\\r\\n"}))
      updated["summary"].as_s.should_not contain "s3cr3t-value"
      updated["summary"].as_s.should contain "$TOKEN"
    end
  end
end
