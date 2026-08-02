require "./spec_helper"

# Round 5 stopped MCP masking the repeater's REQUEST bytes into the store
# (`spec/mcp_repeater_draft_provenance_spec.cr`) and left `target` / `sni` / `name` / `tags`
# masked, on the rationale that those are "short author-typed fields with no wire semantics
# of their own … re-expanded identically by every surface".
#
# Neither half of that survives contact with `sni`:
#
#   * `sni` IS the wire — it is the TLS `server_name` extension, the exact field a
#     vhost-confusion / certificate-routing / CDN-origin test exists to control — and
#     `target` is the dial tuple, which also supplies the ClientHello ServerName whenever
#     `sni` is absent.
#   * the two ends do NOT share a vocabulary. `Env.mask_secrets` resolves against
#     `Env.masking_vars`, which folds in every session-binding value currently held; the send
#     path resolves with `Env.effective_vars` (env vars only) and `Repeater::Plan` runs
#     `refuse_unresolved(Env.unresolved(s, deferred: nil))`, which refuses a declared binding
#     name outright. So a binding value masked into an SNI mints a `$NAME` that can never
#     resolve on any send path, from any surface. A one-way door — the author's string is gone
#     and the refusal names an env var they never wrote.
#
# `update_repeater` re-reads BOTH fields from the existing row when the caller did not supply
# them and re-masks, so a plain RENAME destroyed an SNI the CLI had stored correctly.
#
# The binding has to be BOUND INSIDE the driven server: `Bindings` persists rules, never held
# values, and `Tools#bind_binding_layer` installs a freshly-loaded (unbound) layer at bind
# time. So these drive a real `send_request` at a local origin first — which is exactly how
# an agent reaches this state.

