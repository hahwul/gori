require "../spec_helper"
require "../support/mcp_harness"
require "socket"

private def prepared_fuzz_args(target : String = "http://127.0.0.1:9") : JSON::Any
  JSON.parse({"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: h\r\n\r\n",
              "url" => target, "payloads" => [{"list" => ["a", "b"]}], "name" => "review me"}.to_json)
end

describe "MCP create_fuzzer" do
  it "creates with Send traffic off, without opening a connection or launching a job" do
    with_store do |store|
      origin = TCPServer.new("127.0.0.1", 0)
      accepted = Channel(Bool).new(1)
      spawn do
        if conn = origin.accept?
          accepted.send(true)
          conn.close
        end
      end
      begin
        tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false,
          denied_permissions: Set{"send"})
        args = prepared_fuzz_args("http://127.0.0.1:#{origin.local_address.port}")
        args.as_h["auto_calibrate"] = JSON::Any.new(true) # validation must not sample the origin
        result = tools.call("create_fuzzer", args)
        result.is_error.should be_false, result.text
        receipt = JSON.parse(result.text)
        receipt["total"].as_i64.should eq(2_i64)
        receipt["name"].as_s.should eq("review me")
        row = store.get_fuzz_session(receipt["id"].as_i64).not_nil!
        row.template.should eq(args["template"].as_s)
        store.fuzz_runs.size.should eq(0)
        store.recent_agent_actions(0_i64, 10).any? { |e| e.payload == "create_fuzzer" }.should be_true
        select
        when accepted.receive
          fail "create_fuzzer opened a socket"
        when timeout(30.milliseconds)
        end
      ensure
        origin.close
      end
    end
  end

  it "leaves the catalogue and refuses calls when Editing project data is off" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, denied_permissions: Set{"write"})
      listed = JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
      listed.should_not contain("create_fuzzer")
      tools.call("create_fuzzer", prepared_fuzz_args).error_code.should eq("TOOL_DISABLED")
      store.fuzz_sessions.should be_empty
    end
  end

  ["no positions", "unresolved env", "bad payload"].each do |kind|
    it "refuses #{kind} exactly as fuzz_start does and writes no tab" do
      with_store do |store|
        with_env_syntax(Gori::Env::Syntax::Namespaced) do
          tools = tools_for(store)
          args = prepared_fuzz_args
          case kind
          when "no positions"   then args.as_h["template"] = JSON::Any.new("GET / HTTP/1.1\r\n\r\n")
          when "unresolved env" then args.as_h["template"] = JSON::Any.new("GET /$ENV.GORI_MISSING_1910/§x§ HTTP/1.1\r\n\r\n")
          when "bad payload"    then args.as_h["payloads"] = JSON.parse(%([{"numbers":"broken"}]))
          end
          args.as_h.delete("name")
          run = tools.call("fuzz_start", args)
          create = tools.call("create_fuzzer", args)
          run.is_error.should be_true
          create.is_error.should be_true, "run=#{run.text}, create=#{create.text}"
          create.error_code.should eq(run.error_code)
          create.text.should eq(run.text), "run=#{run.text}, create=#{create.text}"
          store.fuzz_sessions.should be_empty
        end
      end
    end
  end

  it "keeps author bytes in storage and masks the target in the receipt" do
    with_store_env do |store|
      Gori::Env.set_project_var(store, "PREP1910", "secret1910")
      args = prepared_fuzz_args("http://secret1910.test")
      args.as_h["template"] = JSON::Any.new("GET /secret1910/§x§ HTTP/1.1\nHost: h\n\n")
      result = tools_for(store).call("create_fuzzer", args)
      result.is_error.should be_false, result.text
      row = store.fuzz_sessions.first
      row.template.should eq(args["template"].as_s)
      row.target.should eq("http://secret1910.test")
      result.text.should_not contain("secret1910")
    end
  end

  it "refuses run-only arguments rather than dropping them" do
    with_store do |store|
      %w[save_results record_history allow_unscoped].each do |key|
        args = prepared_fuzz_args
        args.as_h[key] = JSON::Any.new(true)
        result = tools_for(store).call("create_fuzzer", args)
        result.error_code.should eq("INVALID_ARGUMENT")
      end
      store.fuzz_sessions.should be_empty
    end
  end

  it "gates an exec chain with the same off and ask permissions as a run" do
    posix_only!("exec chain path")
    with_store do |store|
      args = prepared_fuzz_args
      args.as_h["template"] = JSON::Any.new("GET /§x¦exec:/usr/bin/false§ HTTP/1.1\r\n\r\n")
      off = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, denied_permissions: Set{"exec"})
      off.call("create_fuzzer", args).error_code.should eq("TOOL_DISABLED")
      ask = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false, asked_permissions: Set{"exec"})
      ask.call("create_fuzzer", args).error_code.should eq("APPROVAL_PENDING")
      store.fuzz_sessions.should be_empty
    end
  end
