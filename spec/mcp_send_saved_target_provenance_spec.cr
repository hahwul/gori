require "./spec_helper"

# `send_request{save_as_repeater:true}` masked the saved row's TARGET.
#
# Round 5 already stopped this seam masking the saved REQUEST bytes, on the ground that "a
# saved session is a REPLAY source before it is a display". The target is the same kind of
# thing and was left masked anyway: it is the dial tuple, and — with `sni: nil` on this path,
# always — it is what supplies the TLS ClientHello ServerName too. It is not a caption.
#
# What makes masking it destructive rather than cosmetic is that the two ends do not share a
# vocabulary. `Env.mask_secrets` resolves against `Env.masking_vars`, which folds in every
# session-binding value currently held; the send path resolves with `Env.effective_vars` (env
# vars only) and `Repeater::Plan` runs `refuse_unresolved(Env.unresolved(s, deferred: nil))`,
# which refuses a DECLARED binding name outright. A binding value masked in here therefore
# mints a `$NAME` that can never resolve on any send path from any surface — a one-way door,
# with the author's string gone and a refusal naming an env var they never wrote.
#
# The binding has to be BOUND INSIDE the driven server: `Bindings` persists rules, never held
# values. So these drive a real `send_request` at a local origin first, which is exactly how
# an agent reaches this state. Sibling coverage for `create_repeater` / `update_repeater`
# lives in `spec/mcp_repeater_wire_field_provenance_spec.cr`.

private def with_store(&)
  path = File.tempname("gori-sendtarget", ".db")
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
# save a repeater row.
private def bind_call(port : Int32, id : Int32 = 1) : String
  call("send_request", %({"url":"http://127.0.0.1:#{port}/health","allow_unscoped":true}), id)
end

private def edge_rule(store) : Nil
  Gori::Bindings.load(store).add("edge", "", Gori::ExtractKind::Header, "X-Served-By")
end

# The host an operator running a vhost-confusion test types. Pinned to the loopback origin by
# a project host override, so the send is real and the saved row is the row a real send made.
private EDGE_HOST = "prod-edge-07.internal.example.com"

private def pin_edge_host(store, port : Int32) : Nil
  Gori::HostOverrides.load(store).add(EDGE_HOST, "127.0.0.1").should be_true
end

describe "MCP send_request(save_as_repeater) keeps the author's target" do
  it "saves a target that collides with a live session binding verbatim" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        pin_edge_host(store, port)
        res = drive(store, bind_call(port),
          call("send_request",
            %({"url":"http://#{EDGE_HOST}:#{port}/vhost","method":"GET",) +
            %("save_as_repeater":true,"allow_unscoped":true}), 2))
        payload = tool_payload(res[1])
        row = store.get_repeater(payload["saved_repeater_id"].as_i64).not_nil!
        row.target.should eq("http://#{EDGE_HOST}:#{port}")
        # The pre-fix row, spelled out. `$edge` is a DECLARED BINDING name and every send path
        # refuses one, so the row became unsendable from every surface at once.
        row.target.should_not eq("http://$edge.internal.example.com:#{port}")
        Gori::Env.unresolved(row.target, deferred: nil).should be_empty
      end
    end
  end

  # The consequence, end to end: the saved row must still build a plan. Before the fix this
  # raised `UnresolvedEnv` naming `$edge` — in the very process where `$edge` WAS bound, since
  # the send path only consults env vars.
  it "leaves the saved row replayable" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        pin_edge_host(store, port)
        res = drive(store, bind_call(port),
          call("send_request",
            %({"url":"http://#{EDGE_HOST}:#{port}/vhost","method":"GET",) +
            %("save_as_repeater":true,"allow_unscoped":true}), 2))
        row = store.get_repeater(tool_payload(res[1])["saved_repeater_id"].as_i64).not_nil!
        plan = Gori::Repeater::Plan.build(
          Gori::Repeater::PlanOptions.new([row.request], target: row.target,
            overrides: Gori::HostOverrides.load(store), verify: false), ungated_outbound)
        plan.host.should eq(EDGE_HOST)
        plan.port.should eq(port)
      end
    end
  end

  # COMPLEMENT: `name` is a TUI tab caption and never reaches a socket, so it KEEPS masking on
  # the way in. The rule is "does this field become bytes the origin sees", not "did the author
  # type it" — pinned here so the fix is not read as "stop masking everything".
  it "still masks the tab NAME, which never reaches a socket" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        pin_edge_host(store, port)
        res = drive(store, bind_call(port),
          call("send_request",
            %({"url":"http://#{EDGE_HOST}:#{port}/vhost","method":"GET","save_as_repeater":true,) +
            %("name":"node prod-edge-07","allow_unscoped":true}), 2))
        row = store.get_repeater(tool_payload(res[1])["saved_repeater_id"].as_i64).not_nil!
        row.name.should eq("node $edge")
        row.target.should eq("http://#{EDGE_HOST}:#{port}")
      end
    end
  end

  # COMPLEMENT: the reply the agent reads is untouched. This tool's reply never carried a
  # target field at all — which is the whole point: `masked_target` existed for the STORE
  # alone, the one place a masked projection must not go. What the reply does carry
  # (`effective_request`, the description of the bytes that went out) is unchanged, and it was
  # never masked, before or after.
  it "does not change the reply the agent reads" do
    with_store do |store|
      edge_rule(store)
      with_edge_origin do |port|
        pin_edge_host(store, port)
        res = drive(store, bind_call(port),
          call("send_request",
            %({"url":"http://#{EDGE_HOST}:#{port}/vhost","method":"GET",) +
            %("save_as_repeater":true,"allow_unscoped":true}), 2))
        payload = tool_payload(res[1])
        payload["status"].as_i.should eq(200)
        payload["saved_repeater_id"].as_i64.should be > 0
        payload.as_h.has_key?("target").should be_false
        payload["effective_request"]["host"].as_s.should eq(EDGE_HOST)
      end
    end
  end

  # COMPLEMENT: an author who deliberately types a literal `$KEY` in the url. On THIS path the
  # stored target is the RESOLVED dial tuple by construction (`built.scheme/host/port` — the
  # builder expanded the url before it dialled), so the round-trip property is that the row
  # holds the value that was actually reached and stays sendable. `mask_secrets` was the one
  # thing that could take a resolvable target and make it unresolvable.
  it "stores the resolved dial tuple for a url the author wrote with a $KEY" do
    with_store do |store|
      with_edge_origin do |port|
        Gori::Env.save_project(store, [{"EDGEHOST", "127.0.0.1"}])
        res = drive(store, call("send_request",
          %({"url":"http://$EDGEHOST:#{port}/vhost","method":"GET",) +
          %("save_as_repeater":true,"allow_unscoped":true})))
        row = store.get_repeater(tool_payload(res[0])["saved_repeater_id"].as_i64).not_nil!
        row.target.should eq("http://127.0.0.1:#{port}")
        Gori::Env.unresolved(row.target, deferred: nil).should be_empty
      end
    end
  end

  # CONTROL: with no binding rule at all, the row is the same either way. Pins that the fix is
  # about the collision and not a general change of what gets stored.
  it "stores the same target when nothing collides" do
    with_store do |store|
      with_edge_origin do |port|
        res = drive(store, call("send_request",
          %({"url":"http://127.0.0.1:#{port}/vhost","method":"GET",) +
          %("save_as_repeater":true,"allow_unscoped":true})))
        row = store.get_repeater(tool_payload(res[0])["saved_repeater_id"].as_i64).not_nil!
        row.target.should eq("http://127.0.0.1:#{port}")
      end
    end
  end
end