private def with_store(&)
  path = File.tempname("gori-wirefield", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  prev_layer = Gori::Env.layer
  begin
    yield store
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# An origin that names the backend node that answered — the header the extract rule reads.
private def with_edge_origin(&)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 200 OK\r\nX-Served-By: prod-edge-07\r\nContent-Length: 0\r\n\r\n"
      conn.flush
      conn.close
    end
  end
  begin
    yield port
  ensure
    server.close
  end
end

private def drive(store, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

private def tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

private def call(tool : String, args : String, id : Int32 = 1) : String
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"#{tool}","arguments":#{args}}})
end

# The send that binds `$edge` to `prod-edge-07`, inside the server that will then be asked to
# store a repeater row.
private def bind_call(port : Int32, id : Int32 = 1) : String
  call("send_request", %({"url":"http://127.0.0.1:#{port}/health","allow_unscoped":true}), id)
end

private def edge_rule(store) : Nil
  Gori::Bindings.load(store).add("edge", "", Gori::ExtractKind::Header, "X-Served-By")
end

private AUTHORED_SNI    = "prod-edge-07.internal.example.com"
private AUTHORED_TARGET = "https://prod-edge-07.internal.example.com:8443/vhost"
private REQ             = "GET /vhost HTTP/1.1\r\nHost: front.example.com\r\n\r\n"

describe "MCP repeater rows keep the author's wire fields" do
  it "stores an SNI that collides with a live session binding verbatim" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        res = drive(store, bind_call(port),
          call("create_repeater",
            %({"target":"https://127.0.0.1:1/vhost","request":#{REQ.to_json},) +
            %("sni":#{AUTHORED_SNI.to_json},"name":"vhost-test"}), 2))
        row = store.get_repeater(tool_payload(res[1])["id"].as_i64).not_nil!
        row.sni.should eq(AUTHORED_SNI)
        # The pre-fix row, spelled out: `$edge` is a DECLARED BINDING name, and every send
        # path refuses one (`Env.unresolved(s, deferred: nil)`), so the row became unsendable
        # from every surface and the author's string unrecoverable.
        row.sni.should_not eq("$edge.internal.example.com")
        Gori::Env.unresolved(row.sni.not_nil!, deferred: nil).should be_empty
      end
    end
  end

  it "stores a target that collides with a live session binding verbatim" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        res = drive(store, bind_call(port),
          call("create_repeater",
            %({"target":#{AUTHORED_TARGET.to_json},"request":#{REQ.to_json}}), 2))
        row = store.get_repeater(tool_payload(res[1])["id"].as_i64).not_nil!
        row.target.should eq(AUTHORED_TARGET)
        Gori::Env.unresolved(row.target, deferred: nil).should be_empty
      end
    end
  end

  # THE AMPLIFIER. `update_repeater` falls back to the existing row for any field the caller
  # did not mention, so RENAMING a tab re-masked an SNI nobody touched — an agent tidying up
  # after itself permanently destroyed the operator's TLS ServerName.
  it "keeps the SNI and the target through a rename that mentions neither" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        rid = store.insert_repeater(target: AUTHORED_TARGET, request: REQ.to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0, sni: AUTHORED_SNI)
        drive(store, bind_call(port),
          call("update_repeater", %({"id":#{rid},"name":"vhost confusion test"}), 2))
        row = store.get_repeater(rid).not_nil!
        row.sni.should eq(AUTHORED_SNI)
        row.target.should eq(AUTHORED_TARGET)
        row.name.should eq("vhost confusion test")
      end
    end
  end

  # COMPLEMENT: an author who deliberately types a literal `$KEY` as the SNI gets it back
  # verbatim. The store holds bytes; resolving them is the send path's job, and this is the
  # documented way to reach a per-project SNI.
  it "stores a deliberately-typed literal $KEY SNI unchanged, and it still resolves" do
    with_store do |store|
      Gori::Env.save_project(store, [{"HOSTPART", "corpnet"}])
      res = drive(store, call("create_repeater",
        %({"target":"https://127.0.0.1:1/vhost","request":#{REQ.to_json},) +
        %("sni":"a.$HOSTPART.example.com"})))
      row = store.get_repeater(tool_payload(res[0])["id"].as_i64).not_nil!
      row.sni.should eq("a.$HOSTPART.example.com")
      Gori::Env.expand(row.sni.not_nil!, {"HOSTPART" => "corpnet"}, "$").should eq("a.corpnet.example.com")
    end
  end

  # COMPLEMENT: a session with no SNI is untouched — `nil` in, `nil` out, never an empty
  # string, which `Repeater::Plan` would read as "an SNI was requested".
  it "leaves a session with no SNI alone" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        res = drive(store, bind_call(port),
          call("create_repeater",
            %({"target":"https://127.0.0.1:1/vhost","request":#{REQ.to_json}}), 2))
        store.get_repeater(tool_payload(res[1])["id"].as_i64).not_nil!.sni.should be_nil
      end
    end
  end

  # COMPLEMENT: `name` is a TUI caption and never reaches a socket, so it KEEPS masking on the
  # way in. The rule is "does this become bytes the origin sees", not "did the author type
  # it" — this pins the other side of it so the fix is not read as "stop masking everything".
  it "still masks the tab NAME, which never reaches a socket" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        res = drive(store, bind_call(port),
          call("create_repeater",
            %({"target":"https://127.0.0.1:1/vhost","request":#{REQ.to_json},) +
            %("name":"node prod-edge-07"}), 2))
        store.get_repeater(tool_payload(res[1])["id"].as_i64).not_nil!.name.should eq("node $edge")
      end
    end
  end

  # COMPLEMENT: masking on the way OUT is a display transform and is deliberate. The reply the
  # agent reads must still spell the binding, even though the row does not.
  it "still masks the target in the reply it hands the agent" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        res = drive(store, bind_call(port),
          call("create_repeater",
            %({"target":#{AUTHORED_TARGET.to_json},"request":#{REQ.to_json}}), 2))
        payload = tool_payload(res[1])
        payload["target"].as_s.should eq("https://$edge.internal.example.com:8443/vhost")
        store.get_repeater(payload["id"].as_i64).not_nil!.target.should eq(AUTHORED_TARGET)
      end
    end
  end
end