end

describe "MCP fuzz exec steps supplied by an env value" do
  # `§x¦$P§` passes the exec gate while P is benign; once P names a command the builder refuses
  # whatever `exec` says, in its own words rather than as a permission refusal.
  it "refuses create_fuzzer and fuzz_start with exec allowed, and stores nothing" do
    with_store_env do |store|
      Gori::Env.set_project_var(store, "P", "exec:/usr/bin/true")
      Gori::Settings.project_env_vars = [{"P", "exec:/usr/bin/true"}]
      args = prepared_fuzz_args
      args.as_h["template"] = JSON::Any.new("GET /?q=§x¦$P§ HTTP/1.1\r\nHost: h\r\n\r\n")
      tools = tools_for(store)
      created = tools.call("create_fuzzer", args)
      created.error_code.should eq("INVALID_ARGUMENT")
      created.text.should contain(Gori::Fuzz::Plan::ENV_COMMAND_REFUSAL)
      store.fuzz_sessions.should be_empty
      args.as_h.delete("name")
      args.as_h["allow_unscoped"] = JSON::Any.new(true)
      started = tools.call("fuzz_start", args)
      started.error_code.should eq("INVALID_ARGUMENT")
      started.text.should contain(Gori::Fuzz::Plan::ENV_COMMAND_REFUSAL)
    end
  end
end

describe "MCP prepared Fuzzer execution" do
  it "advertises every run input except the three run-only options, plus name" do
    tools = Gori::MCP::Tools.catalogue_json(nil, true)
    catalogue = JSON.parse(tools).as_a.index_by(&.["name"].as_s)
    run = catalogue["fuzz_start"]["inputSchema"]["properties"].as_h.keys
    create = catalogue["create_fuzzer"]["inputSchema"]["properties"].as_h.keys
    create.sort.should eq(((run - %w[save_results record_history allow_unscoped]) + ["name"]).sort)
  end

  it "runs expanded marking and processors from the restored tab, after creation sent nothing" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store_env do |store|
        Gori::Env.set_project_var(store, "SEED1910", "abc")
        origin = TCPServer.new("127.0.0.1", 0)
        received = Channel(String).new(1)
        spawn do
          if conn = origin.accept?
            head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
            received.send(String.new(head))
            conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            conn.close
          end
        end
        begin
          args = JSON.parse({"url" => "http://127.0.0.1:#{origin.local_address.port}",
                             "template" => "GET /$ENV.SEED1910 HTTP/1.1\r\nHost: h\r\n\r\n",
                             "marks" => ["abc"], "payloads" => [{"list" => ["p"]}],
                             "processors" => [{"type" => "prefix", "text" => "X"}],
                             "timeout_ms" => 1500}.to_json)
          tools = Gori::MCP::Tools.new(store, true, false, denied_permissions: Set{"send"})
          created = tools.call("create_fuzzer", args)
          created.is_error.should be_false, created.text
          row = store.fuzz_sessions.first
          row.template.should eq(args["template"].as_s)
          view = Gori::Tui::FuzzerView.new
          view.restore(row)
          view.run_request_count.should eq(1_i64)
          view.config.timeout.should eq(1500.milliseconds)
          view.apply_advanced(view.advanced_snapshot) # opening and applying must retain all options
          engine, error = view.build_engine(false, Gori::Scope.load(store), project: store)
          error.should be_nil
          done = false
          engine.not_nil!.run { |event| done = true if event.is_a?(Gori::Fuzz::DoneEvent) }
          done.should be_true
          received.receive.should start_with("GET /Xp HTTP/1.1")
          view.config.timeout.should eq(1500.milliseconds)
        ensure
          origin.close
        end
      end
    end
  end

  it "runs the restored WebSocket script with its payload processors" do
    with_store do |store|
      port = start_mcp_ws_origin
      args = JSON.parse({"url" => "http://127.0.0.1:#{port}",
                         "template" => "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
                         "messages" => [{"text" => "§x§"}], "payloads" => [{"list" => ["p"]}],
                         "processors" => [{"type" => "suffix", "text" => "!"}], "idle_ms" => 100}.to_json)
      created = tools_for(store).call("create_fuzzer", args)
      created.is_error.should be_false, created.text
      view = Gori::Tui::FuzzerView.new
      view.restore(store.fuzz_sessions.first)
      view.run_request_count.should eq(1_i64)
      engine, error = view.build_engine(false, Gori::Scope.load(store), project: store)
      error.should be_nil
      results = [] of Gori::Fuzz::Result
      engine.not_nil!.run { |event| results << event.result if event.is_a?(Gori::Fuzz::ResultEvent) }
      results.size.should eq(1)
      results.first.error.should be_nil
      results.first.ws_frames_in.should_not be_nil
      String.new(results.first.body.not_nil!).should contain("p!")
    end
  end

  it "round-trips the additional config, stop predicate, race warmup and macro definition" do
    with_store do |store|
      args = prepared_fuzz_args
      extras = JSON.parse(<<-JSON).as_h
        {"max_redirects":9,"sse_max_events":3,"sse_max_ms":2300,"no_encode":true,
        "insecure":true,"verbatim":true,"keep":"interesting","include_sensitive":true,
        "stop_on":{"after_matches":3,"match":{"header":"X-A: b","lines":">2"},"filter":{"regex":"bad"}},
        "macro_steps":["future login"],"macro_every":"off","macro_expect":["CSRF"],"macro_on_failure":"stop"}
        JSON
      args.as_h.merge!(extras)
      created = tools_for(store).call("create_fuzzer", args)
      created.is_error.should be_false, created.text
      view = Gori::Tui::FuzzerView.new
      view.restore(store.fuzz_sessions.first)
      engine, error = view.build_engine(true, Gori::Scope.load(store), project: store)
      error.should be_nil
      engine.should_not be_nil
      state = Gori::Fuzz::SessionConfig.new
      state.apply_json(view.config_json).should be_true
      saved = state.options.not_nil!
      saved.max_redirects.should eq(9)
      saved.sse_events.should eq(3)
      saved.sse_ms.should eq(2300_i64)
      saved.auto_encode?.should be_false
      saved.verbatim?.should be_true
      saved.verify?.should be_false
      saved.include_sensitive?.should be_true
      state.config.keep.should eq(Gori::Fuzz::Keep::Interesting)
      state.config.stop_after_matches.should eq(3)
      view.matcher.stop_condition.not_nil!.match_header.should eq("X-A: b")
      view.matcher.stop_condition.not_nil!.match_lines.should eq(">2")
      view.matcher.stop_condition.not_nil!.filter_regex.not_nil!.source.should eq("bad")
      view.config.request_macro.not_nil!.steps.should eq(["future login"])
      view.config.request_macro.not_nil!.cadence.off?.should be_true
      view.config.request_macro.not_nil!.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)

      race = JSON.parse({"url" => "http://h", "template" => "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
                         "race_count" => 3, "race_warmup" => "GET /warm HTTP/1.1\r\nHost: h\r\n\r\n"}.to_json)
      result = tools_for(store).call("create_fuzzer", race)
      result.is_error.should be_false, result.text
      view.restore(store.fuzz_sessions.last)
      built, error = view.build_engine(false, Gori::Scope.load(store), project: store)
      error.should be_nil
      built.not_nil!.race_count.should eq(3)
      view.config.race_warmup.should eq("GET /warm HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
    end
  end

  it "keeps malformed extension data inert through an Advanced edit and save" do
    with_store do |store|
      config = %({"sets":[{"kind":"list","value":"x,y"}],"plan_options":{"future_option":true}})
      id = store.insert_fuzz_session("http://h", "GET /§x§ HTTP/1.1\r\n\r\n", false, nil, config, nil, 0)
      view = Gori::Tui::FuzzerView.new
      view.restore(store.get_fuzz_session(id).not_nil!)
      view.apply_advanced(view.advanced_snapshot)
      engine, error = view.build_engine(false, Gori::Scope.load(store))
      engine.should be_nil
      error.not_nil!.should contain("cannot be read")
      JSON.parse(view.config_json)["plan_options"]["future_option"].as_bool.should be_true
    end
  end
end

describe "Prepared option edits" do
  it "clears extension-owned config before an immediate rerun or peer restore" do
    with_store do |store|
      args = JSON.parse({"url" => "http://h", "template" => "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
                         "race_count" => 3, "race_warmup" => "GET /warm HTTP/1.1\r\nHost: h\r\n\r\n"}.to_json)
      tools_for(store).call("create_fuzzer", args).is_error.should be_false
      row = store.fuzz_sessions.first
      view = Gori::Tui::FuzzerView.new
      view.restore(row)
      view.build_engine(false, Gori::Scope.load(store)).first.should_not be_nil
      view.config.race_warmup.should_not be_nil
      view.apply_advanced(view.advanced_snapshot.copy_with(plan_options: ""))
      view.build_engine(false, Gori::Scope.load(store)).first.should_not be_nil
      view.config.race_warmup.should be_nil
      view.restore(row)
      view.build_engine(false, Gori::Scope.load(store)).first.should_not be_nil
      view.config.race_warmup.should_not be_nil
      view.apply_peer_session(Gori::Store::FuzzSessionRecord.new(row.id, row.target, row.template,
        false, nil, %({"race_count":3}), nil, 0))
      view.build_engine(false, Gori::Scope.load(store)).first.should_not be_nil
      view.config.race_warmup.should be_nil
    end
  end
end

describe "Prepared Repeater capture provenance" do
  it "keeps captured variables and bare LF literal after restoring a Repeater seed" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store_env do |store|
        Gori::Env.set_project_var(store, "CAPTURE1910", "must-not-expand")
        head = "GET /?q=x&literal=$ENV.CAPTURE1910 HTTP/1.1\nHost: h\n\n"
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(created_at: 1_i64,
          scheme: "http", host: "h", port: 80, method: "GET", target: "/?q=x&literal=$ENV.CAPTURE1910",
          http_version: "HTTP/1.1", head: head.to_slice, source: Gori::FlowSource::Kind::Proxy))
        tools = tools_for(store)
        repeater = mcp_ok_json(tools, "create_repeater", {"flow_id" => fid}.to_json)["id"].as_i64
        args = JSON.parse({"repeater_id" => repeater, "marks" => ["x"], "payloads" => [{"list" => ["p"]}]}.to_json)
        created = tools.call("create_fuzzer", args)
        created.is_error.should be_false, created.text
        view = Gori::Tui::FuzzerView.new
        view.restore(store.fuzz_sessions.first)
        view.evidence?.should be_true
        engine, error = view.build_engine(false, Gori::Scope.load(store), project: store)
        error.should be_nil
        engine.not_nil!.total.should eq(1_i64)
        view.begin_run(1_i64)
        row = Gori::Fuzz::Result.new(0_i64, ["p"], nil, 200, 2_i64, 1, 1, 1_i64, nil, false, false, nil)
        view.append_result(row)
        request = String.new(view.result_request(row).bytes)
        request.should contain("q=p&literal=$ENV.CAPTURE1910")
        request.should_not contain("must-not-expand")
        request.should_not contain("\r\n")
        view.finish_run
        view.apply_advanced(view.advanced_snapshot.copy_with(plan_options: ""))
        view.apply_set(0, Gori::Tui::SetSpec.new(:null, "1"))
        view.build_engine(false, Gori::Scope.load(store), project: store).first.should_not be_nil
        view.begin_run(1_i64)
        plain = Gori::Fuzz::Result.new(0_i64, [""], nil, 200, 2_i64, 1, 1, 1_i64, nil, false, false, nil)
        view.append_result(plain)
        String.new(view.result_request(plain).bytes).should_not contain("\r\n")
      end
    end
  end
end
